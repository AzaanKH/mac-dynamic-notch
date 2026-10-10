import CoreGraphics
import Testing

@testable import NotchRouterApp

@Test
func physicalNotchGeometryUsesSafeAreaAndAuxiliaryRegions() {
  let geometry = NotchGeometry(
    screenWidth: 1_512,
    safeAreaTop: 32,
    auxiliaryTopLeftWidth: 656,
    auxiliaryTopRightWidth: 656
  )

  #expect(geometry.hasPhysicalNotch)
  #expect(geometry.hardwareWidth == 200)
  #expect(geometry.hardwareHeight == 32)
  #expect(geometry.restingWidth == 200)
  #expect(geometry.restingHeight == 32)
}

@Test
func smallPhysicalNotchStaysWithinMenuBar() {
  let geometry = NotchGeometry(
    screenWidth: 1_000,
    safeAreaTop: 24,
    auxiliaryTopLeftWidth: 410,
    auxiliaryTopRightWidth: 410
  )

  #expect(geometry.hasPhysicalNotch)
  #expect(geometry.hardwareWidth == 180)
  #expect(geometry.hardwareHeight == 24)
  #expect(geometry.restingWidth == 180)
  #expect(geometry.restingHeight == 24)
}

@Test
func softwareNotchGeometryIsUsedWithoutAValidHardwareCutout() {
  let missingAuxiliaryRegion = NotchGeometry(
    screenWidth: 1_512,
    safeAreaTop: 32,
    auxiliaryTopLeftWidth: nil,
    auxiliaryTopRightWidth: 656
  )
  let missingSafeArea = NotchGeometry(
    screenWidth: 1_512,
    safeAreaTop: 0,
    auxiliaryTopLeftWidth: 656,
    auxiliaryTopRightWidth: 656
  )
  let implausiblyNarrowCutout = NotchGeometry(
    screenWidth: 1_512,
    safeAreaTop: 32,
    auxiliaryTopLeftWidth: 736,
    auxiliaryTopRightWidth: 736
  )

  for geometry in [
    missingAuxiliaryRegion,
    missingSafeArea,
    implausiblyNarrowCutout,
  ] {
    #expect(!geometry.hasPhysicalNotch)
    #expect(geometry.hardwareWidth == 0)
    #expect(geometry.hardwareHeight == 0)
    #expect(geometry.restingWidth == 176)
    #expect(geometry.restingHeight == max(geometry.menuBarHeight, geometry.hardwareHeight))
  }
}

@Test
func surfaceBodyClearsTheHardwareNotchInEveryMode() {
  let geometry = NotchGeometry(
    screenWidth: 1_512,
    safeAreaTop: 32,
    auxiliaryTopLeftWidth: 656,
    auxiliaryTopRightWidth: 656
  )
  var musicWithIndicator = CompactPresentation()
  musicWithIndicator.update(available: [.music, .battery], needsApproval: false)

  for presentation in [CompactPresentation(), musicWithIndicator] {
    for mode in [SurfaceMode.compact, .peek, .expanded] {
      let size = geometry.surfaceSize(
        for: mode,
        presentation: presentation,
        hasRecentActivity: false
      )
      let ear = NotchSurfaceMetrics(mode: mode).earRadius
      #expect(size.width - 2 * ear >= geometry.hardwareWidth)
      #expect(size.height >= geometry.hardwareHeight)
    }
  }
}

@Test
func transitionCanvasHoldsBothOutlinesAndOvershoot() {
  let compact = CGSize(width: 432, height: 32)
  let expanded = CGSize(width: 588, height: 500)

  let growing = NotchGeometry.transitionCanvasSize(displayed: compact, target: expanded)
  #expect(growing.width > expanded.width)
  #expect(growing.height > expanded.height)

  // Shrinking keeps the larger outline visible until the spring settles.
  let shrinking = NotchGeometry.transitionCanvasSize(displayed: growing, target: compact)
  #expect(shrinking == growing)
}

@Test
func onlyTheExpandedPanelReservesRoomForItsShadow() {
  let surface = CGSize(width: 432, height: 32)

  for mode in [SurfaceMode.compact, .peek] {
    #expect(NotchGeometry.restingPanelSize(surface: surface, mode: mode) == surface)
  }
  let expanded = NotchGeometry.restingPanelSize(surface: surface, mode: .expanded)
  #expect(expanded.width > surface.width)
  #expect(expanded.height > surface.height)
}

@Test
func clicksPassThroughEverywhereTheOutlineIsNotDrawn() {
  let panel = CGRect(x: 0, y: 0, width: 628, height: 530)
  let surface = CGRect(x: 20, y: 30, width: 588, height: 500)
  func passes(_ x: CGFloat, _ y: CGFloat) -> Bool {
    NotchGeometry.passesMouseThrough(
      at: CGPoint(x: x, y: y), panelFrame: panel, surfaceFrame: surface, mode: .expanded
    )
  }

  #expect(passes(10, 520), "Shadow margin")
  #expect(passes(300, 10), "Below the surface")
  #expect(!passes(314, 280), "Inside the drawn outline")
  // Inside the surface's bounds but beside the inset body, below its ear.
  #expect(passes(25, 300), "Side strip excluded by the ears")
  // The rounded bottom-left corner of the outline.
  #expect(passes(36, 32), "Cut-off bottom corner")
  // Outside the panel the setting has no effect; leave the panel interactive
  // so a drag arriving from elsewhere still finds the drop target.
  #expect(!passes(900, 300))
}
