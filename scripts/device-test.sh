#!/usr/bin/env bash
#
# device-test.sh — install, launch and smoke-test an APK on the running emulator.
#
# This is the acceptance harness: it fails loudly (non-zero) when the app does not
# launch, dies, or crashes, and prints actionable logcat evidence on failure.
#
# Usage:
#   scripts/device-test.sh [options] <path/to/app.apk>
#
# Options:
#   --pkg <name>       Application id to launch          (default: dev.swiftui.android)
#   --activity <name>  Launcher activity, e.g. .MainActivity or com.x/.Main
#                      (default: resolved on-device with `cmd package resolve-activity`)
#   --serial <serial>  adb serial                        (default: first running emulator)
#   --settle <sec>     Seconds to wait after launch      (default: 3)
#   --shot <path>      Screenshot path                   (default: build/screenshots/app-<timestamp>.png)
#   --no-install       Do not reinstall; test the already-installed build
#   --no-clear         Do not clear the logcat buffer before launch
#   --keep-log <path>  Copy the full device logcat to <path> even on success
#   -h, --help         Show this help
#
# Exit codes:
#   0 pass · 2 usage/bad APK · 3 device not ready · 4 install failed ·
#   5 launch failed · 6 process not alive · 7 crash detected · 1 other failure
#
# Environment: ANDROID_HOME (default $ANDROID_HOME)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export ANDROID_HOME="${ANDROID_HOME:?set ANDROID_HOME}"
ADB="${ANDROID_HOME}/platform-tools/adb"

PKG="dev.swiftui.android"
ACTIVITY=""
SERIAL=""
SETTLE=3
SHOT=""
DO_INSTALL=1
CLEAR_LOG=1
KEEP_LOG=""
APK=""

TMP_BASE="${TMPDIR:-/tmp}/swiftui-android"
mkdir -p "${TMP_BASE}"

log()  { printf '[device-test] %s\n' "$*" >&2; }
step() { printf '[device-test] == %s\n' "$*" >&2; }
die()  { local code="$1"; shift; printf '[device-test] FAIL: %s\n' "$*" >&2; exit "${code}"; }

usage() { sed -n 's/^# \{0,1\}//p' "${BASH_SOURCE[0]}" | sed -n '1,36p' | sed '/^$/q'; }

# ----------------------------------------------------------------------------- options
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pkg)       PKG="${2:-}";      shift 2 ;;
    --pkg=*)     PKG="${1#*=}";     shift ;;
    --activity)  ACTIVITY="${2:-}"; shift 2 ;;
    --activity=*) ACTIVITY="${1#*=}"; shift ;;
    --serial)    SERIAL="${2:-}";   shift 2 ;;
    --serial=*)  SERIAL="${1#*=}";  shift ;;
    --settle)    SETTLE="${2:-3}";  shift 2 ;;
    --settle=*)  SETTLE="${1#*=}";  shift ;;
    --shot)      SHOT="${2:-}";     shift 2 ;;
    --shot=*)    SHOT="${1#*=}";    shift ;;
    --keep-log)  KEEP_LOG="${2:-}"; shift 2 ;;
    --keep-log=*) KEEP_LOG="${1#*=}"; shift ;;
    --no-install) DO_INSTALL=0; shift ;;
    --no-clear)   CLEAR_LOG=0;  shift ;;
    -h|--help)   usage; exit 0 ;;
    --)          shift; APK="${1:-}"; shift || true; break ;;
    -*)          usage >&2; die 2 "unknown option: $1" ;;
    *)           APK="$1"; shift ;;
  esac
done

[[ -n "${PKG}" ]] || die 2 "--pkg must not be empty"
[[ "${SETTLE}" =~ ^[0-9]+$ ]] || die 2 "--settle must be an integer number of seconds"

if [[ -z "${APK}" ]]; then
  usage >&2
  die 2 "no APK given"
fi
if [[ ! -f "${APK}" ]]; then
  die 2 "APK not found: ${APK}"
fi
APK="$(cd "$(dirname "${APK}")" && pwd)/$(basename "${APK}")"
[[ -x "${ADB}" ]] || die 3 "adb not found at ${ADB} (is the Android SDK platform-tools installed?)"

