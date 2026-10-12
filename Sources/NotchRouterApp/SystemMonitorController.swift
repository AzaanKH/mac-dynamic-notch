import AppKit
import Observation
import CoreWLAN
import Darwin
import Dispatch
import Foundation
import Network

enum MemoryPressureLevel: String, Equatable, Sendable {
  case normal = "Normal"
  case warning = "Warning"
  case critical = "Critical"
}

enum ThermalCondition: String, Equatable, Sendable {
  case nominal = "Nominal"
  case fair = "Fair"
  case serious = "Serious"
  case critical = "Critical"
}

struct SystemSnapshot: Equatable, Sendable {
  var cpuUsage = 0.0
  var memoryUsed: UInt64 = 0
  var memoryTotal: UInt64 = 0
  var memoryPressure: MemoryPressureLevel = .normal
  var diskFree: Int64 = 0
  var diskTotal: Int64 = 0
  var thermalCondition: ThermalCondition = .nominal
  var isLowPowerModeEnabled = false
}

struct NetworkSnapshot: Equatable, Sendable {
  var isOnline = false
  var interfaceName = "Offline"
  var wifiSignal: Int?
  var hasVPN = false
  var isConstrained = false
  var isExpensive = false
  var downloadBytesPerSecond = 0.0
  var uploadBytesPerSecond = 0.0
  var receivedSinceLaunch: UInt64 = 0
  var sentSinceLaunch: UInt64 = 0
}

enum ConnectionTestState: Equatable, Sendable {
  case idle
  case testing
  case success(milliseconds: Int)
  case failed(String)
}

@MainActor
@Observable
final class SystemMonitorController {
  static let enabledPreferenceKey = "systemSectionEnabled"

  private(set) var isEnabled: Bool
  private(set) var system = SystemSnapshot()
  private(set) var network = NetworkSnapshot()
  private(set) var connectionTest: ConnectionTestState = .idle

  private let defaults: UserDefaults
  private let lowPowerMode: () -> Bool
  private let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
  @ObservationIgnored nonisolated(unsafe) private var timer: Timer?
  private var isSystemSectionVisible = false
  private var isDisplaySleeping = false
  var samplingInterval: TimeInterval? { timer?.timeInterval }
  @ObservationIgnored private var pathMonitor: NWPathMonitor?
  private let pathQueue = DispatchQueue(label: "com.notchrouter.network-path")
  @ObservationIgnored private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
  @ObservationIgnored nonisolated(unsafe) private var notificationObservers: [NSObjectProtocol] = []
  @ObservationIgnored nonisolated(unsafe) private var workspaceObservers: [NSObjectProtocol] = []
  private var previousCPUTicks: CPUTicks?
  private var previousNetworkCounters: InterfaceCounters?
  private var previousNetworkSampleUptime: TimeInterval?
  private var monitoredInterfaceNames: Set<String> = []
  private var pathHasVPN = false
  private var receivedSinceLaunch: UInt64 = 0
  private var sentSinceLaunch: UInt64 = 0
  @ObservationIgnored private var connectionTestTask: Task<Void, Never>?
  @ObservationIgnored private var diskRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var sampleTask: Task<Void, Never>?
  private var pathUsesWiFi = false
  private var pathGeneration: UInt = 0
  private var previousWiFiRefreshUptime: TimeInterval?
  private var previousDiskRefreshUptime: TimeInterval?

  private static let diskRefreshInterval: TimeInterval = 30

