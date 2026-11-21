#!/usr/bin/env bash
#
# emulator.sh — drive the `swiftui_test` Android emulator headlessly (arm64, API 35).
#
# Usage:
#   scripts/emulator.sh start                Boot the AVD headless (never starts a 2nd instance)
#                                            and wait for sys.boot_completed=1. Prints the serial.
#   scripts/emulator.sh wait                 Wait for the already-running emulator to finish booting.
#   scripts/emulator.sh stop                 Shut the emulator down.
#   scripts/emulator.sh status               Print serial/state/sdk/abi/wm size/density.
#                                            Exit 1 when not running, 3 when not booted.
#   scripts/emulator.sh screenshot [path]    adb exec-out screencap -p -> path
#                                            (default: build/screenshots/emu-<timestamp>.png)
#   scripts/emulator.sh logcat [regex]       Stream logcat, optionally filtered by a
#                                            case-insensitive extended regex.
#                                            If the first arg starts with '-', args go to adb logcat.
#   scripts/emulator.sh create-avd [--force] (Re)create the AVD from the installed arm64 image.
#
# Environment overrides:
#   ANDROID_HOME    Android SDK (resolved by scripts/env.sh)
#   AVD_NAME        default swiftui_test
#   EMULATOR_PORT   default 5554        (serial becomes emulator-5554)
#   BOOT_TIMEOUT    default 420 seconds per boot attempt
#   EMULATOR_GPU    default host        (start falls back to swiftshader_indirect if host fails)
#
# Exit codes: 0 ok, 1 failure, 2 usage, 3 device not running/bootable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The Android SDK location comes from scripts/env.sh (environment -> scripts/local.env ->
# convention). It also puts a JDK 17+ on PATH, which avdmanager/sdkmanager require.
# shellcheck source=scripts/env.sh
source "${REPO_ROOT}/scripts/env.sh"
port_env_need android
EMULATOR="$EMULATOR_BIN"

AVD_NAME="${AVD_NAME:-swiftui_test}"
EMULATOR_PORT="${EMULATOR_PORT:-5554}"
SERIAL="${SERIAL:-emulator-${EMULATOR_PORT}}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-420}"
SHOT_DIR="${SHOT_DIR:-${REPO_ROOT}/build/screenshots}"

TMP_BASE="${TMPDIR:-/tmp}/swiftui-android"
mkdir -p "${TMP_BASE}" >/dev/null 2>&1 || true
EMULATOR_LOG="${EMULATOR_LOG:-${TMP_BASE}/emulator-${AVD_NAME}.log}"
EMULATOR_PIDFILE="${EMULATOR_PIDFILE:-${TMP_BASE}/emulator-${AVD_NAME}.pid}"

# ----------------------------------------------------------------------------- output
log() { printf '[emulator] %s\n' "$*" >&2; }
die() { printf '[emulator] ERROR: %s\n' "$*" >&2; exit 1; }
need() { [[ -x "$1" ]] || die "missing executable: $1 (is the Android SDK installed?)"; }

fmt_elapsed() {
  printf '%dm%02ds' $(($1 / 60)) $(($1 % 60))
}

# ----------------------------------------------------------------------------- process/device helpers
running_serials() {
  "$ADB" devices 2>/dev/null |
    awk -F'\t' 'NR > 1 && $1 ~ /^emulator-/ && ($2 == "device" || $2 == "offline") { print $1 }'
}

first_running_serial() {
  running_serials | head -1
}

device_is_booted() {
  local value
  value="$("$ADB" -s "$1" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n' || true)"
  [[ "$value" == "1" ]]
}

# sys.boot_completed=1 fires before the launcher has drawn, so a screenshot taken
# immediately can come out all-black. Wait for a focused window (bounded, non-fatal).
device_ui_ready() {
  "$ADB" -s "$1" shell dumpsys window 2>/dev/null | grep -q 'mCurrentFocus=Window'
}

wait_for_ui() {
  local target="$1" timeout="$2" start elapsed
  start=${SECONDS}
  while :; do
    elapsed=$((${SECONDS} - start))
    if ((elapsed >= timeout)); then
      log "warning: no focused window after $(fmt_elapsed "$timeout"); continuing anyway"
      return 1
    fi
    if device_ui_ready "$target"; then
      log "ui ready after $(fmt_elapsed "$elapsed")"
      return 0
    fi
    sleep 1
  done
}

