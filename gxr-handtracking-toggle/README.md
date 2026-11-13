# `gxr-handtracking-toggle` - Galaxy XR hand tracking toggle (KernelSU module)

One button in the KernelSU Manager that turns off the headset's ability to
switch its active input mode to hand tracking, and turns it back on again - so
releasing a controller's grip (or putting it down) can no longer hand control
away from it.

**Status: confirmed working, live, on the owner's headset (2026-11-13).** With
the patch applied (Action pressed once), releasing a controller's grip no
longer switches the active input mode to HAND and no longer suspends the
controller - tracking continues through the grip release. Pressing Action
again restores stock behaviour.

## How it works (replaces the v0.1 mechanism)

v0.1 tried disabling the hand-tracking DNN (`perceptionhost`). A live
grip-release capture proved that **did not work**: the headset still switched
to HAND and suspended the controllers even with the hand pipeline off. Reverse
engineering `surfaceflinger` (read-only, via a rooted memory dump) found why:
the switch is requested over Binder from another process and surfaceflinger
just applies it in `XRInputManager::setInputModeType`. That function has a
check for mode `HAND` (value 1) that, if true, stores the new mode, logs
`"Updated active input mode to HAND"`, and tells the hand device to start.

This module patches **two instructions** inside that one function, live, in
the running `surfaceflinger` process's own memory:

| offset (= vaddr) | original | patched | effect |
|---|---|---|---|
| `0x285EBC` | `cmp w8, #9` | `cmp w8, #1` | test for mode 1 (HAND) instead of 9 (DWELL_WITH_EYE) |
| `0x285EC0` | `b.eq 0x285F28` (apply the mode) | `b.eq 0x286274` (function epilogue) | a request for HAND falls straight through to "do nothing, return" |

Every other mode (`CONTROLLER`, `EYE`, `AUTO`, ...) is handled by the unchanged
code below and is unaffected. **Nothing on disk is ever touched** - only the
live process's memory, through `/proc/<pid>/mem`. A reboot, or the (very
unlikely) crash-respawn of `surfaceflinger`, always comes back stock, because
nothing persists. This version has **no boot-time re-apply**: press Action
again after every reboot if you want it disabled again.

Each press re-finds the live address from `/proc/<pid>/maps` (ASLR gives
`surfaceflinger` a new load address every time it starts) and decides the
direction from what the live bytes actually are, the same way the earlier
module decided mount state - not from a saved flag.

## What this does and does not touch

- Patches only `surfaceflinger`'s own live memory. No file on `/system` or
  `/vendor` is ever written. No other process is touched.
- Does **not** disable the hand-tracking DNN itself (unlike v0.1) - hands keep
  being computed in the background; only the ability to switch *into* HAND
  mode is blocked.
- Settings keys (`auto_switch_hand_controllers`, `natural_input_mode`) and the
  `com.android.xr.flags.force_controller_use_without_grip_and_pairing`
  DeviceConfig flag were confirmed, by reverse engineering, **not** to be read
  anywhere near this logic in `surfaceflinger` - so this module does not rely
  on them.

## Risk - read this before installing

`surfaceflinger` is the core display compositor, not a simple restartable HAL
like `perceptionhost`. This is a materially bigger risk than the v0.1
mechanism:

- If the patch ever landed wrong, realistic failure modes are a frozen/black
  display or the compositor process crashing.
- Recovering from that would likely need a forced reboot (power button), which
  means re-entering your PIN afterward, and losing root.
- Mitigations built into this module: the write only happens after the
  device/build match, the **whole `surfaceflinger` file's SHA-256** matches the
  pinned build, a 64-bit-arithmetic self-check passes (the device's normal
  shell arithmetic is only 32-bit and silently wraps on addresses this large -
  found and worked around during development), and the **live 8 bytes at the
  computed address** match byte-for-byte one of the two shipped reference
  files before anything is written. The write is read back and compared, and
  the process's pid is checked before and after to catch a crash. Any
  mismatch aborts without writing.
- Validated live in stages on 2026-11-13: first read-only (the live bytes
  matched the offline analysis exactly), then a content-identical write-back
  (a true no-op, to prove the write path itself before any semantic change),
  then the real patch - `surfaceflinger` kept running under the same pid each
  time, with no crash, and the owner confirmed the actual grip-release fix
  worked (controllers kept tracking through a grip release with the patch
  applied).
- No ptrace-attach/thread-freeze is used, only a plain, root-gated read/write
  of `/proc/<pid>/mem` (this already proved sufficient and SELinux-permitted
  live, without any extra `sepolicy.rule`). The patched branch is only reached
  when a grip-release/HAND request actually arrives, not a hot loop, so the
  realistic window for a conflicting concurrent read is small; it was judged
  an acceptable trade for not adding ptrace-seize complexity. Flagging this
  explicitly as a judgement call, not a proven-zero risk.

## Install

1. Build the zip (see Packaging) and install it from the KernelSU Manager. If
   you still have v0.1 installed, install this zip over it (same module id).
2. The installer reverts the v0.1 mechanism if it is still active (unmounts its
   `host_config.json` replacement and restarts `perceptionhost`), and reverts
   this version's own patch if it happens to already be applied, so you always
   start from a clean stock state.
3. Reboot to activate (KernelSU loads modules at boot). Installing changes
   nothing: hand-switching stays stock until you press Action.
4. Press **Action** on the module. The output shows the new state and checks.

After a reboot you must enter your PIN on the headset before ADB works again.

## Manual recovery

```sh
# is surfaceflinger alive, and what pid?
pidof surfaceflinger

# forcibly put it back to stock without the module (root): recompute the live
# address the same way the module does, then write the ORIGINAL bytes back -
# see common.sh for the exact steps (sf_load_bias, then ORIG_REF).

# the only ALWAYS-reliable rollback: disable the module in the Manager and
# reboot. Nothing on disk was ever changed, so stock behaviour is guaranteed
# back the moment surfaceflinger restarts.
```

## Files

| file | purpose |
|---|---|
| `module.prop` | module metadata |
| `common.sh` | shared helpers: pinned hashes/offsets, 64-bit math self-check, address computation, the toggle itself (sourced) |
| `action.sh` | the toggle (Manager Action button) |
| `customize.sh` | installer: build/device gate, v0.1 migration cleanup, ensures a clean stock start, permissions |
| `uninstall.sh` | revert the patch if active |
| `payload/sf_setinputmode_orig.bin` | the 8 original bytes at the patch offset |
| `payload/sf_setinputmode_patched.bin` | the 8 patched bytes |

Log: `/data/local/tmp/gxr-handtracking-toggle.log` (appended).

## Live test (done - 2026-11-13)

Installed, rebooted, pressed Action once ("hand tracking is now DISABLED"),
then released a controller's grip while wearing the headset: the controller
kept tracking instead of switching to hands and losing pose. Pressed Action
again to restore stock behaviour.

## Packaging

```sh
python tools/make_module_zip.py gxr-handtracking-toggle dist/gxr-handtracking-toggle-v1.0.0.zip
```

The script writes forward-slash entry names with `module.prop` at the zip root.
