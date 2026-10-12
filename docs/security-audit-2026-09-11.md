# NotchRouter security audit

Remediation follow-up, 11 September 2026. The findings and line references below
record the original audit snapshot. The subsequent implementation addresses S1
through S5 for the default configuration and bundled clients:

- Sparkle is pinned and resolved to 2.9.6. Universal packaging embeds its updated
  framework, Autoupdate, and Updater helpers and rejects artifacts below 2.9.6.
- Browser artwork now travels as bounded thumbnail bytes. The native app ignores
  browser-provided artwork URLs. Native Spotify downloads use exact HTTPS host
  restrictions, reject redirects, omit ambient cookies and credentials, cap bytes
  while receiving, and decode through a bounded thumbnail path shared with display.
- Rotation and shutdown cancel accepted connections and pending request tasks.
  Rotation keeps listeners bound. Work already executing in a handler before
  revocation may finish; it cannot return a response on a revoked connection.
- Bundled clients use a private Unix socket, validate ownership and permissions,
  and never fall back to TCP. Per the user's compatibility choice, the old TCP API
  remains available only through an explicit setting that defaults off. Its
  impersonation risk remains when third-party clients opt into that transport.
- Accepted connections also have an absolute deadline and concurrency cap,
  mitigating S6 while implementing the revocation lifecycle.

Follow-up verification: 128 Swift tests and 11 browser tests pass. The universal
app packages successfully with Sparkle 2.9.6, and its executables and Sparkle
Autoupdate contain arm64 and x86_64 slices. Production signing, notarization,
installed-browser behavior, and an actual update installation remain unverified.
Existing installed helper copies must be reinstalled from Settings after updating
the app; reload the browser extension and refresh media tabs. Until then, older
helpers still use TCP. Artwork blocked by browser access restrictions uses a
fallback icon.


Audited on 11 September 2026. Scope is the current working tree, including modified and untracked source files, based on commit `420190f73a2e30d660a051e43cd380017a14f537`. Existing local changes were preserved. No application code or dependency versions were changed.

Six findings warrant remediation. Upgrade Sparkle first, then address artwork fetching and the local API's authentication lifecycle. No unauthenticated remote code execution was established.

| ID | Severity | Finding | Evidence |
| --- | --- | --- | --- |
| S1 | High | Sparkle 2.9.5 has a published installer vulnerability | Pinned version and upstream advisory |
| S2 | Medium | Webpages can cause native requests to loopback and private services through artwork | Code tracing and loopback fixture |
| S3 | Medium | Artwork limits apply after the response is downloaded | 16 MiB response consumed with a 1 KiB limit |
| S4 | Medium | Previously accepted connections retain revoked tokens | Old token returned HTTP 200 after rotation |
| S5 | Medium | Another local user can impersonate the fixed-port server and collect client tokens | Code review; cross-user exploit not executed |
| S6 | Low | Unauthenticated connections have no application-level deadline or total connection limit | Code review and a delayed partial request |

Severity accounts for the desktop deployment. A webpage is untrusted even after the user installs the browser bridge. Another local account is outside the per-user token boundary. An unrestricted process already running as the same user can read the token file by design; that alone is not reported as a vulnerability.

**S1. Upgrade the vulnerable Sparkle dependency.**

[Package.swift](../Package.swift), line 25, pins Sparkle to `2.9.5`, and [Package.resolved](../Package.resolved) resolves that version. Packaging embeds its installer helpers. [SoftwareUpdateController.swift](../Sources/NotchRouterApp/SoftwareUpdateController.swift), lines 18–32, enables the updater when a release feed and public key are configured.

The upstream advisory GHSA-3x7w-j75x-ppq5 affects versions through 2.9.5 and is fixed in 2.9.6. A filesystem race between path validation and moving an update archive can make a privileged installer move a protected file. Exploitation requires local access, a privileged installation, and a difficult race; the advisory also describes a filename constraint. The shipped version is affected, but this audit did not execute a privileged update exploit. [Upstream advisory](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-3x7w-j75x-ppq5).

