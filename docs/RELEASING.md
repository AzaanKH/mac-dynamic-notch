# Releasing NotchRouter

The release workflow builds `arm64` and `x86_64` slices independently, merges
all three executables with `lipo`, embeds Sparkle, and creates dSYMs from the
merged binaries. It then signs every nested executable and Sparkle helper with
the hardened runtime before signing the outer app bundle.

The signed app is placed in a compressed DMG, the DMG is Developer ID signed,
submitted with `notarytool`, stapled, and assessed with Gatekeeper. Only that
final stapled DMG is signed with Sparkle's Ed25519 key and added to an appcast
that is itself signed. NotchRouter requires both feed validation and archive
validation before extraction.

## One-time setup

Create these GitHub Actions secrets:

| Name | Value |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded `.p12` containing a **Developer ID Application** certificate and private key. |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12`. |
| `APPLE_API_KEY` | Contents of an App Store Connect `AuthKey_….p8` key that can use the notary service. |
| `APPLE_API_KEY_ID` | App Store Connect API key ID. |
| `APPLE_API_ISSUER_ID` | App Store Connect API issuer ID. |
| `SPARKLE_PRIVATE_KEY` | Private key exported by Sparkle's `generate_keys -x`. Keep this stable and secret. |
| `SENTRY_DSN` | Public DSN for the NotchRouter macOS Sentry project. |
| `SENTRY_AUTH_TOKEN` | Sentry token with project release/debug-file upload access. |

Create these GitHub Actions variables:

| Name | Value |
| --- | --- |
| `SPARKLE_PUBLIC_ED_KEY` | Public Ed25519 key printed by Sparkle's `generate_keys`. |
| `SENTRY_ORG` | Sentry organization slug. |
| `SENTRY_PROJECT` | Sentry project slug. |

Sparkle's private key is a release credential, not a server credential. Do not
store it in the repository or on the web server that hosts the appcast. Keep an
offline backup: losing it requires a carefully tested Developer ID key-rotation
recovery before installed builds can accept another signing key.
The release script also derives the public key from this private seed and fails
before building if it does not match `SPARKLE_PUBLIC_ED_KEY`.

The workflow derives the public feed URL as:

```text
https://github.com/OWNER/REPOSITORY/releases/latest/download/appcast.xml
```

If releases are hosted elsewhere, update the three GitHub URL values in
`.github/workflows/release.yml` together. The appcast and every DMG URL must be
served over HTTPS.

## Publish a release

Update and test the source, then push a three-component semantic version tag:

```sh
git tag v0.3.0
git push origin v0.3.0
```

The workflow uses the tag as `CFBundleShortVersionString` and derives a stable,
monotonically increasing integer `CFBundleVersion` as
`MAJOR × 1,000,000 + MINOR × 1,000 + PATCH`. Each version component is limited
to 999. A successful run publishes:

- `NotchRouter-VERSION-universal.dmg` — universal, signed, notarized, and
  stapled installer image.
- `appcast.xml` — Ed25519-signed Sparkle feed containing the DMG's own
  Ed25519 signature.
- `SHA256SUMS` — checksums for the DMG, appcast, and retained dSYM archive.
- A 90-day workflow artifact containing all dSYMs; the same dSYMs are uploaded
  to Sentry before the GitHub release is published.

The release job fails closed if any architecture slice, release setting,
signature, notarization ticket, appcast signature, dSYM, or crash-reporting
credential is missing.

## Local verification

An unsigned universal bundle for local testing does not need release
credentials:

```sh
./scripts/package-app.sh release
open .build/NotchRouter.app
```

To exercise signing locally, export a real identity name or SHA-1 hash:

```sh
CODESIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" \
  ./scripts/package-app.sh release
```

Inspect the result with:

```sh
lipo -archs .build/NotchRouter.app/Contents/MacOS/NotchRouter
codesign --verify --deep --strict --verbose=2 .build/NotchRouter.app
codesign -d --entitlements :- .build/NotchRouter.app
```

`scripts/release.sh` is the non-interactive release entry point used by CI. It
also supports a local `notarytool` keychain profile through
`NOTARY_KEYCHAIN_PROFILE`, or Apple ID authentication through
`NOTARY_APPLE_ID`, `NOTARY_PASSWORD`, and `NOTARY_TEAM_ID`.

## Crash reporting and privacy

Sentry starts before AppKit finishes launching only when the user has enabled
Share crash reports and the packaged plist has a `SentryDSN`. Consent defaults
off, and local source builds do not include a DSN. Release builds set
`sendDefaultPii` to `false`, attach the exact
`com.notchrouter.app@VERSION+BUILD` release, and upload matching universal
dSYMs so native crashes can be symbolicated.

Before the first public release, document crash reporting in the product's
privacy notice and verify the Sentry project's data-retention and scrubbing
settings.
