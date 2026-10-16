#!/system/bin/sh
# gxr-display-off - the root daemon.
#
# While the module is enabled this daemon OWNS the "eyes gone" behaviour:
#   - it suppresses the stock SystemUI eye-sleep ONCE
#     (setprop debug.ix.sysui.eyes_monitor.enabled false) and never restores it
#     (a reboot restores the property default),
#   - it follows the eye signal on logcat, and after `delay` seconds without
#     eyes it acts ONCE according to `mode`, then restores when eyes return.
#
# Eye signal (see 02-Headset-Research/gxr-eyesmonitor-sleep-20261016/
# research/7-eye-signal.md):
#   logcat -s EyesMonitor:D CpmInput:I
#     EyesMonitor: eyeDetected : No eye detected   -> absent  (authoritative)
#     EyesMonitor: eyeDetected : Eyes detected!    -> present (authoritative)
#     CpmInput: XREyeDevice - eyeState changed LEFT: n, RIGHT: n
#        present when either side == 1; absent when neither == 1 (supplement, so
#        the daemon still works if the EyesMonitor lines stop).
# The delay itself is the debounce: blinks (a brief 1 -> 2 -> 1 flip) never come
# close to the >= 15 s minimum inactivity window.
#
# FAIL-SAFE: any exit or signal restores both panels (DCS 0x29) and re-enables
# esd_check. The displays must NEVER be left blanked.
#
# Log: /data/local/tmp/gxr-display-off.log (fresh per start; previous as .1).
MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/gxr-display-off

LOG=/data/local/tmp/gxr-display-off.log
STATE=/data/local/tmp/gxr-display-off.state
PANEL=/data/local/tmp/gxr-display-off.panel
PIDF=/data/local/tmp/gxr-display-off.pid
FIFO=/data/local/tmp/gxr-display-off.pipe

# Confirmed live mapping (RESULTS.md, 2026-10-16): dri/0/DSI-1 = LEFT,
# dri/1/DSI-2 = RIGHT.
LEFT=/sys/kernel/debug/dri/0/DSI-1/tx_cmd
RIGHT=/sys/kernel/debug/dri/1/DSI-2/tx_cmd
DPMS_L=/sys/class/drm/card0-DSI-1/dpms
DPMS_R=/sys/class/drm/card1-DSI-2/dpms
ESD_L=/sys/devices/virtual/lcd/panel/esd_check
ESD_R=/sys/devices/virtual/lcd/panel1/esd_check
# DCS over debugfs: 0x28 = display off (blank), 0x29 = display on (restore).
OFF="0x39 0x01 0x00 0x00 0x00 0x00 0x01 0x28"
ON="0x39 0x01 0x00 0x00 0x00 0x00 0x01 0x29"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# ---- config: read once at start (the WebUI/Manager restarts the watcher on change) ----
readval() { [ -f "$MODDIR/$1" ] && cat "$MODDIR/$1" 2>/dev/null; }
MODE=$(readval mode); case "$MODE" in sleep|displayoff|off) ;; *) MODE=displayoff ;; esac
DELAY=$(readval delay); case "$DELAY" in ''|*[!0-9]*) DELAY=90 ;; esac
ESD=$(readval esd); [ "$ESD" = "1" ] || ESD=0

BLANKED=0    # 1 while both panels are blanked by us
ESD_OFF=0    # 1 while we have forced esd_check to 0
ACTED=0      # 1 once we acted for the current absence
LAST_PRESENT=""
READER_PID=""
LOGPID=""

# ---- panel helpers ----
dpms_on() {
  [ "$(cat "$DPMS_L" 2>/dev/null)" = "On" ] && [ "$(cat "$DPMS_R" 2>/dev/null)" = "On" ]
}

# tx <node> <bytes>: write the DCS packet and return the reported
# last_cmd_tx_sts value (e.g. 0x1). The write() itself always "succeeds"; only
# this read-back tells the truth (sde_connector.c).
tx() {
  echo "$2" > "$1" 2>/dev/null
  cat "$1" 2>/dev/null | sed -n 's/.*last_cmd_tx_sts:\(0x[0-9a-fA-F]*\).*/\1/p'
}