The signed feed and archive checks are good controls, but do not repair this installer filesystem race. Pin at least Sparkle 2.9.6, refresh the lockfile, run the package tests, and verify packaging and an update using disposable installations.

The separate GHSA-4v99-qgq9-6pxp advisory also covers this version, but requires the host updater process to run as root. Ordinary NotchRouter launches do not establish that condition, so it is not counted as a second finding. [Root-process advisory](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-4v99-qgq9-6pxp).

**S2. Restrict native artwork requests derived from webpages.**

[content.js](../BrowserExtension/content.js), lines 169–176 and 201–203, accepts any HTTP or HTTPS artwork address from page metadata. [BrowserMediaModels.swift](../Sources/NotchRouterCore/BrowserMediaModels.swift), lines 78–90, and [MusicController.swift](../Sources/NotchRouterApp/MusicController.swift), in `browserSnapshot`, only validate the URL scheme. `updateArtworkPalette`, lines 366–387, passes that address to the native loader automatically. [MusicArtworkView.swift](../Sources/NotchRouterApp/MusicArtworkView.swift), line 11, also fetches it using `AsyncImage`.

A page with detected media can set its artwork to a loopback or private-network HTTP endpoint. The extension forwards the metadata through the authenticated native host, and the app makes the request outside the browser. This bypasses restrictions imposed by the browser on requests to local resources. User interaction with the artwork is unnecessary.

An isolated probe passed a `127.0.0.1` artwork URL through the production model validator and production palette loader. The fixture received the GET without an `Origin` or `Authorization` header. The extension-to-loader path was traced in source; an installed browser was not used for this probe. This establishes native request issuance, not arbitrary response disclosure to the webpage. Impact depends on the target service, especially services that trust local clients or mutate state through GET requests.

Use one controlled artwork-loading path for both palette extraction and display. Reject local, private, link-local, and otherwise nonpublic destinations, including after DNS resolution and on redirects. Handle DNS changes between validation and connection. Avoid ambient cookies and credentials. Alternatively, design a bounded image transfer from the browser so the native app never fetches a page-supplied address. Scheme checks or an HTTPS-only rule alone do not provide destination isolation.

**S3. Enforce artwork resource limits while receiving and decoding.**

[MusicArtworkPalette.swift](../Sources/NotchRouterApp/MusicArtworkPalette.swift), lines 26–44, uses `URLSession.data(from:)` before testing `data.count <= maxBytes`. The entire response is accumulated before the nominal 8 MB limit is evaluated. Image creation also precedes the small sampling draw without a source pixel-count limit. The separate `AsyncImage` path has no application-defined size limit.

The fixture served 16,777,216 bytes. Calling the production loader with `maxBytes: 1024` downloaded the response and only then returned `nil`. The bound therefore limits acceptance, not download size or peak buffering. A malicious media page can select an oversized artwork response and cause excessive memory and network use. Highly compressed images with extreme dimensions are an additional decoding concern identified by inspection; no decompression-bomb or out-of-memory test was run.

Stream the response and cancel when the byte budget is exceeded. Check the declared length early, but still count received bytes because responses can omit or misstate it. Bound decoded dimensions and use ImageIO thumbnail creation before full-size rendering. Apply the same limits to artwork display. Add tests for oversized declared lengths, chunked responses exceeding the limit, excessive image dimensions, cancellation, and redirects.

**S4. Revoke authentication on existing connections.**

[ActivityHTTPServer.swift](../Sources/NotchRouterApp/ActivityHTTPServer.swift), lines 80–103, captures the current token when accepting each connection. `stop`, lines 109–113, cancels only the listener. `updateToken`, lines 115–123, restarts it without closing accepted connections. Each `HTTPConnection` subsequently authenticates against its own immutable token at line 246.

The isolated socket probe performed this sequence:

