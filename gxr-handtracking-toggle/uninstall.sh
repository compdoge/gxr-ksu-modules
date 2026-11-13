#!/system/bin/sh
# gxr-handtracking-toggle - KernelSU module uninstall.
#
# If the surfaceflinger patch is currently active, revert it so hand tracking
# is back to stock before the module is removed. Nothing else to clean up: the
# patch never touched a file.
MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/gxr-handtracking-toggle
. "$MODDIR/common.sh"

if gate_ok && math_ok; then
  PID=$(sf_pid)
  if [ -n "$PID" ]; then
    BIAS=$(sf_load_bias "$PID")
    if [ -n "$BIAS" ]; then
      ADDR=$(bb_math "$BIAS + $PATCH_FILE_OFFSET")
      if [ -n "$ADDR" ]; then
        CHK=/data/local/tmp/gxr-ht-uninstall-check.bin
        dd if=/proc/$PID/mem bs=1 skip=$ADDR count=$PATCH_LEN of="$CHK" 2>/dev/null
        if [ -s "$CHK" ] && cmp -s "$CHK" "$PATCHED_REF"; then
          dd if="$ORIG_REF" of=/proc/$PID/mem bs=1 seek=$ADDR conv=notrunc 2>/dev/null
        fi
        rm -f "$CHK"
      fi
    fi
  fi
fi

rm -rf "$STATE_DIR" 2>/dev/null
