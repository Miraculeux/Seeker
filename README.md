# Seeker

A fast, native dual-pane file manager for macOS, built with SwiftUI.

## Features

### Navigation & Layout
- **Dual-pane layout** with independent navigation; copy / move between panes in one shortcut
- **Tabbed browsing** — multiple tabs per pane, each with its own history
- **Tool window bar** — the bottom of each main window lists its open Find Duplicates, Compare Folders, Search, Similar Images, Semantic Search, and Sync Folders windows. Click a label to bring the existing window forward (including minimized windows) without restarting its task. Labels track the current folders, with full paths in tooltips; the bar scrolls horizontally for many windows and disappears when they are all closed.
- **Three view modes** — List (with tree expansion), Icons, and Column browser
- **Tree view in List mode** — expand folders inline with the disclosure chevron, or use ← / → on the keyboard (similar to Finder's List view)
- **Sidebar** — favorites and volumes, with modern Finder-style outline icons (including the system Applications glyph when available), accent-colored favorites in active native macOS windows and neutral location icons, auto-detection of mount / unmount, and eject support
- **Computer location** — a host-named entry (for example, M4Pro) lists browsable mounted disks, including the startup disk; hidden Time Machine and system mounts are excluded from both Locations and this disk overview, even when showing hidden files. No Network entry is added.
- **Inline path editing** — click the pencil in the breadcrumb or press ⌘⇧G to type a path directly
- **Pane filtering** — each main-window pane filters its current listing as you type, with case-insensitive `*` and `?` filename wildcards
- **Back / Forward history** per tab, plus ⌘↑ to step into the enclosing folder
- Directory enumeration and sorting run in the background; superseded navigation and search work is cancelled between filesystem operations
- **`seeker://` URL scheme** — `seeker://reveal?path=…` selects a file in its parent folder; `seeker://open?path=…` opens a folder. Short forms `seeker://<absolute path>` are also accepted.

### File Operations
- Copy, move, rename, delete, duplicate, new folder / new file — all with a background progress panel
- Recursive copy planning, archive preparation, bulk deletion, and undo run off the UI thread; batch-rename previews are debounced and validated again before applying
- Batch rename keeps accepted previews valid when text editing ends; failed attempts report errors and keep the dialog open when no files were renamed
- Cross-pane copy / move (⌘⇧C / ⌘⇧M)
- Cut / Copy / Paste between any locations
- Trash lists recoverable items from the startup disk and mounted external volumes, even when Finder omits an external volume; unreadable Trash folders are reported explicitly
- **Put Back** in the Trash context menu or File menu restores items deleted by Seeker to their original locations, including after restarting. For items deleted outside Seeker, choose a restore folder. Existing files are never overwritten; failed items stay in the Trash.
- Drag and drop, with Option to force copy
- Compress to `.zip`, decompress archives
- Move to Trash via ⌘⌫
- Share menu (NSSharingService) — AirDrop, Mail, Messages, etc.
- **Clear application extended attributes** — in Applications (or any folder containing `.app` bundles), right-click selected apps → **Clear Extended Attributes…**. Available in List, Icon, and Column views (single app in Column view). After confirmation, macOS requests administrator authorization and Seeker runs the equivalent of `sudo xattr -cr -s` on only those apps. This irreversibly removes all extended attributes, including quarantine, Finder tags, and custom metadata; use only for apps you trust. The `-s` flag prevents following symbolic-link targets. Errors, including partial failures, are reported; cancelling authorization makes no changes.

### Preview & Inspection
- **Quick Look** — Space to preview any file
- **Auto Preview** mode — keeps Quick Look in sync with the selection as you arrow through files
- Native macOS file icons via NSWorkspace
- File Info inspector

### Metadata Tools
- **Image metadata editor** — view and edit EXIF / IPTC fields; one-click "Strip GPS & Personal Info" for selected images
- **Audio / video metadata editor** — read and write tags for MP3 (ID3v2), FLAC, M4A / MP4, DSF, DFF, AIFF, WAV, and Matroska / WebM containers, including cover art
- Metadata rewrites stream unchanged media payloads in bounded chunks and atomically replace the file, rather than buffering entire recordings
- **Duplicate finder** — content-hash based (xxHash3), with bulk move-to-trash
- Duplicate Finder uses a top action bar like Compare Folders: selection totals, Rescan, Move to Trash, and Cancel/Stop while work is running. There is no bottom button bar or Done button; use the system window close button to close it.
- Search uses the same two-panel layout as Semantic Search: choose a folder from the tree on the left, then search and inspect results on the right. Its top action bar provides status, Stop, Quick Look, and Reveal without a bottom button bar or extra close icon. Name searches run automatically after typing pauses and support case-insensitive `*` (any characters) and `?` (one character) wildcards; queries without wildcards retain substring matching. The **Subfolders** checkbox is enabled by default and can be cleared to search only the selected directory's direct children. Close the window with the system close button or Esc.
- Duplicate results use two levels: containing directory, then its duplicate files. Both levels sort by name in natural ascending order; full directory paths distinguish same-named folders. Suggested keeps still follow scan-root priority, independent of display order.
- **Duplicate relationships** — matching content shares a numbered **Group** badge, even across different names or folders. Click the badge to see all identical copies, their full paths, and their current deletion/keep status. **Locate** expands the destination folder, scrolls to the file, and shows it in the explorer without changing deletion checkboxes. Other visible copies of the selected file have a link marker and outline. Group numbers remain stable after deletions within a scan; a new scan assigns fresh numbers.
- **Duplicate comparison panes** — the right side has two vertically resizable file explorers: the selected file above and an identical copy below. Choose another copy by its full path in the lower pane. Both panes support the existing browsing, preview, open, and file operations. Same-directory copies use two independent explorers highlighting different files, not recursively generated panels. Deleting from either pane updates the results and available copies; no matching selection shows an empty-state message.
- **Visual similarity search** — uses the same left-folder-tree/right-results layout as Search and Semantic Search, ranking nearby images with Vision, pHash, aspect ratio, and optional semantic embeddings
- Search folder trees reveal selected folders even through hidden ancestors (such as macOS `/Volumes`); unrelated hidden folders remain hidden.
- **Semantic image search** — finds images from an open-ended text description using an on-device Core ML model
- Semantic Search supports recursive folders, persistent embedding/OCR caches, OCR text matching, configurable relevance thresholds, and Top-K result limits

### Semantic Models
- Multilingual SigLIP 2 Base Core ML (8-bit, about 356 MB) is the recommended default for semantic search and optional image-comparison scoring
- MobileCLIP-S2 is available as a faster English-optimized alternative; MobileCLIP-S0 is the smaller option
- Model downloads can use ModelScope (default), Hugging Face, or a custom mirror URL
- Models run locally; the default storage is `~/Library/Application Support/com.marvel.Seeker/SemanticModels/`, and Settings → AI Models can select another folder
- MobileCLIP-S2 requires about 200 MB to download; tokenizer assets use the official Hugging Face source when ModelScope is selected

### Specialised Conversions
- **NCM dump** — decrypts NetEase Cloud Music `.ncm` files back to playable FLAC / MP3 with original tags and cover art (available from the file or folder context menu)

### Terminal Integration
- **Open Terminal Here** — opens Terminal.app at the current directory (right-click on the explorer's empty area, or use the toolbar button)

### Customisation
- Show / hide hidden files (⌘⇧.)
- Show / hide file extensions
- Configurable columns — toggle and reorder Size, Date Modified, Kind
- **All keyboard shortcuts are user-configurable** in Settings → Shortcuts
- Remembers each pane's last location on relaunch

## Default Keyboard Shortcuts

| Action | Shortcut |
|---|---|
| Open File | ⌘O |
| New Folder | ⌘⇧N |
| New File | ⌘⌥N |
| Rename | ⏎ |
| Move to Trash | ⌘⌫ |
| Copy to Other Pane | ⌘⇧C |
| Move to Other Pane | ⌘⇧M |
| Back / Forward | ⌘[ / ⌘] |
| Enclosing Folder | ⌘↑ |
| Edit Path / Go to Folder | ⌘⇧G |
| Home / Desktop / Downloads | ⌘⇧H / ⌘⇧D / ⌘⇧L |
| Toggle Hidden Files | ⌘⇧. |
| Toggle Dual Pane | ⌘U |
| Toggle Favorites Sidebar | ⌘B |
| List / Icon / Column View | ⌘1 / ⌘2 / ⌘3 |
| Expand / Collapse Folder (List view) | → / ← |
| New Tab / Close Tab | ⌘T / ⌘W |
| Quick Look | Space |

All shortcuts are configurable in **Settings → Shortcuts**.

## Requirements

- macOS 26 (Tahoe) or later
- Apple Silicon Mac

## Build & Run

```bash
swift build
swift run
```

### Regression Tests

```bash
swift test
```

The tests use isolated synthetic files to check cancellation, sorting, batch
rename safety, preview limits, hashing, DSF duration and audio properties, and
streaming media metadata updates.
Application-attribute tests use disposable synthetic bundles without requesting
administrator privileges, and check recursive clearing, quoted paths, cancellation,
and preservation of unselected apps and symbolic-link targets.
Tool-window tests use disposable AppKit windows to check front-to-back ordering,
minimize/restore, registration cleanup, multi-window ownership, and compact bar layout.
They do not require network downloads or access to a personal media library.

### Build a Signed Release

```bash
./scripts/build-release.sh 1.0.0
```

Produces a hardened-runtime, code-signed `.app` and a DMG in `dist/`. Override the signing identity with `SIGN_IDENTITY=...` if needed.

## Installation

### From Release

1. Download `Seeker-x.x.x.dmg` from [Releases](../../releases)
2. Open the DMG and drag **Seeker** to **Applications**
3. On first launch, right-click → **Open**, then click **Open** in the dialog

> The app is signed but not notarized. If macOS blocks it, run:
> ```bash
> xattr -cr /Applications/Seeker.app
> ```

### Permissions

The first time you use **Open Terminal Here**, macOS will ask whether Seeker can control Terminal — click **OK**. You can later toggle this in **System Settings → Privacy & Security → Automation**.

## License

MIT
