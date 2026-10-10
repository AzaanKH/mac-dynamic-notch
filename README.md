# NotchRouter

NotchRouter puts AI activity, a focus timer, files, music, clipboard history,
and system status in a macOS notch panel. It supports physical notches and
external displays, Spaces, and full-screen apps.

The compact panel shows one live signal at a time. Hover to peek, or click to
open the six sections. Option-N opens Activity; Escape collapses the panel.
Left/Right Arrow cycles sections and 1–6 selects a section. Tab/Shift-Tab moves
between text fields, and between all controls when Keyboard Navigation is on in
System Settings › Keyboard.

Integrations are opt-in. Agents send activity through the local `notchctl` CLI
or authenticated local API. Music supports Apple Music, Spotify, and an
optional browser bridge.

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

Run the test suite with `swift test`, or use `swift test --filter <test-name>`
for a focused check. See [AGENTS.md](AGENTS.md) for repository conventions.

Developer ID signing, hardened runtime, notarization, the stapled DMG, Sentry
symbol upload, and Sparkle's signed appcast are handled by the tag-driven
release workflow. See [Releasing NotchRouter](docs/RELEASING.md) for required
credentials and verification commands.

## Using the app

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

Browser download history also appears inside Files when the browser bridge's
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
shortcuts to the other sections. A deliberate click opens the full Music section
immediately. Playback changes update the compact artwork and playback state but
never open the mini-player on their own.

When artwork is available (Spotify or the browser bridge), NotchRouter samples
the cover art and tints the notch with a soft ambient glow derived from the
dominant color. The compact playback glyph, progress bar, and play button pick
up the same accent. Colors are normalized for legibility on black and cached per
artwork URL. Increased Contrast suppresses the glow; Reduce Motion limits
transitions. Apple Music's native fallback keeps the default pink
accent because its scripting metadata exposes no artwork URL.

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

The packaged app includes an opt-in browser extension for Chrome, Edge, Brave,
Chromium, and Firefox-compatible browsers including Zen. Open
**Settings → Integrations → Browser bridge** and choose **Install Browser Bridge**
or **Reinstall Bridge** to update an earlier installation. Then:

- In **Zen or Firefox**, open `about:debugging#/runtime/this-firefox`, choose
  **Load Temporary Add-on**, and select `manifest.json` from the installed
  extension folder. Allow the media sites you want to use and reload those tabs.
  You must repeat temporary loading after restarting the browser. A persistent,
  Mozilla-signed add-on is not included yet.
- In **Chrome, Edge, Brave, or Chromium**, enable Developer mode on the Extensions
  page, choose **Load unpacked**, and select the installed extension folder.
- **Safari is not supported yet.** It needs a bundled Safari Web Extension and
  a different native messaging handler.

See [the browser bridge guide](BrowserExtension/README.md) for version requirements
and installation details.

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
token and calls the private per-user socket, so neither the extension nor a web page can
read that token. Browser sessions expire if the extension stops heartbeating.

Browser artwork is fetched by the content script without credentials or redirects,
subject to browser access restrictions. It sends a JPEG thumbnail of at most
256 × 256 pixels and 32 KiB to the app, cropped to a centered square. Only PNG,
JPEG, GIF, and WebP covers up to 16 megapixels are used, checked from the file
header before decoding. Other formats, and sites that prevent artwork access,
retain the fallback icon. Legacy extensions can still report playback, but their artwork
URLs are never fetched by native code. Native Spotify artwork is restricted to
recognized Spotify HTTPS hosts, with an 8 MB streaming limit and bounded decoding.

The same setup is available from the CLI:

```sh
.build/NotchRouter.app/Contents/Resources/bin/notchctl install-browser-extension
.build/NotchRouter.app/Contents/Resources/bin/notchctl remove-browser-extension
```

Safari requires a separately signed Safari app extension, and persistent
Firefox installation requires a signed add-on, so neither is advertised as
supported by this local package.

### Battery and System

While the Mac is charging, the compact surface can show battery percentage and
the IOKit time-to-full estimate. It displays **Calculating…** when macOS has not
yet stabilized the estimate. Accessory batteries are intentionally not
advertised because macOS has no single reliable public API for AirPods, Magic
accessories, and other Bluetooth devices.

Choose **System**, or enable it under **Settings → General → System section**,
for aggregate CPU, memory pressure and use, disk, thermal, Low Power Mode, and
network information. Sampling runs every ten seconds in the background and every
second while the expanded System section is visible, or every two seconds in
Low Power Mode. Opening System refreshes immediately. Sampling pauses while
displays sleep and stops when the feature is disabled. The metrics use
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

It publishes the turn identifier, workspace name, lifecycle state, tool name,
and a final response excerpt of up to 1,000 characters to local NotchRouter.
A `task_title` label or the hook's `prompt` supplies a task title of up to 160
characters, retained across later updates. If neither is supplied, the card
uses “AI work”. Show details expands the saved message and dated update history.
Prompt and response excerpts may contain sensitive task content and are saved
in local activity history. The adapter does not read transcripts or tool output.
Delivery is best-effort: if NotchRouter is closed, the hook exits successfully
and never interrupts Codex. Changed details publish immediately; identical
running events are coalesced to one heartbeat per minute. Re-running the installer is
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
   push-notification service. Do not expose the local API to the network.

The default transport is the private Unix socket at
`~/Library/Application Support/NotchRouter/api.sock`. Use `notchctl`, or send
`POST http://localhost/v1/activities` through that socket with curl's
`--unix-socket` option and
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

The private socket requires the per-user token and sits in a directory accessible
only to your macOS account. Token rotation closes accepted connections immediately.
Requests have a 64 KiB limit, a 10-second lifetime, and a 64-connection cap.

For existing third-party clients, **Settings → Integrations → Allow legacy TCP
integrations** enables `http://127.0.0.1:48271`. TCP defaults off. It still rejects
browser-origin requests and requires the token, but another local account can
impersonate that port while NotchRouter is stopped. The bundled CLI and browser
bridge never fall back to TCP.

Installed integrations run helper executables copied at install time, and helpers
from before this update use TCP, which no longer works with the new default
transport. Settings → Integrations marks hooks or a bridge whose helper differs
from the running app's copy; choose **Update Hooks** or **Update Bridge**, then
reload the browser extension and refresh media tabs.

Keep summaries free of secrets:
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
shown. Notifications, Music, Clipboard, browser downloads, and System
metrics are disabled until the user enables the relevant capability.

## Recommended adapter contract

An integration should emit transitions rather than frequent logs:

```text
queued → running → needs_approval → running → succeeded
                         └───────────────→ failed
```

Use one stable activity ID for the whole run. Set `action_url` when the user can
review or resume the work in the source app. Approval actions open deep links;
NotchRouter does not approve work on the source app's behalf.

## Distribution notes

Local packages are unsigned unless `CODESIGN_IDENTITY` is set. Tagged releases
use the Developer ID, hardened runtime, notarization, Sparkle, and Sentry pipeline described in
[Releasing NotchRouter](docs/RELEASING.md). The app is intentionally not
sandboxed; local CLI integrations use a private Unix socket and
shared Application Support token. Publish a privacy policy covering crash
reporting before distributing the first Sentry-enabled build.
