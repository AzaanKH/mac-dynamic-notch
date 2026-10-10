# NotchRouter verification map

Start with the isolated launch and doctor in [SKILL.md](../SKILL.md).
The baseline has empty app data, optional integrations off, and a private Unix
socket. Never drive a shared installed copy. `VERIFY_CTL` and `VERIFY_RUN`
refer to the helper and exact evidence directory created by that launch.

For desktop recipes, `notch` is the native `cua_repl` app bound to this run's
unique bundle ID. A named click means `await notch.click(index)` with the
matching fresh accessibility index, followed by `await notch.getAXState()`.
Do not reuse old indices. Capture action, before/after accessibility text,
screenshots, and a second read-only view for mutations.

Each entry point needs its own result. For example, CLI publication does not
prove menu-bar demo publication, and clicking Focus does not prove key 2.
Record passed, failed, or blocked plus the exact unmet prerequisite. Optional
integration enablement cannot be proven under the baseline's forced-off flags.

## Features

- [Agent activity](activity.md): CLI publication and updates; panel search, details, and dismissal.
- [Navigation](navigation.md): notch, menu-bar, section keys, collapse, and quit.
- [Focus timer](focus.md): presets, start, pause/resume, extension, reset, and persistence.
- [File shelf](files.md): choose or drop files, preview, and remove bookmarks.
- [Settings and API](settings.md): settings entry points, private API status, and authentication.
- [Optional integrations](integrations.md): clipboard, music, browser bridge, and their isolation limits.
- [System status](system.md): system section, local metrics, and battery presentation.

## Seed proof coverage

The skill's creation run proved `notchctl send` running → succeeded, listing,
persisted history, and panel → Activity → Show details. Native discovery
initially failed, but direct access by the unique bundle ID succeeded.
Other entry points are recipes, not claims of completed verification.
See the run's artifacts for machine-specific evidence; do not treat an old
passing run as verification of new code.
