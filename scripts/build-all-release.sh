#!/usr/bin/env bash
#
# Build store / release artifacts for every platform this host can produce.
#
# Version is always read from pubspec.yaml (Flutter's version: X.Y.Z+build).
#
# Outputs land in dist/ with the naming convention:
#   ErebrusAI-<platform>-vX.X.X.<ext>
#
# Examples:
#   ErebrusAI-ios-v1.0.0.ipa
#   ErebrusAI-macos-v1.0.0.zip
#   ErebrusAI-windows-v1.0.0.zip
#   ErebrusAI-ubuntu-v1.0.0.tar.gz
#   ErebrusAI-android-playstore-v1.0.2.aab
#   ErebrusAI-android-dappstore-v1.0.2.apk
#
# Usage:
#   ./scripts/build-all-release.sh              # all platforms supported here
#   ./scripts/build-all-release.sh ios macos
#   ./scripts/build-all-release.sh android
#   ./scripts/build-all-release.sh android-playstore
#   ./scripts/build-all-release.sh android-dappstore
#   ./scripts/build-all-release.sh --skip-verify
#   ./scripts/build-all-release.sh --skip-tests
#   ./scripts/build-all-release.sh --list
#
# On macOS: iOS, macOS (native). Ubuntu via Docker when available.
# Windows requires a Windows host (or CI).
# Android: Google Play AAB + Solana dApp Store APK (signed flavors).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

APP_NAME="ErebrusAI"
DIST_DIR="${ROOT_DIR}/dist"
SKIP_VERIFY=0
SKIP_TESTS=0
TARGETS=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() { echo "✗ $*" >&2; exit 1; }
info() { echo "▸ $*"; }
ok() { echo "✓ $*"; }
warn() { echo "⚠ $*" >&2; }

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

read_version() {
  # Canonical version is pubspec.yaml only (Flutter's version: X.Y.Z+build).
  local pubspec="${ROOT_DIR}/pubspec.yaml"
  [[ -f "${pubspec}" ]] || die "pubspec.yaml not found at ${pubspec}"

  local version_line
  version_line="$(grep -E '^version:[[:space:]]*' "${pubspec}" | head -1 | awk '{print $2}')"
  [[ -n "${version_line}" ]] || die "Could not read version: from pubspec.yaml"

  VERSION_NAME="${version_line%%+*}"
  VERSION_CODE="${version_line##*+}"
  [[ -n "${VERSION_NAME}" ]] || die "Empty version name in pubspec.yaml (${version_line})"
  # If there is no +build suffix, treat build as 1.
  if [[ "${VERSION_CODE}" == "${version_line}" ]]; then
    VERSION_CODE="1"
  fi
  [[ "${VERSION_NAME}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.+-]+)?$ ]] \
    || die "Unexpected version name '${VERSION_NAME}' in pubspec.yaml (expected X.Y.Z)"

  VERSION_TAG="v${VERSION_NAME}"
  ok "version from pubspec.yaml: ${VERSION_NAME}+${VERSION_CODE} → ${VERSION_TAG}"
}

artifact_path() {
  # artifact_path <platform-slug> <ext>
  echo "${DIST_DIR}/${APP_NAME}-$1-${VERSION_TAG}.$2"
}

# Optional compile-time overrides. RuntimeConfig also loads the bundled .env
# asset; --dart-define-from-file wins for String.fromEnvironment keys.
dart_define_args() {
  if [[ -f "${ROOT_DIR}/.env" ]]; then
    echo "--dart-define-from-file=${ROOT_DIR}/.env"
  else
    warn ".env missing — copy env.example → .env for production config"
    echo ""
  fi
}

host_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT) echo "windows" ;;
    *) echo "unknown" ;;
  esac
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

ensure_dist() {
  mkdir -p "${DIST_DIR}"
}

copy_artifact() {
  local src="$1" dest="$2"
  [[ -f "${src}" ]] || die "Build output missing: ${src}"
  cp -f "${src}" "${dest}"
  ok "artifact → ${dest##${ROOT_DIR}/} ($(du -h "${dest}" | awk '{print $1}'))"
}

