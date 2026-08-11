# NotchRouter Browser Media

This unpacked Manifest V3 extension supports Google Chrome, Microsoft Edge,
Brave, and Chromium on macOS. Install the native bridge from NotchRouter's
Integrations settings, enable Developer mode on the browser's Extensions page,
then choose **Load unpacked** and select this folder.

The extension sends metadata only while a tab contains a playable audio or
video element. Page content, browsing history, cookies, and authentication data
are not sent. The native host reads NotchRouter's user-only integration token;
the extension and web pages never receive it.
