#!/usr/bin/env bash
#
# emulator.sh — drive the `swiftui_test` Android emulator headlessly (arm64, API 35).
#
# Usage:
#   scripts/emulator.sh start              Boot the AVD headless (idempotent: never a 2nd instance)
#                                          and wait for sys.boot_completed=1. Prints the device serial.
#   scripts/emulator.sh wait               Wait for the already-running emulator to finish booting.
#   scripts/emulator.sh stop               Shut the emulator down (adb emu kill, pid fallback).
#   scripts/emulator.sh status             Print serial/state/sdk/abi/wm size/density. Exit 1 if down.
#   scripts/emulator.sh screenshot [path]  adb exec-out screencap -p -> path
#                                          (default: build/screenshots/emu-<timestamp>.png)
#   scripts/emulator.sh logcat [regex]     Stream logcat, optionally filtered by a case-insensitive
#                                          extended regex. Extra args are passed to `adb logcat` when
#                                          the first arg starts with '-'.
#   scripts/emulator.sh create-avd [--force]
#                                          (Re)create the AVD from the installed arm64 image.
#
# Environment overrides:
#   ANDROID_HOME     default $ANDROID_HOME
#   AVD_NAME         default swiftui_test
#   EMULATOR_PORT    default 5554 (serial = emulator-5554)
#   BOOT_TIMEOUT     default 420 s per boot attempt
#   EMULATOR_GPU     default "host"; start() auto-retries with swiftshader_indirect if host fails
#
# Exit codes: 0 ok, 1 failure, 2 usage, 3 device not bootable/not running.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

export ANDROID_HOME="${ANDROID_HOME:?set ANDROID_HOME}"
ADB="${ANDROID_HOME}/platform-tools/adb"
EMULATOR="${ANDROID_HOME}/emulator/emulator"
AVDMANAGER="${ANDROID_HOME}/cmdline-tools/latest/bin/avdmanager"
SDKMANAGER="${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager"

AVD_NAME="${AVD_NAME:-swiftui_test}"
EMULATOR_PORT="${EMULATOR_PORT:-5554}"
SERIAL="${SERIAL:-emulator-${EMULATOR_PORT}}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-420}"
SHOT_DIR="${SHOT_DIR:-${REPO_ROOT}/build/screenshots}"

TMP_BASE="${TMPDIR:-/tmp}/swiftui-android"
mkdir -p "${TMP_BASE}"
EMULATOR_LOG="${EMULATOR_LOG:-${TMP_BASE}/emulator-${AVD_NAME}.log}"
EMULATOR_PIDFILE="${EMULATOR_PIDFILE:-${TMP_BASE}/emulator-${AVD_NAME}.pid}"

# ----------------------------------------------------------------------------- helpers
log()  { printf '[emulator] %s\n' "$*" >&2; }
die()  { printf '[emulator] ERROR: %s\n' "$*" >&2; exit "${2:-1}"; }
need() { [[ -x "$1" ]] || die "missing executable: $1 (is the Android SDK installed?)"; }

# Human readable elapsed seconds.
fmt_elapsed() { local s=$1; printf '%dm%02ds' $((s / 60)) $((s % 60)); }

# Serial of a running/offline emulator, if any (first one).
first_running_serial() {
  "${ADB}" devices 2>/dev/null |
    awk -F'\t' 'NR > 1 && $1 ~ /^emulator-/ && ($2 == "device" || $2 == "offline" || $2 == "booting") { print $1; exit }'
}

# All emulator serials known to adb.
all_running_serials() {
  "${ADB}" devices 2>/dev/null |
    awk -F'\t' 'NR > 1 && $1 ~ /^emulator-/ && ($2 == "device" || $2 == "offline" || $2 == "booting") { print $1 }'
}

emulator_state() { "${ADB}" -s "$1" get-state 2>/dev/null | tr -d '\r' || true; }