# Flutter regenerates FlutterGeneratedPluginSwiftPackage at tool defaults
# (.iOS("13.0") / .macOS("10.15")). erebrus_mlx / erebrus_speech need iOS 17
# and macOS 14 (same as Runner). Pin after pub get / before Apple builds.
ensure_spm_platform_versions() {
  # Flutter always regenerates FlutterGeneratedPluginSwiftPackage at tool
  # defaults (.iOS("13.0") / .macOS("10.15")) on `pub get`. Official bump only
  # happens inside `flutter build ios|macos` via updateMinimumDeployment.
  # erebrus_mlx / erebrus_speech require iOS 17 / macOS 14 (same as Runner).
  local ios_min="${EREBRUS_IOS_MIN:-17.0}"
  local macos_min="${EREBRUS_MACOS_MIN:-14.0}"
  local ios_pkg="${ROOT_DIR}/ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift"
  local macos_pkg="${ROOT_DIR}/macos/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift"

  if [[ -f "${ios_pkg}" ]] && ! grep -qF ".iOS(\"${ios_min}\")" "${ios_pkg}"; then
    /usr/bin/perl -pi -e "s/\\.iOS\\(\"[0-9.]+\"\\)/.iOS(\"${ios_min}\")/g" "${ios_pkg}"
    ok "SPM iOS package pin → ${ios_min}"
  fi
  if [[ -f "${macos_pkg}" ]] && ! grep -qF ".macOS(\"${macos_min}\")" "${macos_pkg}"; then
    /usr/bin/perl -pi -e "s/\\.macOS\\(\"[0-9.]+\"\\)/.macOS(\"${macos_min}\")/g" "${macos_pkg}"
    ok "SPM macOS package pin → ${macos_min}"
  fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

preflight() {
  require_cmd flutter
  ensure_dist

  # pubspec lists .env as a Flutter asset — release builds fail without it.
  if [[ ! -f "${ROOT_DIR}/.env" ]]; then
    if [[ -f "${ROOT_DIR}/env.example" ]]; then
      warn ".env missing — creating from env.example (fill secrets before shipping)"
      cp "${ROOT_DIR}/env.example" "${ROOT_DIR}/.env"
    else
      die "Missing .env (required Flutter asset). Add env.example or create .env."
    fi
  fi

  info "host=$(host_os)  version=${VERSION_NAME}+${VERSION_CODE}  out=dist/"
  info "flutter pub get"
  flutter pub get
  ensure_spm_platform_versions

  if [[ "${SKIP_TESTS}" -eq 0 ]]; then
    info "flutter analyze"
    flutter analyze
    info "flutter test"
    flutter test
  else
    warn "skipping analyze + test (--skip-tests)"
  fi
}

# ---------------------------------------------------------------------------
# Android — Google Play AAB + Solana dApp Store APK
# ---------------------------------------------------------------------------

ensure_android_signing() {
  [[ -f android/key.properties ]] || die \
    "Missing android/key.properties. Copy android/key.properties.example and fill passwords."

  local missing=0
  for prefix in playstore dappstore; do
    for key in storeFile storePassword keyAlias keyPassword; do
      if ! grep -qE "^${prefix}\\.${key}=.+" android/key.properties; then
        warn "android/key.properties missing ${prefix}.${key}"
        missing=1
      fi
    done
  done
  [[ "${missing}" -eq 0 ]] || die "Fix android/key.properties before Android release builds."

  resolve_keystore() {
    local raw="$1"
    if [[ "${raw}" = /* ]]; then
      [[ -f "${raw}" ]] && { echo "${raw}"; return; }
      return 1
    fi
    local c
    for c in "android/app/${raw}" "android/${raw}" "${raw}"; do
      if [[ -f "${c}" ]]; then
        echo "${c}"
        return 0
      fi
    done
    return 1
  }

  local play_ks dapp_ks play_path dapp_path
  play_ks="$(grep '^playstore.storeFile=' android/key.properties | cut -d= -f2-)"
  dapp_ks="$(grep '^dappstore.storeFile=' android/key.properties | cut -d= -f2-)"
  play_path="$(resolve_keystore "${play_ks}")" \
    || die "Play Store keystore not found (playstore.storeFile=${play_ks})"
  dapp_path="$(resolve_keystore "${dapp_ks}")" \
    || die "dApp Store keystore not found (dappstore.storeFile=${dapp_ks})"
  ok "playstore keystore: ${play_path}"
  ok "dappstore keystore: ${dapp_path}"
}

verify_android_apk() {
  local apk="$1"
  [[ "${SKIP_VERIFY}" -eq 0 ]] || return 0
  info "Verifying Android APK version + signature…"
  local aapt=""
  if [[ -n "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ]]; then
    aapt="$(ls -d "${ANDROID_HOME:-$ANDROID_SDK_ROOT}"/build-tools/*/aapt 2>/dev/null | tail -1 || true)"
  fi
  if [[ -n "${aapt}" ]]; then
    local short build
    short="$("${aapt}" dump badging "${apk}" 2>/dev/null | sed -n "s/.*versionName='\\([^']*\\)'.*/\\1/p" | head -1)"
    build="$("${aapt}" dump badging "${apk}" 2>/dev/null | sed -n "s/.*versionCode='\\([^']*\\)'.*/\\1/p" | head -1)"
    echo "    versionName=${short} versionCode=${build}"
    [[ "${short}" == "${VERSION_NAME}" ]] && ok "APK versionName matches pubspec (${VERSION_NAME})" \
      || warn "APK versionName '${short}' != pubspec ${VERSION_NAME}"
    [[ "${build}" == "${VERSION_CODE}" ]] && ok "APK versionCode matches pubspec (${VERSION_CODE})" \
      || warn "APK versionCode '${build}' != pubspec ${VERSION_CODE}"
  else
    warn "aapt not found — skip versionName/versionCode check"
  fi
  if command -v apksigner >/dev/null 2>&1; then
    apksigner verify --verbose "${apk}" >/dev/null && ok "apksigner verify passed"
  fi
}