1. Start a server with a synthetic old token on an unused loopback port.
2. Open a connection and send an incomplete header block without authorization.
3. Leave the request unfinished for five seconds.
4. Rotate the server to a synthetic new token.
5. Complete the existing request with the old token.

The response was `HTTP/1.1 200 OK`. A new connection using the old token received `401 Unauthorized`, confirming that revocation is incomplete specifically for accepted connections. Someone holding a leaked token can stockpile connections before rotation and use each for a later request. There is no application-level deadline bounding that opportunity.

The first probe run also encountered a replacement-listener bind failure while the old connection remained open. A later run restarted successfully, so this availability effect is timing-dependent. The old-token acceptance reproduced in both runs.

Track and cancel accepted connections on rotation and shutdown. Check a current authentication generation when dispatching requests, rather than only a copied secret. Define handling of already-authorized work explicitly. Regression tests should cover delayed headers and bodies across rotation, old-token rejection, successful new-token requests, and shutdown with open connections. The Settings claim that rotation immediately rejects the old token is currently inaccurate.

**S5. Authenticate the local server before sending credentials.**

[NotchCLI.swift](../Sources/NotchCLI/NotchCLI.swift), lines 282–298, and [NotchBrowserHost/main.swift](../Sources/NotchBrowserHost/main.swift), lines 70–82, send the token to plain HTTP on a fixed port. Neither checks the identity or owning user of the process listening there.

When NotchRouter is stopped, another process can bind `127.0.0.1:48271`. A CLI invocation or browser heartbeat then sends that listener the user's token and payload. An attacker running as another logged-in account does not need read access to the victim's private Application Support directory. The token can subsequently authenticate to the real app until rotated. An impersonating server can also return native bridge responses, including download commands when the browser's download integration is enabled.

This finding follows directly from the client request and response paths. No second account was used, and the user's real port and token were not accessed. It requires malicious local execution and a period when the genuine listener is absent; it is not a remote-network interception claim.

For bundled clients, prefer a per-user Unix-domain socket inside the private support directory with peer-identity checks, or an authenticated XPC service. If TCP compatibility is retained, authenticate the server through a credential pinned in private storage before transmitting a bearer token. A health check, randomized port alone, or retrying a bind failure does not establish server identity. Reject redirects for this local protocol as an additional boundary control.

**S6. Bound unauthenticated connection lifetime and concurrency.**

[ActivityHTTPServer.swift](../Sources/NotchRouterApp/ActivityHTTPServer.swift), lines 95–103 and 208–232, accepts connections without a total connection cap and keeps receiving incomplete requests without a request deadline. The 64 KiB request limit applies per connection and only to bytes already received. Authentication occurs after the complete request is parsed.

A local process can hold many incomplete requests open, retaining sockets, connection objects, and buffers before providing any token. A declared body that never arrives has the same effect. The probe demonstrated a partial request remaining usable after five seconds; source review found no application timeout. This audit did not attempt resource exhaustion or measure the operating system's eventual limits. Severity is low because the demonstrated access is local and the impact is availability.

Add an absolute header/body deadline, an idle deadline, and a maximum number of accepted connections. Reject declared lengths exceeding the request budget immediately. Cancel connections on expiry and shutdown, and verify legitimate clients recover after an over-limit client is removed.

Other observations are worth addressing, but are not counted as established exploits:

- Clipboard app exclusions use `NSWorkspace.shared.frontmostApplication` at polling time, rather than the identity of the pasteboard writer. See [ClipboardStore.swift](../Sources/NotchRouterApp/ClipboardStore.swift), lines 428–429 and 529–541. Copying unmarked content in an excluded app and switching apps before the poll can defeat that attribution. Sensitive pasteboard markers are still checked independently. Add a transition-focused test and describe the limitation instead of promising a strict writer-based exclusion. This scenario was not exercised against the user's desktop.
- GitHub Actions references use mutable `@v4` tags. Pin reviewed commit SHAs for checkout and artifact upload, particularly in the release job. Repository rules for release tags, workflow changes, and secret access require a separate settings review.
- Crash reporting defaults off, and its UI says changes take effect after restart. `sendDefaultPii = false` is not evidence that every diagnostic is scrubbed. Inspect representative Sentry envelopes and project retention/scrubbing settings, particularly network breadcrumbs associated with artwork URLs. No Sentry payload was transmitted or inspected here.
- The app is intentionally unsandboxed and the API token is shared with opted-in local integrations. Clipboard/history contents are plaintext inside private directories. These are existing trust-model choices, not newly demonstrated vulnerabilities. File action URLs require a user click; no automatic shell execution from activity payloads was found.

Controls verified or observed during review:

- The server explicitly binds `127.0.0.1`. Socket probes returned 401 for missing or obsolete tokens on fresh connections, 403 for an Origin-bearing authenticated request, and 200 for the current token.
- Token generation uses 32 bytes from `SecRandomCopyBytes`. The support directory is secured to mode 0700 and newly written tokens to 0600. History writers use atomic writes and private permissions.
- HTTP parser tests cover duplicate headers, malformed requests, negative lengths, integer overflow, and incomplete bodies. Activity fields, history size, and several command queues are bounded.
- Native messaging manifests restrict allowed extension identifiers. Download access is optional and checked in the extension before command execution. Zero-length, oversized, truncated-header, and truncated-body native messages terminated cleanly in isolated framing checks.
- Integration installation is user-triggered. Hook commands quote the executable path, state filenames use SHA-256 digests, and native music commands use fixed operations with numeric seek values.
- Packaging configures signed Sparkle feeds and archive validation before extraction. Release scripts require Developer ID signing with hardened runtime, notarization, and signature checks. The Sentry CLI download has a pinned checksum, and both Swift binary dependencies declare artifact checksums.

Verification completed:

| Check | Result |
| --- | --- |
| `swift test` | 120 tests passed |
| `node --test BrowserExtension/tests/*.test.cjs` | 8 tests passed |
| Production server and artwork source compiled into isolated probe | Confirmed S2, S3, and S4 behaviors; baseline authentication checks passed |
| Native host malformed-frame probes | 4 cases exited cleanly without output |
| `zsh -n` for packaging, release, and symbol-upload scripts | Passed |
| `plutil -lint` for Info.plist and entitlements | Passed |
| Credential-pattern scan | No matches across 95 working-tree files and 455 blobs reachable from local Git refs, covering 148 commits |

The credential scan checked private-key markers and recognizable GitHub, AWS, OpenAI, Slack, Google API, and Sentry token formats without printing candidate secrets. It was a custom pattern scan, not an exhaustive entropy or provider-validation scan. It excluded build outputs and did not inspect unreachable Git objects, remote-only refs, or account settings. The extension's manifest key is public identity material, not a private key.

Sentry Cocoa's published advisory listing was checked; it did not identify an advisory affecting the pinned 9.25.0 version. This is not a claim that the binary is vulnerability-free. [Upstream advisory listing](https://github.com/getsentry/sentry-cocoa/security/advisories).

Audit artifacts are retained locally in `/tmp/notchrouter-security-audit`, including the standalone Swift probe, fixture runner, probe results, native framing results, and secret-scan summary. The baseline Swift log is `/tmp/notchrouter-security-swift-test.log`. The probe links the built core objects and compiles the production HTTP server and palette source directly; it does not use the running app, saved histories, or integration token.

This review covered first-party API, browser bridge, CLI/installers, persistence, clipboard, file handling, notifications, music/network operations, dependency configuration, and release scripts. It did not decompile third-party binaries, run destructive exhaustion or privilege-escalation tests, exercise an installed browser end to end, or inspect GitHub/Sentry account settings. Packaging was reviewed but not rerun because bundle contents were unchanged; production signing, notarization, and an actual update remain unverified. Successful tests do not resolve the findings above.
