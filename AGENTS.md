# Working on NotchRouter

NotchRouter is a macOS 14+ Swift 6 app. It displays activity from external
agents through a local API; it does not call an OpenAI model itself.

## Repository layout

- `Sources/NotchRouterApp`: AppKit panel, SwiftUI views, and feature controllers.
- `Sources/NotchRouterCore`: shared events, validation, persistence models, and paths.
- `Sources/NotchCLI`: `notchctl` and integration installers.
- `Sources/NotchBrowserHost` and `BrowserExtension`: native messaging bridge.
- `scripts` and `docs/RELEASING.md`: app packaging and release operations.

## Making changes

Carry authorized work through implementation and verification. Resolve routine
choices from the code and user request. Ask when a missing answer would change
the scope or behavior. Preserve unrelated local changes.

Follow the user's instructions over repository workflow preferences. If an
instruction prevents progress, identify the file and exact rule involved.

Respect Swift 6 actor isolation. Keep blocking work off the main actor. Preserve the
loopback token boundary and explicit opt-in for integrations. Retain saved-data
migrations while their formats can still exist on users' machines.

Before deleting code or files, check callers, platform callbacks, packaging,
and documentation references. Keep original artwork and release assets even
when they are not referenced by Swift code. Avoid speculative abstractions,
placeholder files, and documents that repeat existing instructions.

## Verification and reporting

Use `swift test --filter <test-name>` for a focused change and `swift test` for
changes across the package. CI runs `swift test`. Test observable behavior,
failure paths, and wire formats. Avoid tests that only restate constants or
round-trip synthesized Codable conformance without checking the external format.
Isolate test defaults, temporary files, ports, and pasteboards.

Run checks appropriate to the change. Once they pass, repeat or broaden them
only for new edits, failures, or unresolved concerns. Use
`./scripts/package-app.sh` when bundle contents or packaging change.

Report what changed, verification results, and any unverified behavior in plain,
concise language. Distinguish existing failures from failures introduced here.

These workflow choices follow the [GPT-6 Astra guide](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-6-astra).
