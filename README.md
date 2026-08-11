# NotchRouter

NotchRouter is a native macOS notch hub for live AI work, files, music,
clipboard history, and local system status. It uses a transparent AppKit panel
at the top center of the active display and hosts a restrained SwiftUI
interface inside it.

The compact surface prioritizes one live signal at a time. The expanded surface
provides six focused sections instead of turning the notch into a dense
control-center dashboard.

## What is implemented

- Physical-notch geometry from `NSScreen.safeAreaInsets` and the auxiliary top
  regions, with a software-notch fallback on external displays.
- A borderless `NSPanel` across Spaces and full-screen apps.
- Keyboard-first operation: Option-Space opens Activity globally, Escape
  collapses, Left/Right Arrow cycles sections, 1–6 jumps directly to a
  section, and Tab/Shift-Tab traverses controls.
- Compact, hover/peek, and expanded states with reduced-motion support.
- Contextual hover shortcuts for jumping directly to Activity, Files, Music,
  or Clipboard without opening the default section first.
- A local AI activity API with token authentication.
- Current state plus a bounded history of what each agent reported doing.
- Review/deep-link actions for approval events.
- A persistent 15, 25, or 50-minute focus timer with pause, resume, reset, and
  add-time controls, plus optional completion notifications and sounds.
- Optional macOS notifications for approval, completion, and failure. They are
  off until enabled from Settings, where each notification type can be chosen
  independently.
- A small `notchctl` client intended for agent hooks and Apple Shortcuts.
- A persistent file shelf with whole-notch drop targeting, an open-panel
  fallback, drag-out, native Quick Look, missing-file cleanup, Finder reveal,
  and AirDrop actions.
- Opt-in Apple Music and Spotify metadata and controls using bounded,
  background Apple Events. No private MediaRemote framework is loaded.
- An opt-in Manifest V3 extension for Chrome, Edge, Brave, and Chromium that
  relays active audio/video metadata and, with a separate optional Downloads
  permission, download progress and controls through an authenticated
  native-messaging host.
- Event-driven Mac charging percentage and time-to-full status from IOKit,
  shown contextually on the compact surface while charging.
- An opt-in combined System section for aggregate CPU and memory usage, memory
  pressure, free disk space, thermal state, Low Power Mode, local connection
  state, Wi-Fi signal, VPN detection, and network throughput.
- System output volume and mute controls in both the hover mini-player and the
  expanded Music section, implemented with public Core Audio APIs.
- A native Settings window for launch-at-login, pointer/active-window/pinned
  display placement, optional external-display hiding, history retention,
  notification types, permissions, token rotation, and integration setup.
- Opt-in text and image clipboard history with concealed, transient,
  auto-generated, and known password-manager pasteboards excluded, plus
  search, pinned clips, configurable auto-expiry, and per-app exclusions.
- JSON persistence under `~/Library/Application Support/NotchRouter`.

## Build and run

Requirements: macOS 14 or later and Swift 6.

```sh
./scripts/package-app.sh
open .build/NotchRouter.app
```

The packaging script creates a universal `arm64`/`x86_64` app. Local bundles
are left unsigned unless `CODESIGN_IDENTITY` is provided; it never falls back
to an ad-hoc signature.

The package also opens directly in Xcode through `Package.swift`. For fast
development without an app bundle:

```sh
swift run NotchRouter
```

UserNotifications work most predictably from the packaged `.app`.

Developer ID signing, hardened runtime, notarization, the stapled DMG, Sentry
symbol upload, and Sparkle's signed appcast are handled by the tag-driven
release workflow. See [Releasing NotchRouter](docs/RELEASING.md) for required
credentials and verification commands.

## Focus, files, music, clipboard, and system status

Click the notch and choose a section from the navigation strip.

### Focus timer

Choose **Focus**, select a 15, 25, or 50-minute session, and start the timer.
The countdown continues when the notch is collapsed and across app relaunches.
An active or paused timer appears on the compact surface when no AI activity
needs attention. You can pause or resume it directly from the hover surface,
add five minutes from the expanded controls, and restart or dismiss it when the
session completes.

Completion notifications and sounds can be enabled independently in
**Settings → Notifications**. Both are off by default; the sound does not
require system notification permission.

### File shelf

Drag files or folders directly onto the notch, or choose **Files → Choose
Files…**. NotchRouter stores read-only security-scoped bookmarks; it does not
copy, move, upload, or delete the underlying files. Clearing the shelf removes
only its bookmarks.

Items can be dragged back into another app, previewed with Quick Look, opened
with a double-click, revealed in Finder, or deliberately sent through AirDrop.
Unavailable items are marked as missing; **Clean Missing** removes only those
stale shelf entries and never deletes files from disk.

Chromium download history also appears inside Files when the browser bridge's
optional Downloads permission is enabled. Active downloads take over the
compact surface when no AI activity has priority. Pause, resume, cancel, and
Finder reveal commands are returned to the browser through native messaging;
the app never performs or proxies the download itself.

### Music

