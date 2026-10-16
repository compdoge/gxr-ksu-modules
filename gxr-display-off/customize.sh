#!/system/bin/sh
# gxr-display-off - KernelSU module installer customization (sourced by the
# installer after extraction).
set_perm $MODPATH/service.sh    0 0 0755
set_perm $MODPATH/supervise.sh  0 0 0755
set_perm $MODPATH/watch.sh      0 0 0755
set_perm $MODPATH/webui.sh      0 0 0755
set_perm $MODPATH/action.sh     0 0 0755
set_perm $MODPATH/uninstall.sh  0 0 0755
# Do NOT set permissions on $MODPATH/webroot -- KernelSU sets them itself.

# Preserve the user's option files across an in-place update. KernelSU extracts
# the new version to modules_update/<id> and, at boot, WIPES the old module dir
# and renames the new one into place -- so any mode/delay/esd file left in the
# module dir is otherwise lost on every update. customize.sh runs while the OLD
# module dir still exists, so copy them forward here. The `paused` marker is
# deliberately NOT preserved: a fresh install starts unpaused.
OLD=/data/adb/modules/gxr-display-off
KEPT=
if [ -n "$MODPATH" ] && [ -d "$MODPATH" ] && [ -d "$OLD" ]; then
  for f in mode delay esd; do
    if [ -f "$OLD/$f" ] && [ ! -e "$MODPATH/$f" ]; then
      cp -af "$OLD/$f" "$MODPATH/$f" 2>/dev/null && KEPT="$KEPT $f"
    fi
  done
fi

# Kill any watcher/supervisor still running from an OLDER module version so it
# cannot keep blanking panels after an in-place update, and restore the panels.
# (The new watcher starts on reboot -- KernelSU modules are not active until
# then.) Logged to /data/local/tmp/gxr-display-off_install.log.
KLOG=/data/local/tmp/gxr-display-off_install.log
{
  echo "install: stopping old watcher + supervisor (watcher pid before: $(cat /data/local/tmp/gxr-display-off.pid 2>/dev/null)); kept:${KEPT:- none}"
  pkill -f "supervise.sh --loop" 2>/dev/null
  sleep 1
  pkill -f "gxr-display-off/watch.sh" 2>/dev/null
  sleep 1
  # Fail-safe restore: never leave the panels blanked after an update.
  echo 0x39 0x01 0x00 0x00 0x00 0x00 0x01 0x29 > /sys/kernel/debug/dri/0/DSI-1/tx_cmd 2>/dev/null
  echo 0x39 0x01 0x00 0x00 0x00 0x00 0x01 0x29 > /sys/kernel/debug/dri/1/DSI-2/tx_cmd 2>/dev/null
  echo 1 > /sys/devices/virtual/lcd/panel/esd_check 2>/dev/null
  echo 1 > /sys/devices/virtual/lcd/panel1/esd_check 2>/dev/null
  echo "install: after stop (watcher pid: $(cat /data/local/tmp/gxr-display-off.pid 2>/dev/null))"
} >> "$KLOG" 2>&1

ui_print "- gxr-display-off: Galaxy XR display-off on eye loss installed"
ui_print "  installed DISABLED - enable it in the Manager when you are ready"
ui_print "  reboot to activate (KernelSU modules load at boot)"
ui_print "  configure the mode and delay from the Manager: tap WebUI on this module"
ui_print "  rollback: disable the module, then reboot"
