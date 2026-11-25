# Galaxy XR Fan Control - focus (`gxr-fanctl-focus`)

Fork of [`BreadDoesStuff/galaxy-xr-modules`](https://github.com/BreadDoesStuff/galaxy-xr-modules)
`modules/gxr-fanctl` v1.0.0 (commit tree `93dcf73`, MIT - see [`NOTICE`](NOTICE)).

**What is different from upstream:** the default mode is `focus`. The fans run
at max (step 7) **only while Steam Link or Virtual Desktop is the focused app**.
The rest of the time the fan node is handed back to Samsung SSRM and the stock
fan curve runs exactly as if the module were not installed.

All upstream modes (`stock`, `max`, `fixed`, `curve`) are still available.

## How focus is detected

Every `INTERVAL` seconds (default 2):

1. A cheap `/proc`-only check (`ps -A -o NAME=`) looks for any process whose
   package matches `FOCUS_PKGS`. If neither app is running, nothing else is
   queried and the fan stays in `IDLE_MODE`.
2. Only when one of them is running, `dumpsys activity activities` is read and
   the package of the focused (top resumed) activity is taken from the
   `ResumedActivity:` / `mFocusedApp=` line (or `topResumedActivity=` on builds
   that print it). Measured on `I610UEU2AZF3`: about 20 ms, ~30 KB of output.
3. If that package matches `FOCUS_PKGS`, the fan is locked at `FOCUS_STEP`.
   After focus is lost the step is held for `FOCUS_GRACE` seconds (default 10)
   so the system menu, notification shade or a quick app switch does not make
   the fan flap.

Default package globs:

| App | Package |
| --- | --- |
| Steam Link | `com.valvesoftware.steamlinkvr` (and Morphe renamed builds `com.valvesoftware.steamlinkvr.*`) |
| Virtual Desktop | `virtualdesktop.android` (Play Store id; `VirtualDesktop.Android` also matched) |

## How the fan is controlled (unchanged from upstream)

The headset has two fans on a MAX31760 behind the `sec_fan` driver. The only
input is `/sys/class/sec_fan/fan/step` (0-7; PWM `0, 85, 90, 95, 100, 110, 120, 140`).
To take control, the daemon `chown`s that node to root so SSRM's writes fail
with `EACCES`; to give control back it `chown`s it back to `system` (1000).
These are runtime sysfs permissions only and reset on reboot. No files on
`/system` or `/vendor` are touched.

## Configuration

WebUI in the KernelSU manager, `/data/adb/gxr-fanctl-focus/config.conf`
(applied live), or the CLI:

`su -c /data/adb/modules/gxr-fanctl-focus/fanctl status | mode <m> | idle <m> | pkgs "<globs>" | step <0-7> | curve "<pairs>" | set KEY VAL | get | log | start | stop | restart | reset`

| Key | Default | Description |
| --- | --- | --- |
| `MODE` | `focus` | `focus`, or upstream `stock` / `max` / `fixed` / `curve` |
| `FOCUS_PKGS` | `"com.valvesoftware.steamlinkvr* virtualdesktop.android* VirtualDesktop.Android*"` | Package globs that count as "streaming app focused" |
| `FOCUS_STEP` | `7` | Step while focused |
| `IDLE_MODE` | `stock` | `stock` / `curve` / `fixed` / `max` when not focused |
| `FOCUS_GRACE` | `10` | Seconds to hold `FOCUS_STEP` after focus is lost |
| `FIXED_STEP` | `7` | Step for `fixed` |
| `CURVE` | `"36:2 40:3 43:4 46:5 50:6 54:7"` | `tempC:step` pairs for `curve` |
| `MIN_STEP` | `1` | Step below the first curve pair |
| `HYST` | `2` | Degrees C before stepping down |
| `INTERVAL` | `2` | Poll and focus-check interval (s) |
| `SENSORS` | `"cpu-* cpuss-* gpuss-* ddr sys-therm-0"` | Thermal zone globs for `curve` |
| `FAILSAFE_STEP` | `7` | Step if no sensor can be read |

`status` shows e.g. `mode=focus(active) step=7 focus=1 fpkg=com.valvesoftware.steamlinkvr ...`
or `mode=focus(idle:stock) step=ssrm focus=0 fpkg=- ...`.

## Coexistence with upstream `gxr-fanctl`

This module has its own id and data directory
(`/data/adb/gxr-fanctl-focus/`), so it is not replaced by upstream updates.
Both modules drive the same node, so:

- the installer refuses to install while upstream `gxr-fanctl` is enabled;
- the daemon exits (status `mode=conflict`) if the upstream daemon is running.

Disable or remove upstream `gxr-fanctl` first.

## Changes vs upstream (code)

- `fand.sh`: new `focus` mode (`target_running`, `focused_pkg`, `update_focus`),
  `IDLE_MODE`, `FOCUS_*` keys, `focus=`/`fpkg=` in status, upstream-conflict
  check. `release_node` now resets the last written step so re-locking always
  rewrites the node (upstream could wait up to 30 s after `stock` -> `max` if the
  last step was already 7).
- `fanctl`: `focus` mode, `idle` and `pkgs` commands, new keys allowed in `set`.
- WebUI: Focus button and focus settings.
- Paths, id and data directory renamed to `gxr-fanctl-focus`.

## Rollback

- `fanctl mode stock`, or disable the module and reboot: SSRM owns the fan again.
- Uninstall hands the node back to SSRM and deletes `/data/adb/gxr-fanctl-focus/`.

## Status

Not yet tested live on the headset as a module. The focus parser was checked
read-only against `dumpsys` on `I610UEU2AZF3` (home app focused); the
"Steam Link / Virtual Desktop focused" case has not been observed yet.
