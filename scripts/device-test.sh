#!/usr/bin/env bash
#
# device-test.sh — install, launch and smoke-test an APK on the running emulator.
#
# This is the acceptance harness: it exits non-zero when the APK fails to install,
# fails to launch, is not alive after launch, crashes (Java or native), or ANRs,
# and prints the last 100 lines of filtered logcat as evidence.
#
# Usage:
#   scripts/device-test.sh [options] <path/to/app.apk>
#
# Options:
#   --pkg <name>        Application id to launch        (default: dev.swiftui.android)
#   --activity <name>   Launcher activity, e.g. .MainActivity or com.x/.Main
#                       (default: resolved on-device with `cmd package resolve-activity`)
#   --serial <serial>   adb serial                      (default: first running emulator)
#   --settle <sec>      Seconds to wait after launch    (default: 3)
#   --shot <path>       Screenshot path                 (default: build/screenshots/app-<ts>.png)
#   --no-install        Test the already-installed build (skip adb install)
#   --no-clear          Do not clear the logcat buffer before launch
#   --keep-log <path>   Also copy full logcat to <path> on success
#   -h, --help          Show this help
#
# Exit codes:
#   0 pass · 2 usage/bad APK · 3 device not ready · 4 install failed ·
#   5 launch failed · 6 process not alive · 7 crash/ANR detected · 1 screenshot failed
#
# Environment: ANDROID_HOME (default $ANDROID_HOME)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export ANDROID_HOME="${ANDROID_HOME:?set ANDROID_HOME}"
ADB="${ANDROID_HOME}/platform-tools/adb"

TMP_BASE="${TMPDIR:-/tmp}/swiftui-android"
mkdir -p "${TMP_BASE}" >/dev/null 2>&1 || true

PKG="dev.swiftui.android"
ACTIVITY=""
SERIAL=""
SETTLE=3
SHOT=""
DO_INSTALL=1
CLEAR_LOG=1
KEEP_LOG=""
APK=""

# ----------------------------------------------------------------------------- messages
log() { printf '[device-test] %s\n' "$*" >&2; }
step() { printf '[device-test] == %s\n' "$*" >&2; }
die() {
  local code="$1"
  shift
  printf '[device-test] FAIL: %s\n' "$*" >&2
  exit "$code"
}

usage() { sed -n '3,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed '$d'; }

# ----------------------------------------------------------------------------- options
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pkg)        PKG="${2:-}";      shift 2 ;;
    --pkg=*)      PKG="${1#*=}";     shift ;;
    --activity)   ACTIVITY="${2:-}"; shift 2 ;;
    --activity=*) ACTIVITY="${1#*=}"; shift ;;
    --serial)     SERIAL="${2:-}";   shift 2 ;;
    --serial=*)   SERIAL="${1#*=}";  shift ;;
    --settle)     SETTLE="${2:-3}";  shift 2 ;;
    --settle=*)   SETTLE="${1#*=}";  shift ;;
    --shot)       SHOT="${2:-}";     shift 2 ;;
    --shot=*)     SHOT="${1#*=}";    shift ;;
    --keep-log)   KEEP_LOG="${2:-}"; shift 2 ;;
    --keep-log=*) KEEP_LOG="${1#*=}"; shift ;;
    --no-install) DO_INSTALL=0; shift ;;
    --no-clear)   CLEAR_LOG=0;  shift ;;
    -h|--help)    usage; exit 0 ;;
    --)           shift; APK="${1:-}"; shift || true; break ;;
    -*)           usage >&2; die 2 "unknown option: $1" ;;
    *)            APK="$1"; shift ;;
  esac
done

[[ -n "$PKG" ]] || die 2 "--pkg must not be empty"
[[ "$SETTLE" =~ ^[0-9]+$ ]] || die 2 "--settle must be a whole number of seconds"
if [[ -z "$APK" ]]; then
  # An APK path is only required when something is going to be installed.
  [[ "$DO_INSTALL" -eq 0 ]] || { usage >&2; die 2 "no APK given"; }
