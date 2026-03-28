import SwiftUI
import UniformTypeIdentifiers

struct FileInfoView: View {
    @Environment(AppState.self) var appState

    private var selectedFile: FileItem? {
        appState.activeExplorer.selectedFile
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

            if let file = selectedFile {
                fileInfoContent(file)
            } else {
                noSelection
            }
        }
        .frame(width: 220)
        .background(.background)
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

    // MARK: - File Info Content

    private func fileInfoContent(_ file: FileItem) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                // Icon + Name
                VStack(spacing: 8) {
                    Image(nsImage: file.nsIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)

                    Text(file.name)
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

                Spacer(minLength: 16)
            }
        }
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

    private func permissionsSection(_ file: FileItem) -> some View {
        let fm = FileManager.default
        let path = file.url.path
        let readable = fm.isReadableFile(atPath: path)
        let writable = fm.isWritableFile(atPath: path)
        let executable = fm.isExecutableFile(atPath: path)

        return VStack(spacing: 6) {
            HStack {
                Text("Permissions")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
            }

            HStack(spacing: 8) {
                permBadge("R", active: readable)
                permBadge("W", active: writable)
                permBadge("X", active: executable)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
    }

    private func permBadge(_ letter: String, active: Bool) -> some View {
        Text(letter)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(active ? .white : .secondary.opacity(0.5))
            .frame(width: 22, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(active ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.06))
            )
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
}
