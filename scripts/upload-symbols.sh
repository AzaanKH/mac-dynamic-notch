#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
project_directory=${script_directory:h}
dsym_directory=${1:-"${project_directory}/dist/dSYMs"}

fail() {
  print -u2 -r -- "error: $*"
  exit 1
}

require_value() {
  local variable_name=$1
  [[ -n ${(P)variable_name:-} ]] || fail "${variable_name} must be set"
}

command -v sentry-cli >/dev/null 2>&1 \
  || fail "sentry-cli must be installed"
[[ -d "$dsym_directory" ]] || fail "dSYM directory not found: ${dsym_directory}"
find "$dsym_directory" -type d -name '*.dSYM' -print -quit | grep -q . \
  || fail "No dSYMs found under ${dsym_directory}"

for variable_name in \
  SENTRY_AUTH_TOKEN \
  SENTRY_ORG \
  SENTRY_PROJECT \
  SENTRY_RELEASE; do
  require_value "$variable_name"
done

if ! sentry-cli releases info \
  --org "$SENTRY_ORG" \
  --project "$SENTRY_PROJECT" \
  "$SENTRY_RELEASE" >/dev/null 2>&1; then
  sentry-cli releases new \
    --org "$SENTRY_ORG" \
    --project "$SENTRY_PROJECT" \
    "$SENTRY_RELEASE"
fi
sentry-cli debug-files upload \
  --org "$SENTRY_ORG" \
  --project "$SENTRY_PROJECT" \
  --include-sources \
  --wait \
  "$dsym_directory"
sentry-cli releases finalize \
  --org "$SENTRY_ORG" \
  --project "$SENTRY_PROJECT" \
  "$SENTRY_RELEASE"
