#!/system/bin/sh
# gxr-handtracking-toggle - KernelSU Manager "Action" button.
#
# Each press flips whether the headset can switch its active input mode to
# HAND, decided from the REAL live bytes in surfaceflinger's memory, not from
# a saved flag:
#   stock (hands can be used)    -> patch: hands can no longer be switched to
#   patched (hands disabled)     -> revert: stock behaviour restored
#
# This patches ONLY the running surfaceflinger process's own memory - never the
# file on disk, never any other process. It does NOT persist across a reboot or
# a surfaceflinger crash/respawn; both always come back stock. Press Action
# again after a reboot if you want hands disabled again.
MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/gxr-handtracking-toggle
. "$MODDIR/common.sh"
ECHO=1

echo "gxr-handtracking-toggle: Galaxy XR hand tracking toggle"
echo "mechanism: live-patches surfaceflinger's CPM input code (no file is changed)"
echo

if sf_toggle; then
  echo
  echo "RESULT: hand tracking is now $(echo "$NEWSTATE" | tr a-z A-Z)"
  if [ "$NEWSTATE" = disabled ]; then
    echo "        the headset can no longer switch the active input mode to HAND"
    echo "        controllers should keep tracking even when ungripped"
  else
    echo "        stock behaviour restored: grip release can switch to HAND again"
  fi
  echo "boot  : NOT remembered - a reboot always comes back stock; press Action again"
  echo "undo  : press Action again"
else
  echo
  echo "RESULT: FAILED - nothing was changed on the device. See $LOG for details."
  echo "        full rollback (if you ever doubt the state): disable this module"
  echo "        in the Manager and reboot - surfaceflinger always reloads stock"
  echo "        from disk at boot."
fi
