import AppKit
@testable import NotchRouterApp
import Testing

@Test
func panelKeyboardActionsMapNavigationAndNumberKeys() {
  #expect(
    PanelKeyboardAction.resolve(keyCode: 48, modifierFlags: [])
      == .selectNextKeyView
  )
  #expect(
    PanelKeyboardAction.resolve(keyCode: 48, modifierFlags: .shift)
      == .selectPreviousKeyView
  )
  #expect(PanelKeyboardAction.resolve(keyCode: 53, modifierFlags: []) == .collapse)
  #expect(
    PanelKeyboardAction.resolve(keyCode: 123, modifierFlags: [])
      == .selectPreviousSection
  )
  #expect(
    PanelKeyboardAction.resolve(keyCode: 124, modifierFlags: [])
      == .selectNextSection
  )

  let topRowKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22]
  let keypadKeyCodes: [UInt16] = [83, 84, 85, 86, 87, 88]
  for (index, keyCode) in topRowKeyCodes.enumerated() {
    #expect(
      PanelKeyboardAction.resolve(keyCode: keyCode, modifierFlags: [])
        == .selectSection(index + 1)
    )
  }
  for (index, keyCode) in keypadKeyCodes.enumerated() {
    #expect(
      PanelKeyboardAction.resolve(keyCode: keyCode, modifierFlags: .numericPad)
        == .selectSection(index + 1)
    )
  }
}

@Test
func panelKeyboardActionsIgnoreConflictingModifiersAndUnknownKeys() {
  for modifiers: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
    #expect(
      PanelKeyboardAction.resolve(keyCode: 18, modifierFlags: modifiers) == nil
    )
    #expect(
      PanelKeyboardAction.resolve(keyCode: 123, modifierFlags: modifiers) == nil
    )
  }

  #expect(PanelKeyboardAction.resolve(keyCode: 48, modifierFlags: .command) == nil)
  #expect(PanelKeyboardAction.resolve(keyCode: 0, modifierFlags: []) == nil)
  #expect(
    PanelKeyboardAction.resolve(keyCode: 18, modifierFlags: .capsLock)
      == .selectSection(1)
  )
}

@MainActor
@Test
func numberShortcutsOpenTheirMatchingSections() {
  let viewModel = NotchViewModel()

  for section in NotchSection.allCases {
    #expect(viewModel.selectSection(keyboardNumber: section.keyboardNumber))
    #expect(viewModel.mode == .expanded)
    #expect(viewModel.selectedSection == section)
  }

  #expect(!viewModel.selectSection(keyboardNumber: 0))
  #expect(!viewModel.selectSection(keyboardNumber: 7))
}

@MainActor
@Test
func arrowNavigationCyclesAndWrapsExpandedSections() {
  let viewModel = NotchViewModel()

  #expect(!viewModel.selectAdjacentSection(offset: 1))
  viewModel.show(.activity)

  #expect(viewModel.selectAdjacentSection(offset: -1))
  #expect(viewModel.selectedSection == .system)
  #expect(viewModel.selectAdjacentSection(offset: 1))
  #expect(viewModel.selectedSection == .activity)
  #expect(viewModel.selectAdjacentSection(offset: 1))
  #expect(viewModel.selectedSection == .focus)
}

@MainActor
@Test
func collapseAndInvalidKeyboardNavigationPreserveExpectedState() {
  let viewModel = NotchViewModel()
  var modeChanges: [SurfaceMode] = []
  viewModel.onModeChange = { modeChanges.append($0) }

  viewModel.show(.files)
  #expect(viewModel.mode == .expanded)
  viewModel.collapse()
  #expect(viewModel.mode == .compact)
  #expect(viewModel.selectedSection == .files)
  #expect(!viewModel.selectAdjacentSection(offset: 1))
  #expect(viewModel.selectedSection == .files)

  viewModel.collapse()
  #expect(modeChanges == [.expanded, .compact])
}
