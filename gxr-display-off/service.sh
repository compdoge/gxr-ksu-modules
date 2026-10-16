#!/system/bin/sh
# gxr-display-off - KernelSU boot service script.
#
# Registers the eye-driven watcher at boot (and in late-load mode):
#   1. make sure debugfs is mounted (the DSI tx_cmd nodes live there),
#   2. start the watcher through supervise.sh (which respawns it and keeps the
#      fail-safe restore).
#
# Never block boot: this returns as soon as the supervised watcher is started in
# the background (supervise.sh backgrounds it with setsid).
#
# The stock eye-sleep suppression is done by watch.sh itself, once, at start.
# MODDIR = the module dir.
MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/gxr-display-off

# debugfs: /sys/kernel/debug/dri exists only after debugfs is mounted. Mount it
# only when it is missing (idempotent, reversible with umount).
if [ ! -d /sys/kernel/debug/dri ]; then
  mount -t debugfs none /sys/kernel/debug 2>/dev/null
fi

# late_start can be very early; give SystemUI/logcat/surfaceflinger a moment.
sleep 8

# A reboot always brings the module up: clear the WebUI "Pause" marker so a pause
# is transient (it lasts until Resume or a reboot). Without this, a stale paused
# file left in the module dir would keep the watcher stopped after a reboot.
rm -f "$MODDIR/paused" 2>/dev/null

sh "$MODDIR/supervise.sh"
