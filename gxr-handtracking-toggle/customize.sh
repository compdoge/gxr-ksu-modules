#!/system/bin/sh
# gxr-handtracking-toggle - KernelSU module installer customization (sourced by
# the installer after extraction). $MODPATH is the new module's own directory.
#
# The pinned hashes only fit one build: refuse to install anywhere else.
if [ "$(getprop ro.product.device)" != "xrvst2" ] ||
   [ "$(getprop ro.build.version.incremental)" != "I610UEU2AZF3" ]; then
  abort "! This module is pinned to xrvst2 / I610UEU2AZF3. Not installing."
fi

set_perm $MODPATH/common.sh  0 0 0755
set_perm $MODPATH/action.sh  0 0 0755
set_perm $MODPATH/uninstall.sh 0 0 0755

# --- Migration: v0.1 of this module used a different mechanism entirely (a
# bind-mounted, hand-disabled perception/host_config.json). It was found live
# NOT to stop the switch to HAND, so v0.2.0 replaces it. If that old mount is
# still active from a v0.1 install, remove it so nothing stale is left behind.
OLD_TARGET=/vendor/etc/perception/host_config.json
if grep -qF " $OLD_TARGET " /proc/1/mountinfo 2>/dev/null; then
  ui_print "- found the old v0.1 host_config.json mount; removing it"
  n=0
  while grep -qF " $OLD_TARGET " /proc/1/mountinfo 2>/dev/null && [ "$n" -lt 4 ]; do
    if [ -x /system/bin/nsenter ]; then
      nsenter -t 1 -m -- umount "$OLD_TARGET" 2>/dev/null
    else
      umount "$OLD_TARGET" 2>/dev/null
    fi
    n=$((n + 1))
  done
  if grep -qF " $OLD_TARGET " /proc/1/mountinfo 2>/dev/null; then
    ui_print "  WARNING: could not unmount it - see the README for manual recovery"
  else
    ui_print "  unmounted; restarting perceptionhost so it re-reads the stock config"
    OLDHPID=$(pidof android.hardware.perceptionhost 2>/dev/null)
    [ -n "$OLDHPID" ] && kill -9 "$OLDHPID" 2>/dev/null
  fi
fi
rm -f /data/adb/gxr-handtracking-toggle/state \
      /data/adb/gxr-handtracking-toggle/host_config.json \
      /data/adb/gxr-handtracking-toggle/boot_pending 2>/dev/null

# --- Make sure a (re)install never leaves the new surfaceflinger patch applied
# behind the scenes: if it is currently active, revert it so the device always
# starts from stock right after install/update.
MODDIR=$MODPATH
. "$MODDIR/common.sh"
if gate_ok && math_ok; then
  PID=$(sf_pid)
  if [ -n "$PID" ]; then
    BIAS=$(sf_load_bias "$PID")
    if [ -n "$BIAS" ]; then
      ADDR=$(bb_math "$BIAS + $PATCH_FILE_OFFSET")
      if [ -n "$ADDR" ]; then
        CHK=/data/local/tmp/gxr-ht-install-check.bin
        dd if=/proc/$PID/mem bs=1 skip=$ADDR count=$PATCH_LEN of="$CHK" 2>/dev/null
        if [ -s "$CHK" ] && cmp -s "$CHK" "$PATCHED_REF"; then
          ui_print "- an active hand-tracking patch was found; reverting it before install"
          dd if="$ORIG_REF" of=/proc/$PID/mem bs=1 seek=$ADDR conv=notrunc 2>/dev/null
          dd if=/proc/$PID/mem bs=1 skip=$ADDR count=$PATCH_LEN of="$CHK" 2>/dev/null
          if cmp -s "$CHK" "$ORIG_REF"; then
            ui_print "  reverted: hand tracking is back to stock"
          else
            ui_print "  WARNING: could not confirm the revert - see the README"
          fi
        fi
        rm -f "$CHK"
      fi
    fi
  fi
fi

ui_print "- gxr-handtracking-toggle: Galaxy XR hand tracking toggle installed"
ui_print "  stock behaviour until you press Action - nothing is changed by installing"
ui_print "  reboot to activate (KernelSU modules load at boot)"
ui_print "  Action: toggles whether the headset can switch to hand tracking"
ui_print "  this patches only surfaceflinger's own live memory - never a file on disk"
ui_print "  NOT remembered across reboot: press Action again after each reboot"
ui_print "  rollback: press Action again, or disable the module (reboot restores stock)"
