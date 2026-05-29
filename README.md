# Seeker

A fast, native dual-pane file manager for macOS, built with SwiftUI.

## Features

### Navigation & Layout
- **Dual-pane layout** with independent navigation; copy / move between panes in one shortcut
- **Tabbed browsing** — multiple tabs per pane, each with its own history
- **Three view modes** — List (with tree expansion), Icons, and Column browser
- **Tree view in List mode** — expand folders inline with the disclosure chevron, or use ← / → on the keyboard (similar to Finder's List view)
- **Sidebar** — favorites and volumes, with auto-detection of mount / unmount and eject support
- **Inline path editing** — click the pencil in the breadcrumb or press ⌘⇧G to type a path directly
- **Back / Forward history** per tab, plus ⌘↑ to step into the enclosing folder
- **`seeker://` URL scheme** — `seeker://reveal?path=…` selects a file in its parent folder; `seeker://open?path=…` opens a folder. Short forms `seeker://<absolute path>` are also accepted.

### File Operations
- Copy, move, rename, delete, duplicate, new folder / new file — all with a background progress panel
- Cross-pane copy / move (⌘⇧C / ⌘⇧M)
- Cut / Copy / Paste between any locations
- Drag and drop, with Option to force copy
- Compress to `.zip`, decompress archives
- Move to Trash via ⌘⌫
- Share menu (NSSharingService) — AirDrop, Mail, Messages, etc.

### Preview & Inspection
- **Quick Look** — Space to preview any file
- **Auto Preview** mode — keeps Quick Look in sync with the selection as you arrow through files
- Native macOS file icons via NSWorkspace
- File Info inspector

### Metadata Tools
- **Image metadata editor** — view and edit EXIF / IPTC fields; one-click "Strip GPS & Personal Info" for selected images
- **Audio / video metadata editor** — read and write tags for MP3 (ID3v2), FLAC, M4A / MP4, DSF, DFF, AIFF, WAV, and Matroska / WebM containers, including cover art
- **Duplicate finder** — content-hash based (xxHash3), with bulk move-to-trash

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
