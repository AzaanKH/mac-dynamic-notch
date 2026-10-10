# Panel navigation

The compact notch expands into six sections. Users can navigate by mouse,
keyboard, hover shortcuts, or the menu-bar extra.

## Sub-features

- `navigation.expand-collapse`: click expands; Collapse notch or Escape collapses.
- `navigation.sections`: section buttons and number keys select the same section.
- `navigation.menu`: menu entries open the requested section.
- `navigation.quit`: quit controls terminate the selected app.

## How to get to it (user POV)

- Hover or click the notch; use Activity, Focus, Files, Music, Clipboard, System.
- Expanded keyboard controls are 1–6, Left/Right Arrow, Tab/Shift-Tab, Escape.
- Menu-bar entries are Show Activity, Show Focus Timer, Show Files, Show Music,
  Show Clipboard, Show System, Settings…, and Quit NotchRouter.
- Quit also appears on the hover power button, expanded power button,
  right-click context menu, and Command-Q while expanded.

## Driving it with native cua_repl

Preconditions: doctor passed; exact verification bundle bound to `notch`.

- Expand: click the `NotchRouter` container from fresh state. Require
  `NOTCH ROUTER`, all six section buttons, and `Private event API ready`.
- Section buttons: click each named button and capture the selected state and
  section-specific controls. Use the corresponding feature recipe for results.
- Section keys: `await notch.pressKey("2")` then `await notch.getAXState()`
  must select Focus with Start Focus. Repeat separately for 1 Activity,
  3 Files, 4 Music, 5 Clipboard, and 6 System.
- Arrow navigation: `await notch.pressKey("Right")` or
  `await notch.pressKey("Left")`, then inspect the selected section.
- Focus traversal: `await notch.pressKey("Tab")` and
  `await notch.pressKey("shift+Tab")`; require the focused element to move.
- Collapse: click `Collapse notch`; separately test
  `await notch.pressKey("Escape")`. Each should remove expanded controls.
- Menu entries: select the verification app's menu extra from its own tree,
  then click the exact Show… name. Require the corresponding selected section.
- Quit: after saving evidence, click the bound app's `Quit NotchRouter`.
  For the keyboard entry, use `await notch.pressKey("super+q")` on the expanded
  app. `ps -p` for the recorded PID must show it exited; run cleanup afterward.

## Gotchas

- Section order is Activity, Focus, Files, Music, Clipboard, System.
- A physical notch and an external display have different geometry. Capture
  the display used; neither proves the other.
- If menu-extra or hover controls are absent from the accessibility tree,
  capture a fresh screenshot and use only the bound app's observed controls.
  A hidden entry point is unverified, not equivalent to a passing section key.
- Avoid desktop-wide coordinates when the installed app overlaps the test app.
- Once Quit succeeds, do not call `cua.getApp` again; it could relaunch without
  the isolated environment.
