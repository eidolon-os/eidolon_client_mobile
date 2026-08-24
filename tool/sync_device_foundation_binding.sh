#!/usr/bin/env bash
set -euo pipefail

readonly SDK_COMMIT="d88196757e8c054befd2c17f7cb9c7a9eb6f5253"
readonly SDK_BINDING="contracts/device_foundation/v1/generated/dart/device_foundation_v1.dart"
readonly MOBILE_BINDING="lib/src/generated/device_foundation_v1.dart"

mode="${1:---check}"
sdk_root="${EIDOLON_SDK_ROOT:-../eidolon_sdk}"

if [[ "$mode" != "--check" && "$mode" != "--sync" ]]; then
  echo "usage: $0 [--check|--sync]" >&2
  exit 64
fi

if ! git -C "$sdk_root" cat-file -e "$SDK_COMMIT:$SDK_BINDING" 2>/dev/null; then
  echo "canonical SDK binding $SDK_COMMIT:$SDK_BINDING is unavailable" >&2
  exit 66
fi

temporary_binding="$(mktemp)"
trap 'rm -f "$temporary_binding"' EXIT
git -C "$sdk_root" show "$SDK_COMMIT:$SDK_BINDING" >"$temporary_binding"

if cmp -s "$temporary_binding" "$MOBILE_BINDING"; then
  echo "device-foundation Dart binding matches SDK $SDK_COMMIT"
  exit 0
fi

if [[ "$mode" == "--check" ]]; then
  echo "device-foundation Dart binding drifted from SDK $SDK_COMMIT" >&2
  exit 1
fi

cp "$temporary_binding" "$MOBILE_BINDING"
echo "synced device-foundation Dart binding from SDK $SDK_COMMIT"
