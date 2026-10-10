import Foundation
import NotchRouterCore
import Testing

@testable import NotchRouterApp

@Test
func everyPassiveFeatureCombinationFitsMenuBar() {
  for height: CGFloat in [22, 24, 32, 38] {
    for physical in [false, true] {
      let geometry = NotchGeometry(
        screenWidth: 1512,
        safeAreaTop: physical ? height : 0,
        menuBarHeight: height,
        auxiliaryTopLeftWidth: physical ? 656 : nil,
        auxiliaryTopRightWidth: physical ? 656 : nil
      )
      for mask in 0..<(1 << CompactActivityKind.allCases.count) {
        let available = CompactActivityKind.allCases.enumerated().compactMap {
          mask & (1 << $0.offset) != 0 ? $0.element : nil
        }
        var presentation = CompactPresentation()
        presentation.update(available: available, needsApproval: available.contains(.agent))
        for pin in available {
          presentation.pin(pin)
          let size = geometry.compactSize(
            primary: presentation.primary,
            hasRecentActivity: true,
            showsIndicator: presentation.showsIndicator
          )
          #expect(size.height <= height)
          #expect(size.width > geometry.hardwareWidth)
        }
        #expect(geometry.compactSize(
          primary: presentation.primary, hasRecentActivity: false,
          showsIndicator: presentation.showsIndicator
        ).height <= height)
      }
    }
  }
}

@MainActor
@Test
func backgroundEventsNeverExpandOrReplaceUserSection() {
  let model = NotchViewModel()
  var transitions: [SurfaceMode] = []
  model.onModeChange = { transitions.append($0) }
  for state in ActivityState.allCases {
    model.activityArrived(AIActivity(event: ActivityEventRequest(
      activityID: "passive", source: "Test", title: "Task", state: state
    ), now: .now))
    #expect(model.mode == .compact)
  }
  model.musicChanged(event: .playbackStarted, hasActiveActivity: false)
  model.focusTimerCompleted(hasActiveActivity: false)
  #expect(transitions.isEmpty)
  model.show(.clipboard)
  model.activityArrived(AIActivity(event: ActivityEventRequest(
    activityID: "approval", source: "Test", title: "Approval", state: .needsApproval
  ), now: .now))
  model.musicChanged(event: .playbackStarted, hasActiveActivity: false)
  model.focusTimerCompleted(hasActiveActivity: false)
  #expect(model.mode == .expanded)
  #expect(model.selectedSection == .clipboard)
  model.collapse()
}

@MainActor
@Test
func deliberateHoverOpensPreviewAndLeavingClosesIt() async throws {
  let model = NotchViewModel()
  model.pointerChanged(isInside: true)
  try await Task.sleep(for: .milliseconds(150))
  #expect(model.mode == .compact)
  model.pointerChanged(isInside: false)
  try await Task.sleep(for: .milliseconds(500))
  #expect(model.mode == .compact)
  model.pointerChanged(isInside: true)
  try await Task.sleep(for: .milliseconds(600))
  #expect(model.mode == .peek)
  model.pointerChanged(isInside: false)
  try await Task.sleep(for: .milliseconds(500))
  #expect(model.mode == .compact)
}

@MainActor
@Test
func clickKeyboardAndFileDragCanExpand() {
  let model = NotchViewModel()
  model.toggleExpanded()
  #expect(model.mode == .expanded)
  model.collapse()
  #expect(model.selectSection(keyboardNumber: NotchSection.music.keyboardNumber))
  #expect(model.mode == .expanded)
  #expect(model.selectedSection == .music)
  model.collapse()
  model.prepareForFileDrop(isTargeted: true)
  #expect(model.mode == .expanded)
  #expect(model.selectedSection == .files)
  model.prepareForFileDrop(isTargeted: false)
  model.collapse()
}
