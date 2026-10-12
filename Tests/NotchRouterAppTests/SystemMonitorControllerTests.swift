import Foundation
import Testing
@testable import NotchRouterApp

@MainActor
@Test
func systemSamplingFollowsSectionNavigationAndPanelVisibility() throws {
  let suite = UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let controller = SystemMonitorController(defaults: defaults, lowPowerMode: { false })
  defer { controller.setEnabled(false) }
  let viewModel = NotchViewModel()
  let update = {
    controller.setPresentation(mode: viewModel.mode, section: viewModel.selectedSection)
  }
  viewModel.onModeChange = { _ in update() }
  viewModel.onSectionChange = update

  #expect(controller.samplingInterval == nil)
  controller.setEnabled(true)
  let backgroundInterval = try #require(controller.samplingInterval)
  viewModel.show(.music)
  #expect(controller.samplingInterval == backgroundInterval)
  viewModel.show(.system)
  let visibleInterval = try #require(controller.samplingInterval)
  #expect(visibleInterval < backgroundInterval)
  viewModel.selectedSection = .activity // The mouse-driven section picker.
  #expect(controller.samplingInterval == backgroundInterval)
  viewModel.selectAdjacentSection(offset: -1) // Keyboard navigation wraps to System.
  #expect(controller.samplingInterval == visibleInterval)
  controller.setPresentation(mode: .expanded, section: .system, isVisible: false)
  #expect(controller.samplingInterval == backgroundInterval)
  update()
  #expect(controller.samplingInterval == visibleInterval)
  viewModel.collapse()
  #expect(controller.samplingInterval == backgroundInterval)
  controller.setEnabled(false)
  viewModel.show(.system)
  #expect(controller.samplingInterval == nil)
}

@MainActor
@Test
func sleepingDisplaysSuspendSystemReadsAndWakeRefreshesImmediately() async throws {
  let suite = UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let controller = SystemMonitorController(defaults: defaults)
  defer { controller.setEnabled(false) }
  controller.setDisplaySleeping(true)
  controller.setEnabled(true)
  controller.setPresentation(mode: .expanded, section: .system)
  controller.refresh()
  try await Task.sleep(for: .milliseconds(50))
  #expect(controller.samplingInterval == nil)
  #expect(controller.system.memoryTotal == 0)

  controller.setDisplaySleeping(false)
  #expect(controller.samplingInterval != nil)
  for _ in 0..<100 {
    if controller.system.memoryTotal > 0 { break }
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(controller.system.memoryTotal > 0, "Wake samples immediately without waiting for the next timer")
  controller.setDisplaySleeping(true)
  #expect(controller.samplingInterval == nil)
  controller.setEnabled(false)
  controller.setDisplaySleeping(false)
  #expect(controller.samplingInterval == nil, "Wake must not re-enable a disabled feature")
}

@MainActor
@Test
func powerNotificationsAdjustVisibleSystemSamplingWithoutOpeningThePanel() async throws {
  let suite = UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  var lowPower = false
  let controller = SystemMonitorController(defaults: defaults, lowPowerMode: { lowPower })
  defer { controller.setEnabled(false) }
  controller.setPresentation(mode: .expanded, section: .system)
  controller.setEnabled(true)
  let normalInterval = try #require(controller.samplingInterval)
  lowPower = true
  NotificationCenter.default.post(name: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"), object: nil)
  for _ in 0..<100 {
    if controller.system.isLowPowerModeEnabled { break }
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(controller.system.isLowPowerModeEnabled)
  #expect(try #require(controller.samplingInterval) > normalInterval)
  controller.setDisplaySleeping(true)
  lowPower = false
  NotificationCenter.default.post(name: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"), object: nil)
  try await Task.sleep(for: .milliseconds(20))
  #expect(controller.samplingInterval == nil)
}

@MainActor
@Test
func systemSamplesPublishWholeSnapshotsAndSkipUnchangedValues() throws {
  let suite = UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let controller = SystemMonitorController(defaults: defaults)
  let systemChanges = ObservationChangeCounter { _ = controller.system }
  let networkChanges = ObservationChangeCounter { _ = controller.network }
  controller.applySample(SystemMonitorSample(
    cpuTicks: CPUTicks(used: 100, total: 200), memory: (500, 1_000),
    counters: InterfaceCounters(received: 100, sent: 50, hasVPN: false), uptime: 1
  ), includesWiFi: false)
  #expect(systemChanges.count == 1)
  #expect(controller.system.memoryUsed == 500)
  #expect(controller.system.memoryTotal == 1_000)
  #expect(networkChanges.count == 0)

  let next = SystemMonitorSample(
    cpuTicks: CPUTicks(used: 125, total: 300), memory: (600, 1_000),
    counters: InterfaceCounters(received: 300, sent: 150, hasVPN: true),
    wifiSignal: -60, uptime: 3
  )
  controller.applySample(next, includesWiFi: true)
  #expect(systemChanges.count == 2)
  #expect(controller.system.cpuUsage == 0.25)
  #expect(networkChanges.count == 1)
  #expect(controller.network.downloadBytesPerSecond == 100)
  #expect(controller.network.uploadBytesPerSecond == 50)
  #expect(controller.network.receivedSinceLaunch == 200)
  #expect(controller.network.sentSinceLaunch == 100)
  #expect(controller.network.hasVPN == true)
  #expect(controller.network.wifiSignal == -60)

  // Identical reads with no elapsed time must not reset a valid CPU sample.
  controller.applySample(next, includesWiFi: true)
  #expect(systemChanges.count == 2)
  #expect(networkChanges.count == 1)
}

@MainActor
@Test
func systemCounterResetsDoNotCreateTrafficSpikes() throws {
  let suite = UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let controller = SystemMonitorController(defaults: defaults)
  controller.applySample(SystemMonitorSample(
    counters: InterfaceCounters(received: 10_000, sent: 5_000, hasVPN: false), uptime: 1
  ), includesWiFi: false)
  controller.applySample(SystemMonitorSample(
    counters: InterfaceCounters(received: 10, sent: 5, hasVPN: false), uptime: 2
  ), includesWiFi: false)
  #expect(controller.network.downloadBytesPerSecond == 0)
  #expect(controller.network.uploadBytesPerSecond == 0)
  #expect(controller.network.receivedSinceLaunch == 0)
  #expect(controller.network.sentSinceLaunch == 0)
}
