#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
project_directory=${script_directory:h}
configuration=${1:-release}
minimum_macos_version=${MINIMUM_MACOS_VERSION:-14.0}
architecture_value=${ARCHITECTURES:-"arm64 x86_64"}
architectures=(${(s: :)architecture_value})
build_directory=${BUILD_DIRECTORY:-"${project_directory}/.build/universal"}
output_directory=${OUTPUT_DIRECTORY:-"${project_directory}/.build"}
app_directory="${output_directory}/NotchRouter.app"
contents_directory="${app_directory}/Contents"
dsym_directory="${output_directory}/dSYMs"
entitlements_path="${project_directory}/Resources/NotchRouter.entitlements"

log() {
  print -r -- "==> $*"
}

fail() {
  print -u2 -r -- "error: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_value() {
  local variable_name=$1
  [[ -n ${(P)variable_name:-} ]] || fail "${variable_name} must be set"
}

plist_upsert_string() {
  local key=$1
  local value=$2
  local plist=$3

  plutil -remove "$key" "$plist" >/dev/null 2>&1 || true
  plutil -insert "$key" -string "$value" "$plist"
}

plist_upsert_bool() {
  local key=$1
  local value=$2
  local plist=$3

  plutil -remove "$key" "$plist" >/dev/null 2>&1 || true
  plutil -insert "$key" -bool "$value" "$plist"
}

remove_bundle_if_present() {
  local target=$1
  [[ ${target:t} == "NotchRouter.app" ]] || fail "Refusing to remove unexpected bundle path: ${target}"
  [[ ! -e "$target" ]] || rm -rf -- "$target"
}

remove_dsym_if_present() {
  local target=$1
  [[ ${target:t} == *.dSYM ]] || fail "Refusing to remove unexpected dSYM path: ${target}"
  [[ ! -e "$target" ]] || rm -rf -- "$target"
}

for command_name in swift lipo ditto plutil codesign otool dsymutil dwarfdump; do
  require_command "$command_name"
done

[[ "$configuration" == "debug" || "$configuration" == "release" ]] \
  || fail "Configuration must be 'debug' or 'release'"
