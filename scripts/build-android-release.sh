#!/usr/bin/env bash
# Signed Android store artifacts for Google Play and Solana dApp Store.
#
#   ./scripts/build-android-release.sh              # both
#   ./scripts/build-android-release.sh playstore    # AAB
#   ./scripts/build-android-release.sh dappstore    # APK
#
# Names (version from pubspec.yaml):
#   dist/ErebrusAI-android-playstore-vX.Y.Z.aab
#   dist/ErebrusAI-android-dappstore-vX.Y.Z.apk
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FLAVOR="${1:-all}"
case "$FLAVOR" in
  playstore) exec ./scripts/build-all-release.sh --skip-tests android-playstore ;;
  dappstore) exec ./scripts/build-all-release.sh --skip-tests android-dappstore ;;
  all)       exec ./scripts/build-all-release.sh --skip-tests android ;;
  -h|--help)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "Usage: $0 [playstore|dappstore|all]" >&2
    exit 1
    ;;
esac