boot_completed() {
  local s="$1" v
  v="$("${ADB}" -s "$s" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n' || true)"
  [[ "$v" == "1" ]]
}

# True while the emulator process we launched is still alive (if we launched one).
our_emulator_alive() {
  local pid
  [[ -f "${EMULATOR_PIDFILE}" ]] || return 1
  pid="$(cat "${EMULATOR_PIDFILE}" 2>/dev/null || true)"
  [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

tail_emulator_log() {
  if [[ -s "${EMULATOR_LOG}" ]]; then
    printf '\n--- last 40 lines of %s ---\n' "${EMULATOR_LOG}" >&2
    tail -40 "${EMULATOR_LOG}" >&2
  fi
}

# ----------------------------------------------------------------------------- AVD creation
# avdmanager/sdkmanager need JDK 17+; this machine's default java is 11.
ensure_java() {
  local candidate="${JAVA_HOME:-}"
  local version=""
  if [[ -n "${candidate}" && -x "${candidate}/bin/java" ]]; then
    version="$("${candidate}/bin/java" -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -1)"
  fi
  if [[ "${version}" =~ ^[0-9]+$ ]] && (( version >= 17 )); then
    return 0
  fi
  local jdk21="/opt/homebrew/opt/openjdk@21"
  if [[ -x "${jdk21}/bin/java" ]]; then
    export JAVA_HOME="${jdk21}"
    export PATH="${jdk21}/bin:${PATH}"
    log "using ${JAVA_HOME} for avdmanager (default java is ${version:-missing})"
    return 0
  fi
  log "warning: avdmanager may fail without JDK 17+ (JAVA_HOME=${JAVA_HOME:-<unset>})"
}

installed_system_image() {
  # Prefer the google_apis arm64 image, otherwise the plain default arm64 one.
  local candidate
  for candidate in \
    "system-images;android-35;google_apis;arm64-v8a" \
    "system-images;android-35;default;arm64-v8a" \
    "system-images;android-34;default;arm64-v8a" \
    "system-images;android-36;default;arm64-v8a"; do
    local rel="${candidate//;//}"
    if [[ -d "${ANDROID_HOME}/system-images/${rel}" ]] || [[ -f "${ANDROID_HOME}/system-images/${rel}/system.img" ]]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

set_ini() { # set_ini <file> <key> <value>
  local file="$1" key="$2" value="$3"
  local tmp="${file}.tmp.$$"
  awk -v k="${key}" -v v="${value}" '
    BEGIN { done = 0 }
    $0 ~ "^" k "=" { if (!done) { print k "=" v; done = 1 }; next }
    { print }
    END { if (!done) print k "=" v }
  ' "${file}" > "${tmp}"
  mv "${tmp}" "${file}"
}

cmd_create_avd() {
  echo "DEBUG-in-cmd AVDMANAGER=[${AVDMANAGER:-UNSET}]" >&2
  ensure_java
  echo "DEBUG-after-java AVDMANAGER=[${AVDMANAGER:-UNSET}]" >&2
  declare -p AVDMANAGER 2>&1 || true
  local force="${1:-}"
  declare -p AVDMANAGER 2>&1 || true
  echo "DEBUG AVDMANAGER=[${ADVMANAGER:-UNSET}]" >&2
  need "${ADVMANAGER}"

  local image
  image="$(installed_system_image)" || die "no arm64 system image installed under ${ANDROID_HOME}/system-images.
Install one with:
  yes | ${SDKMANAGER} --sdk_root=${ANDROID_HOME} --install 'platform-tools' 'emulator' 'system-images;android-35;default;arm64-v8a'" 1

  log "system image: ${image}"

  if [[ -f "${HOME}/.android/avd/${AVD_NAME}.ini" ]]; then
    if [[ "${force}" == "--force" ]]; then
      log "recreating AVD ${AVD_NAME} (--force)"
      rm -rf "${HOME}/.android/avd/${AVD_NAME}.avd" "${HOME}/.android/avd/${AVD_NAME}.ini"
    else
      log "AVD ${AVD_NAME} already exists (pass --force to recreate)"
      printf '%s\n' "${HOME}/.android/avd/${AVD_NAME}.avd"
      return 0
    fi
  fi

  local device_profile="medium_phone"
  local create_out
  if ! create_out="$(echo no | "${AVDMANAGER}" create avd -n "${AVD_NAME}" -k "${image}" \
        -d "${device_profile}" --force 2>&1)"; then
    log "create with profile '${device_profile}' failed, retrying without -d"
    printf '%s\n' "${create_out}" >&2
    create_out="$(echo no | "${AVDMANAGER}" create avd -n "${AVD_NAME}" -k "${image}" --force 2>&1)" ||
      die "avdmanager create avd failed:
${create_out}"
  fi

  local cfg="${HOME}/.android/avd/${AVD_NAME}.avd/config.ini"
  [[ -f "${cfg}" ]] || die "AVD created but config.ini not found at ${cfg}"

  # Phone-like 6.4" panel, 1080x2340 @ 420dpi, no snapshots, 4 GB RAM, software GL safe default.
  set_ini "${cfg}" hw.lcd.width 1080
  set_ini "${cfg}" hw.lcd.height 2340
  set_ini "${cfg}" hw.lcd.density 420
  set_ini "${cfg}" hw.ramSize 4096
  set_ini "${cfg}" vm.heapSize 512
  set_ini "${cfg}" hw.keyboard yes
  set_ini "${cfg}" hw.mainKeys no
  set_ini "${cfg}" hw.gpu.enabled yes
  set_ini "${cfg}" hw.gpu.mode host
  set_ini "${cfg}" hw.audioInput no
  set_ini "${cfg}" hw.audioOutput no
  set_ini "${cfg}" disk.dataPartition.size 6442450944
  set_ini "${cfg}" showDeviceFrame no
  set_ini "${cfg}" fastboot.forceColdBoot yes
  set_ini "${cfg}" fastboot.forceFastBoot no

  log "AVD ${AVD_NAME} created: ${cfg}"
  printf '%s\n' "${cfg}"
}

# ----------------------------------------------------------------------------- boot
# Launch a fresh emulator process with the requested GPU mode.
launch_emulator() {
  local gpu="$1"
  need "${EMULATOR}"
  : > "${EMULATOR_LOG}" 2>/dev/null || true

  log "launching ${AVD_NAME} headless (gpu=${gpu}, port=${EMULATOR_PORT}, log=${EMULATOR_LOG})"
  nohup "${EMULATOR}" \
      -avd "${AVD_NAME}" \
      -port "${EMULATOR_PORT}" \
      -no-window \
      -no-audio \
      -no-boot-anim \
      -no-snapshot \
      -no-metrics \
      -accel on \
      -gpu "${gpu}" \
      -netdelay none \
      -netspeed full \
      >>"${EMULATOR_LOG}" 2>&1 &
  echo $! > "${EMULATOR_PIDFILE}"
}

# Wait for the emulator to appear in adb, then for sys.boot_completed=1.
wait_for_boot() {
  local serial="$1" timeout="$2" start now elapsed
  start=${SECONDS}
  local saw_device=0

  while :; do
    now=${SECONDS}
    elapsed=$((now - start))
    (( elapsed < timeout )) || break

    if [[ "${saw_device}" -eq 0 ]] && [[ -n "$("${ADB}" devices 2>/dev/null | awk -F'\t' -v s="${serial}" 'NR>1 && $1==s {print $1}')" ]]; then
      saw_device=1
      log "device ${serial} appeared in adb after $(fmt_elapsed "${elapsed}")"
    fi

    if boot_completed "${serial}"; then
      log "boot completed after $(fmt_elapsed "${elapsed}")"
      return 0
    fi

    # If we launched it and the process is gone, fail fast instead of waiting out the timeout.
    if [[ -f "${EMULATOR_PIDFILE}" ]] && ! our_emulator_alive; then
      log "emulator process exited during boot"
      tail_emulator_log
      return 1
    fi
    sleep 2
  done

  log "timed out after $(fmt_elapsed "${timeout}") waiting for ${serial} to boot"
  tail_emulator_log
  return 1
}

cmd_start() {
  need "${ADB}"
  need "${EMULATOR}"

  local existing
  existing="$(first_running_serial || true)"
  if [[ -n "${existing}" ]]; then
    log "emulator already running: ${existing} — not starting a second instance"
    SERIAL="${existing}"
    wait_for_boot "${SERIAL}" "${BOOT_TIMEOUT}" || die "existing emulator ${SERIAL} never finished booting" 3
    printf '%s\n' "${SERIAL}"
    return 0
  fi

  local gpu="${EMULATOR_GPU:-host}"
  launch_emulator "${gpu}"
  if wait_for_boot "${SERIAL}" "${BOOT_TIMEOUT}"; then
    printf '%s\n' "${SERIAL}"
    return 0
  fi

  if [[ -z "${EMULATOR_GPU:-}" ]]; then
    log "boot with gpu=${gpu} failed — retrying once with gpu=swiftshader_indirect"
    "${ADB}" -s "${SERIAL}" emu kill >/dev/null 2>&1 || true
    local pid
    pid="$(cat "${EMULATOR_PIDFILE}" 2>/dev/null || true)"
    [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
    sleep 3
    : > "${EMULATOR_PIDFILE}"
    launch_emulator swiftshader_indirect
    if wait_for_boot "${SERIAL}" "${BOOT_TIMEOUT}"; then
      printf '%s\n' "${SERIAL}"
      return 0
    fi
  fi

  die "emulator failed to boot. See ${EMULATOR_LOG} and ~/.android/avd/${AVD_NAME}.avd/emulator-user.ini" 3
}

cmd_wait() {
  need "${ADB}"
  local serial
  serial="$(first_running_serial || true)"
  [[ -n "${serial}" ]] || die "no emulator is running (start it with: scripts/emulator.sh start)" 3
  SERIAL="${serial}"
  wait_for_boot "${SERIAL}" "${BOOT_TIMEOUT}" || die "emulator ${SERIAL} did not finish booting" 3
  printf '%s\n' "${SERIAL}"
}

cmd_stop() {
  need "${ADB}"
  local serial
  serial="$(first_running_serial || true)"
  if [[ -z "${serial}" ]]; then
    log "no emulator running"
    return 0
  fi

  log "stopping ${serial}"
  "${ADB}" -s "${serial}" emu kill >/dev/null 2>&1 || true

  local deadline=$((SECONDS + 30)) pid
  while (( SECONDS < deadline )); do
    [[ -z "$(all_running_serials || true)" ]] && break
    sleep 1
  done

  if [[ -n "$(all_running_serials || true)" ]]; then
    pid="$(cat "${EMULATOR_PIDFILE}" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      log "adb emu kill did not take effect; killing pid ${pid}"
      kill "${pid}" 2>/dev/null || true
      sleep 2
      kill -9 "${pid}" 2>/dev/null || true
    fi
  fi

  rm -f "${EMULATOR_PIDFILE}"
  if [[ -n "$(all_running_serials || true)" ]]; then
    die "emulator still listed by adb after stop" 1
  fi
  log "emulator stopped"
}

cmd_status() {
  need "${ADB}"
  local serial state boot sdk abi size density uptime
  serial="$(first_running_serial || true)"
  if [[ -z "${serial}" ]]; then
    printf 'state: not running\n'
    if [[ -f "${HOME}/.android/avd/${AVD_NAME}.ini" ]]; then
      printf 'avd: %s (exists, not booted)\n' "${AVD_NAME}"
    else
      printf 'avd: %s (missing — run: scripts/emulator.sh create-avd)\n' "${AVD_NAME}"
    fi
    return 1
  fi

  state="$(emulator_state "${serial}")"
  boot="$("${ADB}" -s "${serial}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n' || true)"
  sdk="$("${ADB}" -s "${serial}" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r\n' || true)"
  abi="$("${ADB}" -s "${serial}" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r\n' || true)"
  size="$("${ADB}" -s "${serial}" shell wm size 2>/dev/null | tr -d '\r' | tr '\n' ' ' || true)"
  density="$("${ADB}" -s "${serial}" shell wm density 2>/dev/null | tr -d '\r' | tr '\n' ' ' || true)"
  uptime="$("${ADB}" -s "${serial}" shell cat /proc/uptime 2>/dev/null | tr -d '\r\n' || true)"

  printf 'avd: %s\n' "${AVD_NAME}"
  printf 'serial: %s\n' "${serial}"
  printf 'state: %s\n' "${state}"
  printf 'boot_completed: %s\n' "${boot:-<empty>}"
  printf 'sdk: %s\n' "${sdk:-<unknown>}"
  printf 'abi: %s\n' "${abi:-<unknown>}"
  printf 'wm_size: %s\n' "${size:-<unknown>}"
  printf 'wm_density: %s\n' "${density:-<unknown>}"
  printf 'uptime_sec: %s\n' "${uptime:-<unknown>}"
  [[ "${boot}" == "1" ]] || return 3
  return 0
}

cmd_screenshot() {
  need "${ADB}"
  local out="${1:-}"
  local serial
  serial="$(first_running_serial || true)"
  [[ -n "${serial}" ]] || die "no emulator running" 3
  boot_completed "${serial}" || die "emulator ${serial} is not fully booted yet" 3

  if [[ -z "${out}" ]]; then
    mkdir -p "${SHOT_DIR}"
    out="${SHOT_DIR}/emu-$(date +%Y%m%d-%H%M%S).png"
  else
    mkdir -p "$(dirname "${out}")"
  fi

  "${ADB}" -s "${serial}" exec-out screencap -p > "${out}"
  [[ -s "${out}" ]] || die "screencap produced an empty file: ${out}"

  local magic
  magic="$(head -c 8 "${out}" | od -An -tx1 | tr -d ' \n')"
  [[ "${magic}" == "89504e470d0a1a0a" ]] || die "screencap output is not a PNG (magic=${magic}): ${out}"

  local bytes
  bytes="$(wc -c < "${out}" | tr -d ' ')"
  log "screenshot: ${out} (${bytes} bytes, ${serial})"
  printf '%s\n' "${out}"
}

cmd_logcat() {
  need "${ADB}"
  local serial
  serial="$(first_running_serial || true)"
  [[ -n "${serial}" ]] || die "no emulator running" 3

  if [[ $# -eq 0 ]]; then
    exec "${ADB}" -s "${serial}" logcat -v threadtime
  fi
  if [[ "$1" == -* ]]; then
    exec "${ADB}" -s "${serial}" logcat -v threadtime "$@"
  fi
  # Regex filter mode.
  "${ADB}" -s "${serial}" logcat -v threadtime | grep --line-buffered -Ei -- "$1" || true
}

usage() {
  sed -n 's/^# \{0,1\}//p' "${BASH_SOURCE[0]}" | sed -n '1,40p' | sed '/^$/q'
}

main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift || true
  case "${cmd}" in
    start)      cmd_start "$@" ;;
    wait)       cmd_wait "$@" ;;
    stop)       cmd_stop "$@" ;;
    status)     cmd_status "$@" ;;
    screenshot) cmd_screenshot "$@" ;;
    logcat)     cmd_logcat "$@" ;;
    create-avd) cmd_create_avd "$@" ;;
    ""|-h|--help|help) usage; [[ -n "${cmd}" ]] || exit 2 ;;
    *) usage >&2; die "unknown command: ${cmd}" 2 ;;
  esac
}

main "$@"
