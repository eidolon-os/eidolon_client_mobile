#!/usr/bin/env bash
set -euo pipefail

readonly SDK_COMMIT="6a62e2f762637d9bff0103fdcbe7e5f6e45a310e"
readonly SDK_BINDING="contracts/device_foundation/v1/generated/dart/device_foundation_v1.dart"
readonly MOBILE_BINDING="lib/src/generated/device_foundation_v1.dart"
readonly SDK_CONSUMER_FIXTURE="contracts/device_foundation/v1/examples/valid/admission-consumer-surface.json"
readonly MOBILE_CONSUMER_FIXTURE="test/fixtures/device_foundation/admission-consumer-surface.json"
readonly SDK_ADMISSION_FIXTURE="contracts/device_foundation/v1/examples/valid/admission.json"
readonly MOBILE_ADMISSION_FIXTURE="test/fixtures/device_foundation/admission.json"
readonly SDK_ADMISSION_GOLDEN="contracts/device_foundation/v1/golden/admission-event-stream.json"
readonly MOBILE_ADMISSION_GOLDEN="test/fixtures/device_foundation/admission-event-stream.json"
# The single authority for the descriptor canonical signing bytes; the Dart
# canonicaliser is tested against it so a field added in the SDK cannot be
# missed here without a red test.
readonly SDK_DESCRIPTOR_GOLDEN="contracts/device_foundation/v1/golden/owner-domain-descriptor.json"
readonly MOBILE_DESCRIPTOR_GOLDEN="test/fixtures/device_foundation/owner-domain-descriptor.json"
# The setup descriptor's field table. It used to be written by hand in the
# firmware and again by hand here, which is how the device came to encode an
# endless setup window as 0 while this side refused any duration it could not
# act on. Both ends now answer to this vector.
readonly SDK_SETUP_DESCRIPTOR_GOLDEN="contracts/device_foundation/v1/golden/setup-descriptor.json"
readonly MOBILE_SETUP_DESCRIPTOR_GOLDEN="test/fixtures/device_foundation/setup-descriptor.json"
# How a device instance id is derived from an operational key. This app used to
# invent `mobile-android-<hash of ANDROID_ID>`, which Hub answers 422 to, so no
# enrollment for this phone could exist — and the phone's own read path compared
# its invented id against Hub's derived one and never matched. The derivation is
# held to these numbers rather than to review.
readonly SDK_COMMISSIONING_IDENTITY_GOLDEN="contracts/device_foundation/v1/golden/development-commissioning-identity.json"
readonly MOBILE_COMMISSIONING_IDENTITY_GOLDEN="test/fixtures/device_foundation/development-commissioning-identity.json"

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
  "$SDK_DESCRIPTOR_GOLDEN"
  "$SDK_SETUP_DESCRIPTOR_GOLDEN"
  "$SDK_COMMISSIONING_IDENTITY_GOLDEN"
)
mobile_paths=(
  "$MOBILE_BINDING"
  "$MOBILE_CONSUMER_FIXTURE"
  "$MOBILE_ADMISSION_FIXTURE"
  "$MOBILE_ADMISSION_GOLDEN"
  "$MOBILE_DESCRIPTOR_GOLDEN"
  "$MOBILE_SETUP_DESCRIPTOR_GOLDEN"
  "$MOBILE_COMMISSIONING_IDENTITY_GOLDEN"
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