STAMP="$(date +%Y%m%d-%H%M%S)"
SHOT_DIR="${REPO_ROOT}/build/screenshots"
mkdir -p "${SHOT_DIR}"
SHOT="${SHOT:-${SHOT_DIR}/app-${STAMP}.png}"
mkdir -p "$(dirname "${SHOT}")"
LOGCAT_FILE="${TMP_BASE}/logcat-${STAMP}.txt"

# ----------------------------------------------------------------------------- device
if [[ -z "${SERIAL}" ]]; then
  SERIAL="$("${ADB}" devices 2>/dev/null |
    awk -F'\t' 'NR > 1 && $1 ~ /^emulator-/ && $2 == "device" { print $1; exit }')"
fi
[[ -n "${SERIAL}" ]] ||
  die 3 "no emulator/device online. Boot one with: scripts/emulator.sh start"

STEP_START=${SECONDS}
step "device ${SERIAL}"
[[ "$("${ADB}" -s "${SERIAL}" get-state 2>/dev/null | tr -d '\r')" == "device" ]] ||
  die 3 "device ${SERIAL} is not online (adb get-state failed)"
BOOT="$("${ADB}" -s "${SERIAL}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')"
[[ "${BOOT}" == "1" ]] || die 3 "device ${SERIAL} is online but not booted (sys.boot_completed=${BOOT:-<empty>}). Run: scripts/emulator.sh wait"

SDK="$("${ADB}" -s "${SERIAL}" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r\n')"
ABI="$("${ADB}" -s "${SERIAL}" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r\n')"
log "android sdk=${SDK} abi=${ABI} apk=$(basename "${APK}") pkg=${PKG}"

# ----------------------------------------------------------------------------- install
INSTALL_OUT=""
if [[ "${DO_INSTALL}" -eq 1 ]]; then
  step "installing ${APK}"
  INSTALL_OUT="$("${ADB}" -s "${SERIAL}" install -r -t "${APK}" 2>&1)"
  printf '%s\n' "${INSTALL_OUT}" >&2
  if ! grep -q '^Success' <<<"${INSTALL_OUT}"; then
    case "${INSTALL_OUT}" in
      *INSTALL_FAILED_UPDATE_INCOMPATIBLE*|*INSTALL_FAILED_VERSION_DOWNGRADE*)
        log "hint: uninstall first: adb -s ${SERIAL} uninstall '${PKG}'" ;;
      *INSTALL_PARSE_FAILED_NO_CERTIFICATES*)
        log "hint: the APK is unsigned or has an invalid signature" ;;
      *INSTALL_FAILED_INSUFFICIENT_STORAGE*)
        log "hint: emulator storage is full: scripts/emulator.sh create-avd --force" ;;
      *device\ offline*|*closed*)
        log "hint: adb connection dropped; retry with: adb kill-server && adb start-server" ;;
    esac
    die 4 "adb install failed"
  fi
else
  log "skipping install (--no-install)"
fi

# ----------------------------------------------------------------------------- resolve activity
if [[ -z "${ACTIVITY}" ]]; then
  RESOLVED="$("${ADB}" -s "${SERIAL}" shell cmd package resolve-activity --brief "${PKG}" 2>/dev/null |
    tr -d '\r' | awk 'NF { last = $0 } END { print last }')"
  [[ -n "${RESOLVED}" && "${RESOLVED}" == */* ]] ||
    die 5 "could not resolve a launcher activity for '${PKG}'.
       Is that the right package id? Check with:
         adb -s ${SERIAL} shell pm list packages | grep -i swiftui
       Or pass --activity <activity>, e.g. --activity .MainActivity"
  COMPONENT="${RESOLVED}"
else
  case "${ACTIVITY}" in
    */*)        COMPONENT="${ACTIVITY}" ;;
    .*)         COMPONENT="${PKG}/${ACTIVITY}" ;;
    "${PKG}".*) COMPONENT="${PKG}/.${ACTIVITY#"${PKG}".}" ;;
    *)          COMPONENT="${PKG}/${ACTIVITY}" ;;
  esac
