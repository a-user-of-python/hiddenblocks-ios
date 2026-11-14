#!/usr/bin/env python3
"""Offline prefetch + loopback patch for the HiddenBlocks iOS app.

Runs in CI after the gh-pages web build of hiddenblocks.github.io has
been downloaded. It:

  1. Copies the web build into the app's Web/ resources.
  2. Scans the built JS for every asset the editor would otherwise fetch
     from a remote host at runtime:
       - Scratch library assets (costumes, sounds, backdrops, sprites),
         identified by their <md5>.<ext> names, normally served from
         cdn.assets.scratch.mit.edu / assets.scratch.mit.edu.
       - PenguinMod library files (libraryFilePage entries), normally
         served from library.penguinmod.com, plus the sound-preview
         waveform images the sound library displays.
       - Extension-gallery files (extension JS + icons), normally
         served from extensions.turbowarp.org / extensions.penguinmod.com.
  3. Downloads all of them (build time only — the app itself is fully
     offline) into WebOffline/ in a mirrored layout.
  4. Rewrites the remote host prefixes inside the built JS/HTML to
     loopback paths (/__scratch/, /__scratchhost, /__pm/, /__ext/…),
     which the app's local server maps onto WebOffline/.

Any hard asset that fails to download fails the build: shipping a
half-offline editor is worse than shipping nothing. Sound-preview
images (a waveform thumbnail in the sound library) and extension
gallery icons are cosmetic and soft-fail: they are counted and
reported, never fatal — several gallery icon URLs already 404 on the
live site, so their absence matches what the website itself shows.

Usage:
  offline_prefetch.py --web <gh-pages dir> --out-web <dir> --out-offline <dir>
"""

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import sys
import urllib.parse
import urllib.request

SCRATCH_CDN = "https://cdn.assets.scratch.mit.edu/internalapi/asset/{name}/get/"
PM_FILES = "https://library.penguinmod.com/files/"

RE_SCRATCH_ASSET = re.compile(r"[0-9a-f]{32}\.(?:svg|png|jpg|jpeg|wav|mp3)")
RE_PM_PAGE = re.compile(r"""libraryFilePage"?\s*:\s*"([^"]+)\"""")
RE_PM_PAGE_SQ = re.compile(r"""libraryFilePage'?\s*:\s*'([^']+)'""")
RE_EXT_URL = re.compile(r"""https://extensions\.(?:turbowarp\.org|penguinmod\.com)/[^\s"'\)\]]+""")

# Byte-level host rewrites applied to the built JS/HTML. Order matters:
# the CDN prefix must be rewritten before the bare asset host (the CDN
# string contains the bare host as a substring after "cdn.").
PATCHES = [
    (b"https://cdn.assets.scratch.mit.edu/internalapi/asset/", b"/__scratch/"),
    (b"https://assets.scratch.mit.edu", b"/__scratchhost"),
    (b"https://library.penguinmod.com/", b"/__pm/"),
    (b"https://extensions.turbowarp.org/", b"/__ext/turbowarp/"),
    (b"https://extensions.penguinmod.com/", b"/__ext/penguinmod/"),
]

RESIDUAL_HOSTS = [
    b"cdn.assets.scratch.mit.edu",
    b"assets.scratch.mit.edu",
    b"library.penguinmod.com",
    b"extensions.turbowarp.org",
    b"extensions.penguinmod.com",
]


