# System status

Users inspect local CPU, memory, disk, network, and power information in System.
The compact notch may show battery charging status.

## Sub-features

- `system.enable`: the section supports an explicit opt-in.
- `system.metrics`: enabled System displays current local measurements.
- `system.battery`: charging presentation follows hardware state.

## How to get to it (user POV)

- System button, key 6, or menu-bar Show System.
- Settings → General → System section controls availability.
- Battery charging appears automatically when compact presentation priority allows.

## Driving it with native cua_repl

Preconditions: isolated app ready. Metrics are observations of the host Mac,
not synthetic seeded values. Inspect the current section before enabling it.

- Open: click System or separately run `await notch.pressKey("6")`, then
  `await notch.getAXState()`. Capture the disabled prompt or current metrics.
- Enable: if offered, click the observed enable control in System; alternatively
  use Settings → General → System section in the isolated preferences.
  Capture the resulting CPU, memory, disk, thermal, and network fields.
- Refresh: revisit System and require populated values; compare memory and
  disk observations with read-only `vm_stat` and `df -h /` evidence. Values
  need reasonable units and bounds, not exact agreement across sample times.
- Battery: if the Mac is charging, capture percentage and the estimate or
  Calculating… label. Use `pmset -g batt` as the independent read-only view.
  Report the compact entry point skipped if the hardware state does not allow it.

## Gotchas

- Opening System refreshes immediately. Sampling cadence changes with expansion,
  display sleep, and Low Power Mode.
- Test connection makes a real HEAD request to Apple's connectivity endpoint;
  it is outside the local-only baseline. Reading network counters does not.
- Battery and compact priority depend on real hardware and other active features.
- Do not claim accessory battery support or force machine power settings to
  produce a desired screenshot.
