# gxr-ksu-modules

A **KernelSU module source** for the Samsung Galaxy XR (`SM-I610`). It is a small
catalogue that tells the KernelSU manager where to find my modules and their
updates. It contains no module code: each module is built and released from its
own repository, and this repo only mirrors the release metadata.

The current contents are:

| Module | What it does | Home repository |
| --- | --- | --- |
| `gxr-alvr` — Galaxy XR face tracking relay | Runs the headset-side face/eye relay (`gxr_alvr`) as root and streams the full face/eye parameter set to VRCFaceTracking over UDP 41463. | [`compdoge/gxr-root-ft`](https://github.com/compdoge/gxr-root-ft) |

## Requirements

This source targets the KernelSU build used on the Galaxy XR —
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
   **Install selected**. Installing does not start the relay — reboot the headset
   as the module's own README describes.

Updates are picked up from this source too: when a newer release appears, the
module is offered as an update.

## How it works

The manager reads [`modules.json`](modules.json) at the repository root. Each
entry names a module and points at a per-module `update.json`:

```json
{
  "version": "v1.3.6",
  "versionCode": 27,
  "zipUrl": "https://github.com/compdoge/gxr-root-ft/releases/download/v1.3.6/gxr-alvr-v1.3.6.zip",
  "sha256": "d37754665811f6d3382ad70fa36d8a519c238e663ae491d6b478c13759b40588"
}
```

The manager downloads `zipUrl`, verifies the SHA-256, then checks that the ZIP's
`module.prop` matches the catalogue's `id` and `versionCode` before installing.
Because every `zipUrl` points at an immutable GitHub release asset in the
module's own repository, this repo never needs to store a ZIP.

`sha256` is optional to the manager but always written here, so a swapped or
truncated download is refused.

## Keeping it in sync

`tools/sync.py` (standard library only) finds the newest stable release of each
module's home repository, reads `version` / `versionCode` from the `module.prop`
inside the release ZIP, computes the SHA-256, and rewrites `modules/<id>/update.json`:

```sh
python tools/sync.py            # refresh everything
python tools/sync.py --dry-run  # preview
python tools/sync.py --only gxr-alvr
```

[`.github/workflows/sync.yml`](.github/workflows/sync.yml) runs it every six
hours, on manual dispatch, and on a `sync-catalogue` `repository_dispatch`
event, committing any change. A module repository can therefore trigger a
refresh right after it publishes a release.

## Adding another module

1. Add an entry to `modules.json`:

   ```json
   {
     "id": "my-module",
     "name": "My Module",
     "description": "One line about it.",
     "updateJson": "https://raw.githubusercontent.com/compdoge/gxr-ksu-modules/main/modules/my-module/update.json"
   }
   ```

2. Add its home repository to [`tools/sources.json`](tools/sources.json):

   ```json
   { "my-module": { "repository": "compdoge/my-module-repo" } }
   ```

3. Run `python tools/sync.py`. The module's releases must be stable (non-
   prerelease, non-draft) and carry a ZIP asset named `my-module-…zip` with a
   single `module.prop` at the ZIP root.

The `id` must match `^[a-zA-Z][a-zA-Z0-9._-]+$` and must be identical across
every release of that module.

## Notes and limitations

- The repository must stay **public**; both the manager and `sync.py` fetch it
  anonymously.
- The manager calls the GitHub API without a token, so it is subject to GitHub's
  unauthenticated rate limit (60 requests/hour per IP). If a source fails to
  load with "GitHub request limit reached", wait and retry.
- The module's own repository remains the source of truth. This catalogue only
  mirrors release metadata; it does not build, sign, or re-host the modules.

## License

MIT — see [`LICENSE`](LICENSE). Module code is licensed in its own repository.
