#!/usr/bin/env python3
"""Refresh this KernelSU module source catalogue from the modules' home repositories.

The KernelSU-GXR manager (4uva4ek/KernelSU-GXR, branch ``galaxyxr``) reads
``modules.json`` at the repository root. For every entry it then fetches that
module's ``updateJson`` document, which must have this shape:

    {"version": "v1.3.6", "versionCode": 27,
     "zipUrl": "https://.../gxr-alvr-v1.3.6.zip",
     "sha256": "<64 hex chars>"}

GitHub's own release JSON does not look like that, so this script bridges the
two: it finds the newest stable (non-draft, non-prerelease) release of each
module's home repository, downloads the release ZIP, reads ``version`` /
``versionCode`` from the ``module.prop`` inside it, computes the ZIP's SHA-256,
and writes ``modules/<id>/update.json``.

Only the Python standard library is used. Paths are resolved relative to this
repository, so the script can be run from anywhere.

    python tools/sync.py                  # refresh every module in modules.json
    python tools/sync.py --dry-run        # report changes without writing
    python tools/sync.py --only gxr-alvr  # one module

Set ``GITHUB_TOKEN`` (or ``GH_TOKEN``) to raise the GitHub API rate limit; the
archive itself is always downloaded anonymously.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import sys
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

API = "https://api.github.com"
ROOT = Path(__file__).resolve().parent.parent
CATALOGUE = ROOT / "modules.json"
SOURCES = ROOT / "tools" / "sources.json"
TOKEN = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")

ID_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9._-]+$")
USER_AGENT = "gxr-ksu-modules-sync"


def http_get(url: str, *, api: bool) -> bytes:
    headers = {"User-Agent": USER_AGENT}
    if api:
        headers["Accept"] = "application/vnd.github+json"
        headers["X-GitHub-Api-Version"] = "2022-11-28"
        if TOKEN:
            headers["Authorization"] = f"Bearer {TOKEN}"
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        if api and exc.code in (403, 429):
            raise SystemExit(
                f"GitHub API rate limit reached for {url}. Set GITHUB_TOKEN and retry."
            ) from exc
        raise SystemExit(f"HTTP {exc.code} for {url}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"Cannot reach {url}: {exc.reason}") from exc


def api_json(url: str):
    return json.loads(http_get(url, api=True).decode("utf-8"))


def read_module_prop(zip_bytes: bytes) -> dict[str, str]:
    """Return the key/value pairs of the single root ``module.prop`` in a module ZIP."""
    try:
        archive = zipfile.ZipFile(io.BytesIO(zip_bytes))
    except zipfile.BadZipFile as exc:
        raise ValueError("release asset is not a valid ZIP") from exc

    with archive:
        names = [name.removeprefix("./") for name in archive.namelist()]
        if names.count("module.prop") != 1:
            raise ValueError("ZIP must contain exactly one module.prop at its root")
        if archive.getinfo("module.prop").file_size > 16384:
            raise ValueError("module.prop is unreasonably large")
        with archive.open("module.prop") as handle:
            text = handle.read().decode("utf-8", "replace")

    props: dict[str, str] = {}
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in props:
            raise ValueError(f"duplicate module.prop key: {key}")
        props[key] = value
    return props


def find_release(repository: str, asset_prefix: str, asset_ext: str):
    """Newest stable release that carries a matching asset, as (release, asset)."""
    page = 1
    while True:
        batch = api_json(f"{API}/repos/{repository}/releases?per_page=100&page={page}")
        if not batch:
            return None
        for release in batch:
            if release.get("draft") or release.get("prerelease"):
                continue
            for asset in release.get("assets") or []:
                name = asset.get("name", "")
                if name.startswith(asset_prefix) and name.lower().endswith(asset_ext):
                    return release, asset
        if len(batch) < 100:
            return None
        page += 1


def sync_module(module: dict, source: dict, dry_run: bool):
    module_id = module["id"]
    repository = source["repository"]
    asset_prefix = source.get("assetPrefix", f"{module_id}-")
    asset_ext = source.get("assetExtension", ".zip")

    found = find_release(repository, asset_prefix, asset_ext)
    if found is None:
        raise RuntimeError(f"{repository}: no stable release with a '{asset_prefix}*{asset_ext}' asset")
    release, asset = found
    zip_url = asset["browser_download_url"]

    payload = http_get(zip_url, api=False)
    sha256 = hashlib.sha256(payload).hexdigest()
    props = read_module_prop(payload)

    prop_id = props.get("id")
    version = props.get("version")
    version_code = props.get("versionCode", "")
    if prop_id != module_id:
        raise RuntimeError(
            f"{repository} {release['tag_name']}: ZIP id '{prop_id}' does not match catalogue id '{module_id}'"
        )
    if not version:
        raise RuntimeError(f"{repository} {release['tag_name']}: module.prop is missing 'version'")
    if not version_code.isdigit() or int(version_code) <= 0:
        raise RuntimeError(
            f"{repository} {release['tag_name']}: module.prop has an invalid versionCode '{version_code}'"
        )

    document = {
        "version": version,
        "versionCode": int(version_code),
        "zipUrl": zip_url,
        "sha256": sha256,
    }
    new_text = json.dumps(document, indent=2) + "\n"

    path = ROOT / "modules" / module_id / "update.json"
    old_text = path.read_text(encoding="utf-8") if path.exists() else None
    changed = old_text != new_text
    if changed and not dry_run:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(new_text, encoding="utf-8", newline="\n")
    return changed, document, path


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Refresh modules/<id>/update.json from upstream releases.")
    parser.add_argument("--dry-run", action="store_true", help="report changes without writing files")
    parser.add_argument("--only", metavar="ID", action="append", help="sync only this module id (repeatable)")
    args = parser.parse_args(argv)

    catalogue = json.loads(CATALOGUE.read_text(encoding="utf-8"))
    if catalogue.get("schemaVersion") != 1:
        raise SystemExit("modules.json: unsupported schemaVersion (expected 1)")
    sources = json.loads(SOURCES.read_text(encoding="utf-8"))

    failures: list[str] = []
    changed_any = False
    for module in catalogue.get("modules") or []:
        module_id = module.get("id", "")
        if args.only and module_id not in args.only:
            continue
        if not ID_RE.match(module_id):
            failures.append(f"{module_id!r}: invalid module id in modules.json")
            continue
        if not str(module.get("updateJson", "")).rstrip("/").endswith(f"modules/{module_id}/update.json"):
            failures.append(f"{module_id}: updateJson should point at modules/{module_id}/update.json")
            continue
        source = sources.get(module_id)
        if not source or not source.get("repository"):
            failures.append(f"{module_id}: no source entry in tools/sources.json")
            continue
        try:
            changed, document, path = sync_module(module, source, args.dry_run)
        except (RuntimeError, ValueError) as exc:
            failures.append(f"{module_id}: {exc}")
            continue
        changed_any = changed_any or changed
        state = "updated" if changed else "up to date"
        print(f"{module_id}: {document['version']} ({document['versionCode']}) -> "
              f"{path.relative_to(ROOT).as_posix()} [{state}]")

    if failures:
        for line in failures:
            print(f"error: {line}", file=sys.stderr)
        return 1
    if args.dry_run and changed_any:
        print("dry run: no files written")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