build_android_playstore() {
  info "Google Play App Bundle (playstore, ${VERSION_NAME}+${VERSION_CODE})"
  ensure_android_signing
  local define_args
  define_args="$(dart_define_args)"
  # shellcheck disable=SC2086
  flutter build appbundle --flavor playstore --release \
    --target-platform android-arm64 ${define_args}

  local src="build/app/outputs/bundle/playstoreRelease/app-playstore-release.aab"
  [[ -f "${src}" ]] || die "Play Store AAB not found: ${src}"
  local dest
  dest="$(artifact_path android-playstore aab)"
  copy_artifact "${src}" "${dest}"
}

build_android_dappstore() {
  info "Solana dApp Store APK (dappstore, ${VERSION_NAME}+${VERSION_CODE})"
  ensure_android_signing
  local define_args
  define_args="$(dart_define_args)"
  # shellcheck disable=SC2086
  flutter build apk --flavor dappstore --release \
    --target-platform android-arm64 ${define_args}

  local src="build/app/outputs/flutter-apk/app-dappstore-release.apk"
  if [[ ! -f "${src}" ]]; then
    src="build/app/outputs/apk/dappstore/release/app-dappstore-release.apk"
  fi
  local dest
  dest="$(artifact_path android-dappstore apk)"
  copy_artifact "${src}" "${dest}"
  verify_android_apk "${dest}"
}

build_android() {
  build_android_playstore
  build_android_dappstore
}

# ---------------------------------------------------------------------------
# iOS — IPA for TestFlight / App Store
# ---------------------------------------------------------------------------

build_ios() {
  [[ "$(host_os)" == "macos" ]] || die "iOS builds require macOS + Xcode"

  info "iOS IPA (App Store / TestFlight)"
  require_cmd xcodebuild
  ensure_spm_platform_versions

  local define_args
  define_args="$(dart_define_args)"
  # shellcheck disable=SC2086
  flutter build ipa --release ${define_args}

  local src
  src="$(find build/ios/ipa -maxdepth 1 -name '*.ipa' 2>/dev/null | head -1 || true)"
  [[ -n "${src}" ]] || die "IPA not found under build/ios/ipa/ — check signing / export logs"
  local dest
  dest="$(artifact_path ios ipa)"
  copy_artifact "${src}" "${dest}"

  if [[ "${SKIP_VERIFY}" -eq 0 ]]; then
    verify_ios_ipa "${dest}"
  fi
}

verify_ios_ipa() {
  local ipa="$1"
  info "Verifying iOS IPA version metadata…"
  local work
  work="$(mktemp -d)"
  unzip -q "${ipa}" -d "${work}"
  local app
  app="$(find "${work}/Payload" -maxdepth 1 -name '*.app' | head -1)"
  if [[ -z "${app}" ]]; then
    rm -rf "${work}"
    die "IPA has no Payload/*.app"
  fi

  local short build
  short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app}/Info.plist" 2>/dev/null || true)"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${app}/Info.plist" 2>/dev/null || true)"
  echo "    Runner CFBundleShortVersionString=${short} CFBundleVersion=${build}"

  if [[ "${short}" != "${VERSION_NAME}" ]]; then
    warn "Runner short version '${short}' != pubspec ${VERSION_NAME}"
  else
    ok "Runner version matches pubspec (${VERSION_NAME})"
  fi
  if [[ "${build}" != "${VERSION_CODE}" ]]; then
    warn "Runner build '${build}' != pubspec build ${VERSION_CODE}"
  else
    ok "Runner build matches pubspec (${VERSION_CODE})"
  fi

  rm -rf "${work}"
}

