# Focus timer

Users choose a session length and keep a countdown visible while working.
Timer state survives app relaunches.

## Sub-features

- `focus.presets`: 15, 25, and 50-minute sessions.
- `focus.controls`: Start Focus, Pause, Resume, +5 min, and Reset.
- `focus.complete`: Start Again and Done after completion.
- `focus.persist`: saved timer state agrees with visible state.

## How to get to it (user POV)

- Expanded Focus section, key 2, or menu-bar Show Focus Timer.
- The active or paused compact timer exposes Pause/Resume on hover when it has
  presentation priority. Completion exposes Start Again and Done.

## Driving it with native cua_repl

Preconditions: isolated app ready, no agent activity demanding attention.
Do not enable notification or sound preferences under the baseline flags.

- Open: click Focus, or separately run `await notch.pressKey("2")` then
  `await notch.getAXState()`. Require preset buttons and Start Focus.
- Preset/start: click `15 min`, then from fresh state click `Start Focus`.
  Require a countdown near 15:00, Pause, +5 min, and Reset.
- Pause: click Pause, capture the time, refresh after other verification work,
  and require Resume with a stable remaining time.
- Extend: click +5 min while paused. Require exactly five minutes added.
- Resume: click Resume and require Pause plus decreasing time.
- Reset: click Reset and require the preset picker and Start Focus again.
- Second view: export only this run's unique preference domain and decode its
  saved timer state. macOS stores this domain through its normal preference
  daemon despite the redirected Foundation home:

  ```sh
  python3 - "$VERIFY_RUN" <<'PY'
  import json, pathlib, plistlib, subprocess, sys
  run = pathlib.Path(sys.argv[1])
  m = json.loads((run / 'run.json').read_text())
  raw = subprocess.check_output(['/usr/bin/defaults', 'export', m['bundle_id'], '-'])
  timer = json.loads(plistlib.loads(raw)['focusTimerState'])
  (run / 'focus-persisted.json').write_text(json.dumps(timer, indent=2) + '\n')
  print(timer)
  PY
  ```

  Require the selected duration and phase to agree with the UI. Preference
  writes can lag; an absent domain is unverified persistence, not permission
  to inspect the production preference domain.
- Completion: allow a real session to finish, then separately test Start Again
  and Done. Capture the completed state before the action. Do not patch saved
  deadlines and call that real countdown proof.

## Gotchas

- Timer display changes once per second; exact running timestamps are unstable.
- CLI activity proof may take compact presentation priority. Use a fresh run
  for hover controls and record that entry point separately.
- The helper does not relaunch an existing run. Persistence across relaunch is
  unverified until a same-profile restart is explicitly performed with the
  recorded environment and process ownership tracking preserved.
- System notifications and sounds are forced off in this workflow.
