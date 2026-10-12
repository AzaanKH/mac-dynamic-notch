import Foundation
import NotchRouterCore
import Testing

@testable import NotchRouterApp

@Test
func compactPresentationKeepsOtherActivitiesVisible() {
  var presentation = CompactPresentation()
  presentation.update(available: [.music, .focus, .agent, .download], needsApproval: false)
  #expect(presentation.primary == .agent)
  #expect(presentation.secondary == [.download, .focus, .music])
  #expect(presentation.showsIndicator)
}

@Test
func compactPresentationApprovalInterruptsAndRestoresPin() {
  let now = Date(timeIntervalSince1970: 1000)
  var presentation = CompactPresentation()
  presentation.update(available: [.agent, .music], needsApproval: false, now: now)
  presentation.pin(.music, now: now)
  #expect(presentation.primary == .music)
  presentation.update(available: [.agent, .music], needsApproval: true, now: now)
  #expect(presentation.primary == .agent)
  #expect(presentation.pinned == .music)
  #expect(presentation.secondary == [.music])
  presentation.update(available: [.agent, .music], needsApproval: false, now: now)
  #expect(presentation.primary == .music)
}

@Test
func compactPresentationPinExpiresOrClearsWhenActivityEnds() {
  let now = Date(timeIntervalSince1970: 1000)
  var presentation = CompactPresentation()
  presentation.update(available: [.agent, .focus], needsApproval: false, now: now)
  presentation.pin(.focus, now: now)
  presentation.update(available: [.agent, .focus], needsApproval: false, now: now.addingTimeInterval(299))
  #expect(presentation.primary == .focus)
  presentation.update(available: [.agent, .focus], needsApproval: false, now: now.addingTimeInterval(300))
  #expect(presentation.primary == .agent)
  #expect(presentation.pinned == nil)
  presentation.pin(.focus, now: now)
  presentation.update(available: [.agent], needsApproval: false, now: now)
  #expect(presentation.pinned == nil)
  presentation.update(available: [.agent, .focus], needsApproval: false, now: now)
  #expect(presentation.primary == .agent)
}

@Test
func compactPresentationRejectsUnavailablePinsAndSupportsUnpinning() {
  var presentation = CompactPresentation()
  presentation.update(available: [.music], needsApproval: false)
  presentation.pin(.focus)
  #expect(presentation.pinned == nil)
  #expect(!presentation.showsIndicator)
  presentation.pin(.music)
  #expect(presentation.showsIndicator)
  presentation.unpin()
  #expect(presentation.pinExpiresAt == nil)
  #expect(!presentation.showsIndicator)
}

@MainActor
@Test
func compactPresentationApprovalsStayCompactAndPreserveOpenSection() {
  let viewModel = NotchViewModel()
  viewModel.presentation.update(available: [.agent, .music], needsApproval: false)
  viewModel.pinActivity(.music)
  defer { viewModel.unpinActivity() }
  var activity = AIActivity(event: ActivityEventRequest(
    activityID: "pin-test", source: "Test", title: "Working", state: .running
  ), now: .now)
  viewModel.activityArrived(activity)
  #expect(viewModel.mode == .compact)
  activity.state = .needsApproval
  viewModel.activityArrived(activity)
  #expect(viewModel.mode == .compact)
  viewModel.show(.music)
  viewModel.activityArrived(activity)
  #expect(viewModel.mode == .expanded)
  #expect(viewModel.selectedSection == .music)
  viewModel.collapse()
}