# ---------------------------------------------------------------------------
# macOS — .app ZIP for distribution; App Store uses Xcode Organizer archive
# ---------------------------------------------------------------------------

build_macos() {
  [[ "$(host_os)" == "macos" ]] || die "macOS builds require a Mac"

  info "macOS release .app"
  require_cmd xcodebuild
  ensure_spm_platform_versions

  local define_args
  define_args="$(dart_define_args)"
  # shellcheck disable=SC2086
  flutter build macos --release ${define_args}

  local app
  app="$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' | head -1)"
  [[ -n "${app}" ]] || die "macOS .app not found under build/macos/Build/Products/Release"

  if [[ "${SKIP_VERIFY}" -eq 0 ]]; then
    verify_macos_app "${app}"
  fi

  local dest
  dest="$(artifact_path macos zip)"
  rm -f "${dest}"
  ditto -c -k --keepParent "${app}" "${dest}"
  ok "artifact → ${dest##${ROOT_DIR}/} ($(du -h "${dest}" | awk '{print $1}'))"
}

verify_macos_app() {
  local app="$1"
  info "Verifying macOS .app version metadata…"
  local plist="${app}/Contents/Info.plist"
  local short build
  short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${plist}" 2>/dev/null || true)"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${plist}" 2>/dev/null || true)"
  echo "    Runner CFBundleShortVersionString=${short} CFBundleVersion=${build}"
  if [[ "${short}" == "${VERSION_NAME}" && "${build}" == "${VERSION_CODE}" ]]; then
    ok "macOS Runner version matches pubspec (${VERSION_NAME}+${VERSION_CODE})"
  else
    warn "macOS Runner ${short}+${build} should be ${VERSION_NAME}+${VERSION_CODE}"
  fi
}

# ---------------------------------------------------------------------------
# Windows — native host only (Flutter cannot cross-compile Windows from macOS)
# ---------------------------------------------------------------------------

build_windows() {
  if [[ "$(host_os)" != "windows" ]]; then
    warn "Windows desktop builds require a Windows host (or CI)."
    warn "Skipped: ${APP_NAME}-windows-${VERSION_TAG}.zip"
    warn "  On Windows:"
    warn "    flutter pub get"
    warn "    flutter build windows --release"
    warn "    zip the contents of build/windows/x64/runner/Release/"
    warn "      → dist/${APP_NAME}-windows-${VERSION_TAG}.zip"
    return 0
  fi

  info "Windows release bundle"
  local define_args
  define_args="$(dart_define_args)"
  # shellcheck disable=SC2086
  flutter build windows --release ${define_args}

  local runner_dir="${ROOT_DIR}/build/windows/x64/runner/Release"
  [[ -d "${runner_dir}" ]] || die "Windows Release folder missing: ${runner_dir}"

  local dest
  dest="$(artifact_path windows zip)"
  rm -f "${dest}"
  (cd "${runner_dir}" && zip -qr "${dest}" .)
  ok "artifact → ${dest##${ROOT_DIR}/} ($(du -h "${dest}" | awk '{print $1}'))"
}

# ---------------------------------------------------------------------------
# Ubuntu / Linux — native Linux, or Docker on macOS when available
# ---------------------------------------------------------------------------

build_ubuntu_native() {
  info "Ubuntu/Linux release bundle (native)"
  local define_args
  define_args="$(dart_define_args)"
  # shellcheck disable=SC2086
  flutter build linux --release ${define_args}

  local bundle
  bundle="$(find build/linux -maxdepth 3 -type d -name 'bundle' | head -1)"
  [[ -n "${bundle}" ]] || die "Linux bundle not found under build/linux"

  local dest
  dest="$(artifact_path ubuntu tar.gz)"
  rm -f "${dest}"
  tar -czf "${dest}" -C "$(dirname "${bundle}")" "$(basename "${bundle}")"
  ok "artifact → ${dest##${ROOT_DIR}/} ($(du -h "${dest}" | awk '{print $1}'))"
}

