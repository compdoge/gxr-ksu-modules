#!/system/bin/sh
# gxr-display-off - helper for the module WebUI (webroot/index.html).
#
# The KernelSU Manager invokes this as root. It validates its arguments, reads
# and writes the module's option files, restarts / pauses / resumes the watcher
# and exports the logs. Output is machine-readable: one "key=value" per line
# (the page parses it). Untrusted input is never echoed back.
MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/gxr-display-off
LOG=/data/local/tmp/gxr-display-off.log
STATE=/data/local/tmp/gxr-display-off.state
PANEL=/data/local/tmp/gxr-display-off.panel
PIDF=/data/local/tmp/gxr-display-off.pid
PAUSED="$MODDIR/paused"

LEFT=/sys/kernel/debug/dri/0/DSI-1/tx_cmd
RIGHT=/sys/kernel/debug/dri/1/DSI-2/tx_cmd
ESD_L=/sys/devices/virtual/lcd/panel/esd_check
ESD_R=/sys/devices/virtual/lcd/panel1/esd_check
ON="0x39 0x01 0x00 0x00 0x00 0x00 0x01 0x29"

readval() { [ -f "$MODDIR/$1" ] && cat "$MODDIR/$1" 2>/dev/null; }

watcher_pid() {
  p=$(cat "$PIDF" 2>/dev/null)
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo "$p"; fi
}

case "$1" in
  status)
    m=$(readval mode); case "$m" in sleep|displayoff|off) ;; *) m=displayoff ;; esac
    d=$(readval delay); case "$d" in ''|*[!0-9]*) d=90 ;; esac
    e=$(readval esd); [ "$e" = "1" ] || e=0

    present=""
    if [ -f "$STATE" ]; then read present since < "$STATE" 2>/dev/null; fi
    case "$present" in
      1) eye=eyes ;;
      0) eye=no-eyes ;;
      *) eye=unknown ;;
    esac

    bl=""
    [ -f "$PANEL" ] && bl=$(cat "$PANEL" 2>/dev/null)
    if [ "$bl" = "1" ]; then panel=blanked; else panel=on; fi

    echo "mode=$m"
    echo "delay=$d"
    echo "esd=$e"
    echo "paused=$([ -f "$PAUSED" ] && echo 1 || echo 0)"
    echo "pid=$(watcher_pid)"
    echo "eye=$eye"
    echo "panel=$panel"
    echo "tail=$(tail -n 12 "$LOG" 2>/dev/null | tr '\n' '~')"
    ;;
  set)
    # set <mode> <delay> <esd>
    MODE="$2"; DELAY="$3"; ESDV="$4"
    case "$MODE" in sleep|displayoff|off) ;; *) echo "error=invalid mode"; exit 2 ;; esac
    case "$DELAY" in ''|*[!0-9]*) echo "error=invalid delay"; exit 2 ;; esac
    if [ "$DELAY" -lt 15 ] || [ "$DELAY" -gt 600 ]; then echo "error=invalid delay"; exit 2; fi
    case "$ESDV" in 0|1) ;; *) echo "error=invalid esd"; exit 2 ;; esac
    printf '%s\n' "$MODE" > "$MODDIR/mode"
    printf '%s\n' "$DELAY" > "$MODDIR/delay"
    printf '%s\n' "$ESDV" > "$MODDIR/esd"
    # Applying a setting means it should run: clear a pause and (re)start.
    rm -f "$PAUSED" 2>/dev/null
    sh "$MODDIR/supervise.sh" >/dev/null 2>&1
    sleep 1
    echo "ok=1"
    echo "pid=$(watcher_pid)"
    ;;
  pause)
    # Stop the supervisor first (killing watch.sh alone would just make it
    # respawn), then the watcher, and restore the displays.
    pkill -f "$MODDIR/supervise.sh --loop" 2>/dev/null
    sleep 1
    pkill -f "$MODDIR/watch.sh" 2>/dev/null
    sleep 1
    echo "$ON" > "$LEFT" 2>/dev/null
    echo "$ON" > "$RIGHT" 2>/dev/null
    echo 1 > "$ESD_L" 2>/dev/null
    echo 1 > "$ESD_R" 2>/dev/null
    printf '0\n' > "$PANEL" 2>/dev/null
    : > "$PAUSED"
    echo "ok=1"
    echo "paused=1"
    ;;
  resume)
    rm -f "$PAUSED" 2>/dev/null
    sh "$MODDIR/supervise.sh" >/dev/null 2>&1
    sleep 1
    echo "ok=1"
    echo "paused=0"
    echo "pid=$(watcher_pid)"
    ;;
  restore)
    # One-shot: unblank both panels now. Does not change the mode or stop the
    # watcher (the watcher would restore again on the next present event).
    echo "$ON" > "$LEFT" 2>/dev/null
    echo "$ON" > "$RIGHT" 2>/dev/null
    echo 1 > "$ESD_L" 2>/dev/null
    echo 1 > "$ESD_R" 2>/dev/null
    printf '0\n' > "$PANEL" 2>/dev/null
    echo "ok=1"
    echo "panel=on"
    ;;
  exportlog)
    # Copy the logs where the user can reach them (Downloads on internal
    # storage), overwriting the previous copy. Uses `cat >` so it does not
    # depend on cp being allowed to write to /sdcard.
    DST=/sdcard/Download
    mkdir -p "$DST" 2>/dev/null
    n=0
    for pair in "gxr-display-off-log.txt:$LOG" "gxr-display-off-log-previous.txt:$LOG.1"; do
      out="${pair%%:*}"; src="${pair#*:}"
      if [ -f "$src" ]; then cat "$src" > "$DST/$out" 2>/dev/null && n=$(( n + 1 )); fi
    done
    echo "ok=$n"
    echo "dir=$DST"
    ;;
  *)
    echo "error=usage: status | set <mode sleep|displayoff|off> <delay 15-600> <esd 0|1> | pause | resume | restore | exportlog"
    exit 2
    ;;
esac
