# Agent activity

Agents publish task progress to the notch. Users can inspect status and update
history, search cards, and dismiss local activity records.

## Sub-features

- `activity.publish-update`: a repeated ID updates one card and saves history.
- `activity.details`: Show details reveals the saved messages and dates.
- `activity.filter`: search and All, Active, Attention, Completed narrow cards.
- `activity.dismiss`: a card or Clear finished removes local records.

## How to get to it (user POV)

- Publish with `notchctl send`, `notchctl demo`, or authenticated POST `/v1/activities`.
- Open through the notch's Activity button, key 1 on the expanded panel,
  menu-bar `Show Activity`, Option-N, or the hover Activity shortcut.
- Menu-bar `Send Demo Activity` publishes a separate built-in demo.

## Driving it with notchctl and native cua_repl

Preconditions: launch and doctor passed; bind only the disposable app.

- Publish/update: `"$VERIFY_CTL" proof "$VERIFY_RUN"` creates
  `Verify isolated activity`, updates running to succeeded, and checks
  authenticated listing plus disk JSON. Require one matching ID and both states.
- Approval: `"$VERIFY_CTL" cli "$VERIFY_RUN" -- send --id verification-review --source "Verification Agent" --title "Review verification" --state needs_approval --message "Waiting for a local review" --progress 0.5`.
  Require the approval card and Attention count to change; cross-check
  `"$VERIFY_CTL" cli "$VERIFY_RUN" -- list`.
- Open panel: click the `NotchRouter` container, then `Activity`; for the
  keyboard entry use `await notch.pressKey("1")` and inspect state. Test menu
  `Show Activity` separately when its menu extra is exposed in the bound tree.
- Details: capture the before state, click `Show details` on
  `Verify isolated activity`, and capture the result. Require `Hide details`,
  `2 updates`, `Verification finished`, and `Checking the isolated app`.
  Compare with `persisted-succeeded.json` history.
- Search: on the fresh `Search activities` field call
  `await notch.setValue(index, "Verify isolated activity")`; refresh state.
  Require the matching card, then enter `no-matching-verification-card` and
  require the empty result. Click `Clear activity search` to restore results.
- Filters: click each of All, Active, Attention, Completed from the current
  tree. Require counts and visible cards to agree with CLI state values.
- Dismiss: click `Dismiss Review verification` on disposable data. Read CLI
  list again and wait for `activities.json` to omit that ID. Test `Clear finished`
  separately with the succeeded card and require the same second-view change.
- Demo: `"$VERIFY_CTL" cli "$VERIFY_RUN" -- demo` should add an approval card
  titled `Review the checkout flow`. Menu-bar `Send Demo Activity` is a separate
  UI action; verify its added card independently.

## Gotchas

- API/CLI success alone cannot prove card layout or interaction.
- Events update the compact indicator without automatically opening the panel.
- A nonterminal activity becomes Disconnected after five minutes without an
  update. Identical heartbeats refresh liveness without duplicate history.
- Option-N is global and can belong to the user's running copy. Test it only
  on a separate desktop with no competing instance.
- Review/Open follows `action_url`; use a deliberately chosen destination.
- Dismiss/Clear finished delete activity records. Restrict those recipes to
  this run's disposable cards. They do not cancel work in the external agent.
