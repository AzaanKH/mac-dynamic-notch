# Optional integrations

Clipboard history, player controls, and the browser bridge require explicit
opt-in. Their disabled states are part of the default user experience.

## Sub-features

- `clipboard.disabled`: capture is off until enabled.
- `music.disabled`: player polling is off until enabled.
- `bridge.setup`: browser and Codex integrations have explicit installation controls.

## How to get to it (user POV)

- Clipboard button, key 5, Show Clipboard menu, or hover Clipboard shortcut;
  Enable Clipboard History also appears in Settings → Privacy.
- Music button, key 4, Show Music menu, or the compact/hover music presentation;
  Enable Music Controls and Settings → Privacy expose the opt-in.
- Settings → Integrations offers Install Hooks and Install Browser Bridge.
  CLI equivalents are install-codex-hooks and install-browser-extension,
  with matching remove commands. Browser toolbar opt-in enables downloads.

## Driving it with native cua_repl

Preconditions: baseline launch with integrations held off.

- Clipboard: click Clipboard or separately run `await notch.pressKey("5")`,
  then `await notch.getAXState()`. Require Enable Clipboard History and no
  captured user content. Do not use the real pasteboard as test seed.
- Music: click Music or separately run `await notch.pressKey("4")`, then
  inspect state. Require Enable Music Controls. Do not click it in this run.
- Setup discovery: open Settings → Integrations. Capture the opt-in hook and
  browser bridge controls, without installing them.
- Enabled workflows: record as blocked in this baseline. Use a separate macOS
  test account, a disposable browser profile, synthetic clipboard content,
  explicitly authorized media controls, and the setup instructions in
  `BrowserExtension/README.md` before testing. Do not adapt the helper by merely
  removing its flags while remaining in the user's shared session.

## Gotchas

- `CFFIXED_USER_HOME` redirects app files, not the system pasteboard, real
  player playback, volume, browser profiles, or permission prompts.
- Forced-off arguments override saved opt-in values; clicking an enable control
  cannot establish a reliable enabled baseline for this skill.
- CLI installers are intentionally blocked by the wrapper. Their presence in
  source or Settings does not prove installation or native messaging works.
- The temporary bundle omits bridge installation resources. Use the packaged
  app in the separate account to test the real installer.
- Safari is unsupported. Firefox temporary add-ons must be reloaded after
  browser restart. Download permission is a separate opt-in from media access.
