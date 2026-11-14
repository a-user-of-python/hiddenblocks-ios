# HiddenBlocks for iOS

A native iOS app that runs the HiddenBlocks editor (a PenguinMod /
TurboWarp / Scratch editor fork, including the Terrain extension)
**fully offline** and at **proper scale** — the editor fills the whole
iPhone/iPad screen edge-to-edge, with no browser chrome and no zoom
layer of its own.

## How it works

- The app is a thin SwiftUI/WKWebView wrapper (this repo). It contains
  no editor code of its own.
- At build time, GitHub Actions downloads the published web build of
  `a-user-of-python/hiddenblocks.github.io` (its `gh-pages` branch),
  then runs `Scripts/offline_prefetch.py`, which:
  - finds every asset the editor would normally fetch from the network
    (the Scratch costume/sound/backdrop/sprite libraries, the
    PenguinMod library files and sound previews, and the extension
    gallery's extension files and icons),
  - downloads all of them into the app bundle (`WebOffline/`),
  - rewrites those remote host prefixes in the editor's JS to loopback
    paths (`/__scratch/`, `/__pm/`, `/__ext/…`).
- At run time, the app serves the bundled editor from a loopback-only
  HTTP server inside the app (`127.0.0.1`, random port). A real HTTP
  origin means localStorage/IndexedDB — project autosave and addon
  settings — work exactly like on the website.
- A content-rule list in the web view blocks **all** non-loopback
  http/https loads, and the bundled web content needs none. The whole
  editor — blocks, paint/sound editors, all built-in extensions
  including Terrain, the full costume/sound/sprite/backdrop libraries,
  the extension gallery, and all addons — works with zero network.

## Addons

All addons registered in the HiddenBlocks build are included, because
the entire web build ships inside the app:

- 48 addons ship as their own `addon-entry-*.js` chunks,
- 18 addons ship inside the shared `addon-default-entry.js` chunk,
- 3 addons (drag-drop, jump-to-def, mute-project) are inlined into the
  main addons chunk by the upstream build.

That is all 69 addons the upstream build registers. (The upstream
source tree also contains two addon folders — `variable-manager` and
`editor-stepping` — that are not registered in the build at all: they
appear in no manifest or entry list, so there is nothing to ship for
them; they are equally absent from the website.)

## Honest limitations (network features)

These are network features by nature and cannot work offline; they
fail gracefully and everything else is unaffected:

- PenguinMod / Scratch accounts, sharing or uploading projects to
  those sites, cloud variables, and opening a project by its online ID.
- Loading a custom extension from a URL you paste in.
- The Translate extension (Google Translate) and the Text-to-Speech
  extension's online voices (Scratch's speech servers).
- Saving assets back to Scratch's servers. Your work is stored locally
  in the app, and projects export to files (.pmp/.sb3) as usual —
  exports are saved to the app's Documents and offered via share sheet.

## Building

Push to this repo (or run the workflow manually): **Actions → Build
IPA** produces `HiddenBlocks-unsigned.ipa` on GitHub's free standard
`macos-26` runner. The IPA is unsigned; sign it (e.g. with Signulous)
to install. Bundle id: `com.user.hiddenblocks`.

## Credits and licensing

See `NOTICE.md`. The bundled editor is GPL-3.0 (its license text is
bundled inside the app as `Web/LICENSE-GPL-3.0.txt`); the Swift
wrapper code in this repo is all rights reserved by its author.