def fetch(url, dest, attempts=3):
    """Download url to dest. Returns byte count. Raises on final failure."""
    last_error = None
    for _ in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "HiddenBlocks-iOS-CI"})
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = resp.read()
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as fh:
                fh.write(data)
            return len(data)
        except Exception as exc:  # noqa: BLE001 - retried, then reported
            last_error = exc
    raise RuntimeError(f"download failed after {attempts} tries: {url}: {last_error}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--web", required=True, help="gh-pages web build directory")
    parser.add_argument("--out-web", required=True, help="destination Web/ directory")
    parser.add_argument("--out-offline", required=True, help="destination WebOffline/ directory")
    args = parser.parse_args()

    if os.path.exists(args.out_web):
        shutil.rmtree(args.out_web)
    if os.path.exists(args.out_offline):
        shutil.rmtree(args.out_offline)
    shutil.copytree(args.web, args.out_web)
    os.makedirs(args.out_offline)

    # ---- Scan the built JS for remote asset references ----------------
    js_blobs = []
    for root, _dirs, files in os.walk(args.out_web):
        for name in files:
            if name.endswith(".js") and not name.endswith(".js.map"):
                path = os.path.join(root, name)
                with open(path, "rb") as fh:
                    js_blobs.append(fh.read())
    print(f"Scanned {len(js_blobs)} JS files")

    scratch_assets = set()
    pm_pages = set()
    ext_urls = set()
    for blob in js_blobs:
        text = blob.decode("utf-8", errors="ignore")
        scratch_assets.update(RE_SCRATCH_ASSET.findall(text))
        pm_pages.update(RE_PM_PAGE.findall(text))
        pm_pages.update(RE_PM_PAGE_SQ.findall(text))
        for url in RE_EXT_URL.findall(text):
            ext_urls.add(url.rstrip(".,;"))
    print(f"Scratch library assets referenced: {len(scratch_assets)}")
    print(f"PenguinMod library files referenced: {len(pm_pages)}")
    print(f"Extension gallery URLs referenced: {len(ext_urls)}")
    if not scratch_assets or not pm_pages or not ext_urls:
        print("ERROR: extraction found nothing — the web build layout changed?")
        return 1

    # ---- Build the download job list ----------------------------------
    # job = (url, dest, hard?)
    jobs = []
    local_copies = 0
    scratch_dir = os.path.join(args.out_offline, "scratch")
    for name in sorted(scratch_assets):
        dest = os.path.join(scratch_dir, name)
        bundled = os.path.join(args.out_web, "static", "assets", name)
        if os.path.exists(bundled):
            # Webpack already bundled this exact asset (its content hash
            # name is the Scratch md5); copy it instead of downloading.
            os.makedirs(scratch_dir, exist_ok=True)
            shutil.copyfile(bundled, dest)
            local_copies += 1
        else:
            jobs.append((SCRATCH_CDN.format(name=name), dest, True))

    pm_dir = os.path.join(args.out_offline, "pm", "files")
    for page in sorted(pm_pages):
        url = PM_FILES + urllib.parse.quote(page)
        jobs.append((url, os.path.join(pm_dir, page), True))
        if page.startswith("sounds/") and page.endswith(".mp3"):
            preview = page.replace("/", "_")[:-len(".mp3")] + ".png"
            jobs.append((PM_FILES + "sound_previews/" + preview,
                         os.path.join(pm_dir, "sound_previews", preview), False))
    for name in sorted(scratch_assets):
        if name.endswith(".wav") or name.endswith(".mp3"):
            asset_id = name[:32]
            jobs.append((PM_FILES + f"scratch_sound_previews/{asset_id}.png",
                         os.path.join(pm_dir, "scratch_sound_previews", f"{asset_id}.png"), False))

    ext_dir = os.path.join(args.out_offline, "ext")
    for url in sorted(ext_urls):
        if "turbowarp.org" in url:
            rel = url[len("https://extensions.turbowarp.org/"):]
            dest = os.path.join(ext_dir, "turbowarp", rel)
        else:
            rel = url[len("https://extensions.penguinmod.com/"):]
            dest = os.path.join(ext_dir, "penguinmod", rel)
        # Extension code (.js) is a hard requirement. Gallery icons are
        # soft: several icon URLs in the upstream gallery index already
        # return 404 on the live site, so a missing icon must not fail
        # the build — the extension itself still loads offline.
        jobs.append((url, dest, rel.endswith(".js")))

    print(f"Local bundled copies reused: {local_copies}")
    print(f"Downloads queued: {len(jobs)} (hard: {sum(1 for j in jobs if j[2])})")

    hard_failures = []
    soft_failures = []
    downloaded_bytes = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=24) as pool:
        futures = {pool.submit(fetch, url, dest): (url, hard) for url, dest, hard in jobs}
        for future in concurrent.futures.as_completed(futures):
            url, hard = futures[future]
            try:
                downloaded_bytes += future.result()
            except Exception as exc:  # noqa: BLE001 - collected and reported
                (hard_failures if hard else soft_failures).append(str(exc))
    print(f"Downloaded {downloaded_bytes} bytes; hard failures: {len(hard_failures)}, "
          f"soft (preview) failures: {len(soft_failures)}")
    for failure in hard_failures[:20]:
        print("HARD FAILURE:", failure)
    if hard_failures:
        print("ERROR: required offline assets are missing; refusing to ship half-offline.")
        return 1

    # ---- Rewrite remote hosts to loopback paths -----------------------
    patch_counts = {old.decode(): 0 for old, _new in PATCHES}
    patched_files = 0
    for root, _dirs, files in os.walk(args.out_web):
        for name in files:
            if name.endswith(".js.map"):
                continue
            if not (name.endswith(".js") or name.endswith(".html")):
                continue
            path = os.path.join(root, name)
            with open(path, "rb") as fh:
                data = fh.read()
            original = data
            for old, new in PATCHES:
                count = data.count(old)
                if count:
                    patch_counts[old.decode()] += count
                    data = data.replace(old, new)
            if data != original:
                patched_files += 1
                with open(path, "wb") as fh:
                    fh.write(data)
    print(f"Patched {patched_files} files; replacements: {json.dumps(patch_counts, indent=1)}")
    if patch_counts["https://cdn.assets.scratch.mit.edu/internalapi/asset/"] == 0:
        print("ERROR: Scratch CDN prefix not found — patch did not apply.")
        return 1
    if patch_counts["https://assets.scratch.mit.edu"] == 0:
        print("ERROR: Scratch asset host not found — patch did not apply.")
        return 1
    if patch_counts["https://library.penguinmod.com/"] == 0:
        print("ERROR: PenguinMod library host not found — patch did not apply.")
        return 1

    # Residual remote references (for the record): anything left is a
    # network-only feature (accounts, cloud, credits links) that the
    # app's content rules block; core library paths must be gone.
    residuals = {}
    for root, _dirs, files in os.walk(args.out_web):
        for name in files:
            if not name.endswith(".js") or name.endswith(".js.map"):
                continue
            with open(os.path.join(root, name), "rb") as fh:
                data = fh.read()
            for host in RESIDUAL_HOSTS:
                count = data.count(host)
                if count:
                    residuals[host.decode()] = residuals.get(host.decode(), 0) + count
    print(f"Residual host mentions in JS after patching: {json.dumps(residuals)}")

    # ---- Manifest ------------------------------------------------------
    offline_files = 0
    offline_bytes = 0
    for root, _dirs, files in os.walk(args.out_offline):
        for name in files:
            offline_files += 1
            offline_bytes += os.path.getsize(os.path.join(root, name))
    manifest = {
        "scratchAssets": len(scratch_assets),
        "penguinModFiles": len(pm_pages),
        "extensionGalleryURLs": len(ext_urls),
        "localCopiesReused": local_copies,
        "downloadedBytes": downloaded_bytes,
        "softFailures": len(soft_failures),
        "patchCounts": patch_counts,
        "residualHostMentions": residuals,
        "offlineFiles": offline_files,
        "offlineBytes": offline_bytes,
    }
    with open(os.path.join(args.out_offline, "MANIFEST.json"), "w") as fh:
        json.dump(manifest, fh, indent=1)
    print(f"WebOffline: {offline_files} files, {offline_bytes} bytes")
    print("Offline prefetch complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