fi
log "component: ${COMPONENT}"

# ----------------------------------------------------------------------------- (re)start cleanly
step "force-stopping ${PKG}"
"${ADB}" -s "${SERIAL}" shell am force-stop "${PKG}" >/dev/null 2>&1 || true
sleep 0.5

if [[ "${CLEAR_LOG}" -eq 1 ]]; then
  "${ADB}" -s "${SERIAL}" logcat -c >/dev/null 2>&1 || log "warning: could not clear logcat buffer"
fi

step "launching ${COMPONENT}"
AM_OUT="$("${ADB}" -s "${SERIAL}" shell am start -W -n "${COMPONENT}" 2>&1)"
printf '%s\n' "${AM_OUT}" >&2
AM_STATUS="$(sed -n 's/^Status: *//p' <<<"${AM_OUT}" | tr -d '\r' | head -1)"
AM_TOTAL="$(sed -n 's/^TotalTime: *//p' <<<"${AM_OUT}" | tr -d '\r' | head -1)"
if [[ "${AM_STATUS}" != "ok" ]] || grep -qE '^Error' <<<"${AM_OUT}"; then
  dump_logcat "${LOGCAT_FILE}"
  print_logcat_excerpt "${LOGCAT_FILE}" "${COMPONENT}"
  die 5 "am start failed (Status: ${AM_STATUS:-<none>}). Is ${COMPONENT} exported/launchable?"
fi

step "settling ${SETTLE}s"
sleep "${SETTLE}"

# ----------------------------------------------------------------------------- screenshot
step "screenshot -> ${SHOT}"
if "${ADB}" -s "${SERIAL}" exec-out screencap -p > "${SHOT}" 2>/dev/null && [[ -s "${SHOT}" ]]; then
  MAGIC="$(head -c 8 "${SHOT}" | od -An -tx1 | tr -d ' \n')"
  if [[ "${MAGIC}" != "89504e470d0a1a0a" ]]; then
    log "warning: screenshot is not a PNG (magic=${MAGIC}); removing"
    rm -f "${SHOT}"
    SHOT=""
  fi
else
  log "warning: screencap failed"
  SHOT=""
fi

# ----------------------------------------------------------------------------- process / crash checks
dump_logcat() {
  local dest="$1"
  if ! "${ADB}" -s "${SERIAL}" logcat -d -b all -v threadtime > "${dest}" 2>/dev/null; then
    "${ADB}" -s "${SERIAL}" logcat -d -v threadtime > "${dest}" 2>/dev/null || : > "${dest}"
  fi
}

# Strict, unambiguous crash signatures (AndroidRuntime FATAL, native debuggerd signals).
STRICT_RE='FATAL EXCEPTION|E/AndroidRuntime|F/AndroidRuntime|Fatal signal [0-9]+|SIGSEGV|SIGABRT|SIGBUS|SIGILL|SIGFPE|am_crash|E/DEBUG|F/DEBUG'
# Context worth showing next to a failure (and ANR / death events).
CONTEXT_RE="$(printf '%s' "${PKG}" | sed 's/[.[\*^$()+?{}|]/\\&/g')|ANR in |has died|Force finishing|Process: |Force stopping"

# Build a filtered evidence file: crash lines, package lines, death/ANR lines.
filter_evidence() {
  local src="$1" dest="$2"
  {
    grep -Ei -- "${STRICT_RE}" "${src}" || true
    grep -Ei -- "${CONTEXT_RE}" "${src}" || true
  } | awk '!seen[$0]++' > "${dest}"
}

print_logcat_excerpt() {
  local src="$1" component="$2" ev="${TMP_BASE}/evidence-${STAMP}.txt"
  filter_evidence "${src}" "${ev}"
  printf '\n--- last 100 lines of filtered logcat (crashes / %s) ---\n' "${PKG}" >&2
  if [[ -s "${ev}" ]]; then
    tail -100 "${ev}" >&2
  else
    printf '(no crash/package lines matched; showing last 100 raw logcat lines)\n' >&2
    tail -100 "${src}" >&2
  fi
  printf -- '--- end logcat excerpt ---\n' >&2
  printf 'full device logcat: %s\n' "${src}" >&2
  printf 'filtered evidence:  %s\n' "${ev}" >&2
}