else
  [[ -f "$APK" ]] || die 2 "APK not found: $APK"
  APK="$(cd "$(dirname "$APK")" && pwd)/$(basename "$APK")"
fi
[[ -x "$ADB" ]] || die 3 "adb not found at ${ADB} (install Android SDK platform-tools)"

STAMP="$(date +%Y%m%d-%H%M%S)"
SHOT_DIR="${REPO_ROOT}/build/screenshots"
mkdir -p "$SHOT_DIR"
SHOT="${SHOT:-${SHOT_DIR}/app-${STAMP}.png}"
mkdir -p "$(dirname "$SHOT")"
LOGCAT_FILE="${TMP_BASE}/logcat-${STAMP}.txt"
EVIDENCE_FILE="${TMP_BASE}/evidence-${STAMP}.txt"

# ----------------------------------------------------------------------------- logcat helpers
dump_logcat() {
  if ! "$ADB" -s "$SERIAL" logcat -d -b all -v threadtime > "$LOGCAT_FILE" 2>/dev/null; then
    "$ADB" -s "$SERIAL" logcat -d -v threadtime > "$LOGCAT_FILE" 2>/dev/null || : > "$LOGCAT_FILE"
  fi
}

# Unambiguous crash signatures. Matches both -v threadtime ("E AndroidRuntime:") and
# -v brief ("E/AndroidRuntime(...)").
CRASH_RE='FATAL EXCEPTION|Fatal signal [0-9]+|[EF] ?/?(AndroidRuntime|DEBUG):|SIGSEGV|SIGABRT|SIGBUS|SIGILL|SIGFPE|am_crash'
PKG_RE="$(printf '%s' "$PKG" | sed 's/[.[\*^$()+?{}|]/\\&/g')"

build_evidence() {
  {
    grep -E -- "$CRASH_RE" "$LOGCAT_FILE" 2>/dev/null || true
    # package lines at warning/error/fatal priority only (keeps the excerpt readable)
    grep -E -- "^[0-9-]+ [0-9:.]+ +[0-9]+ +[0-9]+ [EWF] " "$LOGCAT_FILE" 2>/dev/null |
      grep -E -- "$PKG_RE" || true
    grep -E -- "Process: .*${PKG_RE}|Process ${PKG_RE}.*has died|ANR in .*${PKG_RE}|Force finishing .*${PKG_RE}|Force stopping .*${PKG_RE}|am_anr.*${PKG_RE}|am_crash: \[.*,${PKG_RE},|am_proc_died.*${PKG_RE}" "$LOGCAT_FILE" 2>/dev/null || true
  } | grep -vE 'TransactionExecutor|SQLiteLog' | awk '!seen[$0]++' > "$EVIDENCE_FILE" || true
}

print_failure_evidence() {
  build_evidence
  printf '\n--- last 100 lines of filtered logcat (crashes/ANR/%s) ---\n' "$PKG" >&2
  if [[ -s "$EVIDENCE_FILE" ]]; then
    tail -100 "$EVIDENCE_FILE" >&2
  else
    printf '(nothing matched; last 100 raw logcat lines follow)\n' >&2
    tail -100 "$LOGCAT_FILE" >&2
  fi
  printf -- '--- end logcat excerpt ---\n' >&2
  printf 'full logcat:     %s\n' "$LOGCAT_FILE" >&2
  printf 'filtered lines:  %s\n' "$EVIDENCE_FILE" >&2
  if [[ -n "${SHOT:-}" && -s "${SHOT:-/nonexistent}" ]]; then
    printf 'screenshot:      %s\n' "$SHOT" >&2
  fi
}

# ----------------------------------------------------------------------------- device
STEP_START=$SECONDS

if [[ -z "$SERIAL" ]]; then
  SERIAL="$("$ADB" devices 2>/dev/null | awk -F'\t' 'NR > 1 && $1 ~ /^emulator-/ && $2 == "device" { print $1; exit }')"
