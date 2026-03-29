# Seeker

A fast, native dual-pane file manager for macOS, built with SwiftUI.

## Features

- **Dual-pane layout** with independent navigation
- **Tabbed browsing** — multiple tabs per pane
- **Three view modes** — List, Icons, and Column browser
- **Sidebar** — favorites, volumes with auto-detection of mount/unmount and eject support
- **File operations** — copy, move, rename, delete, duplicate, new folder/file with progress tracking
- **Cross-pane operations** — copy/move files between panes
- **Drag and drop** — with Option-key to copy
- **Quick Look** — press Space to preview any file
- **Multi-file selection** — click, Shift+click, Cmd+click
- **Configurable keyboard shortcuts** — customize all shortcuts in Settings
- **Show/hide hidden files** (⌘⇧.)
- **Show/hide file extensions**
- **Customizable columns** — toggle and reorder size, date modified, kind
- **Remembers last location** on relaunch
- **Native macOS icons** via NSWorkspace

## Default Keyboard Shortcuts

| Action | Shortcut |
|---|---|
| Open File | ⌘O |
| New Folder | ⌘⇧N |
| New File | ⌘⌥N |
| Rename | ⏎ |
| Duplicate | ⌘D |
| Move to Trash | ⌘⌫ |
| Copy to Other Pane | ⌘⇧C |
| Move to Other Pane | ⌘⇧M |
| Back / Forward | ⌘[ / ⌘] |
| Enclosing Folder | ⌘↑ |
| Toggle Hidden Files | ⌘⇧. |
| Toggle Dual Pane | ⌘U |
| Toggle Favorites | ⌘B |
| List / Icon / Column View | ⌘1 / ⌘2 / ⌘3 |
| New Tab / Close Tab | ⌘T / ⌘W |
| Quick Look | Space |

All shortcuts are configurable in **Settings → Shortcuts**.

## Requirements

- macOS 26 (Tahoe) or later
- Apple Silicon or Intel Mac

## Build & Run

```bash
swift build
swift run
```

### Build for Release

```bash
./scripts/build-release.sh 1.0.0
```

This creates a universal binary (arm64 + x86_64) with both DMG and ZIP in `dist/`.

## Installation

### From Release

1. Download `Seeker-x.x.x.dmg` from [Releases](../../releases)
2. Open the DMG and drag **Seeker** to **Applications**
3. On first launch, right-click → **Open**, then click **Open** in the dialog

> The app is ad-hoc signed but not notarized. If macOS blocks it, run:
> ```bash
> xattr -cr /Applications/Seeker.app
> ```

## License

MIT
