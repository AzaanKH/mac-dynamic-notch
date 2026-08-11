# NotchRouter Browser Bridge

This unpacked Manifest V3 extension supports Google Chrome, Microsoft Edge,
Brave, and Chromium on macOS. Install the native bridge from NotchRouter's
Integrations settings, enable Developer mode on the browser's Extensions page,
then choose **Load unpacked** and select this folder.

Media support starts immediately. Download status is separately opt-in: click
the extension's toolbar icon and approve the browser's Downloads permission.
The badge reads **ON** while enabled. Click the icon again to revoke the
permission.

The extension sends media metadata only while a tab contains a playable audio
or video element. When download access is enabled, it also sends filename,
source URL, byte progress, estimated completion time, and state, and accepts
pause, resume, cancel, and reveal actions. Messages travel only through native
messaging to NotchRouter's loopback server; they create no additional internet
traffic. Page content, cookies, and authentication data are not sent. The
native host reads NotchRouter's user-only integration token; the extension and
web pages never receive it.
