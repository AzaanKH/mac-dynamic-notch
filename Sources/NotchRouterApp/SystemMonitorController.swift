import Combine
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
final class SystemMonitorController: ObservableObject {
  static let enabledPreferenceKey = "systemSectionEnabled"

  @Published private(set) var isEnabled: Bool
  @Published private(set) var system = SystemSnapshot()
  @Published private(set) var network = NetworkSnapshot()
  @Published private(set) var connectionTest: ConnectionTestState = .idle

  private let defaults: UserDefaults
  nonisolated(unsafe) private var timer: Timer?
  private var interval: TimeInterval = 2
  private var pathMonitor: NWPathMonitor?
  private let pathQueue = DispatchQueue(label: "com.notchrouter.network-path")
  private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
  nonisolated(unsafe) private var notificationObservers: [NSObjectProtocol] = []
  private var previousCPUTicks: CPUTicks?
  private var previousNetworkCounters: InterfaceCounters?
  private var previousNetworkSampleUptime: TimeInterval?
  private var monitoredInterfaceNames: Set<String> = []
  private var pathHasVPN = false
  private var receivedSinceLaunch: UInt64 = 0
  private var sentSinceLaunch: UInt64 = 0
  private var connectionTestTask: Task<Void, Never>?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
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

    if isEnabled {
      start()
    }
  }

  deinit {
    timer?.invalidate()
    pathMonitor?.cancel()
    memoryPressureSource?.cancel()
    connectionTestTask?.cancel()
    for observer in notificationObservers {
      NotificationCenter.default.removeObserver(observer)
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

  func setSurfaceMode(_ mode: SurfaceMode) {
    let newInterval: TimeInterval = mode == .expanded ? 1 : 2
    guard newInterval != interval else { return }
    interval = newInterval
    if isEnabled {
      scheduleTimer()
    }
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
    guard isEnabled else { return }
    refreshSystemSample()
    refreshNetworkSample()
  }

  private func start() {
    previousCPUTicks = nil
    previousNetworkCounters = nil
    previousNetworkSampleUptime = nil
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
    connectionTest = .idle
  }

  private func scheduleTimer() {
    timer?.invalidate()
    let timer = Timer(
      timeInterval: interval,
      target: self,
      selector: #selector(timerFired),
      userInfo: nil,
      repeats: true
    )
    timer.tolerance = min(interval * 0.15, 0.25)
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  @objc private func timerFired() {
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
      guard let self, let source = self.memoryPressureSource else { return }
      let data = source.data
      if data.contains(.critical) {
        self.system.memoryPressure = .critical
      } else if data.contains(.warning) {
        self.system.memoryPressure = .warning
      } else {
        self.system.memoryPressure = .normal
      }
    }
    memoryPressureSource = source
    source.resume()
  }

  private func apply(_ path: NetworkPathState) {
    if path.interfaceNames != monitoredInterfaceNames {
      monitoredInterfaceNames = path.interfaceNames
      previousNetworkCounters = nil
      previousNetworkSampleUptime = nil
    }
    network.isOnline = path.isOnline
    network.interfaceName = path.interfaceName
    network.hasVPN = path.hasVPN
    pathHasVPN = path.hasVPN
    network.isConstrained = path.isConstrained
    network.isExpensive = path.isExpensive
    network.wifiSignal = path.usesWiFi ? wifiSignalStrength() : nil
    if !path.isOnline {
      network.downloadBytesPerSecond = 0
      network.uploadBytesPerSecond = 0
      if connectionTest == .testing {
        connectionTestTask?.cancel()
        connectionTest = .failed("The connection went offline during the test.")
      }
    }
  }

  private func refreshSystemSample() {
    if let ticks = Self.readCPUTicks() {
      if let previousCPUTicks {
        if ticks.used >= previousCPUTicks.used,
          ticks.total >= previousCPUTicks.total
        {
          let usedDelta = ticks.used - previousCPUTicks.used
          let totalDelta = ticks.total - previousCPUTicks.total
          system.cpuUsage = totalDelta > 0
            ? min(max(Double(usedDelta) / Double(totalDelta), 0), 1)
            : 0
        }
      }
      previousCPUTicks = ticks
    }

    if let memory = Self.readMemoryUsage() {
      system.memoryUsed = memory.used
      system.memoryTotal = memory.total
    }
    if let disk = Self.readDiskUsage() {
      system.diskFree = disk.free
      system.diskTotal = disk.total
    }
    refreshProcessState()
  }

  private func refreshProcessState() {
    system.thermalCondition = switch ProcessInfo.processInfo.thermalState {
    case .nominal: .nominal
    case .fair: .fair
    case .serious: .serious
    case .critical: .critical
    @unknown default: .fair
    }
    system.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
  }

  private func refreshNetworkSample() {
    guard
      let counters = Self.readInterfaceCounters(
        restrictedTo: monitoredInterfaceNames
      )
    else { return }
    let uptime = ProcessInfo.processInfo.systemUptime
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
    network.downloadBytesPerSecond = Double(receivedDelta) / elapsed
    network.uploadBytesPerSecond = Double(sentDelta) / elapsed
    network.receivedSinceLaunch = receivedSinceLaunch
    network.sentSinceLaunch = sentSinceLaunch
    network.hasVPN = pathHasVPN || counters.hasVPN
    if network.wifiSignal != nil {
      network.wifiSignal = wifiSignalStrength()
    }
  }

  private func wifiSignalStrength() -> Int? {
    guard let rssi = CWWiFiClient.shared().interface()?.rssiValue(), rssi < 0 else {
      return nil
    }
    return rssi
  }

  private static func readCPUTicks() -> CPUTicks? {
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

  private static func readMemoryUsage() -> (used: UInt64, total: UInt64)? {
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

  private static func readDiskUsage() -> (free: Int64, total: Int64)? {
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

  private static func readInterfaceCounters(
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

private struct CPUTicks {
  let used: UInt64
  let total: UInt64
}

private struct InterfaceCounters {
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
