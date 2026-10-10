# Settings and private API

Users inspect preferences and opt into integrations. Activity publishing uses a
private local socket and a bearer token.

## Sub-features

- `settings.open`: all settings controls open the same settings window.
- `settings.tabs`: General, Notifications, Privacy, and Integrations are reachable.
- `api.health-auth`: health is public locally; listing requires the token.

## How to get to it (user POV)

- Expanded Open Settings button, notch context-menu Settings…,
  menu-bar Settings…, or Command-comma while expanded.
- In Settings choose General, Notifications, Privacy, or Integrations.
- CLI health/list and the Unix socket provide diagnostic entry points.

## Driving it with native cua_repl and control.py

Preconditions: doctor passed; bind the unique verification bundle.

- Gear: click Open Settings. Require a `NotchRouter Settings` window.
- Keyboard: separately use `await notch.pressKey("super+comma")` on the
  expanded panel, then inspect state and require the same settings window.
- Menus: separately choose Settings… in the notch context menu and the
  verification menu extra. Record each successful entry point.
- Tabs: click General, Notifications, Privacy, Integrations using current
  accessibility indices. Capture headings and controls for each tab.
- API diagnostics: `"$VERIFY_CTL" doctor "$VERIFY_RUN"` proves GET
  `/v1/health` is 200, GET `/v1/activities` without a token is 401, and a
  token-authenticated GET is 200. Inspect `doctor.json` and the Integrations
  status in the UI independently.
- CLI diagnostics: `"$VERIFY_CTL" cli "$VERIFY_RUN" -- health` and
  `"$VERIFY_CTL" cli "$VERIFY_RUN" -- list`; require exit 0 and valid JSON.

## Gotchas

- Open Data Folder exposes the isolated folder only when the run launched
  with its recorded environment. Read paths before opening anything.
- Do not click Copy Token, reveal tokens into screenshots, rotate tokens, or
  enable legacy TCP as part of the baseline proof.
- Login items and OS permission settings are shared with the macOS account.
  A disposable app home does not isolate them.
- Check for Updates is unavailable in the temporary bundle because no release
  feed or public key is supplied. That is not a release-update test.