build_ubuntu_docker() {
  require_cmd docker
  info "Ubuntu/Linux release via Docker (cross-build from $(host_os))"

  local image="${EREBRUS_LINUX_DOCKER_IMAGE:-ghcr.io/cirruslabs/flutter:stable}"
  info "docker pull ${image}"
  docker pull "${image}"

  docker run --rm \
    -v "${ROOT_DIR}:/app" \
    -w /app \
    "${image}" \
    bash -lc '
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev zip >/dev/null
      if [[ -f env.example && ! -f .env ]]; then cp env.example .env; fi
      flutter config --enable-linux-desktop
      flutter pub get
      DEFINE=""
      if [[ -f .env ]]; then DEFINE="--dart-define-from-file=/app/.env"; fi
      # shellcheck disable=SC2086
      flutter build linux --release ${DEFINE}
      BUNDLE="$(find build/linux -maxdepth 3 -type d -name bundle | head -1)"
      test -n "${BUNDLE}"
      VERSION_LINE="$(grep "^version:" pubspec.yaml | awk "{print \$2}")"
      VERSION_NAME="${VERSION_LINE%%+*}"
      DEST="dist/ErebrusAI-ubuntu-v${VERSION_NAME}.tar.gz"
      mkdir -p dist
      rm -f "${DEST}"
      tar -czf "${DEST}" -C "$(dirname "${BUNDLE}")" "$(basename "${BUNDLE}")"
      echo "✓ docker artifact → ${DEST}"
      ls -lh "${DEST}"
    '
  local dest
  dest="$(artifact_path ubuntu tar.gz)"
  [[ -f "${dest}" ]] || die "Docker Linux build did not produce ${dest##${ROOT_DIR}/}"
  ok "artifact → ${dest##${ROOT_DIR}/} ($(du -h "${dest}" | awk '{print $1}'))"
}

build_ubuntu() {
  case "$(host_os)" in
    linux)
      build_ubuntu_native
      ;;
    macos|windows)
      if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        build_ubuntu_docker
      else
        warn "Ubuntu/Linux Flutter builds need a Linux host or a running Docker daemon."
        warn "Skipped: ${APP_NAME}-ubuntu-${VERSION_TAG}.tar.gz"
        warn "  Options:"
        warn "    1) Start Docker Desktop, re-run: ./scripts/build-all-release.sh ubuntu"
        warn "    2) On Ubuntu: flutter build linux --release"
        warn "    3) CI workflow that builds on ubuntu-latest"
      fi
      ;;
    *)
      warn "Unknown host — cannot build Ubuntu/Linux"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Upload instructions (printed after successful Apple builds)
# ---------------------------------------------------------------------------

print_apple_upload_steps() {
  cat <<EOF

══════════════════════════════════════════════════════════════════════════════
  TestFlight / App Store upload steps (iOS + macOS)
══════════════════════════════════════════════════════════════════════════════

Version: ${VERSION_NAME}+${VERSION_CODE}  (from pubspec.yaml)
Bundle:  com.erebrus.ai

── iOS (TestFlight / App Store) ──────────────────────────────────────────────

Artifact: dist/${APP_NAME}-ios-${VERSION_TAG}.ipa

Option A — Transporter (GUI)
  1. Open Transporter (Mac App Store or Xcode → Open Developer Tool).
  2. Sign in with the Apple ID that has App Store Connect access for
     com.erebrus.ai.
  3. Drag dist/${APP_NAME}-ios-${VERSION_TAG}.ipa into Transporter → Deliver.
  4. In App Store Connect → TestFlight, wait for processing, then add testers.

Option B — App Store Connect API (CLI)
  xcrun altool --upload-app --type ios \\
    --file "dist/${APP_NAME}-ios-${VERSION_TAG}.ipa" \\
    --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>

Option C — Xcode Organizer
  1. open ios/Runner.xcworkspace
  2. Product → Destination → Any iOS Device
  3. Product → Archive → Distribute App → App Store Connect → Upload

Verify before shipping:
  • CFBundleShortVersionString == ${VERSION_NAME}
  • CFBundleVersion == ${VERSION_CODE}

── macOS (Mac App Store / optional notarized ZIP) ────────────────────────────

ZIP artifact (sideload / GitHub): dist/${APP_NAME}-macos-${VERSION_TAG}.zip

Mac App Store path:
  1. open macos/Runner.xcworkspace
  2. Product → Archive → Distribute App → App Store Connect → Upload

── Android ───────────────────────────────────────────────────────────────────

Google Play AAB:
  dist/${APP_NAME}-android-playstore-${VERSION_TAG}.aab
  → Play Console (com.erebrus.ai)

Solana dApp Store APK:
  dist/${APP_NAME}-android-dappstore-${VERSION_TAG}.apk
  → Solana dApp Store publisher portal (separate signing key)

── Desktop sideload ──────────────────────────────────────────────────────────

  Windows: dist/${APP_NAME}-windows-${VERSION_TAG}.zip  (Windows host / CI)
  Ubuntu:  dist/${APP_NAME}-ubuntu-${VERSION_TAG}.tar.gz

══════════════════════════════════════════════════════════════════════════════
EOF
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
  echo
  echo "══════════════════════════════════════════════════════════════════════════════"
  echo "  Release artifacts (${VERSION_NAME}+${VERSION_CODE})"
  echo "══════════════════════════════════════════════════════════════════════════════"
  if compgen -G "${DIST_DIR}/${APP_NAME}-*-${VERSION_TAG}.*" >/dev/null; then
    ls -lh "${DIST_DIR}/${APP_NAME}"-*-"${VERSION_TAG}".* 2>/dev/null | awk '{print "  " $9 "  (" $5 ")"}'
  else
    echo "  (no matching artifacts in dist/)"
  fi
  echo "══════════════════════════════════════════════════════════════════════════════"
}