set_panel_state() { printf '%s\n' "$1" > "$PANEL" 2>/dev/null; }

blank_panels() {
  # Transfers are accepted only while the display is On (dpms=On).
  if ! dpms_on; then
    log "blank refused: display not On (dpms L=$(cat "$DPMS_L" 2>/dev/null) R=$(cat "$DPMS_R" 2>/dev/null))"
    return 1
  fi
  # ESD guard: disable the ESD IRQ on both panels BEFORE blanking (esd=1 only).
  if [ "$ESD" = "1" ]; then
    echo 0 > "$ESD_L" 2>/dev/null
    echo 0 > "$ESD_R" 2>/dev/null
    ESD_OFF=1
    log "esd_check disabled on both panels (esd=1)"
  fi
  ls=$(tx "$LEFT" "$OFF")
  rs=$(tx "$RIGHT" "$OFF")
  log "blank 0x28: last_cmd_tx_sts LEFT=$ls RIGHT=$rs"
  # Success is confirmed ONLY by last_cmd_tx_sts:0x1. On 0x0 the transfer was
  # refused; do not claim success, and retry on the next evaluation.
  if [ "$ls" = "0x1" ] && [ "$rs" = "0x1" ]; then
    BLANKED=1
    set_panel_state 1
    return 0
  fi
  # Half-done: put both back on and re-enable the guard, then report failure.
  tx "$LEFT" "$ON" >/dev/null
  tx "$RIGHT" "$ON" >/dev/null
  if [ "$ESD_OFF" = "1" ]; then
    echo 1 > "$ESD_L" 2>/dev/null
    echo 1 > "$ESD_R" 2>/dev/null
    ESD_OFF=0
  fi
  set_panel_state 0
  return 1
}

restore_panels() {
  ls=$(tx "$LEFT" "$ON")
  rs=$(tx "$RIGHT" "$ON")
  log "restore 0x29: last_cmd_tx_sts LEFT=$ls RIGHT=$rs"
  BLANKED=0
  set_panel_state 0
  if [ "$ESD_OFF" = "1" ]; then
    echo 1 > "$ESD_L" 2>/dev/null
    echo 1 > "$ESD_R" 2>/dev/null
    ESD_OFF=0
    log "esd_check re-enabled on both panels"
  fi
}

fail_safe() {
  # Never leave the panels blanked: force 0x29 on both and re-enable esd_check.
  echo "$ON" > "$LEFT" 2>/dev/null
  echo "$ON" > "$RIGHT" 2>/dev/null
  echo 1 > "$ESD_L" 2>/dev/null
  echo 1 > "$ESD_R" 2>/dev/null
  BLANKED=0
  ESD_OFF=0
  set_panel_state 0
}

# ---- the action taken once per absence ----
act() {
  elapsed="$1"
  case "$MODE" in
    displayoff)
      if blank_panels; then
        ACTED=1
        log "ACT: displayoff - both panels blanked after ${elapsed}s without eyes"
      else
        ACTED=0   # refused/failed: retry on the next evaluation
        log "ACT: displayoff - blank failed after ${elapsed}s without eyes; will retry"
      fi
      ;;
    sleep)
      input keyevent 223 2>/dev/null
      ACTED=1
      log "ACT: sleep - sent input keyevent 223 (KEYCODE_SLEEP) after ${elapsed}s without eyes [LIVE VALIDATION PENDING]"
      ;;
    *)
      ACTED=1
      log "ACT: off - nothing to do after ${elapsed}s without eyes"
      ;;
  esac
}

# ---- logcat reader (a background process; writes the present/since state) ----
set_state() {
  now=$(date +%s)
  printf '%s %s\n' "$1" "$now" > "$STATE.tmp" 2>/dev/null && mv -f "$STATE.tmp" "$STATE" 2>/dev/null
}

