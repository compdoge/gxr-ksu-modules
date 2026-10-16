# gxr-ksu-modules

A **KernelSU module source** for the Samsung Galaxy XR (`SM-I610`). It is the
catalogue that tells the KernelSU manager where to find my modules and their
updates. Most modules are built and released from their own repository and this
repo only mirrors their release metadata; `gxr-display-off` is the exception -
its source lives here in full (see below).

The current contents are:

| Module | What it does | Source |
| --- | --- | --- |
| `gxr-alvr` - Galaxy XR face tracking relay | Runs the headset-side face/eye relay (`gxr_alvr`) as root and streams the full face/eye parameter set to VRCFaceTracking over UDP 41463. | [`compdoge/gxr-root-ft`](https://github.com/compdoge/gxr-root-ft) |
| `gxr-display-off` - Galaxy XR display-off on eye loss | Blanks both headset panels (or sleeps the system) after the wearer's eyes are gone for the set delay, and restores them on eyes; WebUI to pick the mode and delay. | this repo: [`gxr-display-off/`](gxr-display-off) |

## Requirements

This source targets the KernelSU build used on the Galaxy XR:
[`4uva4ek/KernelSU-GXR`](https://github.com/4uva4ek/KernelSU-GXR) (branch
`galaxyxr`), whose manager has a **Module sources** feature. It is not the
official `modules.kernelsu.org` catalogue and does not use the same format.

## Add this source

1. Open the KernelSU Manager on the headset.
2. Go to **Modules**, then tap **Sources**.
3. Under **Module sources**, paste:

   ```
   https://github.com/compdoge/gxr-ksu-modules
   ```

   and tap **Add source**. It becomes the active source.
4. The module list now shows **Galaxy XR face tracking relay**. Select it and tap
   **Install selected**. Installing does not start the relay; reboot the headset
   as the module's own README describes.

Updates are picked up from this source too: when a newer release appears, the
module is offered as an update.

## Modules whose source lives here

`gxr-display-off` is developed in this repository (`gxr-display-off/`), not in a
separate one. It has no published release yet, so it is not in `modules.json`;
build and install it by hand until a release exists:

```sh
python tools/make_module_zip.py gxr-display-off dist/gxr-display-off-v0.1.0.zip
```

The ZIP has `module.prop` at the root and forward-slash entry names (KernelSU
will not show a module's WebUI if `webroot/index.html` is stored with a
backslash, which is what Windows ZIP tools write). See
[`gxr-display-off/README.md`](gxr-display-off/README.md) for the modes, the WebUI
and recovery.

## License

MIT - see [`LICENSE`](LICENSE). Module code is licensed in its own repository.