fi
[[ -n "$SERIAL" ]] || die 3 "no device online. Boot the emulator first: scripts/emulator.sh start"

step "device ${SERIAL}"
[[ "$("$ADB" -s "$SERIAL" get-state 2>/dev/null | tr -d '\r')" == "device" ]] ||
  die 3 "device ${SERIAL} is not online (adb get-state failed)"
BOOT="$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')"
[[ "$BOOT" == "1" ]] || die 3 "device ${SERIAL} is not booted yet (sys.boot_completed=${BOOT:-<empty>}); run: scripts/emulator.sh wait"

# A freshly booted headless device can have the keyguard up, which yields black screenshots.
"$ADB" -s "$SERIAL" shell input keyevent 224 >/dev/null 2>&1 || true   # KEYCODE_WAKEUP
"$ADB" -s "$SERIAL" shell wm dismiss-keyguard >/dev/null 2>&1 || true

SDK="$("$ADB" -s "$SERIAL" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r\n')"
ABI="$("$ADB" -s "$SERIAL" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r\n')"
log "android sdk=${SDK} abi=${ABI} apk=$(basename "${APK:-<already-installed>}") pkg=${PKG}"

# ----------------------------------------------------------------------------- install
INSTALL_OUT=""
if [[ "$DO_INSTALL" -eq 1 ]]; then
  step "installing $(basename "$APK")"
  INSTALL_OUT="$("$ADB" -s "$SERIAL" install --no-incremental -r -t "$APK" 2>&1)"
  printf '%s\n' "$INSTALL_OUT" >&2
  if ! grep -q '^Success' <<<"$INSTALL_OUT"; then
    case "$INSTALL_OUT" in
      *INSTALL_FAILED_UPDATE_INCOMPATIBLE*|*INSTALL_FAILED_VERSION_DOWNGRADE*)
        log "hint: uninstall first: adb -s ${SERIAL} uninstall ${PKG} && retry" ;;
      *INSTALL_PARSE_FAILED_NO_CERTIFICATES*) log "hint: APK is unsigned / has an invalid signature" ;;
      *INSTALL_PARSE_FAILED_MANIFEST_MALFORMED*) log "hint: AndroidManifest.xml is malformed" ;;
      *INSTALL_FAILED_INSUFFICIENT_STORAGE*)  log "hint: emulator storage full; recreate the AVD" ;;
      *INSTALL_FAILED_NO_MATCHING_ABIS*)      log "hint: APK has no arm64-v8a native code, but the emulator is arm64-v8a" ;;
      *device\ offline*|*device\ not\ found*|*closed*)
        log "hint: adb connection dropped; retry with: adb kill-server && adb start-server" ;;
    esac
    die 4 "adb install failed"
  fi
else
  log "skipping install (--no-install)"
fi

# ----------------------------------------------------------------------------- component
if [[ -z "$ACTIVITY" ]]; then
  RESOLVED="$("$ADB" -s "$SERIAL" shell cmd package resolve-activity --brief "$PKG" 2>/dev/null |
    tr -d '\r' | awk 'NF { last = $0 } END { print last }')"
  if [[ -z "$RESOLVED" || "$RESOLVED" != */* ]]; then
    log "no launcher activity for '${PKG}'. Installed packages matching 'swiftui':"
    "$ADB" -s "$SERIAL" shell pm list packages 2>/dev/null | tr -d '\r' | grep -i swiftui >&2 || true
    die 5 "could not resolve a launcher activity for '${PKG}'. Pass --pkg/--activity explicitly (e.g. --activity .MainActivity)"
  fi
  COMPONENT="$RESOLVED"
else
  case "$ACTIVITY" in
    */*)          COMPONENT="$ACTIVITY" ;;
    .*)           COMPONENT="${PKG}/${ACTIVITY}" ;;
    "${PKG}".*)   COMPONENT="${PKG}/.${ACTIVITY#"${PKG}".}" ;;
    *)            COMPONENT="${PKG}/${ACTIVITY}" ;;
  esac
