#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PACKAGE_NAME="live.eidolon.eidolon_client_mobile"
readonly MAIN_ACTIVITY="${PACKAGE_NAME}/.MainActivity"
readonly DEVICE_ID_NAMESPACE="eidolon-mobile-android-v1"

FLUTTER_BIN="${EIDOLON_FLUTTER_BIN:-${HOME}/Developer/flutter/bin/flutter}"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${HOME}/Developer/Android/sdk}"
ADB_BIN="${EIDOLON_ADB_BIN:-${ANDROID_SDK_ROOT}/platform-tools/adb}"
JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
BUILD_MODE="${EIDOLON_MOBILE_BUILD_MODE:-debug}"
SERIAL="${ANDROID_SERIAL:-}"
SKIP_BUILD=0
TAIL_LINES=300

export ANDROID_SDK_ROOT JAVA_HOME
export PATH="${JAVA_HOME}/bin:${ANDROID_SDK_ROOT}/platform-tools:${PATH}"

die() {
  echo "error: $*" >&2
  exit 1
}

info() {
  echo ">> $*"
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/android-mobile.sh <command> [options]

Commands:
  devices       List attached Android devices
  diagnose      Check Flutter, Android SDK, ADB, Java, APK and device
  build         Build an Android APK
  install       Install/update the existing APK and preserve app data
  reinstall     Uninstall then install the existing APK (clean reinstall)
  restart       Force-stop and launch the app
  run           Build, install and restart
  logs          Stream ADB logcat for the running app
  logs-tail     Print recent ADB logs and exit
  clear-logs    Clear the selected device's logcat buffer
  identity      Print ANDROID_ID and the deterministic Eidolon device ID

Options:
  --serial <id>          Select an ADB device (defaults to the only online one)
  --mode <debug|profile|release>
  --skip-build           For run: reuse the existing APK
  --lines <count>        For logs-tail (default: 300)

Environment overrides:
  EIDOLON_FLUTTER_BIN, ANDROID_SDK_ROOT, EIDOLON_ADB_BIN,
  EIDOLON_MOBILE_BUILD_MODE, ANDROID_SERIAL, JAVA_HOME
EOF
}

require_tools() {
  [[ -x "${ADB_BIN}" ]] || die "adb not executable: ${ADB_BIN}"
}

select_device() {
  require_tools
  if [[ -n "${SERIAL}" ]]; then
    local state
    state="$("${ADB_BIN}" -s "${SERIAL}" get-state 2>/dev/null || true)"
    [[ "${state}" == "device" ]] || die "device is not online: ${SERIAL}"
    return
  fi

  local -a devices=()
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] && devices+=("${candidate}")
  done < <("${ADB_BIN}" devices | awk 'NR > 1 && $2 == "device" { print $1 }')

  case "${#devices[@]}" in
    0) die "no online Android device found" ;;
    1) SERIAL="${devices[0]}" ;;
    *) die "multiple devices found; pass --serial <id>" ;;
  esac
}

apk_path() {
  echo "${PROJECT_ROOT}/build/app/outputs/flutter-apk/app-${BUILD_MODE}.apk"
}

build_apk() {
  [[ -x "${FLUTTER_BIN}" ]] || die "flutter not executable: ${FLUTTER_BIN}"
  info "building ${BUILD_MODE} APK"
  (
    cd "${PROJECT_ROOT}"
    "${FLUTTER_BIN}" pub get
    "${FLUTTER_BIN}" build apk "--${BUILD_MODE}"
  )
  [[ -f "$(apk_path)" ]] || die "APK was not created: $(apk_path)"
  info "APK ready: $(apk_path)"
}

install_apk() {
  select_device
  local apk
  apk="$(apk_path)"
  [[ -f "${apk}" ]] || die "APK not found; run build first: ${apk}"
  info "installing ${apk} on ${SERIAL}"
  "${ADB_BIN}" -s "${SERIAL}" install -r "${apk}"
}

reinstall_apk() {
  select_device
  local apk
  apk="$(apk_path)"
  [[ -f "${apk}" ]] || die "APK not found; run build first: ${apk}"
  info "clean reinstall on ${SERIAL}"
  "${ADB_BIN}" -s "${SERIAL}" uninstall "${PACKAGE_NAME}" >/dev/null 2>&1 || true
  "${ADB_BIN}" -s "${SERIAL}" install "${apk}"
}

