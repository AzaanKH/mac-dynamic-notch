---
name: verify-notchrouter
description: Launch an isolated NotchRouter macOS app and verify its notch panel, activity CLI, and private local API with saved evidence. Use for behavior checks after app changes or to reproduce desktop and integration regressions.
---

# Verify NotchRouter

NotchRouter is a macOS 14+ Swift 6 desktop app. Its primary interface is the
AppKit/SwiftUI notch panel. `notchctl` and the authenticated Unix-socket API
publish external agent activity. Read [the feature map](features/README.md),
then the relevant recipe before driving it.

## Launch

Run from the repository root on a logged-in macOS desktop with Swift 6,
Python 3, and the native `cua_repl` tool available for UI checks:

```sh
VERIFY_CTL="$PWD/.agents/skills/verify-notchrouter/scripts/control.py"
VERIFY_RUN=$("$VERIFY_CTL" launch)
printf '%s\n' "$VERIFY_RUN"
"$VERIFY_CTL" doctor "$VERIFY_RUN"
```

Keep `VERIFY_RUN` for later calls. Shell variables do not persist between tool
sessions; use the printed absolute directory when necessary.

The helper runs `swift build`, copies the actual debug app and CLI into a
disposable bundle, and links its existing Sparkle framework. It uses a unique
`com.notchrouter.verify.r…` bundle identifier for preferences and a short
`/tmp/notch-verify-…/home` via `CFFIXED_USER_HOME` for Foundation paths. A
Foundation probe must confirm that redirection before the app starts. Data,
token, instance lock, and `api.sock` belong to that home. No seed or API key
is required; the app creates its integration token. macOS `cfprefsd` writes
that unique preference domain in the account's normal Preferences folder;
cleanup deletes only the generated domain. Existing app preferences are untouched.

Readiness means the recorded PID owns the private socket, `/v1/health` returns
`{"status":"ok"}`, authenticated listing succeeds, and unauthenticated listing
fails with 401. No TCP listener is allowed. Legacy TCP normally uses 48271 but
is disabled here. Launch failures clean up their disposable process and state.

This runs the real app, with no dry-run mode or mocked stores. Launch arguments
hold clipboard capture, music integration, notifications, focus sound, crash
reporting, and legacy TCP off. The temporary bundle has no Sparkle feed or
release resources, so this workflow cannot prove updates, release packaging,
browser installation, notification delivery, or enabling those held-off
preferences. The system pasteboard, media players, global shortcut, display,
and OS permission store remain shared. Use a separate macOS test account for
those integrations. Avoid Option-N while another copy owns that shortcut.

The documented normal launch is `./scripts/package-app.sh` followed by
`open .build/NotchRouter.app`, or `swift run NotchRouter`. Those commands use
the user's real state. Do not use them for this isolated workflow, or launch
the disposable bundle with `open`, which would lose its environment.

## Doctor

```sh
"$VERIFY_CTL" doctor "$VERIFY_RUN"
```

Run before the first drive and after surprising failures. It reads the process
start time and command, app/CLI hashes, bundle identity, data ownership and
permissions, socket ownership, TCP listeners, health, and authentication state.
It writes only `doctor.json` in the evidence directory. It never creates or
prints a token. A failed check means stop driving and inspect `app.log`.

## Drive

Start with the repeatable CLI activity proof:

```sh
"$VERIFY_CTL" proof "$VERIFY_RUN"
```

This calls real `notchctl send` and `list`, checks running then succeeded on
the same activity ID, and independently reads persisted `activities.json`.
For individual commands use the wrapper, which supplies the isolated home:

```sh
"$VERIFY_CTL" cli "$VERIFY_RUN" -- health
"$VERIFY_CTL" cli "$VERIFY_RUN" -- list
"$VERIFY_CTL" cli "$VERIFY_RUN" -- send --id verification-review \
  --source "Verification Agent" --title "Review verification" \
  --state needs_approval --message "Waiting for a local review" --progress 0.5
```

For desktop proof, read `bundle_id` and `app` from `run.json` after doctor
passes. Bind `notch` using `await cua.getApp(bundleID)` in `cua_repl`, with
`bundleID` set to that exact recorded value. Never resolve by the generic
name `NotchRouter`, which could select the user's copy. `getApp` can launch
missing apps, so do not call it after this run exits or is cleaned up.

