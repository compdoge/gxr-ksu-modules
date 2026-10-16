# `gxr-display-off` - Galaxy XR display-off on eye loss (KernelSU module)

Turns the Galaxy XR's own "eyes are gone" moment into a **visible** action. When
the wearer's eyes have been absent for the configured delay, the module either
blanks both micro-OLED panels with a DCS display-off (burn-in-safe, system stays
awake and eyes wake it again) or triggers the system sleep (stock-like). While
the module is enabled it suppresses the stock SystemUI eye-sleep so the delay is
yours to set.

This directory is the module **source**. It lives in the
[`compdoge/gxr-ksu-modules`](https://github.com/compdoge/gxr-ksu-modules) repo
(not a separate repository). Releases are published from this repo; the catalogue
entry is added once a release exists (see Packaging below).

Proven mechanism: `02-Headset-Research/gxr-eyesmonitor-sleep-20261016/RESULTS.md`
(a true per-eye panel blank via debugfs DSI `tx_cmd`, DCS `0x28`/`0x29`).
Eye-signal research: `.../research/7-eye-signal.md`.

## Install

1. Build the zip (`tools/make_module_zip.py`; see Packaging) and install it from
   the KernelSU Manager.
2. The module installs **disabled**. Enabling it is a separate, deliberate step.
3. **Reboot** to activate (KernelSU loads `service.sh` at boot).
4. Configure the mode and delay from the Manager: tap **WebUI** on this module.

After a reboot you must enter your PIN on the headset before ADB works again.

## Modes

At most one mode is on; both off is allowed.

| Mode | What happens after `delay` seconds with no eyes | Sleeps? | Panels |
|---|---|---|---|
| `displayoff` | Both panels blank (DCS `0x28`); restored on eyes (`0x29`) | No | Fully blank, system awake |
| `sleep` | `input keyevent 223` (KEYCODE_SLEEP) | Yes | Powered off by the OS |
| `off` | Nothing (the module only suppresses the stock eye-sleep) | No | Left on |

`displayoff` is meant to **replace** sleep, so it must not fire earlier than
sleep would; the same delay applies to whichever mode is on.

`displayoff` is the default when no `mode` file exists, so a freshly enabled
module blanks both panels after the delay instead of sleeping. `sleep` reproduces
the stock eye-sleep (the system sleeps after the delay). `off` is the safe inert
choice: the module suppresses the stock eye-sleep and does nothing else, so the
headset will not auto-sleep or auto-blank on eye loss (only a manual sleep
applies).

## Suppressing the stock eye-sleep

While enabled, `watch.sh` sets `debug.ix.sysui.eyes_monitor.enabled=false` once
at start. This stops the stock SystemUI 60 s warning and 90 s
`goToSleep(xr_doff)`, so the module's own delay is the only thing that acts. The
module never restores the property; a reboot returns it to its default (`true`),
which is also the rollback.

## Option files

Every setting is an optional file in the module directory. The WebUI writes them
for you and restarts the watcher on **Apply**. They are preserved across module
updates.

| file | values | default | purpose |
|---|---|---|---|
| `mode` | `sleep` / `displayoff` / `off` | `displayoff` | What to do after the delay with no eyes. |
| `delay` | integer seconds, 15-600 | `90` | Shared inactivity delay before acting (matches the stock sleep timing). |
| `esd` | `0` / `1` | `0` | `1` disables the ESD IRQ (`esd_check` -> 0) while blanked, so it cannot silently unblank during a long hold. |
| `paused` | marker (empty file) | absent | Written by WebUI **Pause**; cleared by **Resume** or **Apply**. A reboot starts the watcher regardless. |

By hand (root):

```sh
echo displayoff > /data/adb/modules/gxr-display-off/mode
echo 90         > /data/adb/modules/gxr-display-off/delay
echo 0          > /data/adb/modules/gxr-display-off/esd
sh /data/adb/modules/gxr-display-off/supervise.sh   # apply
```

## WebUI

One page (`webroot/index.html`), matched to the `gxr-alvr` FT module's style and
bridge. It talks to `webui.sh` through `ksu.exec(...)` and reads `key=value`
output.

- **Status**: mode pill, live eye state (eyes / no eyes / unknown), panels (On /
  Blanked), watcher pid, delay, ESD guard, log tail.
- **Behaviour**: mutually exclusive `Auto sleep` and `Display off` toggles (both
  may be off), one shared `Delay` (15-600, default 90), **Apply**.
- **Actions**: **Pause** (stop the watcher and restore the displays),
  **Resume**, **Restore displays now**, **Export logs** (to `/sdcard/Download`).
- **Advanced** (collapsed): the eye-signal source, the exact blank/restore byte
  strings, the ESD-guard toggle, the config file location, and recovery steps.

## Action button

The Manager **Action** button runs `action.sh`: an **English status-and-recovery
report only**. It never toggles or changes the running mode, and never starts or
stops the watcher. The KernelSU enable checkbox is the activation preference;
the WebUI is where settings change.

## Files

| file | purpose |
|---|---|
| `module.prop` | module metadata |
| `service.sh` | boot: mount debugfs if needed, then start the watcher via `supervise.sh` |
| `supervise.sh` | run `watch.sh` under a respawn supervisor; growing retry delay; fail-safe restore on every exit and before giving up |
| `watch.sh` | the eye-driven daemon (signal -> delay -> act -> restore) |
| `webui.sh` | root helper for the WebUI (`status` / `set` / `pause` / `resume` / `restore` / `exportlog`) |
| `action.sh` | Manager Action button = status/recovery report (never toggles) |
| `customize.sh` | installer permissions, option-file preservation, ui_print |
| `uninstall.sh` | stop the watcher, restore both panels, re-enable `esd_check` |
| `sepolicy.rule` | allow the KernelSU root domain to use debugfs/sysfs (Enforcing) |
| `webroot/index.html` | the Manager WebUI page |
| `mode`, `delay`, `esd`, `paused` | runtime config (not shipped - see Option files) |

## Logs

`/data/local/tmp/gxr-display-off.log` - a **fresh file on every start** (the
previous run is kept as `.1`). It records the eye-state transitions, every blank
and restore with the returned `last_cmd_tx_sts`, the ESD-guard changes, and a
status line every 15 s. `webui.sh exportlog` copies it (and `.1`) to
`/sdcard/Download` as `gxr-display-off-log.txt` and
`gxr-display-off-log-previous.txt`.

## Manual recovery

If the displays ever look wrong:

```sh
# restore both panels now (DCS 0x29), without changing the mode
sh /data/adb/modules/gxr-display-off/webui.sh restore

# stop the watcher and restore the displays
sh /data/adb/modules/gxr-display-off/webui.sh pause

# full rollback: disable the module in the Manager, then reboot
```

The watcher restores on any exit or signal (its `trap`), and the supervisor
restores after every watcher exit, so the panels are never left blanked. A
reboot re-initializes the panels. A reboot is a device action: ask before doing
it, and remember the PIN.

## Live-verify caveats

These are **not yet confirmed on a live, enabled install** and are marked
`[LIVE]` in the research notes:

- **Sleep mode** acts with `input keyevent 223` (KEYCODE_SLEEP). Whether that
  reproduces the stock `xr_doff` sleep cleanly, and how eyes/DON wake it again,
  must be validated live. (Default mode is `displayoff`, the verified path.)
- The eye signal (both `EyesMonitor` and `CpmInput` lines) is expected to keep
  emitting while the panels are blanked (the pipeline keeps running), but this
  has not been captured for the full 90 s+ hold.
- A long hold (> 90 s) with both panels blanked: confirm the framework never
  sleeps the device (the blank leaves the system awake by design).
- The logcat signal only emits on **state change**, so a watcher started while
  the eyes are already absent waits for the next change (it assumes "present"
  until then, which never blanks unexpectedly).

## Packaging

`tools/make_module_zip.py` (standard library only) builds the release zip with
**forward-slash** entry names and `module.prop` at the zip root:

```sh
python tools/make_module_zip.py gxr-display-off dist/gxr-display-off-v0.1.0.zip
```

Windows zip tools (Compress-Archive, `ZipFile.CreateFromDirectory`) write
backslashes, which turns `webroot/index.html` into a literal filename with a
backslash at the root; KernelSU then reports `web=false` and the WebUI never
appears. This script exists to avoid exactly that.

**Catalogue:** `modules.json` is left unchanged until a **published, stable
GitHub release** exists with a zip asset named
`gxr-display-off-v<version>.zip`; `tools/sync.py` then generates
`modules/gxr-display-off/update.json`. Until then, build and install the module
by hand from this directory.

## Safety

- Reversible and systemless: nothing persistent except the module dir under
  `/data/adb/modules`; `0x28`/`0x29` write nothing persistent.
- The headset must stay bootable; nothing here writes firmware, boot images, or
  original system files.
- Fail-safe by construction: the watcher restores on exit, the supervisor
  restores after every exit, and `uninstall.sh` restores before removing.
- Live tests follow propose -> ready -> validation, one action at a time.