emulator_log_tail() {
  if [[ -s "$EMULATOR_LOG" ]]; then
    printf '\n--- last 40 lines of %s ---\n' "$EMULATOR_LOG" >&2
    tail -40 "$EMULATOR_LOG" >&2 || true
  fi
}

our_emulator_alive() {
  local pid
  [[ -f "$EMULATOR_PIDFILE" ]] || return 1
  pid="$(cat "$EMULATOR_PIDFILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

# ----------------------------------------------------------------------------- java for avdmanager
# avdmanager/sdkmanager need JDK 17+; the machine default is JDK 11.
ensure_java() {
  local version=""
  if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
    version="$("${JAVA_HOME}/bin/java" -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -1)"
  fi
  if [[ -n "$version" ]] && ((version >= 17)); then
    return 0
  fi
  log "warning: JDK 17+ not found; avdmanager may fail (JAVA_HOME=${JAVA_HOME:-<unset>})"
}

# ----------------------------------------------------------------------------- AVD creation
installed_system_image() {
  local candidate rel
  for candidate in \
    "system-images;android-35;google_apis;arm64-v8a" \
    "system-images;android-35;default;arm64-v8a" \
    "system-images;android-34;default;arm64-v8a"; do
    rel="${candidate#system-images;}"
    rel="${rel//;//}"
    if [[ -f "${ANDROID_HOME}/system-images/${rel}/system.img" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

set_ini() {
  local file="$1" key="$2" value="$3" tmp
  tmp="${file}.tmp.$$"
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    index($0, k "=") == 1 { if (!done) { print k "=" v; done = 1 }; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# ----------------------------------------------------------------------------- commands
cmd_create_avd() {
  ensure_java
  local force="${1:-}" image cfg create_out

  need "$AVDMANAGER"
  image="$(installed_system_image)" || die "no arm64 system image under ${ANDROID_HOME}/system-images. Install with: yes | ${SDKMANAGER} --sdk_root=${ANDROID_HOME} --install 'platform-tools' 'emulator' 'system-images;android-35;default;arm64-v8a'"
  log "system image: ${image}"

  if [[ -f "${HOME}/.android/avd/${AVD_NAME}.ini" ]]; then
    if [[ "$force" == "--force" ]]; then
      log "recreating AVD ${AVD_NAME} (--force)"
      rm -rf "${HOME}/.android/avd/${AVD_NAME}.avd" "${HOME}/.android/avd/${AVD_NAME}.ini"
    else
      log "AVD ${AVD_NAME} already exists (pass --force to recreate)"
      printf '%s\n' "${HOME}/.android/avd/${AVD_NAME}.avd"
      return 0
    fi
  fi

  if ! create_out="$(printf 'no\n' | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$image" -d medium_phone --force 2>&1)"; then
    log "create with 'medium_phone' profile failed; retrying without -d"
    printf '%s\n' "$create_out" >&2
    create_out="$(printf 'no\n' | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$image" --force 2>&1)" ||
      die "avdmanager create avd failed: ${create_out}"
  fi

  cfg="${HOME}/.android/avd/${AVD_NAME}.avd/config.ini"
  [[ -f "$cfg" ]] || die "AVD created but ${cfg} is missing"

  # Phone-like 6.4" panel 1080x2340 @ 420dpi; no snapshots; 4 GB RAM.
  set_ini "$cfg" hw.lcd.width 1080
  set_ini "$cfg" hw.lcd.height 2340
  set_ini "$cfg" hw.lcd.density 420
  set_ini "$cfg" hw.ramSize 4096
  set_ini "$cfg" vm.heapSize 512
  set_ini "$cfg" hw.keyboard yes
  set_ini "$cfg" hw.mainKeys no
  set_ini "$cfg" hw.gpu.enabled yes
  set_ini "$cfg" hw.gpu.mode host
  set_ini "$cfg" hw.audioInput no
  set_ini "$cfg" hw.audioOutput no
  set_ini "$cfg" disk.dataPartition.size 6442450944
  set_ini "$cfg" showDeviceFrame no
  set_ini "$cfg" fastboot.forceColdBoot yes
  set_ini "$cfg" fastboot.forceFastBoot no

  log "AVD ${AVD_NAME} ready: ${cfg}"
  printf '%s\n' "$cfg"
}

launch_emulator() {
  local gpu="$1"
  need "$EMULATOR"
  : > "$EMULATOR_LOG" 2>/dev/null || true

  log "launching ${AVD_NAME} headless (gpu=${gpu}, port=${EMULATOR_PORT}, log=${EMULATOR_LOG})"
  nohup "$EMULATOR" \
    -avd "$AVD_NAME" \
    -port "$EMULATOR_PORT" \
    -no-window \
    -no-audio \
    -no-boot-anim \
    -no-snapshot \
    -no-metrics \
    -accel on \
    -gpu "$gpu" \
    -netdelay none \
    -netspeed full \
    >>"$EMULATOR_LOG" 2>&1 &
  printf '%s\n' "$!" > "$EMULATOR_PIDFILE"
}

# Poll adb until sys.boot_completed=1. Returns 0 on success, 1 on timeout/death.
wait_for_boot() {
  local target="$1" timeout="$2" start elapsed saw_device=0
  start=${SECONDS}

  while :; do
    elapsed=$((${SECONDS} - start))
    ((elapsed < timeout)) || break

    if [[ "$saw_device" -eq 0 ]] && [[ -n "$("$ADB" devices 2>/dev/null | awk -F'\t' -v s="$target" 'NR > 1 && $1 == s { print $1 }')" ]]; then
      saw_device=1
      log "device ${target} appeared in adb after $(fmt_elapsed "$elapsed")"
    fi

    if device_is_booted "$target"; then
      log "boot completed after $(fmt_elapsed "$elapsed")"
      return 0
    fi

    if [[ -f "$EMULATOR_PIDFILE" ]] && ! our_emulator_alive; then
      log "emulator process exited during boot"
      emulator_log_tail
      return 1
    fi
    sleep 2
  done

  log "timed out after $(fmt_elapsed "$timeout") waiting for ${target} to boot"
  emulator_log_tail
  return 1
}

cmd_start() {
  need "$ADB"
  need "$EMULATOR"

  local existing gpu
  existing="$(first_running_serial || true)"
  if [[ -n "$existing" ]]; then
    log "emulator already running: ${existing} (not starting a second instance)"
    SERIAL="$existing"
    wait_for_boot "$SERIAL" "$BOOT_TIMEOUT" || die "existing emulator ${SERIAL} never finished booting"
    wait_for_ui "$SERIAL" 60 || true
    printf '%s\n' "$SERIAL"
    return 0
  fi

  gpu="${EMULATOR_GPU:-host}"
  launch_emulator "$gpu"
  if wait_for_boot "$SERIAL" "$BOOT_TIMEOUT"; then
    wait_for_ui "$SERIAL" 60 || true
    printf '%s\n' "$SERIAL"
    return 0
  fi

  if [[ -z "${EMULATOR_GPU:-}" ]]; then
    log "boot with gpu=${gpu} failed; retrying once with gpu=swiftshader_indirect"
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
    local pid
    pid="$(cat "$EMULATOR_PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    sleep 3
    : > "$EMULATOR_PIDFILE"
    launch_emulator swiftshader_indirect
    if wait_for_boot "$SERIAL" "$BOOT_TIMEOUT"; then
      wait_for_ui "$SERIAL" 60 || true
      printf '%s\n' "$SERIAL"
      return 0
    fi
  fi

  die "emulator failed to boot; see ${EMULATOR_LOG} and ~/.android/avd/${AVD_NAME}.avd/emulator-user.ini"
}

cmd_wait() {
  need "$ADB"
  local target
  target="$(first_running_serial || true)"
  [[ -n "$target" ]] || die "no emulator is running (start it with: scripts/emulator.sh start)"
  SERIAL="$target"
  wait_for_boot "$SERIAL" "$BOOT_TIMEOUT" || die "emulator ${SERIAL} did not finish booting"
  wait_for_ui "$SERIAL" 60 || true
  printf '%s\n' "$SERIAL"
}

cmd_stop() {
  need "$ADB"
  local target deadline pid
  target="$(first_running_serial || true)"
  if [[ -z "$target" ]]; then
    log "no emulator running"
    return 0
  fi

  log "stopping ${target}"
  "$ADB" -s "$target" emu kill >/dev/null 2>&1 || true

  deadline=$((SECONDS + 30))
  while ((SECONDS < deadline)); do
    [[ -z "$(running_serials || true)" ]] && break
    sleep 1
  done

  if [[ -n "$(running_serials || true)" ]]; then
    pid="$(cat "$EMULATOR_PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      log "adb emu kill had no effect; killing pid ${pid}"
      kill "$pid" 2>/dev/null || true
      sleep 2
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi

  rm -f "$EMULATOR_PIDFILE"
  [[ -z "$(running_serials || true)" ]] || die "emulator still listed by adb after stop"
  log "emulator stopped"
}

cmd_status() {
  need "$ADB"
  local target state boot sdk abi size density uptime
  target="$(first_running_serial || true)"
  if [[ -z "$target" ]]; then
    printf 'state: not running\n'
    if [[ -f "${HOME}/.android/avd/${AVD_NAME}.ini" ]]; then
      printf 'avd: %s (exists, not booted)\n' "$AVD_NAME"
    else
      printf 'avd: %s (missing - run: scripts/emulator.sh create-avd)\n' "$AVD_NAME"
    fi
    exit 1
  fi

  state="$("$ADB" -s "$target" get-state 2>/dev/null | tr -d '\r' || true)"
  boot="$("$ADB" -s "$target" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n' || true)"
  sdk="$("$ADB" -s "$target" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r\n' || true)"
  abi="$("$ADB" -s "$target" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r\n' || true)"
  size="$("$ADB" -s "$target" shell wm size 2>/dev/null | tr -d '\r' | tr '\n' ' ' || true)"
  density="$("$ADB" -s "$target" shell wm density 2>/dev/null | tr -d '\r' | tr '\n' ' ' || true)"
  uptime="$("$ADB" -s "$target" shell cat /proc/uptime 2>/dev/null | tr -d '\r\n' | awk '{print $1}' || true)"

  printf 'avd: %s\n' "$AVD_NAME"
  printf 'serial: %s\n' "$target"
  printf 'state: %s\n' "$state"
  printf 'boot_completed: %s\n' "${boot:-<empty>}"
  printf 'sdk: %s\n' "${sdk:-<unknown>}"
  printf 'abi: %s\n' "${abi:-<unknown>}"
  printf 'wm_size: %s\n' "${size:-<unknown>}"
  printf 'wm_density: %s\n' "${density:-<unknown>}"
  printf 'uptime_sec: %s\n' "${uptime:-<unknown>}"

  [[ "$boot" == "1" ]] && return 0
  return 3
}

cmd_screenshot() {
  need "$ADB"
  local target out magic bytes
  out="${1:-}"
  target="$(first_running_serial || true)"
  [[ -n "$target" ]] || die "no emulator running"
  device_is_booted "$target" || die "emulator ${target} is not fully booted yet"

  if [[ -z "$out" ]]; then
    mkdir -p "$SHOT_DIR"
    out="${SHOT_DIR}/emu-$(date +%Y%m%d-%H%M%S).png"
  else
    mkdir -p "$(dirname "$out")"
  fi

  "$ADB" -s "$target" exec-out screencap -p > "$out"
  [[ -s "$out" ]] || die "screencap produced an empty file: ${out}"
  magic="$(head -c 8 "$out" | od -An -tx1 | tr -d ' \n')"
  [[ "$magic" == "89504e470d0a1a0a" ]] || die "screencap output is not a PNG (magic=${magic}): ${out}"
  bytes="$(wc -c < "$out" | tr -d ' ')"
  log "screenshot: ${out} (${bytes} bytes, ${target})"
  printf '%s\n' "$out"
}

cmd_logcat() {
  need "$ADB"
  local target
  target="$(first_running_serial || true)"
  [[ -n "$target" ]] || die "no emulator running"
  if [[ $# -eq 0 ]]; then
    exec "$ADB" -s "$target" logcat -v threadtime
  fi
  if [[ "$1" == -* ]]; then
    exec "$ADB" -s "$target" logcat -v threadtime "$@"
  fi
  "$ADB" -s "$target" logcat -v threadtime | grep --line-buffered -Ei -- "$1" || true
}

usage() { sed -n '3,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed '$d'; }

main() {
  local command_name="${1:-}"
  [[ $# -gt 0 ]] && shift || true
  case "$command_name" in
    start) cmd_start "$@" ;;
    wait) cmd_wait "$@" ;;
    stop) cmd_stop "$@" ;;
    status) cmd_status "$@" ;;
    screenshot) cmd_screenshot "$@" ;;
    logcat) cmd_logcat "$@" ;;
    create-avd) cmd_create_avd "$@" ;;
    "") usage >&2; exit 2 ;;
    -h | --help | help) usage ;;
    *) usage >&2; die "unknown command: ${command_name}" ;;
  esac
}

main "$@"