Click the `NotchRouter` container from the fresh accessibility tree using
`await notch.click(index)`, then `await notch.getAXState()`. Here and in the
feature recipes, `index` means the matching element number from the latest
tree, never a stored number. Use named buttons, fields, and menu items. On an
expanded panel, `await notch.pressKey("2")` selects Focus and
`await notch.pressKey("Escape")` collapses it. Inspect fresh state after actions.

If native discovery fails, retry `cua.getApp` once with the recorded bundle ID.
If that also fails, retain the CLI proof and report desktop checks blocked.
Do not substitute API success for UI verification.

## Evidence

Artifacts live in `.build/verification/notchrouter/<run-id>/`, already ignored
by Git. The launch output gives the real path. Preserve it when cleaning up.
`run.json` records the exact build hashes, PID, bundle, and disposable paths.
`commands.jsonl` records each CLI action, stdout, stderr, and exit code.
`activities-running.json`, `activities-succeeded.json`, and matching
`persisted-*.json` prove both updates through independent read-only views.
`proof.json` describes only the CLI proof; UI results belong in `ui-actions.json`.

For UI proof, set `evidencePath` to the printed directory in `cua_repl`, then
save before and after observations. Use the corresponding label for each:

```js
var fs = await import('node:fs/promises');
await fs.writeFile(evidencePath + '/activity-before.ax.txt',
  await notch.getAXState({disableDiffing: true, emit: false}));
await fs.writeFile(evidencePath + '/activity-before.png',
  await notch.getScreenshot({emit: false}));
await notch.getAXState({disableDiffing: true});
```

After clicking `Show details`, save `activity-details.ax.txt` and
`activity-details.png` using the same calls. Inspect the PNG and require the
app identity, title, completion state, both update messages, and `Hide details`.
Write `ui-actions.json` with feature ID, bundle ID, actual actions, expected
result, and observed result. The independent second view is the CLI list and
persisted history. For timer and file shelf mutations, use the second views
specified in their recipes. Never archive the token or unrelated user data.

## Cleanup

```sh
"$VERIFY_CTL" cleanup "$VERIFY_RUN"
test -s "$VERIFY_RUN/proof.json"
test -s "$VERIFY_RUN/cleanup.json"
```

Run cleanup after success and failed drives. For an unattended shell proof,
install `trap '"$VERIFY_CTL" cleanup "$VERIFY_RUN"' EXIT` after launch succeeds.
For UI verification across tool calls, finish explicitly in a cleanup step.
The helper compares PID, process start time, and executable before SIGTERM,
waits for exit, deletes its unique preference domain with `defaults`, then
removes only its marked temporary root. It is safe to call
again. A replaced or stuck PID causes refusal; inspect that specific PID,
never kill by process name. Persistence proof waits for disk writes before
cleanup; SIGTERM itself does not prove graceful app termination.

Verify saved screenshots and transcripts still exist after cleanup. If testing
Quit from the UI, use `Quit NotchRouter` on this bound app first, then cleanup.

## Helpers

One executable helper is included: `scripts/control.py`.

| Invocation | Effect |
| --- | --- |
| `control.py launch` | Build, launch, wait for doctor, print the evidence directory |
| `control.py doctor RUN` | Read-only app checks; save their report |
| `control.py cli RUN -- COMMAND ARGS` | Run isolated health/list/send/demo/help and record the result |
| `control.py proof RUN` | Verify activity publishing, updating, listing, and persistence |
| `control.py cleanup RUN` | Stop the owned app and remove disposable state; retain evidence |

`RUN` means the exact directory printed by launch. Installers and token output
are deliberately excluded from the wrapper. `demo` publishes an approval card
with an example.com action URL; publishing does not follow that URL.

The build is checked by launch. For code changes also follow repository testing
rules: a relevant `swift test --filter TestClassName`, or `swift test` for
package-wide changes. Use `./scripts/package-app.sh` for actual packaging
changes; the temporary verification bundle is not release-package evidence.
