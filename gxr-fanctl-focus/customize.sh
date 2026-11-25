#!/system/bin/sh
SKIPUNZIP=0
DATA=/data/adb/gxr-fanctl-focus

if [ ! -e /sys/class/sec_fan/fan/step ]; then
    ui_print "! /sys/class/sec_fan/fan/step not found - unsupported device"
    abort "! Aborting"
fi
ui_print "- Fan node found: $(cat /sys/class/sec_fan/fan/get_status 2>/dev/null)"
if [ "$(getprop ro.build.version.incremental)" != "I610UEU2AZF3" ]; then
    ui_print "! Only tested on I610UEU2AZF3 (this is $(getprop ro.build.version.incremental))"
fi

# Upstream gxr-fanctl drives the same node; both at once would fight.
UP=/data/adb/modules/gxr-fanctl
if [ -d $UP ] && [ ! -f $UP/disable ] && [ ! -f $UP/remove ]; then
    ui_print "! BreadDoesStuff gxr-fanctl is installed and enabled."
    ui_print "! Disable or remove it first - both control the same fan node."
    abort "! Aborting"
fi

mkdir -p $DATA
if [ -f $DATA/config.conf ]; then
    ui_print "- Keeping existing config $DATA/config.conf"
else
    cp $MODPATH/config.default.conf $DATA/config.conf
    ui_print "- Default config written to $DATA/config.conf"
fi

set_perm_recursive $MODPATH 0 0 0755 0644
set_perm $MODPATH/fand.sh 0 0 0755
set_perm $MODPATH/fanctl 0 0 0755
set_perm $MODPATH/service.sh 0 0 0755
set_perm $MODPATH/uninstall.sh 0 0 0755
ui_print "- Max fan only while Steam Link / Virtual Desktop is focused"
ui_print "- Otherwise the stock Samsung (SSRM) fan curve is used"
ui_print "- CLI: su -c /data/adb/modules/gxr-fanctl-focus/fanctl"
ui_print "- WebUI available in KernelSU manager"