# ---------------------------------------------------------------------------
# Target selection
# ---------------------------------------------------------------------------

default_targets() {
  # Platforms this host can reasonably produce.
  case "$(host_os)" in
    macos)
      echo "android ios macos ubuntu windows"
      ;;
    linux)
      echo "android ubuntu"
      ;;
    windows)
      echo "android windows"
      ;;
    *)
      echo "android"
      ;;
  esac
}

list_targets() {
  cat <<EOF
Available targets (pass as args; default = all supported on this host):

  android              Play Store AAB + dApp Store APK
  android-playstore    Google Play App Bundle only
  android-dappstore    Solana dApp Store APK only
  ios                  IPA for TestFlight / App Store (macOS only)
  macos                .app ZIP + version verification (macOS only)
  windows              Desktop ZIP (Windows host only; skipped elsewhere)
  ubuntu | linux       Linux/GTK tar.gz (native Linux or Docker)

Flags:
  --skip-tests         Skip flutter analyze + flutter test
  --skip-verify        Skip IPA / .app version checks
  --list               Show this help
  -h, --help           Show usage

This host ($(host_os)) default set: $(default_targets)
Naming: ${APP_NAME}-<platform>-vX.X.X.<ext>  (version from pubspec.yaml)
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage 0 ;;
      --list) list_targets; exit 0 ;;
      --skip-tests) SKIP_TESTS=1; shift ;;
      --skip-verify) SKIP_VERIFY=1; shift ;;
      android|android-playstore|android-dappstore|ios|macos|windows|ubuntu|linux|all)
        TARGETS+=("$1"); shift ;;
      *)
        die "Unknown argument: $1 (try --help)"
        ;;
    esac
  done

  read_version

  if [[ ${#TARGETS[@]} -eq 0 ]]; then
    # shellcheck disable=SC2207
    TARGETS=($(default_targets))
  fi

  # Expand aliases
  local expanded=()
  for t in "${TARGETS[@]}"; do
    case "$t" in
      all) expanded+=($(default_targets)) ;;
      linux) expanded+=("ubuntu") ;;
      *) expanded+=("$t") ;;
    esac
  done
  TARGETS=("${expanded[@]}")

  # De-dupe while preserving order
  local seen="|" uniq=()
  for t in "${TARGETS[@]}"; do
    if [[ "${seen}" != *"|${t}|"* ]]; then
      uniq+=("$t")
      seen="${seen}${t}|"
    fi
  done
  TARGETS=("${uniq[@]}")

  preflight

  local built_apple=0
  for t in "${TARGETS[@]}"; do
    echo
    echo "────────── ${t} ──────────"
    case "$t" in
      android) build_android; ;;
      android-playstore) build_android_playstore; ;;
      android-dappstore) build_android_dappstore; ;;
      ios) build_ios; built_apple=1; ;;
      macos) build_macos; built_apple=1; ;;
      windows) build_windows; ;;
      ubuntu) build_ubuntu; ;;
      *) die "Unhandled target: $t" ;;
    esac
  done

  print_summary
  if [[ "${built_apple}" -eq 1 ]]; then
    print_apple_upload_steps
  fi
}

main "$@"