  init(
    defaults: UserDefaults = .standard,
    lowPowerMode: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
  ) {
    self.defaults = defaults
    self.lowPowerMode = lowPowerMode
    isEnabled = defaults.bool(forKey: Self.enabledPreferenceKey)

    notificationObservers = [
      NotificationCenter.default.addObserver(
        forName: ProcessInfo.thermalStateDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.refreshProcessState() }
      },
      NotificationCenter.default.addObserver(
        forName: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"),
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.refreshProcessState() }
      },
    ]

    workspaceObservers = [
      workspaceNotificationCenter.addObserver(
        forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.setDisplaySleeping(true) }
      },
      workspaceNotificationCenter.addObserver(
        forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.setDisplaySleeping(false) }
      },
    ]

    if isEnabled {
      start()
    }
  }

  deinit {
    timer?.invalidate()
    pathMonitor?.cancel()
    memoryPressureSource?.cancel()
    connectionTestTask?.cancel()
    diskRefreshTask?.cancel()
    sampleTask?.cancel()
    for observer in notificationObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    for observer in workspaceObservers {
      workspaceNotificationCenter.removeObserver(observer)
    }
  }

  func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else { return }
    isEnabled = enabled
    defaults.set(enabled, forKey: Self.enabledPreferenceKey)
    if enabled {
      start()
    } else {
      stop()
    }
  }

  func setPresentation(mode: SurfaceMode, section: NotchSection, isVisible: Bool = true) {
    let visible = isVisible && mode == .expanded && section == .system
    guard visible != isSystemSectionVisible else { return }
    isSystemSectionVisible = visible
    scheduleTimer()
    if visible { refresh() }
  }

  func setDisplaySleeping(_ sleeping: Bool) {
    guard sleeping != isDisplaySleeping else { return }
    isDisplaySleeping = sleeping
    if sleeping {
      sampleTask?.cancel()
      sampleTask = nil
      diskRefreshTask?.cancel()
      diskRefreshTask = nil
    }
    scheduleTimer()
    if !sleeping { refresh() }
  }

  func testConnection() {
    guard network.isOnline, connectionTest != .testing else { return }
    connectionTestTask?.cancel()
    connectionTest = .testing
    connectionTestTask = Task { [weak self] in
      do {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(
          url: URL(string: "https://www.apple.com/library/test/success.html")!
        )
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let start = ContinuousClock.now
        let (_, response) = try await session.data(for: request)
        let elapsed = start.duration(to: .now)
        guard let response = response as? HTTPURLResponse,
          (200..<400).contains(response.statusCode)
        else {
          throw ConnectionTestError.unsuccessfulResponse
        }
        guard !Task.isCancelled else { return }
        let components = elapsed.components
        let milliseconds = max(
          Int(components.seconds * 1_000)
            + Int(components.attoseconds / 1_000_000_000_000_000),
          1
        )
        self?.connectionTest = .success(milliseconds: milliseconds)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        self?.connectionTest = .failed(error.localizedDescription)
      }
    }
  }

  func refresh() {
    guard isEnabled, !isDisplaySleeping, sampleTask == nil else { return }
    let interfaceNames = monitoredInterfaceNames
    let generation = pathGeneration
    let uptime = ProcessInfo.processInfo.systemUptime
    let includesWiFi = pathUsesWiFi
      && (previousWiFiRefreshUptime.map { uptime - $0 >= 10 } ?? true)
    if includesWiFi { previousWiFiRefreshUptime = uptime }
    refreshDiskSampleIfNeeded()
    sampleTask = Task { [weak self] in
      let sample = await Task.detached(priority: .utility) {
        SystemMonitorSample(
          cpuTicks: Self.readCPUTicks(),
          memory: Self.readMemoryUsage(),
          counters: Self.readInterfaceCounters(restrictedTo: interfaceNames),
          wifiSignal: includesWiFi ? Self.wifiSignalStrength() : nil,
          uptime: ProcessInfo.processInfo.systemUptime
        )
      }.value
      guard !Task.isCancelled, let self else { return }
      self.sampleTask = nil
      guard self.isEnabled, generation == self.pathGeneration else { return }
      self.applySample(sample, includesWiFi: includesWiFi)
    }
  }

  func applySample(_ sample: SystemMonitorSample, includesWiFi: Bool) {
    refreshSystemSample(sample)
    refreshNetworkSample(sample, includesWiFi: includesWiFi)
  }

  private func start() {
    previousCPUTicks = nil
    previousNetworkCounters = nil
    previousNetworkSampleUptime = nil
    previousDiskRefreshUptime = nil
    previousWiFiRefreshUptime = nil
    receivedSinceLaunch = 0
    sentSinceLaunch = 0
    refreshProcessState()
    startPathMonitor()
    startMemoryPressureMonitor()
    refresh()
    scheduleTimer()
  }

  private func stop() {
    timer?.invalidate()
    timer = nil
    pathMonitor?.cancel()
    pathMonitor = nil
    memoryPressureSource?.cancel()
    memoryPressureSource = nil
    connectionTestTask?.cancel()
    connectionTestTask = nil
    diskRefreshTask?.cancel()
    diskRefreshTask = nil
    sampleTask?.cancel()
    sampleTask = nil
    pathGeneration &+= 1
    previousDiskRefreshUptime = nil
    connectionTest = .idle
  }

  private func scheduleTimer() {
    let interval: TimeInterval? = if !isEnabled || isDisplaySleeping {
      nil
    } else if isSystemSectionVisible {
      system.isLowPowerModeEnabled ? 2 : 1
    } else {
      10
    }
    guard interval != samplingInterval else { return }
    timer?.invalidate()
    timer = nil
    guard let interval else { return }
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.timerFired()
      }
    }
    timer.tolerance = interval * 0.15
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func timerFired() {
    refresh()
  }

  private func startPathMonitor() {
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      let state = NetworkPathState(path: path)
      Task { @MainActor in
        guard let self, self.pathMonitor === monitor else { return }
        self.apply(state)
      }
    }
    pathMonitor = monitor
    monitor.start(queue: pathQueue)
  }

  private func startMemoryPressureMonitor() {
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical],
      queue: .main
    )
    source.setEventHandler { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, let source = self.memoryPressureSource else { return }
        let data = source.data
        let pressure: MemoryPressureLevel = data.contains(.critical) ? .critical
          : data.contains(.warning) ? .warning : .normal
        if self.system.memoryPressure != pressure { self.system.memoryPressure = pressure }
      }
    }
    memoryPressureSource = source
    source.resume()
  }

  private func apply(_ path: NetworkPathState) {
    pathGeneration &+= 1
    if path.interfaceNames != monitoredInterfaceNames || path.isOnline != network.isOnline {
      monitoredInterfaceNames = path.interfaceNames
      previousNetworkCounters = nil
      previousNetworkSampleUptime = nil
      previousWiFiRefreshUptime = nil
    }
    var updated = network
    updated.isOnline = path.isOnline
    updated.interfaceName = path.interfaceName
    updated.hasVPN = path.hasVPN
    pathHasVPN = path.hasVPN
    pathUsesWiFi = path.usesWiFi
    updated.isConstrained = path.isConstrained
    updated.isExpensive = path.isExpensive
    if !path.usesWiFi { updated.wifiSignal = nil }
    if !path.isOnline {
      updated.downloadBytesPerSecond = 0
      updated.uploadBytesPerSecond = 0
      if connectionTest == .testing {
        connectionTestTask?.cancel()
        connectionTest = .failed("The connection went offline during the test.")
      }
    }
    if updated != network { network = updated }
  }

  private func refreshSystemSample(_ sample: SystemMonitorSample) {
    var updated = system
    if let ticks = sample.cpuTicks {
      if let previousCPUTicks {
        if ticks.used >= previousCPUTicks.used,
          ticks.total >= previousCPUTicks.total
        {
          let usedDelta = ticks.used - previousCPUTicks.used
          let totalDelta = ticks.total - previousCPUTicks.total
          if totalDelta > 0 {
            updated.cpuUsage = min(max(Double(usedDelta) / Double(totalDelta), 0), 1)
          }
        }
      }
      previousCPUTicks = ticks
    }

    if let memory = sample.memory {
      updated.memoryUsed = memory.used
      updated.memoryTotal = memory.total
    }
    updateProcessState(&updated)
    if updated != system { system = updated }
    scheduleTimer()
  }

  private func refreshDiskSampleIfNeeded() {
    guard diskRefreshTask == nil else { return }
    let uptime = ProcessInfo.processInfo.systemUptime
    if let previousDiskRefreshUptime,
      uptime - previousDiskRefreshUptime < Self.diskRefreshInterval
    {
      return
    }
    previousDiskRefreshUptime = uptime

    diskRefreshTask = Task { [weak self] in
      let disk = await Task.detached(priority: .utility) {
        Self.readDiskUsage()
      }.value
      guard !Task.isCancelled, let self else { return }
      self.diskRefreshTask = nil
      guard self.isEnabled, let disk else { return }
      var updated = self.system
      updated.diskFree = disk.free
      updated.diskTotal = disk.total
      if updated != self.system { self.system = updated }
    }
  }

  private func refreshProcessState() {
    guard isEnabled else { return }
    var updated = system
    updateProcessState(&updated)
    if updated != system { system = updated }
    scheduleTimer()
  }

  private func updateProcessState(_ system: inout SystemSnapshot) {
    system.thermalCondition = switch ProcessInfo.processInfo.thermalState {
    case .nominal: .nominal
    case .fair: .fair
    case .serious: .serious
    case .critical: .critical
    @unknown default: .fair
    }
    system.isLowPowerModeEnabled = lowPowerMode()
  }

  private func refreshNetworkSample(_ sample: SystemMonitorSample, includesWiFi: Bool) {
    var updated = network
    if includesWiFi { updated.wifiSignal = sample.wifiSignal }
    defer { if updated != network { network = updated } }
    guard let counters = sample.counters else { return }
    updated.hasVPN = pathHasVPN || counters.hasVPN
    let uptime = sample.uptime
    defer {
      previousNetworkCounters = counters
      previousNetworkSampleUptime = uptime
    }

    guard let previousNetworkCounters, let previousNetworkSampleUptime else {
      return
    }
    let elapsed = uptime - previousNetworkSampleUptime
    guard elapsed > 0 else { return }
    let receivedDelta = counters.received >= previousNetworkCounters.received
      ? counters.received - previousNetworkCounters.received
      : 0
    let sentDelta = counters.sent >= previousNetworkCounters.sent
      ? counters.sent - previousNetworkCounters.sent
      : 0
    receivedSinceLaunch &+= receivedDelta
    sentSinceLaunch &+= sentDelta
    updated.downloadBytesPerSecond = Double(receivedDelta) / elapsed
    updated.uploadBytesPerSecond = Double(sentDelta) / elapsed
    updated.receivedSinceLaunch = receivedSinceLaunch
    updated.sentSinceLaunch = sentSinceLaunch

  }

  nonisolated private static func wifiSignalStrength() -> Int? {
    guard let rssi = CWWiFiClient.shared().interface()?.rssiValue(), rssi < 0 else {
      return nil
    }
    return rssi
  }

  nonisolated private static func readCPUTicks() -> CPUTicks? {
    var load = host_cpu_load_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<host_cpu_load_info_data_t>.size
        / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &load) { pointer in
      pointer.withMemoryRebound(
        to: integer_t.self,
        capacity: Int(count)
      ) {
        host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    let user = UInt64(load.cpu_ticks.0)
    let system = UInt64(load.cpu_ticks.1)
    let idle = UInt64(load.cpu_ticks.2)
    let nice = UInt64(load.cpu_ticks.3)
    return CPUTicks(used: user + system + nice, total: user + system + idle + nice)
  }

  nonisolated private static func readMemoryUsage() -> (used: UInt64, total: UInt64)? {
    var statistics = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size
        / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &statistics) { pointer in
      pointer.withMemoryRebound(
        to: integer_t.self,
        capacity: Int(count)
      ) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    let total = ProcessInfo.processInfo.physicalMemory
    var rawPageSize: vm_size_t = 0
    guard host_page_size(mach_host_self(), &rawPageSize) == KERN_SUCCESS else {
      return nil
    }
    let pageSize = UInt64(rawPageSize)
    let reclaimablePages = UInt64(statistics.free_count)
      + UInt64(statistics.inactive_count)
      + UInt64(statistics.speculative_count)
    let available = min(reclaimablePages * pageSize, total)
    return (total - available, total)
  }

  nonisolated private static func readDiskUsage() -> (free: Int64, total: Int64)? {
    do {
      let values = try URL(fileURLWithPath: "/").resourceValues(
        forKeys: [
          .volumeAvailableCapacityForImportantUsageKey,
          .volumeTotalCapacityKey,
        ]
      )
      guard let free = values.volumeAvailableCapacityForImportantUsage,
        let total = values.volumeTotalCapacity
      else { return nil }
      return (free, Int64(total))
    } catch {
      return nil
    }
  }

  nonisolated private static func readInterfaceCounters(
    restrictedTo interfaceNames: Set<String>
  ) -> InterfaceCounters? {
    var firstAddress: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
    defer { freeifaddrs(firstAddress) }

    var received: UInt64 = 0
    var sent: UInt64 = 0
    var hasVPN = false
    var address: UnsafeMutablePointer<ifaddrs>? = firstAddress
    while let current = address {
      defer { address = current.pointee.ifa_next }
      guard let socketAddress = current.pointee.ifa_addr,
        socketAddress.pointee.sa_family == UInt8(AF_LINK),
        current.pointee.ifa_flags & UInt32(IFF_UP) != 0,
        current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
        let rawData = current.pointee.ifa_data
      else { continue }

      let name = String(cString: current.pointee.ifa_name)
      if NetworkPathState.vpnPrefixes.contains(where: name.hasPrefix) {
        hasVPN = true
      }
      guard interfaceNames.isEmpty || interfaceNames.contains(name) else {
        continue
      }
      let data = rawData.assumingMemoryBound(to: if_data.self).pointee
      received &+= UInt64(data.ifi_ibytes)
      sent &+= UInt64(data.ifi_obytes)
    }
    return InterfaceCounters(received: received, sent: sent, hasVPN: hasVPN)
  }
}

