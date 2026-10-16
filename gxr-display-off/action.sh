#!/system/bin/sh
# gxr-display-off - KernelSU Manager "Action" button.
#
# This is an ENGLISH status-and-recovery report ONLY. It NEVER toggles or
# changes the running mode, and never starts or stops the watcher; the KernelSU
# checkbox is the activation preference and the WebUI is where settings change.
#
# The report is read-only: it reads the option files and the live state files
# and prints the recovery commands.
MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/gxr-display-off

echo "gxr-display-off: Galaxy XR display-off on eye loss"
echo "status report (read-only; the running mode was not changed)"
echo
sh "$MODDIR/webui.sh" status 2>/dev/null
echo
echo "Recovery commands:"
echo "  restore both panels now : sh $MODDIR/webui.sh restore"
echo "  stop the watcher        : sh $MODDIR/webui.sh pause"
echo "  start the watcher       : sh $MODDIR/webui.sh resume"
echo "  change the mode         : sh $MODDIR/webui.sh set <sleep|displayoff|off> <delay 15-600> <esd 0|1>"
echo "  full rollback           : disable this module in the Manager, then reboot"
