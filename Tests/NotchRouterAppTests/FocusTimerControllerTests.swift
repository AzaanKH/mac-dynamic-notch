import Foundation
@testable import NotchRouterApp
import Testing

@MainActor
@Test
func focusTimerStartsPausesAndResumesFromTheCurrentTime() {
  let suiteName = "FocusTimerTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }

  var now = Date(timeIntervalSinceReferenceDate: 1_000)
  let timer = FocusTimerController(
    defaults: defaults,
    nowProvider: { now },
    ticksAutomatically: false
  )

  timer.selectDuration(minutes: 15)
  timer.start()
  #expect(timer.phase == .running)
  #expect(timer.formattedRemaining == "15:00")

  now = now.addingTimeInterval(90)
  timer.refresh()
  #expect(timer.formattedRemaining == "13:30")

  timer.pause()
  now = now.addingTimeInterval(60)
  timer.refresh()
  #expect(timer.phase == .paused)
  #expect(timer.formattedRemaining == "13:30")

  timer.resume()
  now = now.addingTimeInterval(30)
  timer.refresh()
  #expect(timer.phase == .running)
  #expect(timer.formattedRemaining == "13:00")
  timer.reset()
}

@MainActor
@Test
func focusTimerCompletesAndRequestsPresentation() {
  let suiteName = "FocusTimerTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }

  var now = Date(timeIntervalSinceReferenceDate: 2_000)
  let timer = FocusTimerController(
    defaults: defaults,
    nowProvider: { now },
    ticksAutomatically: false
  )
  var receivedEvent: FocusTimerPresentationEvent?
  timer.onChange = { receivedEvent = $0 }

  timer.selectDuration(minutes: 1)
  timer.start()
  receivedEvent = nil
  now = now.addingTimeInterval(60)
  timer.refresh()

  #expect(timer.phase == .completed)
  #expect(timer.remainingSeconds == 0)
  #expect(timer.progress == 1)
  #expect(receivedEvent == .completed)
  timer.reset()
}

@MainActor
@Test
func runningFocusTimerRestoresAgainstItsSavedDeadline() {
  let suiteName = "FocusTimerTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }

  var now = Date(timeIntervalSinceReferenceDate: 3_000)
  let original = FocusTimerController(
    defaults: defaults,
    nowProvider: { now },
    ticksAutomatically: false
  )
  original.selectDuration(minutes: 25)
  original.start()

  now = now.addingTimeInterval(120)
  let restored = FocusTimerController(
    defaults: defaults,
    nowProvider: { now },
    ticksAutomatically: false
  )

  #expect(restored.phase == .running)
  #expect(restored.formattedRemaining == "23:00")
  restored.reset()
}

@MainActor
@Test
func elapsedFocusTimerRestoresAsCompleted() {
  let suiteName = "FocusTimerTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }

  var now = Date(timeIntervalSinceReferenceDate: 4_000)
  let original = FocusTimerController(
    defaults: defaults,
    nowProvider: { now },
    ticksAutomatically: false
  )
  original.selectDuration(minutes: 15)
  original.start()

  now = now.addingTimeInterval(901)
  let restored = FocusTimerController(
    defaults: defaults,
    nowProvider: { now },
    ticksAutomatically: false
  )

  #expect(restored.phase == .completed)
  #expect(restored.formattedRemaining == "00:00")
  restored.reset()
}

@MainActor
@Test
func completedFocusTimerPeeksUnlessAnActivityHasPriority() {
  let viewModel = NotchViewModel()

  viewModel.focusTimerCompleted(hasActiveActivity: true)
  #expect(viewModel.mode == .compact)

  viewModel.focusTimerCompleted(hasActiveActivity: false)
  #expect(viewModel.mode == .peek)
  #expect(viewModel.selectedSection == .focus)
  viewModel.collapse()
}

@MainActor
@Test
func focusTimerUpdatesOncePerSecond() {
  #expect(FocusTimerController.tickInterval == .seconds(1))
}