struct SystemMonitorSample: Sendable {
  var cpuTicks: CPUTicks?
  var memory: (used: UInt64, total: UInt64)?
  var counters: InterfaceCounters?
  var wifiSignal: Int?
  var uptime: TimeInterval
}

struct CPUTicks: Sendable {
  let used: UInt64
  let total: UInt64
}

struct InterfaceCounters: Sendable {
  let received: UInt64
  let sent: UInt64
  let hasVPN: Bool
}

private struct NetworkPathState: Sendable {
  static let vpnPrefixes = ["utun", "ppp", "ipsec", "tap", "tun"]

  let isOnline: Bool
  let interfaceName: String
  let interfaceNames: Set<String>
  let usesWiFi: Bool
  let hasVPN: Bool
  let isConstrained: Bool
  let isExpensive: Bool

  init(path: NWPath) {
    isOnline = path.status == .satisfied
    usesWiFi = path.usesInterfaceType(.wifi)
    if path.usesInterfaceType(.wifi) {
      interfaceName = "Wi-Fi"
    } else if path.usesInterfaceType(.wiredEthernet) {
      interfaceName = "Ethernet"
    } else if path.usesInterfaceType(.cellular) {
      interfaceName = "Cellular"
    } else if path.status == .satisfied {
      interfaceName = "Other"
    } else {
      interfaceName = "Offline"
    }
    let preferredType: NWInterface.InterfaceType? = if path.usesInterfaceType(.wifi) {
      .wifi
    } else if path.usesInterfaceType(.wiredEthernet) {
      .wiredEthernet
    } else if path.usesInterfaceType(.cellular) {
      .cellular
    } else if path.status == .satisfied {
      .other
    } else {
      nil
    }
    let matchingInterfaces = path.availableInterfaces.compactMap { interface in
      interface.type == preferredType ? interface.name : nil
    }
    let vpnInterfaces = matchingInterfaces.filter { name in
      Self.vpnPrefixes.contains(where: name.hasPrefix)
    }
    interfaceNames = Set(vpnInterfaces.isEmpty ? matchingInterfaces : vpnInterfaces)
    hasVPN = path.availableInterfaces.contains { interface in
      Self.vpnPrefixes.contains(where: interface.name.hasPrefix)
    }
    isConstrained = path.isConstrained
    isExpensive = path.isExpensive
  }
}

private enum ConnectionTestError: LocalizedError {
  case unsuccessfulResponse

  var errorDescription: String? {
    "The test endpoint did not return a successful response."
  }
}
