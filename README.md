# Seeker

A native dual-pane file manager for macOS, built with SwiftUI.

## Requirements

- macOS 26 or later
- Apple Silicon for the packaged release
- Swift 6.2 or later to build from source

## Features

### File Browsing & Operations

- Independent panes and tabs, with List, Icon and Column views; expandable folders in List view.
- Favorites, mounted volumes, a Computer overview, editable paths and navigation history.
- Filename filtering with case-insensitive `*` and `?` wildcards.
- Copy, move, cut/paste, duplicate, rename, batch rename, new files/folders and deletion.
- Copies preserve empty directories; overwrites require filesystem support for atomic swaps.
- Copying into a same-named folder merges its contents recursively and keeps destination-only items. Same-named files offer Replace, Keep Both, Skip and Cancel, with Apply to all for the remaining batch. Copying within the original folder still creates a numbered duplicate; moves and folder sync retain their separate conflict policies.
- Cross-pane transfers, drag and drop, and browser image imports.
- Trash browsing and Put Back: Seeker remembers original locations for items it trashes; other items require a restore folder.
- ZIP compression and extraction of ZIP, CPGZ and CPIO archives.
- Quick Look, Auto Preview, file information, sharing and Open Terminal Here.
- **Video Summary:** select a supported video and click the film-stack
  toolbar icon, or right-click it and choose **Generate Video Summary**. A
  standalone window automatically generates up to 16 timestamped representative
  frames, with cancellation, regeneration and PNG contact-sheet export.
  MP4, MOV and M4V prefer macOS decoding; unsupported native codecs fall back
  to FFmpeg. MKV, WebM, AVI, MPG/MPEG, TS/MTS/M2TS, WMV, FLV, VOB, OGV,
  3GP/3G2, MXF, ASF, DIVX and F4V use FFmpeg. Actual codec support depends on
  the installed FFmpeg build. The source video is never modified.
- Configurable columns, appearance, shortcuts and per-folder view settings.

**Clear Extended Attributes** is available for application bundles. It requires
administrator authorization and permanently removes all extended attributes,
including quarantine, Finder tags and custom metadata. Use only on trusted apps.

### Search & Folder Tools

- **Search:** filename wildcards or indexed text through Spotlight, with optional recursive searching.
- **Find Duplicates:** content-hash detection, linked duplicate groups, comparison explorers and bulk Move to Trash.
- **Compare Folders:** find entries unique to each side by name or relative path, not by file contents.
- **Sync Folders:** preview and apply Update, Mirror or Two-way plans based on file size and modification time. Mirror moves destination-only files to Trash; Update and Two-way do not delete.
- **Similar Images:** visual matching with Vision, perceptual hashing and optional semantic scoring.
- **Semantic Search:** text-to-image search with local Core ML models, OCR matching and cached image analysis.

The tool-window bar brings existing search, comparison and sync windows forward without restarting their tasks.

Video summaries use local AVFoundation or FFmpeg decoding, sparse sampling approximately
every 30 seconds (at least 16 candidates for videos long enough, capped at 240),
black/white-frame and sharpness filtering, perceptual deduplication and temporal
coverage. Short scenes can be missed; repetitive videos may yield fewer than 16
frames. This is a visual overview, not an AI or audio-based semantic summary.
Summaries are cached under `~/Library/Caches/<bundleID>/video-summaries/`, bounded
to 128 MB and invalidated by source path, size and modification time.
**Generate Again** bypasses cached results.
**Settings → General → Caches → Video Summary Cache → Clear Cache** deletes
video summary cache files independently of icon-view thumbnails and exported PNGs.
This section also displays the cache size and can reveal its folder in Seeker.
Open summaries remain visible; subsequent generation can populate the cache again.

FFmpeg is optional and is not bundled or installed automatically. When needed,
Seeker checks for **both `ffmpeg` and `ffprobe`** in PATH, `/opt/homebrew/bin`,
`/usr/local/bin`, `/opt/local/bin`, `~/.local/bin` and `~/bin`. If either is missing,
the summary window explains how to install them, offers a copyable
`brew install ffmpeg` command and links to installation guidance. After installing,
click **Generate Again**; no restart is needed for installations in these common
locations. Native decoding and existing cached summaries do not require FFmpeg.

### Metadata & Conversion

- Edit image EXIF/IPTC fields and remove GPS, camera serial numbers and private comments.
- Edit audio/video tags for MP3, FLAC, MP4/M4A/MOV, AIFF, DSF, DFF, Matroska/WebM and AVI; cover art is available where supported.
- Read-only tags for WAV, AAC, OGG, Opus, WMA, TS, MPG/MPEG, WMV and FLV.
- Convert NetEase Cloud Music `.ncm` files to MP3 or FLAC, with tags and cover art when available.

### AI Models

Download a model in **Settings → AI Models** before using Semantic Search or optional semantic image scoring.
SigLIP 2 Base Multilingual is the default; MobileCLIP-S2 and S0 are English-optimized alternatives.
Inference runs locally. Download sources and model storage are configurable in the same settings tab.

## Common Shortcuts

These defaults are configurable in **Settings → Shortcuts**:

| Action | Shortcut |
|---|---|
| Open / Rename | ⌘O / Return |
| New Folder / New File | ⌘⇧N / ⌘⌥N |
| Move to Trash | ⌘⌫ |
| Copy / Move to Other Pane | ⌘⇧C / ⌘⇧M |
| Back / Forward | ⌘[ / ⌘] |
| Enclosing Folder / Go to Folder | ⌘↑ / ⌘⇧G |
| Show Hidden Files | ⌘⇧. |
| Toggle Dual Pane / Favorites | ⌘U / ⌘B |
| List / Icon / Column View | ⌘1 / ⌘2 / ⌘3 |
| New Tab / Close Tab | ⌘T / ⌘W |

Space opens Quick Look; → / ← expand or collapse folders in List view.
These controls are separate from the configurable shortcuts above.

## URL Integration

Use `seeker://open?path=…` to open a folder or `seeker://reveal?path=…`
to select an item in its parent folder. URL-encode the path when needed.

## Build & Install

```bash
swift build
swift run
```

To package an arm64 release:

```bash
./scripts/build-release.sh 1.1.0
```

The script creates a DMG in `dist/`. It uses an available code-signing identity,
or ad-hoc signing if none is available; override with `SIGN_IDENTITY`.
Builds are not notarized.

Open the DMG and drag **Seeker** to **Applications**. Follow macOS security
prompts only for a build you trust. Open Terminal Here may request permission
to control Terminal under **System Settings → Privacy & Security → Automation**.

## Tests & Coverage

```bash
swift test
swift test --enable-code-coverage
swift test --show-codecov-path
```

Tests cover core file workflows, metadata, search, caches, tokenizers and NCM
conversion using synthetic fixtures. The last command prints the coverage JSON path.
Use the full suite when comparing coverage; overall totals also include UI and startup code.

To report application coverage without tests, generated sources or bundled xxHash C:

```bash
BIN_DIR="$(swift build --show-bin-path)"
xcrun llvm-cov report "$BIN_DIR/SeekerTests.xctest/Contents/MacOS/SeekerTests" \
  -instr-profile="$BIN_DIR/codecov/default.profdata" \
  -ignore-filename-regex='/Seeker/Tests/|/\.build/|/CXXHash/'
```

## License

MIT
