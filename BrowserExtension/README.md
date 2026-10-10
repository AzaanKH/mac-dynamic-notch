# NotchRouter Browser Bridge

This Manifest V3 extension supports Chrome 121+, Edge, Brave, Chromium, and
Firefox 140+ or a compatible Zen release on macOS. First build/run the updated
NotchRouter app and use **Settings → Integrations → Install Browser Bridge**.
If it was installed before Firefox support was added, choose **Reinstall Bridge**.
This copies the extension and registers the native helper; it does not enable
an extension inside any browser.

- **Zen or Firefox:** open `about:debugging#/runtime/this-firefox`, choose
  **Load Temporary Add-on**, and select `manifest.json` in the folder opened by
  **Open Extension Folder**. Allow access to the media sites you want to use and
  reload existing media tabs. Firefox may label this page **This Firefox** even
  in Zen. This development installation lasts only until you quit the browser.
  Persistent installation requires a Mozilla-signed add-on; this repository
  does not include one. Zen may identify itself as Firefox in the notch.
- **Chrome, Edge, Brave, or Chromium:** open the browser's Extensions page,
  enable Developer mode, choose **Load unpacked**, and select that folder.
- **Safari:** not supported by this package. Safari needs a bundled Safari Web
  Extension and its own native app-extension message handler. Installing the
  current native helper cannot enable Safari integration.

The installed folder is
`~/Library/Application Support/NotchRouter/browser-extension`.
The Firefox/Zen helper manifest is registered in
`~/Library/Application Support/Mozilla/NativeMessagingHosts`.

Firefox's installation prompt lists browsing activity and website content
because media titles and page URLs are sent to the local NotchRouter app.
No status messages are sent to an internet service.

Media support starts immediately. Download status is separately opt-in: click
the extension's toolbar icon and approve the browser's Downloads permission and, in Firefox/Zen, the optional website-activity consent.
The badge reads **ON** while enabled. Click the icon again to revoke the
permission.

The extension sends media metadata only while a tab contains a playable audio
or video element. When download access is enabled, it also sends the base
filename, source host, byte progress, estimated completion time, and state, and
accepts pause, resume, cancel, and reveal actions. Messages travel only through
native messaging to NotchRouter's private per-user socket. Media artwork retrieval
can add a browser request; download-status messages create no internet traffic.
Artwork requests omit credentials, reject redirects, and follow browser access
restrictions. Only a thumbnail up to 256 × 256 pixels and 32 KiB reaches the app.
Artwork that cannot be retrieved uses the fallback icon. Page content, cookies,
and authentication data are not sent. The
native host reads NotchRouter's user-only integration token; the extension and
web pages never receive it.

Playback controls work with HTML audio and video, including embedded frames and
players inside open shadow roots. The notch provides a seek slider and 15-second
skips when a player reports a finite duration and a seekable range. Live streams
remain playable but do not expose seeking. Closed shadow roots and players that
do not expose HTML media elements are not supported.

After updating NotchRouter, reinstall the browser bridge from Settings to replace
the copied native host. Then reload it on the browser's Extensions page and
refresh media tabs to enable the new controls. Older content scripts continue to
support play, pause, and track navigation without seeking.

Run browser bridge checks with `node --test BrowserExtension/tests/*.test.cjs`.

Discovery tracks added elements and open shadow roots instead of rescanning the
whole page on every media heartbeat. Pages without playable media have no media
heartbeat. Visible playback refreshes every second; paused or hidden players
refresh every five seconds, with media events and commands still updating promptly.
A reconciliation finds shadow roots attached later without a DOM mutation every
ten seconds on visible pages and every minute on hidden pages. Foregrounding a
page scans immediately. Removed roots release their observers, and navigating
away stops the page's timers and observers until a back-navigation restore.

Measure scheduled work with `node BrowserExtension/tests/measure-idle.cjs`.
The fixture simulates one minute on a 1,000-element page and reports callback,
discovery, selector-query, and message counts. Pass a saved `content.js` path as
an argument to compare an earlier version. These counts exclude browser timer
throttling and are not CPU or battery measurements.

Compatibility references: [Zen extensions](https://docs.zen-browser.app/user-manual/extensions),
[temporary Firefox installation](https://extensionworkshop.com/documentation/develop/temporary-installation-in-firefox/),
and [Safari native messaging](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension).
