# File shelf

Users keep references to files in the notch, preview them, and remove shelf
entries without deleting the underlying files.

## Sub-features

- `files.choose`: Choose Files… adds a bookmark.
- `files.drop`: dragging a file onto the notch adds it.
- `files.preview`: Quick Look, double-click open, and Reveal expose the file.
- `files.remove`: Remove and Clear remove bookmarks; Clean Missing removes stale entries.

## How to get to it (user POV)

- Files button, key 3, menu-bar Show Files, or hover Files shortcut.
- Drag a file or folder directly onto the notch, or use Choose Files… in Files.
- Each shelf row exposes Quick Look, Reveal, AirDrop, and Remove by filename.

## Driving it with native cua_repl

Preconditions: isolated run ready; create only a disposable fixture:

```sh
python3 - "$VERIFY_RUN" <<'PY'
import json, pathlib, sys
m = json.loads((pathlib.Path(sys.argv[1]) / 'run.json').read_text())
p = pathlib.Path(m['root']) / 'verification-file.txt'
p.write_text('NotchRouter disposable shelf verification\n')
print(p)
PY
```

- Choose: click Files or run `await notch.pressKey("3")`; inspect state.
  Click Choose Files…. In the native picker use
  `await notch.pressKey("super+shift+g")`, type the printed fixture path with
  `await notch.typeText(fixturePath)`, then Return and the observed Open button.
  Require a `verification-file.txt` row.
- Drop: separately drag the fixture from a file-manager window to the isolated
  notch using `cua_repl` and current screenshots. Require the same shelf entry;
  record source and target observations. Skip if overlapping app windows make
  the target ambiguous.
- Preview: click `Quick Look verification-file.txt`. Require the fixture text
  in the preview; close the preview using its observed control.
- Reveal/open: click `Reveal verification-file.txt` or double-click the row
  with `await notch.click(index, {clickCount: 2})`. Require the fixture selected
  in Finder or opened in the associated editor. These are separate entry points.
- Second view: inspect `file-shelf.json` under the recorded data directory and
  save a copy in evidence. Require an entry for the fixture after addition.
- Remove: click `Remove verification-file.txt`. Require no shelf row, no
  matching entry in file-shelf.json, and the original fixture still readable.
- Missing: after adding the fixture again, delete only that disposable fixture,
  then use Clean Missing when offered. Require its stale bookmark gone.

## Gotchas

- The shelf stores security-scoped bookmarks, not copies. Do not use user files
  to test deletion, missing files, or bookmark cleanup.
- AirDrop opens a real sharing flow and is outside this seed proof.
- Browser downloads are a separate bridge path; a shelf addition cannot verify them.
- Clear and Clean Missing need their own UI actions and saved-state observations.
