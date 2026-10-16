#!/system/bin/sh
# gxr-display-off - supervisor.
#
# Both service.sh (boot) and webui.sh (set/resume) start the watcher through
# this script. Its jobs:
#   - run watch.sh under a respawn loop with a growing retry delay,
#   - keep the fail-safe: after EVERY watcher exit, and before giving up, force
#     DCS 0x29 (display on) on both panels and re-enable esd_check, so the
#     displays are never left blanked.
#
# watch.sh reads the config itself (mode/delay/esd), so this script only decides
# whether to start at all (the `paused` marker) and supervises the process.
#
# A deliberate stop must kill the SUPERVISOR first (see webui.sh pause): killing
# watch.sh alone would just make the supervisor start it again.
MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/gxr-display-off
LOG=/data/local/tmp/gxr-display-off.log
PIDF=/data/local/tmp/gxr-display-off.pid
PAUSED="$MODDIR/paused"

LEFT=/sys/kernel/debug/dri/0/DSI-1/tx_cmd
RIGHT=/sys/kernel/debug/dri/1/DSI-2/tx_cmd
ESD_L=/sys/devices/virtual/lcd/panel/esd_check
ESD_R=/sys/devices/virtual/lcd/panel1/esd_check
ON="0x39 0x01 0x00 0x00 0x00 0x00 0x01 0x29"

restore_now() {
  echo "$ON" > "$LEFT" 2>/dev/null
  echo "$ON" > "$RIGHT" 2>/dev/null
  echo 1 > "$ESD_L" 2>/dev/null
  echo 1 > "$ESD_R" 2>/dev/null
}

# ---- supervisor mode: "supervise.sh --loop <cmd...>" ----
if [ "$1" = "--loop" ]; then
  shift
  delay=2
  fails=0
  while :; do
    started=$(date +%s)
    "$@" </dev/null >> "$LOG" 2>&1
    rc=$?
    # Belt-and-suspenders: the panels are never left blank between runs.
    restore_now
    ran=$(( $(date +%s) - started ))
    # A run that lasted long enough to be healthy resets the backoff.
    if [ "$ran" -ge 60 ]; then
      delay=2
      fails=0
    else
      fails=$(( fails + 1 ))
    fi
    if [ "$fails" -ge 15 ]; then
      echo "gxr-display-off: watcher failed to stay up ${fails} times; giving up (panels restored)" >> "$LOG"
      restore_now
      exit 0
    fi
    echo "gxr-display-off: watcher exited rc=$rc after ${ran}s; restarting in ${delay}s" >> "$LOG"
    sleep "$delay"
    delay=$(( delay * 2 ))
    [ "$delay" -gt 60 ] && delay=60
  done
fi

# ---- stop any previous supervisor + watcher ----
# Supervisor first: killing watch.sh alone would just make it respawn.
pkill -f "$MODDIR/supervise.sh --loop" 2>/dev/null
sleep 1
pkill -f "$MODDIR/watch.sh" 2>/dev/null
sleep 1
restore_now

# ---- a paused module does not run; make sure the panels are on ----
if [ -f "$PAUSED" ]; then
  echo "gxr-display-off: paused marker present; not starting the watcher" >> "$LOG"
  exit 0
fi

# ---- fresh log per start; the previous run is kept as .1 for diagnosis ----
[ -f "$LOG" ] && mv -f "$LOG" "$LOG.1"

# ---- start the supervised watcher in the background ----
setsid sh "$MODDIR/supervise.sh" --loop sh "$MODDIR/watch.sh" &
sleep 1
echo "gxr-display-off: supervised watcher started (pid $(cat "$PIDF" 2>/dev/null))" >> "$LOG"
