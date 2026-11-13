#!/system/bin/sh
# gxr-handtracking-toggle (v0.2.0) - shared helpers. SOURCED by the other
# scripts; the caller must set MODDIR first.
#
# Mechanism: patch TWO INSTRUCTIONS in the LIVE memory of the running
# surfaceflinger process (/system/bin/surfaceflinger, which hosts the XR "CPM"
# input code). The patched function, XRInputManager::setInputModeType, is made
# to refuse every request to switch the active input mode to HAND, so a grip
# release can no longer hand tracking away from a controller. Every other
# mode (CONTROLLER, EYE, AUTO, ...) is untouched. Confirmed by reverse
# engineering + a live grip-release capture that the HAND switch (and the
# controller suspend that follows it) is requested over Binder from OUTSIDE
# surfaceflinger and simply applied here - this is the only place found so far
# that can refuse it locally.
#
# The ELF's file offset equals its vaddr for every LOAD segment (p_offset ==
# p_vaddr), so the live runtime address is always:
#   load_bias (from /proc/<pid>/maps) + PATCH_FILE_OFFSET
# recomputed every time, because ASLR gives surfaceflinger a new load address
# on every boot (and on the rare crash-respawn).
#
# NEVER touches the file on disk: only the live process's own memory, read via
# /proc/<pid>/mem. A reboot (or a crash-respawn, if one ever happened) always
# restores stock behaviour, because nothing persists. There is deliberately NO
# boot-time re-apply in this version: press Action again after a reboot.
#
# Fail closed: nothing is written unless the device/build match, the live
# surfaceflinger binary's whole-file hash matches the pinned one, the 64-bit
# arithmetic needed to compute the address passes a self-check, and the live
# 8 bytes at the computed address match EXACTLY one of the two shipped
# reference files. The write is re-read afterwards to confirm it stuck, and
# the process's pid is checked before and after to catch a crash.

TARGET_FILE=/system/bin/surfaceflinger
STATE_DIR=/data/adb/gxr-handtracking-toggle
LOG=/data/local/tmp/gxr-handtracking-toggle.log
PATCH_LEN=8
PATCH_FILE_OFFSET=0x285EBC
ORIG_REF=$MODDIR/payload/sf_setinputmode_orig.bin
PATCHED_REF=$MODDIR/payload/sf_setinputmode_patched.bin

PIN_DEVICE=xrvst2
PIN_INCREMENTAL=I610UEU2AZF3
PIN_BINARY_SHA=21c9cfe2da316536439871a3e95ca68a74ba5dcab45abc92a29821f62275158d

ECHO=0

out() {
  [ "$ECHO" = 1 ] && echo "$*"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null
}

gate_ok() {
  [ "$(getprop ro.product.device)" = "$PIN_DEVICE" ] &&
    [ "$(getprop ro.build.version.incremental)" = "$PIN_INCREMENTAL" ]
}

# surfaceflinger's own shell arithmetic ($(( ))) is only 32-bit on this device
# and silently wraps on addresses this large - verified empirically. KernelSU's
# bundled busybox ash does real 64-bit arithmetic; fall back to a PATH busybox
# if that exact path is missing. math_ok() proves it before any address math is
# trusted, with a value picked specifically to overflow 32 bits.
BB=/data/adb/ksu/bin/busybox
[ -x "$BB" ] || BB=busybox
bb_math() { "$BB" ash -c "echo \$(( $1 ))" 2>/dev/null; }
math_ok() { [ "$(bb_math '0x100000000 + 0x1')" = "4294967297" ]; }

sf_pid() { pidof surfaceflinger 2>/dev/null; }

# Load bias: find the EXECUTABLE (r-xp) mapping backed by TARGET_FILE in the
# process's own maps, then bias = mapping_start - mapping_file_offset. Echoes a
# decimal number, or nothing on any failure.
sf_load_bias() {
  pid=$1
  line=$(grep -m1 "r-xp.*$TARGET_FILE\$" "/proc/$pid/maps" 2>/dev/null)
  [ -n "$line" ] || return 1
  range=$(echo "$line" | awk '{print $1}')
  off_hex=$(echo "$line" | awk '{print $3}')
  start_hex=${range%-*}
  [ -n "$start_hex" ] && [ -n "$off_hex" ] || return 1
  bb_math "0x$start_hex - 0x$off_hex"
}

# One Action press: read the live 8 bytes, decide direction from what they
# actually are, write the other reference file, verify. Sets NEWSTATE to
# "enabled" (stock, hands can be switched to) or "disabled" (patched, hands
# cannot be switched to) on success.
sf_toggle() {
  gate_ok || { out "refused: not $PIN_DEVICE / $PIN_INCREMENTAL"; return 1; }
  math_ok || { out "refused: 64-bit arithmetic self-check failed (busybox missing/broken)"; return 1; }
  [ -f "$ORIG_REF" ] && [ -f "$PATCHED_REF" ] ||
    { out "refused: reference payload files missing from the module"; return 1; }

  got_sha=$(sha256sum "$TARGET_FILE" 2>/dev/null | cut -d' ' -f1)
  [ "$got_sha" = "$PIN_BINARY_SHA" ] ||
    { out "refused: $TARGET_FILE hash is not the pinned one ($got_sha)"; return 1; }

  PID=$(sf_pid)
  [ -n "$PID" ] || { out "refused: surfaceflinger is not running"; return 1; }

  BIAS=$(sf_load_bias "$PID")
  [ -n "$BIAS" ] || { out "refused: could not compute load bias from /proc/$PID/maps"; return 1; }
  ADDR=$(bb_math "$BIAS + $PATCH_FILE_OFFSET")
  [ -n "$ADDR" ] || { out "refused: address computation failed"; return 1; }

  mkdir -p "$STATE_DIR"
  CUR=$STATE_DIR/sf_cur.bin
  dd if=/proc/$PID/mem bs=1 skip=$ADDR count=$PATCH_LEN of="$CUR" 2>/dev/null
  [ -s "$CUR" ] || { out "refused: could not read live bytes at $ADDR (pid $PID) - permission or address wrong"; return 1; }

  if cmp -s "$CUR" "$ORIG_REF"; then
    SRC=$PATCHED_REF; NEWSTATE=disabled; DIRECTION="apply (block switching to HAND)"
  elif cmp -s "$CUR" "$PATCHED_REF"; then
    SRC=$ORIG_REF; NEWSTATE=enabled; DIRECTION="revert (restore stock)"
  else
    out "refused: live bytes at $ADDR are neither the pinned original nor patched pattern - not touching anything"
    return 1
  fi
  out "pid=$PID addr=$ADDR direction=$DIRECTION"

  dd if="$SRC" of=/proc/$PID/mem bs=1 seek=$ADDR conv=notrunc 2>/dev/null

  AFTER=$STATE_DIR/sf_after.bin
  dd if=/proc/$PID/mem bs=1 skip=$ADDR count=$PATCH_LEN of="$AFTER" 2>/dev/null
  if ! cmp -s "$AFTER" "$SRC"; then
    out "WARNING: write did not verify (expected $(od -An -tx1 "$SRC" | tr -d ' \n'), got $(od -An -tx1 "$AFTER" | tr -d ' \n' 2>/dev/null))"
    return 1
  fi

  NEWPID=$(sf_pid)
  if [ "$NEWPID" != "$PID" ]; then
    out "WARNING: surfaceflinger pid changed during the write ($PID -> $NEWPID) - it may have crashed and respawned, which reverts to stock"
    return 1
  fi

  out "verified: surfaceflinger pid $PID still alive, bytes now match the $NEWSTATE pattern"
  return 0
}
