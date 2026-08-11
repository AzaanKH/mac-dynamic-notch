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
func smallPhysicalNotchStillUsesMinimumRestingDimensions() {
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
  #expect(geometry.restingHeight == 32)
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
    #expect(geometry.restingHeight == 34)
  }
}
