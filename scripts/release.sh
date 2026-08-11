#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
project_directory=${script_directory:h}
output_directory=${OUTPUT_DIRECTORY:-"${project_directory}/dist"}
build_directory=${BUILD_DIRECTORY:-"${project_directory}/.build/universal"}

log() {
  print -r -- "==> $*"
}

fail() {
  print -u2 -r -- "error: $*"
  exit 1
}

require_value() {
  local variable_name=$1
  [[ -n ${(P)variable_name:-} ]] || fail "${variable_name} must be set"
}

for variable_name in \
  RELEASE_VERSION \
  BUILD_NUMBER \
  RELEASE_TAG \
  CODESIGN_IDENTITY \
  SPARKLE_FEED_URL \
  SPARKLE_PUBLIC_ED_KEY \
  SPARKLE_PRIVATE_KEY \
  DOWNLOAD_URL_PREFIX \
  RELEASE_NOTES_URL \
  SENTRY_DSN; do
  require_value "$variable_name"
done

[[ "$RELEASE_TAG" == "v${RELEASE_VERSION}" ]] \
  || fail "RELEASE_TAG must equal v${RELEASE_VERSION}"

[[ "$DOWNLOAD_URL_PREFIX" == https://* ]] \
  || fail "DOWNLOAD_URL_PREFIX must use HTTPS"
[[ "$RELEASE_NOTES_URL" == https://* ]] \
  || fail "RELEASE_NOTES_URL must use HTTPS"
[[ "$DOWNLOAD_URL_PREFIX" == */ ]] \
  || DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX}/"

log "Verifying the Sparkle signing keypair"
print -rn -- "$SPARKLE_PRIVATE_KEY" \
  | swift "${script_directory}/verify-sparkle-key.swift" \
      "$SPARKLE_PUBLIC_ED_KEY"

mkdir -p "$output_directory"
output_directory=${output_directory:A}
app_directory="${output_directory}/NotchRouter.app"
dmg_name="NotchRouter-${RELEASE_VERSION}-universal.dmg"
dmg_path="${output_directory}/${dmg_name}"
appcast_path="${output_directory}/appcast.xml"
symbols_archive="${output_directory}/NotchRouter-${RELEASE_VERSION}-dSYMs.zip"
checksum_path="${output_directory}/SHA256SUMS"

REQUIRE_SIGNING=1 \
REQUIRE_RELEASE_CONFIGURATION=1 \
ARCHITECTURES="arm64 x86_64" \
BUILD_DIRECTORY="$build_directory" \
OUTPUT_DIRECTORY="$output_directory" \
"${script_directory}/package-app.sh" release

codesign --verify --deep --strict --verbose=2 "$app_directory"

dmg_staging_directory=$(mktemp -d "${TMPDIR:-/tmp}/notchrouter-dmg.XXXXXX")
update_staging_directory=$(mktemp -d "${TMPDIR:-/tmp}/notchrouter-updates.XXXXXX")
cleanup() {
  rm -rf -- "$dmg_staging_directory" "$update_staging_directory"
}
trap cleanup EXIT

ditto "$app_directory" "${dmg_staging_directory}/NotchRouter.app"
ln -s /Applications "${dmg_staging_directory}/Applications"

[[ ! -e "$dmg_path" ]] || rm -- "$dmg_path"
log "Creating compressed DMG"
hdiutil create \
  -volname "NotchRouter" \
  -srcfolder "$dmg_staging_directory" \
  -format UDZO \
  -ov \
  "$dmg_path"

log "Signing DMG"
codesign \
  --force \
  --timestamp \
  --sign "$CODESIGN_IDENTITY" \
  "$dmg_path"
codesign --verify --verbose=2 "$dmg_path"

notary_arguments=()
if [[ -n ${NOTARY_KEYCHAIN_PROFILE:-} ]]; then
  notary_arguments+=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [[ -n ${NOTARY_KEY_PATH:-} ]]; then
  require_value NOTARY_KEY_ID
  require_value NOTARY_ISSUER_ID
  notary_arguments+=(
    --key "$NOTARY_KEY_PATH"
    --key-id "$NOTARY_KEY_ID"
    --issuer "$NOTARY_ISSUER_ID"
  )
elif [[ -n ${NOTARY_APPLE_ID:-} ]]; then
  require_value NOTARY_PASSWORD
  require_value NOTARY_TEAM_ID
  notary_arguments+=(
    --apple-id "$NOTARY_APPLE_ID"
    --password "$NOTARY_PASSWORD"
    --team-id "$NOTARY_TEAM_ID"
  )
else
  fail "Configure notarization with NOTARY_KEYCHAIN_PROFILE, NOTARY_KEY_PATH, or NOTARY_APPLE_ID"
fi

log "Submitting DMG for notarization"
xcrun notarytool submit "$dmg_path" "${notary_arguments[@]}" --wait
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
spctl --assess \
  --type open \
  --context context:primary-signature \
  --verbose=2 \
  "$dmg_path"

sparkle_generate_appcast=$(find \
  "${build_directory}/artifacts" \
  -type f \
  -name generate_appcast \
  -perm -111 \
  -print \
  -quit 2>/dev/null || true)
[[ -n "$sparkle_generate_appcast" ]] \
  || fail "Could not locate Sparkle's generate_appcast tool"

ditto "$dmg_path" "${update_staging_directory}/${dmg_name}"
if [[ -n ${RELEASE_NOTES_FILE:-} ]]; then
  [[ -f "$RELEASE_NOTES_FILE" ]] \
    || fail "RELEASE_NOTES_FILE does not exist: ${RELEASE_NOTES_FILE}"
  ditto "$RELEASE_NOTES_FILE" \
    "${update_staging_directory}/${dmg_name:r}.md"
fi

log "Generating Ed25519-signed Sparkle appcast"
print -rn -- "$SPARKLE_PRIVATE_KEY" \
  | "$sparkle_generate_appcast" \
      --ed-key-file - \
      --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
      --link "$RELEASE_NOTES_URL" \
      --maximum-versions 1 \
      --maximum-deltas 0 \
      -o "$appcast_path" \
      "$update_staging_directory"

grep -q 'sparkle:edSignature=' "$appcast_path" \
  || fail "Generated appcast does not contain an Ed25519 signature"
grep -q 'sparkle-signatures:' "$appcast_path" \
  || fail "Generated appcast feed is not signed"
grep -q "$dmg_name" "$appcast_path" \
  || fail "Generated appcast does not reference ${dmg_name}"
sparkle_sign_update="${sparkle_generate_appcast:h}/sign_update"
[[ -x "$sparkle_sign_update" ]] \
  || fail "Could not locate Sparkle's sign_update tool"
print -rn -- "$SPARKLE_PRIVATE_KEY" \
  | "$sparkle_sign_update" \
      --verify \
      --ed-key-file - \
      "$appcast_path"

[[ ! -e "$symbols_archive" ]] || rm -- "$symbols_archive"
ditto -c -k --sequesterRsrc --keepParent \
  "${output_directory}/dSYMs" \
  "$symbols_archive"

(
  cd "$output_directory"
  shasum -a 256 "$dmg_name" "${appcast_path:t}" "${symbols_archive:t}" \
    > "${checksum_path:t}"
)

log "Release artifacts are ready"
print -r -- "$dmg_path"
print -r -- "$appcast_path"
print -r -- "$symbols_archive"
print -r -- "$checksum_path"