fi
log "component: ${COMPONENT}"

# ----------------------------------------------------------------------------- (re)launch
step "force-stopping ${PKG}"
"$ADB" -s "$SERIAL" shell am force-stop "$PKG" >/dev/null 2>&1 || true
# ActivityManager tears the process down asynchronously; starting immediately can race
# with that teardown and kill the fresh process (looks like "app not running").
sleep 0.5

if [[ "$CLEAR_LOG" -eq 1 ]]; then
  # Clear every buffer (main/system/crash/events) so stale crash events from earlier
  # runs cannot produce a false failure.
  "$ADB" -s "$SERIAL" logcat -b all -c >/dev/null 2>&1 ||
    "$ADB" -s "$SERIAL" logcat -c >/dev/null 2>&1 ||
    log "warning: could not clear logcat buffers"
fi

step "launching ${COMPONENT}"
AM_OUT="$("$ADB" -s "$SERIAL" shell am start -W -n "$COMPONENT" 2>&1)"
printf '%s\n' "$AM_OUT" >&2
AM_STATUS="$(sed -n 's/^Status: *//p' <<<"$AM_OUT" | tr -d '\r' | head -1)"
AM_TOTAL="$(sed -n 's/^TotalTime: *//p' <<<"$AM_OUT" | tr -d '\r' | head -1)"
if [[ "$AM_STATUS" != "ok" ]] || grep -qE '^Error' <<<"$AM_OUT"; then
  dump_logcat
  print_failure_evidence
  die 5 "am start failed (Status: ${AM_STATUS:-<none>}); is ${COMPONENT} exported and launchable?"
fi

step "settling ${SETTLE}s"
sleep "$SETTLE"

# ----------------------------------------------------------------------------- screenshot
SCREENSHOT_FAILED=0
step "screenshot -> ${SHOT}"
if ! "$ADB" -s "$SERIAL" exec-out screencap -p > "$SHOT" 2>/dev/null; then
  SCREENSHOT_FAILED=1
  rm -f "$SHOT"
elif [[ ! -s "$SHOT" ]]; then
  SCREENSHOT_FAILED=1
  rm -f "$SHOT"
else
  MAGIC="$(head -c 8 "$SHOT" | od -An -tx1 | tr -d ' \n')"
  if [[ "$MAGIC" != "89504e470d0a1a0a" ]]; then
    SCREENSHOT_FAILED=1
    log "warning: screencap produced a non-PNG (magic=${MAGIC})"
    rm -f "$SHOT"
  fi
fi

# ----------------------------------------------------------------------------- checks
dump_logcat
build_evidence

PID="$("$ADB" -s "$SERIAL" shell pidof "$PKG" 2>/dev/null | tr -d '\r\n' | awk '{print $1}')"
FOCUS="$("$ADB" -s "$SERIAL" shell dumpsys window 2>/dev/null | tr -d '\r' |
  sed -n 's/.*mCurrentFocus=\(Window{[^}]*}\).*/\1/p' | head -1)"

CRASH_HIT=0
CRASH_REASON=""
if grep -q 'FATAL EXCEPTION' "$LOGCAT_FILE" 2>/dev/null; then
  if grep -Eq -- "Process: .*${PKG_RE}" "$LOGCAT_FILE" 2>/dev/null ||
     grep -Eq -- "am_crash: \[[0-9]+,0,${PKG_RE}," "$LOGCAT_FILE" 2>/dev/null; then
    CRASH_HIT=1
    CRASH_REASON="java crash (FATAL EXCEPTION)"
  else
    log "note: FATAL EXCEPTION seen for a different process, ignoring it"
  fi
fi
if [[ "$CRASH_HIT" -eq 0 ]] && grep -q 'Fatal signal' "$LOGCAT_FILE" 2>/dev/null; then
  if grep -Eq -- ">>> ${PKG_RE}" "$LOGCAT_FILE" 2>/dev/null; then
    CRASH_HIT=1
    CRASH_REASON="native crash ($(grep -m1 -o 'Fatal signal [0-9]\+ ([A-Z]*)' "$LOGCAT_FILE" | head -1))"
  else
    log "note: native crash signal seen for a different process, ignoring it"
  fi