Choose **Music → Enable Music Controls**. When Apple Music or Spotify is
running, macOS may request Automation permission for that app. The integration
reads the current title, artist, album, duration, position, and playback state
and exposes previous, play/pause, and next controls. Spotify's current artwork
URL supplies the cover image; Apple Music uses a native fallback because its
public scripting metadata does not expose an artwork URL.

The hover mini-player and expanded Music section also expose the current system
output volume. The slider follows output-device and keyboard volume changes,
and the speaker button toggles mute when the active device supports it.

The resting music surface is narrower than an AI activity. It shows only the
cover and playback state around a physical notch. Hover expands it into a
mini-player with the track, artist, previous/play-pause/next controls, and
shortcuts to Activity, Files, and Clipboard. A deliberate click opens the full
Music section immediately. Starting playback or using the previous/next
controls briefly reveals the mini-player; passive song transitions update the
compact artwork without opening it.

Previous and next schedule fast follow-up polls after the player accepts the
command, so new metadata replaces the old track without waiting for the regular
eight-second playback poll.

Each script request runs away from the UI and has a timeout, so a stalled player
cannot freeze the notch. Polling stops completely when music support is
disabled.

NotchRouter also holds a per-user process lock. Launching another installed or
development copy brings the existing instance forward instead of creating a
second panel over the notch.

#### Browser media and downloads

The packaged app includes an opt-in browser extension for Google Chrome,
Microsoft Edge, Brave, and Chromium. Open **Settings → Integrations → Browser
bridge** and choose **Install Browser Bridge**. Then:

1. Open the browser's Extensions page and enable Developer mode.
2. Choose **Load unpacked**.
3. Select the extension folder opened by NotchRouter.

Media support is then active. To add downloads, pin or open the extension and
click its toolbar icon, then approve the Downloads permission. An **ON** badge
indicates access is enabled; clicking again revokes the permission. Download
updates add no internet traffic because the browser already performs the
transfer and sends only small local status messages.

Playing audio or video then supplies the page title, creator, site, artwork,
playback state, position, and duration to the Music surface. Play/pause works on
the active media element. Previous and next are enabled only when the page exposes
a matching media transport button; previous can also restart media that is
more than three seconds in.

The content script observes only media elements and standard media/page
metadata. It does not send page contents, browsing history, cookies, or
authentication data. A native-messaging helper reads the user-only integration
token and calls the loopback API, so neither the extension nor a web page can
read that token. Browser sessions expire if the extension stops heartbeating.

The same setup is available from the CLI:

```sh
.build/NotchRouter.app/Contents/Resources/bin/notchctl install-browser-extension
.build/NotchRouter.app/Contents/Resources/bin/notchctl remove-browser-extension
```

Safari requires a separately signed Safari app extension, and persistent
Firefox installation requires a signed add-on, so neither is advertised as
supported by this local package. No private MediaRemote framework is loaded.

### Battery and System

While the Mac is charging, the compact surface can show battery percentage and
the IOKit time-to-full estimate. It displays **Calculating…** when macOS has not
yet stabilized the estimate. Accessory batteries are intentionally not
advertised because macOS has no single reliable public API for AirPods, Magic
accessories, and other Bluetooth devices.

Choose **System**, or enable it under **Settings → General → System section**,
for aggregate CPU, memory pressure and use, disk, thermal, Low Power Mode, and
network information. Sampling runs every two seconds while compact and every
second while expanded, and stops when the feature is disabled. The metrics use
local APIs and interface counters. **Test connection** is the only action that
contacts the internet; it sends an on-demand HEAD request to Apple's small
connectivity endpoint and reports elapsed time.

### Clipboard

Choose **Clipboard → Enable Clipboard History**, or enable it in **Settings →
Privacy**. Capture starts from the next copy; enabling it does not import the
current clipboard. NotchRouter records text and standard PNG/TIFF image copies,
caps text entries at 10,000 characters, uses the retention limit selected in
Settings, and writes the history and image files with user-only permissions.
Oversized images are downscaled before storage.

Double-click a history row or use its copy button to put its text or image back
on the clipboard. Use the search field to filter by clip contents, content type,
or source app.
Pinned clips stay at the top and are protected from the configured entry limit
and auto-expiry. Choose an expiry period under **Settings → General**.

Known sensitive pasteboard markers are rejected before content is read. The
menu-bar integration token is also written using a concealed pasteboard type
and explicitly suppressed from history. Apps selected under **Settings →
Privacy → Clipboard history** are also excluded by bundle identifier before
their pasteboard contents are read. Content-based secret detection is not
attempted, so clipboard capture should remain visibly opt-in.

To fully close NotchRouter, hover over it and use the red power button at the
end of the shortcut row, expand it and use the power button in the top-right
corner, right-click the notch and choose **Quit NotchRouter**, or use the
menu-bar item. Command-Q also works while the expanded notch is active.

## Send an AI activity

Build the project, launch the app, and use the generated CLI:

```sh
.build/NotchRouter.app/Contents/Resources/bin/notchctl send \
  --id checkout-review-42 \
  --source "My Agent" \
  --title "Review checkout changes" \
  --state running \
  --message "Running unit tests" \
  --progress 0.65
```

Update the same `--id` when its state changes:

```sh
.build/NotchRouter.app/Contents/Resources/bin/notchctl send \
  --id checkout-review-42 \
  --source "My Agent" \
  --title "Review checkout changes" \
  --state needs_approval \
  --message "Three files changed; approval is required" \
  --action-url "https://example.com/reviews/42"
```

Valid states are `queued`, `running`, `needs_approval`, `stale`, `succeeded`,
`failed`, and `cancelled`. NotchRouter automatically marks any nonterminal
activity as `stale` (shown as **Disconnected**) when it receives no update for
five minutes. Send an identical nonterminal update at least once a minute as a
heartbeat; heartbeats refresh liveness without adding duplicate history or
reopening the notch.

Useful diagnostics:

```sh
.build/NotchRouter.app/Contents/Resources/bin/notchctl demo
.build/NotchRouter.app/Contents/Resources/bin/notchctl health
.build/NotchRouter.app/Contents/Resources/bin/notchctl list
```

### T3 Code and Codex adapter

T3 Code uses the Codex app server, so the same Codex lifecycle hooks can publish
its working state to NotchRouter. Build the release CLI, install the user-level
hooks, and restart T3 Code:

```sh
swift build -c release
.build/release/notchctl install-codex-hooks
```

In a new Codex or T3 Code conversation, open `/hooks` and trust the four
NotchRouter hooks. Codex intentionally requires this review whenever a new or
changed command hook is installed.

The adapter maps lifecycle events as follows:

```text
UserPromptSubmit  → running
PermissionRequest → needs_approval
PostToolUse       → running (and periodic heartbeat)
Stop              → succeeded (or failed when no final response exists)
```

It publishes only the turn identifier, workspace name, and lifecycle state. It
does not forward prompts, tool arguments or output, transcripts, source code,
or assistant responses. Delivery is best-effort: if NotchRouter is closed, the
hook exits successfully and never interrupts Codex. Repeated running events are
coalesced to one heartbeat per minute. Re-running the installer is
safe and updates the existing NotchRouter commands without replacing unrelated
hooks or the `notify` command in `~/.codex/config.toml`. The installer copies a
standalone `notchctl` to `~/Library/Application Support/NotchRouter/bin`, so the
hook does not depend on the repository or its `.build` directory remaining in
place.

To remove only the NotchRouter hooks:

```sh
.build/release/notchctl remove-codex-hooks
```

## Integrate another app

There is no public macOS API that reveals arbitrary AI apps' internal task
state. Reliable integrations therefore need an explicit adapter:

1. A native app or agent plugin emits an event when work starts, changes state,
   needs attention, and ends.
2. A command-line agent invokes `notchctl` from its lifecycle hooks.
3. An Apple Shortcut or automation invokes `notchctl`.
4. A remote service sends events through a small local companion or signed
   push-notification service. Do not expose this loopback server to the network.

The raw endpoint is `POST http://127.0.0.1:48271/v1/activities` with
`Authorization: Bearer <token>`. Copy or rotate the token from **Settings →
Integrations**, or read it from:

```text
~/Library/Application Support/NotchRouter/integration-token
```

Example JSON:

```json
{
  "activity_id": "agent-session-123",
  "source": "Build Agent",
  "title": "Prepare release",
  "state": "running",
  "message": "Running the macOS test suite",
  "progress": 0.45,
  "action_url": "https://example.com/runs/123"
}
```

The server binds only to `127.0.0.1`, rejects browser-origin requests, caps
request size, and requires the per-user token. Keep summaries free of secrets:
send a useful description of an action, not prompts, source code, clipboard
contents, or model transcripts.

## Local data

NotchRouter stores its integration token, AI history, file bookmarks, and
clipboard history under:

```text
~/Library/Application Support/NotchRouter
```

Clipboard and file-shelf files are written with mode `0600`. The music
integration stores no listening history; only the latest in-memory snapshot is
shown. System Notifications, Music, Clipboard, browser downloads, and System
metrics are disabled until the user enables the relevant capability.

## Recommended adapter contract

An integration should emit transitions rather than frequent logs:

```text
queued → running → needs_approval → running → succeeded
                         └───────────────→ failed
```

Use one stable activity ID for the whole run. Set `action_url` when the user can
review or resume the work in the source app. A future adapter can add a callback
action for approvals, but the MVP uses deep links so NotchRouter never receives
credentials or impersonates the source app.

## Distribution notes

Local packages are unsigned. Tagged releases use the Developer ID, hardened
runtime, notarization, Sparkle, and Sentry pipeline described in
[Releasing NotchRouter](docs/RELEASING.md). The app is intentionally not
sandboxed because local CLI integrations need a stable loopback endpoint and
shared Application Support token. Publish a privacy policy covering crash
reporting before distributing the first Sentry-enabled build.