dump_logcat "${LOGCAT_FILE}"

PID="$("${ADB}" -s "${SERIAL}" shell pidof "${PKG}" 2>/dev/null | tr -d '\r\n' | awk '{print $1}')"
PROC_STATE="$("${ADB}" -s "${SERIAL}" shell dumpsys activity processes 2>/dev/null |
  grep -Ei "ProcessRecord.*${PKG}|pid=[0-9]+.*${PKG}" | head -3 | tr -d '\r')"
EVIDENCE="${TMP_BASE}/evidence-${STAMP}.txt"
filter_evidence "${LOGCAT_FILE}" "${EVIDENCE}"

CRASH_HIT=0
if [[ -s "${EVIDENCE}" ]] && grep -Eq -- "${STRICT_RE}" "${EVIDENCE}"; then
  CRASH_HIT=1
fi
ANR_HIT=0
if grep -Eq "ANR in ${PKG}|am_anr.*${PKG}" "${LOGCAT_FILE}" 2>/dev/null; then
  ANR_HIT=1
fi

# ----------------------------------------------------------------------------- verdict
if [[ "${CRASH_HIT}" -eq 1 || "${ANR_HIT}" -eq 1 ]]; then
  [[ -n "${SHOT}" ]] && log "screenshot (pre-crash screen): ${SHOT}"
  print_logcat_excerpt "${LOGCAT_FILE}" "${COMPONENT}"
  if grep -q 'Fatal signal' "${LOGCAT_FILE}" 2>/dev/null; then
    log "native crash detected; tombstones on device:"
    "${ADB}" -s "${SERIAL}" shell ls -lt /data/tombstones 2>/dev/null | head -5 >&2 || true
    log "pull one with: adb -s ${SERIAL} shell cat /data/tombstones/tombstone_00"
  fi
  if [[ "${ANR_HIT}" -eq 1 ]]; then
    die 7 "ANR detected for ${PKG}"
  fi
  die 7 "crash detected for ${PKG}"
fi

if [[ -z "${PID}" ]]; then
  log "process state: ${PROC_STATE:-<not found in dumpsys>}"
  [[ -n "${SHOT}" ]] && log "last screenshot: ${SHOT}"
  print_logcat_excerpt "${LOGCAT_FILE}" "${COMPONENT}"
  die 6 "process '${PKG}' is not running ${SETTLE}s after launch (no pid found). The app was killed or exited."
fi

# Surface soft errors that are useful even when the harness passes.
WARN_LINES="$(grep -Ei -- ' E/| E [A-Za-z]+ *:|FATAL|Exception' "${LOGCAT_FILE}" 2>/dev/null |
  grep -F "${PKG}" | head -20 || true)"
if [[ -n "${WARN_LINES}" ]]; then
  printf '\n--- warnings mentioning %s (not fatal) ---\n' "${PKG}" >&2
  printf '%s\n' "${WARN_LINES}" >&2
fi

if [[ -n "${KEEP_LOG}" ]]; then
  mkdir -p "$(dirname "${KEEP_LOG}")"
  cp "${LOGCAT_FILE}" "${KEEP_LOG}"
  log "full logcat copied to ${KEEP_LOG}"
fi

ELAPSED=$((SECONDS - STEP_START))
printf '\n[device-test] PASS\n' >&2
printf '  package:    %s\n' "${PKG}" >&2
printf '  component:  %s\n' "${COMPONENT}" >&2
printf '  pid:        %s\n' "${PID}" >&2
printf '  launch:     TotalTime=%sms (am start Status: ok)\n' "${AM_TOTAL:-?}" >&2
printf '  screenshot: %s\n' "${SHOT:-<none>}" >&2
printf '  logcat:     %s (no crashes)\n' "${LOGCAT_FILE}" >&2
printf '  duration:   %ss\n' "${ELAPSED}" >&2
printf '  serial:     %s\n' "${SERIAL}" >&2
exit 0