fi
if [[ "$CRASH_HIT" -eq 0 ]] && grep -Eq -- "am_crash: \[[0-9]+,0,${PKG_RE}," "$LOGCAT_FILE" 2>/dev/null; then
  CRASH_HIT=1
  CRASH_REASON="crash recorded in the events buffer"
fi
ANR_HIT=0
grep -Eq "(ANR in ${PKG_RE})|(am_anr.*${PKG_RE})" "$LOGCAT_FILE" 2>/dev/null && ANR_HIT=1

if [[ "$CRASH_HIT" -eq 1 || "$ANR_HIT" -eq 1 ]]; then
  if grep -q 'Fatal signal' "$LOGCAT_FILE" 2>/dev/null; then
    log "native crash (SIGSEGV/SIGABRT); recent tombstones:"
    "$ADB" -s "$SERIAL" shell ls -lt /data/tombstones 2>/dev/null | head -4 >&2 || true
    log "read one with: adb -s ${SERIAL} shell cat /data/tombstones/tombstone_00"
  fi
  print_failure_evidence
  if [[ "$ANR_HIT" -eq 1 ]]; then
    die 7 "ANR detected for ${PKG}"
  fi
  die 7 "crash detected for ${PKG}: ${CRASH_REASON}"
fi

if [[ -z "$PID" ]]; then
  log "dumpsys process record:"
  "$ADB" -s "$SERIAL" shell dumpsys activity processes 2>/dev/null |
    grep -Ei "${PKG_RE}" | head -3 >&2 || true
  print_failure_evidence
  die 6 "process '${PKG}' is not running ${SETTLE}s after launch (no pid); it exited or was killed"
fi

if [[ -n "$FOCUS" && "$FOCUS" != *"${PKG}"* ]]; then
  log "warning: focused window is not ${PKG}: ${FOCUS}"
fi

if [[ "$SCREENSHOT_FAILED" -eq 1 ]]; then
  log "hint: run 'adb -s ${SERIAL} exec-out screencap -p > /tmp/x.png' manually; if the device screen is off, wake it with: adb -s ${SERIAL} shell input keyevent 224"
  die 1 "screencap failed (app itself looks alive: pid ${PID})"
fi

# Soft errors worth surfacing even on a pass.
WARN_LINES="$(grep -E ' [EF]/?[A-Za-z0-9_.]+:' "$LOGCAT_FILE" 2>/dev/null | grep -F "$PKG" | head -20 || true)"
if [[ -n "$WARN_LINES" ]]; then
  printf '\n--- error/warning logcat lines mentioning %s (non-fatal) ---\n' "$PKG" >&2
  printf '%s\n' "$WARN_LINES" >&2
fi

if [[ -n "$KEEP_LOG" ]]; then
  mkdir -p "$(dirname "$KEEP_LOG")"
  cp "$LOGCAT_FILE" "$KEEP_LOG"
  log "full logcat copied to ${KEEP_LOG}"
fi

ELAPSED=$((SECONDS - STEP_START))
printf '\n[device-test] PASS\n' >&2
printf '  package:    %s\n' "$PKG" >&2
printf '  component:  %s\n' "$COMPONENT" >&2
printf '  pid:        %s\n' "$PID" >&2
printf '  launch:     TotalTime=%sms (am start Status: ok)\n' "${AM_TOTAL:-?}" >&2
printf '  focus:      %s\n' "${FOCUS:-<none>}" >&2
printf '  screenshot: %s\n' "$SHOT" >&2
printf '  logcat:     %s (no crashes)\n' "$LOGCAT_FILE" >&2
printf '  duration:   %ss\n' "$ELAPSED" >&2
printf '  serial:     %s\n' "$SERIAL" >&2
exit 0
