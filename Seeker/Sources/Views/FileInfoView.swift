import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import AVFoundation
import QuickLookThumbnailing

struct FileInfoView: View {
    @Environment(AppState.self) var appState
    @State private var mediaInfo: MediaInfo?
    @State private var previewImage: NSImage?
    @State private var imageMeta: ImageMetadata?
    @State private var permissions: Permissions?
    @State private var attrError: String?
    @State private var multiSelectionTotalSize: Int64?
    @State private var multiSelectionSizeTask: Task<Void, Never>?
    @State private var folderSize: Int64?
    @State private var folderSizeTask: Task<Void, Never>?
    @State private var folderSizeTargetID: FileItem.ID?
    @State private var volumeInfo: VolumeInfo?
    @State private var volumeInfoTask: Task<Void, Never>?
    @State private var volumeInfoTargetURL: URL?

    private var selectedFile: FileItem? {
        appState.activeExplorer.selectedFile
    }

    private var selectedFileIDs: Set<FileItem.ID> {
        appState.activeExplorer.selectedFileIDs
    }

    /// When nothing is selected, the panel falls back to showing info for
    /// the current location if it is a volume root (e.g. the user clicked a
    /// disk in the sidebar). Returns the standardized volume URL, or nil if
    /// the current directory is not itself a mount point.
    private var volumeRootURL: URL? {
        guard selectedFileIDs.isEmpty, selectedFile == nil else { return nil }
        let url = appState.activeExplorer.currentURL.standardizedFileURL
        guard let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?
            .volume?.standardizedFileURL else { return nil }
        return volume == url ? url : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Info")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))

            Divider()

            if selectedFileIDs.count > 1 {
                multiSelectionContent
            } else if let file = selectedFile {
                fileInfoContent(file)
            } else if let volumeURL = volumeRootURL {
                volumeInfoContent(volumeURL)
            } else {
                noSelection
            }
        }
        .frame(width: 220)
        .background(.background)
    }

    // MARK: - Multi-Selection Summary

    private var multiSelectionContent: some View {
        let files = appState.activeExplorer.selectedFiles

        return VStack(spacing: 16) {
            Spacer()

            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 36, weight: .thin))
                .foregroundColor(.accentColor.opacity(0.6))

            VStack(spacing: 4) {
                Text("\(files.count) items selected")
                    .font(.system(size: 13, weight: .semibold))

                let folders = files.filter { $0.isDirectory }.count
                let regularFiles = files.count - folders
                if folders > 0 && regularFiles > 0 {
                    Text("\(regularFiles) file\(regularFiles == 1 ? "" : "s"), \(folders) folder\(folders == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else if folders > 0 {
                    Text("\(folders) folder\(folders == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    Text("\(regularFiles) file\(regularFiles == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Divider()
                .padding(.horizontal, 12)

            VStack(spacing: 10) {
                if let totalSize = multiSelectionTotalSize {
                    infoRow("Total Size", ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                } else {
                    HStack {
                        Text("Total Size")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 58, alignment: .trailing)
                        ProgressView()
                            .controlSize(.mini)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: selectedFileIDs) { _, newIDs in
            calculateMultiSelectionSize(ids: newIDs)
        }
        .onAppear {
            calculateMultiSelectionSize(ids: selectedFileIDs)
        }
    }

    private func calculateMultiSelectionSize(ids: Set<FileItem.ID>) {
        multiSelectionSizeTask?.cancel()
        multiSelectionTotalSize = nil
        let files = appState.activeExplorer.selectedFiles
        let urls = Array(files.map(\.url))
        multiSelectionSizeTask = Task {
            let total = await Task.detached(priority: .utility) { () -> Int64 in
                var size: Int64 = 0
                let fm = FileManager.default
                for url in urls {
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                    if isDir.boolValue {
                        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
                            while let fileURL = enumerator.nextObject() as? URL {
                                if Task.isCancelled { return -1 }
                                let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                                size += Int64(fileSize)
                            }
                        }
                    } else {
                        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                        size += Int64(fileSize)
                    }
                    if Task.isCancelled { return -1 }
                }
                return size
            }.value
            if !Task.isCancelled && total >= 0 {
                multiSelectionTotalSize = total
            }
        }
    }

    // MARK: - No Selection

    private var noSelection: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32, weight: .thin))
                .foregroundColor(.secondary.opacity(0.4))
            Text("No Selection")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Volume Info Content

    /// Disk/volume summary shown when the current location is a mount point
    /// and nothing is selected (e.g. the user clicked a disk in the sidebar).
    private func volumeInfoContent(_ url: URL) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                // Icon + Name
                VStack(spacing: 8) {
                    Image(nsImage: SidebarRow.icon(for: url))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 96, height: 96)

                    Text(volumeInfo?.name ?? url.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)

                    Text(volumeInfo?.format ?? "Volume")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 16)

                Divider()
                    .padding(.horizontal, 12)

                if let info = volumeInfo, info.totalCapacity > 0 {
                    // Capacity bar
                    VStack(spacing: 6) {
                        GeometryReader { geo in
                            let fraction = max(0, min(1, Double(info.usedCapacity) / Double(info.totalCapacity)))
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.7))
                                    .frame(width: max(2, geo.size.width * fraction))
                            }
                        }
                        .frame(height: 8)

                        HStack {
                            Text("\(byteString(info.usedCapacity)) used")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(byteString(info.availableCapacity)) free")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)

                    Divider()
                        .padding(.horizontal, 12)

                    VStack(spacing: 10) {
                        infoRow("Capacity", byteString(info.totalCapacity))
                        infoRow("Used", byteString(info.usedCapacity))
                        infoRow("Available", byteString(info.availableCapacity))
                        if let format = info.format {
                            infoRow("Format", format)
                        }
                    }
                    .padding(.horizontal, 12)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 8)
                }

                Divider()
                    .padding(.horizontal, 12)

                // Path
                VStack(alignment: .leading, spacing: 4) {
                    Text("Path")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)

                    Text(url.path)
                        .font(.system(size: 10))
                        .foregroundColor(.primary.opacity(0.7))
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)

                Spacer(minLength: 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            await loadVolumeInfo(for: url)
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func loadVolumeInfo(for url: URL) async {
        // Reuse the cached result if we're already showing this volume.
        if volumeInfoTargetURL == url, volumeInfo != nil { return }
        volumeInfo = nil
        volumeInfoTargetURL = url
        let info = await Task.detached(priority: .utility) {
            Self.computeVolumeInfo(at: url)
        }.value
        guard !Task.isCancelled, volumeInfoTargetURL == url else { return }
        volumeInfo = info
    }

    private struct VolumeInfo: Equatable {
        var name: String
        var totalCapacity: Int64
        var availableCapacity: Int64
        var format: String?
        var usedCapacity: Int64 { max(0, totalCapacity - availableCapacity) }
    }

    private nonisolated static func computeVolumeInfo(at url: URL) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeLocalizedFormatDescriptionKey
        ]
        guard let rv = try? url.resourceValues(forKeys: keys) else { return nil }
        let total = Int64(rv.volumeTotalCapacity ?? 0)
        // `volumeAvailableCapacityForImportantUsage` matches the free space
        // Finder reports (it accounts for purgeable space); fall back to the
        // plain available capacity when the richer value isn't provided.
        let available: Int64
        if let important = rv.volumeAvailableCapacityForImportantUsage, important > 0 {
            available = important
        } else {
            available = Int64(rv.volumeAvailableCapacity ?? 0)
        }
        return VolumeInfo(
            name: rv.volumeName ?? url.lastPathComponent,
            totalCapacity: total,
            availableCapacity: min(available, total),
            format: rv.volumeLocalizedFormatDescription
        )
    }

    // MARK: - File Info Content

    private func fileInfoContent(_ file: FileItem) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                // Icon + Name
                VStack(spacing: 8) {
                    // Reserve a stable area so swapping between items with /
                    // without a thumbnail doesn't reflow the panel and cause
                    // the visible "flash" while navigating with arrow keys.
                    ZStack {
                        if let preview = previewImage {
                            Image(nsImage: preview)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 196, maxHeight: 196)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                                )
                                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 1)
                                .transition(.opacity)
                        } else {
                            Image(nsImage: file.nsIcon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 96, height: 96)
                                .transition(.opacity)
                        }
                    }
                    .frame(width: 196, height: 196)
                    .animation(.easeInOut(duration: 0.18), value: previewImage)

                    Text(file.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)

                    Text(file.typeDescription)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 16)

                Divider()
                    .padding(.horizontal, 12)

                // Details
                VStack(spacing: 10) {
                    if !file.isDirectory {
                        infoRow("Size", file.formattedSize)
                        infoRow("Bytes", formattedBytes(file.fileSize))
                    } else {
                        infoRow("Kind", "Folder")
                        folderSizeRow
                    }

                    if let created = file.creationDate {
                        infoRow("Created", formatFullDate(created))
                    }

                    if let modified = file.modificationDate {
                        infoRow("Modified", formatFullDate(modified))
                    }

                    infoRow("Extension", file.url.pathExtension.isEmpty ? "—" : file.url.pathExtension.uppercased())
                }
                .padding(.horizontal, 12)

                Divider()
                    .padding(.horizontal, 12)

                // Path
                VStack(alignment: .leading, spacing: 4) {
                    Text("Path")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)

                    Text(file.url.path)
                        .font(.system(size: 10))
                        .foregroundColor(.primary.opacity(0.7))
                        .textSelection(.enabled)
                        .lineLimit(6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)

                Divider()
                    .padding(.horizontal, 12)

                // Permissions
                permissionsSection(file)

                // EXIF for images. Computed asynchronously in the .task
                // below — reading CGImageSource synchronously per body
                // re-render stalled the panel on RAW/HEIC files.
                if let exifInfo = imageMeta {
                    Divider()
                        .padding(.horizontal, 12)

                    exifSection(exifInfo)
                }

                // Media info for audio/video
                if let mediaInfo = mediaInfo {
                    Divider()
                        .padding(.horizontal, 12)

                    mediaSection(mediaInfo)
                }

                Spacer(minLength: 16)
            }
        }
        .task(id: selectedFile?.id) {
            guard let file = selectedFile else {
                previewImage = nil
                mediaInfo = nil
                imageMeta = nil
                permissions = nil
                return
            }

            // Permissions are cheap (3 access(2) syscalls) but were
            // previously executed inline from `body` — i.e. on every
            // selection change, hover, focus and observable mutation.
            // Refresh them here so they're computed once per selection.
            permissions = await Task.detached(priority: .userInitiated) {
                Self.computePermissions(at: file.url)
            }.value
            if Task.isCancelled { return }
            guard selectedFile?.id == file.id else { return }

            // Debounce rapid arrow-key navigation: if the user moves to
            // another item within ~120ms, the .task(id:) is cancelled here
            // and we never kick off the (relatively expensive) QuickLook +
            // AVAsset loads for the in-between selection. This eliminates
            // the panel flicker while holding Up/Down across many files.
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
            } catch {
                return
            }
            if Task.isCancelled { return }

            async let preview = loadPreview(for: file)
            async let media = mediaMetadata(for: file)
            // Image EXIF is read off-main: `CGImageSourceCreateWithURL`
            // touches the disk and on RAW/HEIC can take 50–500ms.
            async let imeta: ImageMetadata? = Task.detached(priority: .utility) {
                Self.imageMetadata(at: file.url)
            }.value
            let newPreview = await preview
            let newMedia = await media
            let newImageMeta = await imeta

            // Selection may have changed while we were loading; bail out
            // and let the next .task invocation populate the panel so we
            // don't briefly show stale data for the wrong file.
            if Task.isCancelled { return }
            guard selectedFile?.id == file.id else { return }

            // Only swap the preview once the new one is ready. Keeping the
            // previous image visible until then avoids the icon-fallback
            // flash that happened when we eagerly set previewImage = nil.
            previewImage = newPreview
            mediaInfo = newMedia
            imageMeta = newImageMeta
        }
        .onChange(of: selectedFile?.id) { _, _ in
            startFolderSizeIfNeeded()
        }
        .onAppear {
            startFolderSizeIfNeeded()
        }
        .onDisappear {
            folderSizeTask?.cancel()
            folderSizeTask = nil
        }
    }

    // MARK: - Folder size (async, cancellable)

    @ViewBuilder
    private var folderSizeRow: some View {
        if let size = folderSize {
            infoRow("Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        } else {
            HStack {
                Text("Size")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 58, alignment: .trailing)
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Kicks off (or cancels) folder-size enumeration when the selected
    /// item changes. The actual walk runs on a detached utility-priority
    /// Task so it never blocks the main actor or user actions, and is
    /// cancelled the moment the selection changes or the panel disappears.
    private func startFolderSizeIfNeeded() {
        // Always cancel any in-flight walk first.
        folderSizeTask?.cancel()
        folderSizeTask = nil

        guard let file = selectedFile, file.isDirectory else {
            folderSize = nil
            folderSizeTargetID = nil
            return
        }

        // If the selection is the same folder we already sized, keep it.
        if folderSizeTargetID == file.id, folderSize != nil { return }

        folderSize = nil
        folderSizeTargetID = file.id
        let url = file.url
        let targetID = file.id

        folderSizeTask = Task { @MainActor in
            let total = await Task.detached(priority: .utility) { () -> Int64 in
                Self.directorySize(at: url)
            }.value

            // Drop the result if the user moved on to a different item
            // while we were walking.
            guard !Task.isCancelled, folderSizeTargetID == targetID else { return }
            if total >= 0 { folderSize = total }
        }
    }

    /// Sums regular-file sizes under `url`. Returns -1 on cancellation.
    /// Uses `.fileAllocatedSize` when available (matches Finder's
    /// "On disk" measurement) and falls back to logical `.fileSize`.
    private nonisolated static func directorySize(at url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        let keySet = Set(keys)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        var checkCounter = 0
        while let next = enumerator.nextObject() as? URL {
            // Cancellation check every 256 entries keeps overhead low
            // while still aborting promptly on selection changes.
            checkCounter &+= 1
            if checkCounter & 0xFF == 0, Task.isCancelled { return -1 }

            guard let rv = try? next.resourceValues(forKeys: keySet) else { continue }
            guard rv.isRegularFile == true else { continue }
            if let allocated = rv.totalFileAllocatedSize ?? rv.fileAllocatedSize {
                total += Int64(allocated)
            } else if let size = rv.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Info Row

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 58, alignment: .trailing)
            Text(value)
                .font(.system(size: 10))
                .foregroundColor(.primary.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    // MARK: - Permissions

    private struct Permissions: Equatable {
        /// POSIX permission bits masked to 0o777 (owner/group/other rwx).
        var mode: mode_t
        var isHidden: Bool
        var isLocked: Bool
    }

    private nonisolated static func computePermissions(at url: URL) -> Permissions {
        let fm = FileManager.default
        let path = url.path
        let attrs = try? fm.attributesOfItem(atPath: path)
        let mode = (attrs?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        let locked = (attrs?[.immutable] as? NSNumber)?.boolValue ?? false
        let hidden = (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden ?? false
        return Permissions(mode: mode & 0o777, isHidden: hidden, isLocked: locked)
    }

    /// Writes the desired attributes to disk. Runs off the main actor.
    /// The user-immutable ("Locked") flag is cleared first so the other
    /// changes can be applied, then re-set last if requested.
    /// Returns a localized error string on failure, `nil` on success.
    private nonisolated static func writeAttributes(_ p: Permissions, at url: URL) -> String? {
        let fm = FileManager.default
        let path = url.path
        do {
            try fm.setAttributes([.immutable: false], ofItemAtPath: path)
            try fm.setAttributes([.posixPermissions: NSNumber(value: p.mode & 0o777)], ofItemAtPath: path)
            var mutableURL = url
            var rv = URLResourceValues()
            rv.isHidden = p.isHidden
            try mutableURL.setResourceValues(rv)
            if p.isLocked {
                try fm.setAttributes([.immutable: true], ofItemAtPath: path)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Optimistically updates the UI, writes the change to disk off-main,
    /// then re-reads the real on-disk state (reverting the UI on failure).
    private func applyAttributes(_ new: Permissions, to file: FileItem) {
        let url = file.url
        permissions = new
        attrError = nil
        Task { @MainActor in
            let err = await Task.detached(priority: .userInitiated) {
                Self.writeAttributes(new, at: url)
            }.value
            let actual = await Task.detached(priority: .userInitiated) {
                Self.computePermissions(at: url)
            }.value
            guard selectedFile?.id == file.id else { return }
            attrError = err
            permissions = actual
        }
    }

    private func bitBinding(_ file: FileItem, _ mask: mode_t) -> Binding<Bool> {
        Binding(
            get: { ((permissions?.mode ?? 0) & mask) != 0 },
            set: { on in
                guard var p = permissions else { return }
                if on { p.mode |= mask } else { p.mode &= ~mask }
                applyAttributes(p, to: file)
            }
        )
    }

    private func flagBinding(_ file: FileItem, _ keyPath: WritableKeyPath<Permissions, Bool>) -> Binding<Bool> {
        Binding(
            get: { permissions?[keyPath: keyPath] ?? false },
            set: { on in
                guard var p = permissions else { return }
                p[keyPath: keyPath] = on
                applyAttributes(p, to: file)
            }
        )
    }

    private func permissionsSection(_ file: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Permissions")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
            }

            // Column headers
            HStack(spacing: 0) {
                Text("")
                    .frame(width: 48, alignment: .leading)
                ForEach(["R", "W", "X"], id: \.self) { h in
                    Text(h)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 26)
                }
                Spacer(minLength: 0)
            }

            permRow(file, "Owner", read: 0o400, write: 0o200, exec: 0o100)
            permRow(file, "Group", read: 0o040, write: 0o020, exec: 0o010)
            permRow(file, "Other", read: 0o004, write: 0o002, exec: 0o001)

            Divider()
                .padding(.vertical, 2)

            Toggle(isOn: flagBinding(file, \.isHidden)) {
                Text("Hidden")
                    .font(.system(size: 10))
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)

            Toggle(isOn: flagBinding(file, \.isLocked)) {
                Text("Locked")
                    .font(.system(size: 10))
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)

            if let attrError {
                Text(attrError)
                    .font(.system(size: 9))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
    }

    private func permRow(_ file: FileItem, _ label: String, read: mode_t, write: mode_t, exec: mode_t) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.primary.opacity(0.8))
                .frame(width: 48, alignment: .leading)
            ForEach([read, write, exec], id: \.self) { mask in
                Toggle("", isOn: bitBinding(file, mask))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                    .frame(width: 26)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Helpers

    private func formattedBytes(_ bytes: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return (formatter.string(from: NSNumber(value: bytes)) ?? "\(bytes)") + " bytes"
    }

    private func formatFullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Image EXIF

    private struct ImageMetadata {
        var dimensions: String?
        var colorSpace: String?
        var dpi: String?
        var bitDepth: String?
        // EXIF
        var cameraMake: String?
        var cameraModel: String?
        var lens: String?
        var focalLength: String?
        var aperture: String?
        var shutterSpeed: String?
        var iso: String?
        var dateOriginal: String?
        var flash: String?
        var whiteBalance: String?
        // GPS
        var latitude: String?
        var longitude: String?
        var altitude: String?
    }

    private nonisolated static let imageMetadataExts: Set<String> = [
        "jpg", "jpeg", "png", "tiff", "tif", "heic", "heif", "gif", "bmp",
        "webp", "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2"
    ]

    /// Synchronously reads image metadata via `CGImageSource`. Must be
    /// called off the main actor \u2014 on RAW/HEIC files the property
    /// decode performs real disk I/O and can take 50\u2013500ms.
    private nonisolated static func imageMetadata(at url: URL) -> ImageMetadata? {
        let ext = url.pathExtension.lowercased()
        guard imageMetadataExts.contains(ext) else { return nil }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }

        var meta = ImageMetadata()

        // Dimensions
        if let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            meta.dimensions = "\(w) × \(h)"
        }

        // Color space
        if let cs = props[kCGImagePropertyColorModel] as? String {
            meta.colorSpace = cs
        }

        // DPI
        if let dpiX = props[kCGImagePropertyDPIWidth] as? Double {
            meta.dpi = "\(Int(dpiX))"
        }

        // Bit depth
        if let depth = props[kCGImagePropertyDepth] as? Int {
            meta.bitDepth = "\(depth) bit"
        }

        // EXIF dictionary
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let make = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                meta.cameraMake = make[kCGImagePropertyTIFFMake] as? String
                meta.cameraModel = make[kCGImagePropertyTIFFModel] as? String
            }

            if let lens = exif[kCGImagePropertyExifLensModel] as? String {
                meta.lens = lens
            }

            if let fl = exif[kCGImagePropertyExifFocalLength] as? Double {
                meta.focalLength = "\(Int(fl)) mm"
            }

            if let ap = exif[kCGImagePropertyExifFNumber] as? Double {
                meta.aperture = String(format: "f/%.1f", ap)
            }

            if let ss = exif[kCGImagePropertyExifExposureTime] as? Double {
                if ss >= 1 {
                    meta.shutterSpeed = String(format: "%.1f s", ss)
                } else {
                    meta.shutterSpeed = "1/\(Int(1.0 / ss)) s"
                }
            }

            if let isoArr = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso = isoArr.first {
                meta.iso = "ISO \(iso)"
            }

            if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                meta.dateOriginal = date
            }

            if let flash = exif[kCGImagePropertyExifFlash] as? Int {
                meta.flash = (flash & 1) == 1 ? "Fired" : "Off"
            }

            if let wb = exif[kCGImagePropertyExifWhiteBalance] as? Int {
                meta.whiteBalance = wb == 0 ? "Auto" : "Manual"
            }
        } else {
            // Try TIFF dict for make/model even without EXIF
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                meta.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String
                meta.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
            }
        }

        // GPS
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            if let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
               let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String {
                meta.latitude = String(format: "%.6f° %@", lat, latRef)
            }
            if let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
               let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String {
                meta.longitude = String(format: "%.6f° %@", lon, lonRef)
            }
            if let alt = gps[kCGImagePropertyGPSAltitude] as? Double {
                meta.altitude = String(format: "%.1f m", alt)
            }
        }

        return meta
    }

    private func exifSection(_ meta: ImageMetadata) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("Image")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
            }

            if let d = meta.dimensions { infoRow("Size", d) }
            if let cs = meta.colorSpace { infoRow("Color", cs) }
            if let dpi = meta.dpi { infoRow("DPI", dpi) }
            if let bd = meta.bitDepth { infoRow("Depth", bd) }

            if meta.cameraMake != nil || meta.cameraModel != nil || meta.aperture != nil {
                Divider()

                HStack {
                    Text("Camera")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }

                if let make = meta.cameraMake { infoRow("Make", make) }
                if let model = meta.cameraModel { infoRow("Model", model) }
                if let lens = meta.lens { infoRow("Lens", lens) }
                if let fl = meta.focalLength { infoRow("Focal", fl) }
                if let ap = meta.aperture { infoRow("Aperture", ap) }
                if let ss = meta.shutterSpeed { infoRow("Shutter", ss) }
                if let iso = meta.iso { infoRow("ISO", iso) }
                if let flash = meta.flash { infoRow("Flash", flash) }
                if let wb = meta.whiteBalance { infoRow("WB", wb) }
                if let date = meta.dateOriginal { infoRow("Taken", date) }
            }

            if meta.latitude != nil || meta.longitude != nil {
                Divider()

                HStack {
                    Text("Location")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }

                if let lat = meta.latitude { infoRow("Lat", lat) }
                if let lon = meta.longitude { infoRow("Lon", lon) }
                if let alt = meta.altitude { infoRow("Alt", alt) }
            }

            if let file = selectedFile, file.isEditableImage {
                Divider()
                HStack(spacing: 6) {
                    Button {
                        appState.metadataEditorTargets = [file.url]
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                            Text("Edit\u{2026}")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .help("Edit writable EXIF/IPTC fields")

                    Button {
                        appState.activeExplorer.selectedFileIDs = [file.id]
                        appState.stripPrivacyMetadata()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "location.slash")
                            Text("Strip")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .help("Remove GPS, serial number, user comment")
                }
            }

            if let file = selectedFile, file.isReadableMedia {
                Divider()
                Button {
                    appState.mediaMetadataEditorTargets = [file.url]
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "music.note.list")
                        Text("Edit Tags\u{2026}")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .help(file.isEditableMedia
                      ? "Edit audio/video tag metadata"
                      : "View tags (read-only for .\(file.url.pathExtension))")
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Preview Thumbnail

    private static let previewableImageExts: Set<String> = [
        "jpg", "jpeg", "png", "tiff", "tif", "heic", "heif", "gif",
        "bmp", "webp", "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2"
    ]

    private static let previewableMediaExts: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm", "ts", "mpg", "mpeg",
        "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "wma", "opus", "alac"
    ]

    private func loadPreview(for file: FileItem) async -> NSImage? {
        guard !file.isDirectory else { return nil }
        let ext = file.url.pathExtension.lowercased()
        guard Self.previewableImageExts.contains(ext)
                || Self.previewableMediaExts.contains(ext) else { return nil }

        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        let size = CGSize(width: 196, height: 196)
        let request = QLThumbnailGenerator.Request(
            fileAt: file.url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )

        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.nsImage)
            }
        }
    }

    // MARK: - Media Metadata

    private struct MediaInfo {
        var duration: String?
        // Video
        var videoCodec: String?
        var resolution: String?
        var frameRate: String?
        var videoBitrate: String?
        // Audio
        var audioCodec: String?
        var sampleRate: String?
        var channels: String?
        var audioBitrate: String?
        // Common
        var title: String?
        var artist: String?
        var album: String?
        var genre: String?
        var year: String?
    }

    private func mediaMetadata(for file: FileItem) async -> MediaInfo? {
        guard !file.isDirectory else { return nil }
        let ext = file.url.pathExtension.lowercased()
        let mediaExts = [
            "mp4", "mov", "m4v", "avi", "mkv", "mka", "webm", "wmv", "flv", "ts", "mpg", "mpeg",
            "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "wma", "opus", "alac",
            "dsf", "dff"
        ]
        guard mediaExts.contains(ext) else { return nil }

        // DSF/DFF can't be opened by AVFoundation — go through the native
        // parsers (TechnicalInfoService) so we get sample rate, channels,
        // and DSD rate. Same for FLAC, but FLAC also has AVAsset support
        // so we fall back to AV for the duration/tag pass below.
        if ext == "dsf" || ext == "dff" {
            return nativeMediaInfo(for: file.url, ext: ext)
        }

        let asset = AVURLAsset(url: file.url)
        var meta = MediaInfo()

        // Duration
        if let cmDuration = try? await asset.load(.duration) {
            let dur = CMTimeGetSeconds(cmDuration)
            if dur.isFinite && dur > 0 {
                let h = Int(dur) / 3600
                let m = (Int(dur) % 3600) / 60
                let s = Int(dur) % 60
                if h > 0 {
                    meta.duration = String(format: "%d:%02d:%02d", h, m, s)
                } else {
                    meta.duration = String(format: "%d:%02d", m, s)
                }
            }
        }

        // Video tracks
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        if let vt = videoTracks.first {
            let size = try? await vt.load(.naturalSize)
            let transform = try? await vt.load(.preferredTransform)
            if let size, let transform {
                let transformed = size.applying(transform)
                let w = Int(abs(transformed.width))
                let h = Int(abs(transformed.height))
                if w > 0 && h > 0 {
                    meta.resolution = "\(w) × \(h)"
                }
            }

            if let rate = try? await vt.load(.nominalFrameRate), rate > 0 {
                meta.frameRate = String(format: "%.2f fps", rate)
            }

            if let dataRate = try? await vt.load(.estimatedDataRate), dataRate > 0 {
                let mbps = dataRate / 1_000_000
                if mbps >= 1 {
                    meta.videoBitrate = String(format: "%.1f Mbps", mbps)
                } else {
                    meta.videoBitrate = String(format: "%.0f kbps", dataRate / 1000)
                }
            }

            if let descs = try? await vt.load(.formatDescriptions) {
                for desc in descs {
                    let codec = CMFormatDescriptionGetMediaSubType(desc)
                    meta.videoCodec = fourCCToString(codec)
                    break
                }
            }
        }

        // Audio tracks
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        if let at = audioTracks.first {
            if let dataRate = try? await at.load(.estimatedDataRate), dataRate > 0 {
                meta.audioBitrate = String(format: "%.0f kbps", dataRate / 1000)
            }

            if let descs = try? await at.load(.formatDescriptions) {
                for desc in descs {
                    let codec = CMFormatDescriptionGetMediaSubType(desc)
                    meta.audioCodec = fourCCToString(codec)

                    if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                        if asbd.mSampleRate > 0 {
                            let khz = asbd.mSampleRate / 1000
                            meta.sampleRate = String(format: "%.1f kHz", khz)
                        }
                        if asbd.mChannelsPerFrame > 0 {
                            switch asbd.mChannelsPerFrame {
                            case 1: meta.channels = "Mono"
                            case 2: meta.channels = "Stereo"
                            case 6: meta.channels = "5.1"
                            case 8: meta.channels = "7.1"
                            default: meta.channels = "\(asbd.mChannelsPerFrame) ch"
                            }
                        }
                    }
                    break
                }
            }
        }

        // Common metadata (title, artist, album, etc.)
        let commonMetadata = (try? await asset.load(.commonMetadata)) ?? []
        for item in commonMetadata {
            guard let key = item.commonKey else { continue }
            let val = try? await item.load(.stringValue)
            switch key {
            case .commonKeyTitle: meta.title = val
            case .commonKeyArtist: meta.artist = val
            case .commonKeyAlbumName: meta.album = val
            case .commonKeyCreationDate: meta.year = val
            default: break
            }
        }

        // Genre from iTunes metadata
        let itunesMetadata = (try? await asset.load(.metadata)) ?? []
        let filtered = AVMetadataItem.metadataItems(from: itunesMetadata, filteredByIdentifier: .iTunesMetadataUserGenre)
        if let genreItem = filtered.first {
            meta.genre = try? await genreItem.load(.stringValue)
        }

        return meta
    }

    private func fourCCToString(_ code: FourCharCode) -> String {
        let chars = [
            Character(UnicodeScalar((code >> 24) & 0xFF)!),
            Character(UnicodeScalar((code >> 16) & 0xFF)!),
            Character(UnicodeScalar((code >> 8) & 0xFF)!),
            Character(UnicodeScalar(code & 0xFF)!),
        ]
        let raw = String(chars).trimmingCharacters(in: .whitespaces)
        // Map common codes to readable names
        switch raw {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "H.265 (HEVC)"
        case "mp4v": return "MPEG-4"
        case "ap4h", "ap4x": return "ProRes 4444"
        case "apch": return "ProRes 422 HQ"
        case "apcn": return "ProRes 422"
        case "apcs": return "ProRes 422 LT"
        case "apco": return "ProRes 422 Proxy"
        case "aac ": return "AAC"
        case "mp4a": return "AAC"
        case "alac": return "ALAC"
        case ".mp3": return "MP3"
        case "lpcm": return "LPCM"
        case "ac-3": return "AC-3"
        case "ec-3": return "E-AC-3"
        case "fLaC": return "FLAC"
        case "opus": return "Opus"
        default: return raw
        }
    }

    /// Build a `MediaInfo` from the native parser for formats AVFoundation
    /// can't open (DSF, DFF). Uses `TechnicalInfoService` so we report the
    /// correct DSD rate, channel count, and bit depth.
    private func nativeMediaInfo(for url: URL, ext: String) -> MediaInfo? {
        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        let tech: MediaTechnicalInfo
        switch ext {
        case "dsf":
            guard let file = try? DSFFile.read(url) else { return nil }
            tech = TechnicalInfoService.finalize(
                TechnicalInfoService.from(dsf: file, fileSize: fileSize))
        case "dff":
            guard let file = try? DFFFile.read(url) else { return nil }
            tech = TechnicalInfoService.finalize(
                TechnicalInfoService.from(dff: file, fileSize: fileSize))
        default:
            return nil
        }

        var meta = MediaInfo()
        if let s = tech.durationSeconds, s > 0 {
            let total = Int(s)
            let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
            meta.duration = h > 0
                ? String(format: "%d:%02d:%02d", h, m, sec)
                : String(format: "%d:%02d", m, sec)
        }
        meta.audioCodec = tech.codec
        if let rate = tech.sampleRate, rate > 0 {
            // DSD rates (2.8M, 5.6M, 11.2M) read nicer as DSDxxx labels.
            if tech.isDSD {
                let dsdMultiple = Int((rate / 44_100).rounded())
                if dsdMultiple > 0 {
                    meta.sampleRate = "DSD\(dsdMultiple) (\(String(format: "%.1f", rate / 1_000_000)) MHz)"
                } else {
                    meta.sampleRate = String(format: "%.1f MHz", rate / 1_000_000)
                }
            } else {
                meta.sampleRate = String(format: "%.1f kHz", rate / 1000)
            }
        }
        if let ch = tech.channels, ch > 0 {
            switch ch {
            case 1: meta.channels = "Mono"
            case 2: meta.channels = "Stereo"
            case 6: meta.channels = "5.1"
            case 8: meta.channels = "7.1"
            default: meta.channels = "\(ch) ch"
            }
        }
        if let br = tech.bitrate, br > 0 {
            let mbps = br / 1_000_000
            meta.audioBitrate = mbps >= 1
                ? String(format: "%.1f Mbps", mbps)
                : String(format: "%.0f kbps", br / 1000)
        }
        // Pull tags via the same service so DSF/DFF show TITLE/ARTIST/etc.
        if let tags = try? MediaMetadataService.read(url) {
            meta.title  = tags.first("TITLE")
            meta.artist = tags.first("ARTIST")
            meta.album  = tags.first("ALBUM")
            meta.genre  = tags.first("GENRE")
            meta.year   = tags.first("DATE") ?? tags.first("YEAR")
        }
        return meta
    }

    private func mediaSection(_ meta: MediaInfo) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("Media")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
            }

            if let d = meta.duration { infoRow("Duration", d) }

            // Video
            if meta.resolution != nil || meta.videoCodec != nil {
                if let codec = meta.videoCodec { infoRow("Video", codec) }
                if let res = meta.resolution { infoRow("Size", res) }
                if let fps = meta.frameRate { infoRow("FPS", fps) }
                if let br = meta.videoBitrate { infoRow("Bitrate", br) }
            }

            // Audio
            if meta.audioCodec != nil || meta.sampleRate != nil {
                if meta.resolution != nil { Divider() }

                if let codec = meta.audioCodec { infoRow("Audio", codec) }
                if let sr = meta.sampleRate { infoRow("Sample", sr) }
                if let ch = meta.channels { infoRow("Channels", ch) }
                if let br = meta.audioBitrate { infoRow("Bitrate", br) }
            }

            // Tags
            if meta.title != nil || meta.artist != nil || meta.album != nil {
                Divider()

                HStack {
                    Text("Tags")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }

                if let t = meta.title { infoRow("Title", t) }
                if let a = meta.artist { infoRow("Artist", a) }
                if let al = meta.album { infoRow("Album", al) }
                if let g = meta.genre { infoRow("Genre", g) }
                if let y = meta.year { infoRow("Year", y) }
            }
        }
        .padding(.horizontal, 12)
    }
}
