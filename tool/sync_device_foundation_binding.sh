#!/usr/bin/env bash
set -euo pipefail

readonly SDK_COMMIT="ae8ab26f6a0e8afccd7e03024baa4e340754874e"
readonly SDK_BINDING="contracts/device_foundation/v1/generated/dart/device_foundation_v1.dart"
readonly MOBILE_BINDING="lib/src/generated/device_foundation_v1.dart"
readonly SDK_CONSUMER_FIXTURE="contracts/device_foundation/v1/examples/valid/admission-consumer-surface.json"
readonly MOBILE_CONSUMER_FIXTURE="test/fixtures/device_foundation/admission-consumer-surface.json"
readonly SDK_ADMISSION_FIXTURE="contracts/device_foundation/v1/examples/valid/admission.json"
readonly MOBILE_ADMISSION_FIXTURE="test/fixtures/device_foundation/admission.json"
readonly SDK_ADMISSION_GOLDEN="contracts/device_foundation/v1/golden/admission-event-stream.json"
readonly MOBILE_ADMISSION_GOLDEN="test/fixtures/device_foundation/admission-event-stream.json"

mode="${1:---check}"
sdk_root="${EIDOLON_SDK_ROOT:-../eidolon_sdk}"

if [[ "$mode" != "--check" && "$mode" != "--sync" ]]; then
  echo "usage: $0 [--check|--sync]" >&2
  exit 64
fi

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

sdk_paths=(
  "$SDK_BINDING"
  "$SDK_CONSUMER_FIXTURE"
  "$SDK_ADMISSION_FIXTURE"
  "$SDK_ADMISSION_GOLDEN"
)
mobile_paths=(
  "$MOBILE_BINDING"
  "$MOBILE_CONSUMER_FIXTURE"
  "$MOBILE_ADMISSION_FIXTURE"
  "$MOBILE_ADMISSION_GOLDEN"
)

drifted=0
for index in "${!sdk_paths[@]}"; do
  sdk_path="${sdk_paths[$index]}"
  mobile_path="${mobile_paths[$index]}"
  temporary_path="$temporary_root/$index"
  if ! git -C "$sdk_root" cat-file -e "$SDK_COMMIT:$sdk_path" 2>/dev/null; then
    echo "canonical SDK artifact $SDK_COMMIT:$sdk_path is unavailable" >&2
    exit 66
  fi
  git -C "$sdk_root" show "$SDK_COMMIT:$sdk_path" >"$temporary_path"
  if ! cmp -s "$temporary_path" "$mobile_path"; then
    if [[ "$mode" == "--check" ]]; then
      echo "device-foundation artifact drifted: $mobile_path" >&2
      drifted=1
    else
      mkdir -p "$(dirname "$mobile_path")"
      cp "$temporary_path" "$mobile_path"
      echo "synced $mobile_path from SDK $SDK_COMMIT"
    fi
  fi
done

if [[ "$drifted" -ne 0 ]]; then
  exit 1
fi
echo "device-foundation artifacts match SDK $SDK_COMMIT"