reader() {
  while IFS= read -r line; do
    case "$line" in
      *"eyeDetected : No eye detected"*) set_state 0 ;;
      *"eyeDetected : Eyes detected!"*)  set_state 1 ;;
      *"XREyeDevice"*"eyeState changed"*)
        l=$(printf '%s\n' "$line" | sed -n 's/.*LEFT: *\([0-9][0-9]*\).*/\1/p')
        r=$(printf '%s\n' "$line" | sed -n 's/.*RIGHT: *\([0-9][0-9]*\).*/\1/p')
        [ -n "$l" ] && [ -n "$r" ] || continue
        if [ "$l" = "1" ] || [ "$r" = "1" ]; then
          set_state 1
        else
          set_state 0
        fi
        ;;
    esac
  done
}

cleanup() {
  [ -n "$READER_PID" ] && kill "$READER_PID" 2>/dev/null
  [ -n "$LOGPID" ] && kill "$LOGPID" 2>/dev/null
  [ -z "$LOGPID" ] && pkill -f "logcat -s EyesMonitor:D CpmInput:I" 2>/dev/null
  rm -f "$FIFO" "$PIDF" 2>/dev/null
  fail_safe
  log "watch: stopped - fail-safe restore done (panels on, esd_check on)"
}
trap 'log "watch: signal - fail-safe"; cleanup; exit 0' TERM INT HUP

# ---- start ----
echo "$$" > "$PIDF" 2>/dev/null
# Suppress the stock SystemUI eye-sleep, once. The module owns this behaviour
# while it is enabled; it is not restored here (a reboot restores the default).
setprop debug.ix.sysui.eyes_monitor.enabled false 2>/dev/null
log "watch: start pid=$$ mode=$MODE delay=$DELAY esd=$ESD"
log "watch: stock eye-sleep suppressed (debug.ix.sysui.eyes_monitor.enabled=false)"

# Initial state: assume present (the safe default - no action until an absent
# event lands; note the logcat signal only emits on state CHANGE, so a watcher
# started while eyes are already absent waits for the next change).
set_state 1
set_panel_state 0

# Start the reader. A FIFO keeps both the logcat writer and the reader under our
# control for a clean shutdown.
if mkfifo "$FIFO" 2>/dev/null; then
  reader < "$FIFO" &
  READER_PID=$!
  logcat -s EyesMonitor:D CpmInput:I > "$FIFO" 2>/dev/null &
  LOGPID=$!
else
  log "watch: mkfifo unavailable; using a pipeline fallback"
  logcat -s EyesMonitor:D CpmInput:I 2>/dev/null | reader &
  READER_PID=$!
fi

# ---- 1 Hz evaluation loop ----
tick=0
while :; do
  now=$(date +%s)
  present=1
  since=$now
  if [ -f "$STATE" ]; then
    read present since < "$STATE" 2>/dev/null
  fi
  case "$present" in 0|1) ;; *) present=1 ;; esac
  case "$since" in ''|*[!0-9]*) since=$now ;; esac

  if [ "$present" != "$LAST_PRESENT" ]; then
    if [ "$present" = "1" ]; then
      log "eye state: present"
    else
      log "eye state: absent (will act after ${DELAY}s)"
    fi
    LAST_PRESENT=$present
  fi

  if [ "$present" = "1" ]; then
    if [ "$BLANKED" = "1" ] || [ "$ESD_OFF" = "1" ]; then
      restore_panels
    fi
    ACTED=0
    idle=0
  else
    idle=$(( now - since ))
    [ "$idle" -lt 0 ] && idle=0
    if [ "$ACTED" = "0" ] && [ "$idle" -ge "$DELAY" ]; then
      act "$idle"
    fi
  fi

  tick=$(( tick + 1 ))
  if [ $(( tick % 15 )) -eq 0 ]; then
    log "status: mode=$MODE delay=$DELAY esd=$ESD present=$present idle=${idle}s acted=$ACTED blanked=$BLANKED"
  fi
  sleep 1
done

cleanup