restart_app() {
  select_device
  info "restarting ${PACKAGE_NAME} on ${SERIAL}"
  "${ADB_BIN}" -s "${SERIAL}" shell am force-stop "${PACKAGE_NAME}"
  "${ADB_BIN}" -s "${SERIAL}" shell am start -n "${MAIN_ACTIVITY}"
}

app_pid() {
  "${ADB_BIN}" -s "${SERIAL}" shell pidof "${PACKAGE_NAME}" 2>/dev/null | tr -d '\r'
}

stream_logs() {
  select_device
  local pid
  pid="$(app_pid)"
  [[ -n "${pid}" ]] || die "app is not running; restart it first"
  info "streaming logcat for ${PACKAGE_NAME} pid=${pid} on ${SERIAL}"
  exec "${ADB_BIN}" -s "${SERIAL}" logcat --pid="${pid}" -v threadtime
}

tail_logs() {
  select_device
  local pid
  pid="$(app_pid)"
  [[ -n "${pid}" ]] || die "app is not running; restart it first"
  "${ADB_BIN}" -s "${SERIAL}" logcat -d -t "${TAIL_LINES}" --pid="${pid}" -v threadtime
}

device_identity() {
  select_device
  local android_id digest
  android_id="$("${ADB_BIN}" -s "${SERIAL}" shell settings get secure android_id | tr -d '\r\n')"
  [[ -n "${android_id}" && "${android_id}" != "null" ]] || die "ANDROID_ID is unavailable"
  digest="$(printf '%s' "${DEVICE_ID_NAMESPACE}:${android_id}" | shasum -a 256 | awk '{ print $1 }')"
  echo "serial=${SERIAL}"
  echo "android_id=${android_id}"
  echo "device_id=mobile-android-${digest:0:32}"
}

diagnose() {
  echo "project_root=${PROJECT_ROOT}"
  echo "flutter=${FLUTTER_BIN}"
  echo "android_sdk=${ANDROID_SDK_ROOT}"
  echo "adb=${ADB_BIN}"
  echo "java_home=${JAVA_HOME}"
  echo "build_mode=${BUILD_MODE}"
  echo "apk=$(apk_path)"
  echo "apk_exists=$([[ -f "$(apk_path)" ]] && echo true || echo false)"
  if [[ -x "${FLUTTER_BIN}" ]]; then
    "${FLUTTER_BIN}" --version | head -1
  else
    echo "warning: Flutter is not executable" >&2
  fi
  if [[ -x "${JAVA_HOME}/bin/java" ]]; then
    "${JAVA_HOME}/bin/java" -version 2>&1 | head -1
  else
    echo "warning: Java is not available under JAVA_HOME" >&2
  fi
  require_tools
  "${ADB_BIN}" version | head -1
  "${ADB_BIN}" devices -l
  if [[ -n "${SERIAL}" ]] || [[ "$("${ADB_BIN}" devices | awk 'NR > 1 && $2 == "device" { count += 1 } END { print count + 0 }')" == "1" ]]; then
    device_identity
  fi
}

COMMAND="${1:-help}"
[[ $# -gt 0 ]] && shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial) SERIAL="${2:-}"; shift 2 ;;
    --mode) BUILD_MODE="${2:-}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --lines) TAIL_LINES="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "${BUILD_MODE}" in
  debug|profile|release) ;;
  *) die "invalid build mode: ${BUILD_MODE}" ;;
esac

case "${COMMAND}" in
  devices) require_tools; "${ADB_BIN}" devices -l ;;
  diagnose) diagnose ;;
  build) build_apk ;;
  install) install_apk ;;
  reinstall) reinstall_apk ;;
  restart) restart_app ;;
  run)
    [[ "${SKIP_BUILD}" -eq 1 ]] || build_apk
    install_apk
    restart_app
    ;;
  logs) stream_logs ;;
  logs-tail) tail_logs ;;
  clear-logs) select_device; "${ADB_BIN}" -s "${SERIAL}" logcat -c ;;
  identity) device_identity ;;
  help|-h|--help) usage ;;
  *) usage >&2; die "unknown command: ${COMMAND}" ;;
esac