(( ${#architectures[@]} > 0 )) || fail "ARCHITECTURES must not be empty"
for architecture in "${architectures[@]}"; do
  [[ "$architecture" == "arm64" || "$architecture" == "x86_64" ]] \
    || fail "Unsupported architecture: ${architecture}"
done

if [[ ${REQUIRE_RELEASE_CONFIGURATION:-0} == 1 ]]; then
  require_value SPARKLE_FEED_URL
  require_value SPARKLE_PUBLIC_ED_KEY
  require_value SENTRY_DSN
fi

if [[ -n ${SPARKLE_FEED_URL:-} || -n ${SPARKLE_PUBLIC_ED_KEY:-} ]]; then
  require_value SPARKLE_FEED_URL
  require_value SPARKLE_PUBLIC_ED_KEY
  [[ "$SPARKLE_FEED_URL" == https://* ]] \
    || fail "SPARKLE_FEED_URL must use HTTPS"
fi

mkdir -p "$build_directory" "$output_directory" "$dsym_directory"
build_directory=${build_directory:A}
output_directory=${output_directory:A}
app_directory="${output_directory}/NotchRouter.app"
contents_directory="${app_directory}/Contents"
dsym_directory="${output_directory}/dSYMs"

typeset -A binary_directories
cd "$project_directory"

for architecture in "${architectures[@]}"; do
  target_triple="${architecture}-apple-macosx${minimum_macos_version}"
  build_arguments=(
    --configuration "$configuration"
    --scratch-path "$build_directory"
    --triple "$target_triple"
    -debug-info-format dwarf
  )

  log "Building ${target_triple}"
  swift build "${build_arguments[@]}"
  binary_directories[$architecture]=$(swift build "${build_arguments[@]}" --show-bin-path)
done

remove_bundle_if_present "$app_directory"
[[ ${dsym_directory:t} == "dSYMs" ]] \
  || fail "Refusing to replace unexpected dSYM directory: ${dsym_directory}"
[[ ! -e "$dsym_directory" ]] || rm -rf -- "$dsym_directory"
mkdir -p \
  "${contents_directory}/MacOS" \
  "${contents_directory}/Frameworks" \
  "${contents_directory}/Resources/bin" \
  "${contents_directory}/Resources/BrowserExtension" \
  "$dsym_directory"

executables=(NotchRouter notchctl notchrouter-browser-host)
typeset -A executable_destinations
executable_destinations[NotchRouter]="${contents_directory}/MacOS/NotchRouter"
executable_destinations[notchctl]="${contents_directory}/Resources/bin/notchctl"
executable_destinations[notchrouter-browser-host]="${contents_directory}/Resources/bin/notchrouter-browser-host"

for executable in "${executables[@]}"; do
  architecture_binaries=()
  for architecture in "${architectures[@]}"; do
    source_binary="${binary_directories[$architecture]}/${executable}"
    [[ -x "$source_binary" ]] || fail "Missing built executable: ${source_binary}"
    architecture_binaries+=("$source_binary")
  done

  destination=${executable_destinations[$executable]}
  lipo -create "${architecture_binaries[@]}" -output "$destination"
  chmod 755 "$destination"

  built_architectures=" $(lipo -archs "$destination") "
  for architecture in "${architectures[@]}"; do
    [[ "$built_architectures" == *" ${architecture} "* ]] \
      || fail "${executable} is missing its ${architecture} slice"
  done
done

sparkle_framework_source=$(find \
  "${build_directory}/artifacts" \
  -type d \
  -path "*/macos-arm64_x86_64/Sparkle.framework" \
  -print \
  -quit 2>/dev/null || true)
[[ -n "$sparkle_framework_source" ]] \
  || fail "Could not locate Sparkle.framework in SwiftPM artifacts"

sparkle_framework="${contents_directory}/Frameworks/Sparkle.framework"
ditto "$sparkle_framework_source" "$sparkle_framework"

# NotchRouter is not sandboxed, so Sparkle's sandbox-only XPC services are
# unnecessary. Removing them also avoids distributing unused ad-hoc-signed code.
if [[ -L "${sparkle_framework}/XPCServices" ]]; then
  rm -- "${sparkle_framework}/XPCServices"
fi
sparkle_current_version=$(readlink "${sparkle_framework}/Versions/Current")
sparkle_version_directory="${sparkle_framework}/Versions/${sparkle_current_version}"
if [[ -d "${sparkle_version_directory}/XPCServices" ]]; then
  rm -rf -- "${sparkle_version_directory}/XPCServices"
fi

sparkle_executables=(
  "${sparkle_version_directory}/Sparkle"
  "${sparkle_version_directory}/Autoupdate"
  "${sparkle_version_directory}/Updater.app/Contents/MacOS/Updater"
)
for sparkle_executable in "${sparkle_executables[@]}"; do
  [[ -x "$sparkle_executable" ]] \
    || fail "Missing Sparkle executable: ${sparkle_executable}"
  sparkle_architectures=" $(lipo -archs "$sparkle_executable") "
  for architecture in "${architectures[@]}"; do
    [[ "$sparkle_architectures" == *" ${architecture} "* ]] \
      || fail "${sparkle_executable:t} is missing its ${architecture} slice"
  done
done

ditto "${project_directory}/BrowserExtension/." \
  "${contents_directory}/Resources/BrowserExtension"
ditto "${project_directory}/Resources/Info.plist" \
  "${contents_directory}/Info.plist"
ditto "${project_directory}/Resources/NotchRouter.icns" \
  "${contents_directory}/Resources/NotchRouter.icns"

info_plist="${contents_directory}/Info.plist"
release_version=${RELEASE_VERSION:-$(plutil -extract CFBundleShortVersionString raw -o - "$info_plist")}
build_number=${BUILD_NUMBER:-$(plutil -extract CFBundleVersion raw -o - "$info_plist")}
[[ "$release_version" =~ '^[0-9]+([.][0-9]+){1,2}([+-][0-9A-Za-z.-]+)?$' ]] \
  || fail "RELEASE_VERSION must be a dotted numeric version"
[[ "$build_number" =~ '^[0-9]+$' ]] || fail "BUILD_NUMBER must be numeric"

plist_upsert_string CFBundleShortVersionString "$release_version" "$info_plist"
plist_upsert_string CFBundleVersion "$build_number" "$info_plist"
plist_upsert_string LSMinimumSystemVersion "$minimum_macos_version" "$info_plist"

if [[ -n ${SPARKLE_FEED_URL:-} ]]; then
  plist_upsert_string SUFeedURL "$SPARKLE_FEED_URL" "$info_plist"
  plist_upsert_string SUPublicEDKey "$SPARKLE_PUBLIC_ED_KEY" "$info_plist"
  plist_upsert_bool SURequireSignedFeed true "$info_plist"
  plist_upsert_bool SUVerifyUpdateBeforeExtraction true "$info_plist"
  plist_upsert_bool SUEnableAutomaticChecks true "$info_plist"
  plist_upsert_bool SUAllowsAutomaticUpdates true "$info_plist"
  plist_upsert_bool SUAutomaticallyUpdate false "$info_plist"
fi

if [[ -n ${SENTRY_DSN:-} ]]; then
  plist_upsert_string SentryDSN "$SENTRY_DSN" "$info_plist"
  plist_upsert_string SentryEnvironment "${SENTRY_ENVIRONMENT:-production}" "$info_plist"
fi

plutil -lint "$info_plist"

for executable in "${executables[@]}"; do
  destination=${executable_destinations[$executable]}
  if [[ "$executable" == "NotchRouter" ]]; then
    dsym_name="NotchRouter.app.dSYM"
  else
    dsym_name="${executable}.dSYM"
  fi
  dsym_path="${dsym_directory}/${dsym_name}"
  remove_dsym_if_present "$dsym_path"
  dsymutil "$destination" -o "$dsym_path"
  dwarfdump --uuid "$dsym_path" >/dev/null
done

sparkle_dsym_source="${sparkle_framework_source:h}/dSYMs"
if [[ -d "$sparkle_dsym_source" ]]; then
  for sparkle_dsym in "${sparkle_dsym_source}"/*.dSYM; do
    [[ -d "$sparkle_dsym" ]] || continue
    [[ ${sparkle_dsym:t} != "Downloader.xpc.dSYM" ]] || continue
    [[ ${sparkle_dsym:t} != "Installer.xpc.dSYM" ]] || continue
    sparkle_dsym_destination="${dsym_directory}/${sparkle_dsym:t}"
    remove_dsym_if_present "$sparkle_dsym_destination"
    ditto "$sparkle_dsym" "$sparkle_dsym_destination"
  done
fi

if ! otool -L "${contents_directory}/MacOS/NotchRouter" \
  | grep -q '@rpath/Sparkle.framework/'; then
  fail "NotchRouter does not link Sparkle through an @rpath install name"
fi

if [[ -n ${CODESIGN_IDENTITY:-} ]]; then
  [[ -f "$entitlements_path" ]] || fail "Missing entitlements: ${entitlements_path}"
  signing_arguments=(--force --options runtime --timestamp --sign "$CODESIGN_IDENTITY")

  log "Signing embedded Sparkle helpers"
  codesign "${signing_arguments[@]}" "${sparkle_version_directory}/Autoupdate"
  codesign "${signing_arguments[@]}" "${sparkle_version_directory}/Updater.app"
  codesign "${signing_arguments[@]}" "$sparkle_framework"

  log "Signing embedded executables"
  codesign "${signing_arguments[@]}" "${contents_directory}/Resources/bin/notchctl"
  codesign "${signing_arguments[@]}" \
    "${contents_directory}/Resources/bin/notchrouter-browser-host"

  log "Signing NotchRouter.app with the hardened runtime"
  codesign "${signing_arguments[@]}" \
    --entitlements "$entitlements_path" \
    "$app_directory"
  codesign --verify --deep --strict --verbose=2 "$app_directory"

  signed_items=(
    "${sparkle_version_directory}/Autoupdate"
    "${sparkle_version_directory}/Updater.app"
    "$sparkle_framework"
    "${contents_directory}/Resources/bin/notchctl"
    "${contents_directory}/Resources/bin/notchrouter-browser-host"
    "$app_directory"
  )
  for signed_item in "${signed_items[@]}"; do
    signing_details=$(codesign --display --verbose=4 "$signed_item" 2>&1)
    [[ "$signing_details" == *"Authority=Developer ID Application"* ]] \
      || fail "${signed_item} is not signed with Developer ID Application"
    [[ "$signing_details" == *"runtime"* ]] \
      || fail "${signed_item} does not have the hardened runtime enabled"
  done
elif [[ ${REQUIRE_SIGNING:-0} == 1 ]]; then
  fail "CODESIGN_IDENTITY must name a Developer ID Application identity"
else
  log "Leaving the local app unsigned (set CODESIGN_IDENTITY to sign it)"
fi

log "Packaged ${architecture_value} app: ${app_directory}"
print -r -- "$app_directory"
