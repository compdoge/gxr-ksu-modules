#!/system/bin/sh
# gxr-display-off - KernelSU module uninstall.
#
# Stop the watcher (supervisor first, or it would just restart watch.sh), then
# fail-safe restore both panels (DCS 0x29) and re-enable esd_check so the
# displays are never left blanked.
MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/gxr-display-off

LEFT=/sys/kernel/debug/dri/0/DSI-1/tx_cmd
RIGHT=/sys/kernel/debug/dri/1/DSI-2/tx_cmd
ESD_L=/sys/devices/virtual/lcd/panel/esd_check
ESD_R=/sys/devices/virtual/lcd/panel1/esd_check
ON="0x39 0x01 0x00 0x00 0x00 0x00 0x01 0x29"

pkill -f "$MODDIR/supervise.sh --loop" 2>/dev/null
sleep 1
pkill -f "$MODDIR/watch.sh" 2>/dev/null
sleep 1

echo "$ON" > "$LEFT" 2>/dev/null
echo "$ON" > "$RIGHT" 2>/dev/null
echo 1 > "$ESD_L" 2>/dev/null
echo 1 > "$ESD_R" 2>/dev/null

rm -f /data/local/tmp/gxr-display-off.pipe /data/local/tmp/gxr-display-off.pid 2>/dev/null
