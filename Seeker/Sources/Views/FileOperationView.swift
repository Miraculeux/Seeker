import SwiftUI

// MARK: - Compact Progress Indicator (shown in toolbar)

struct FileOperationCompactView: View {
    let manager = FileOperationManager.shared
    @State private var isExpanded = false

    var body: some View {
        if manager.hasActiveOperations || manager.operations.contains(where: { $0.error != nil }) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    if let op = manager.activeOperations.first {
                        // Spinning indicator
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)

                        // Brief text
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(op.kind.rawValue) \(op.filesTotal) item\(op.filesTotal == 1 ? "" : "s")")
                                .font(.system(size: 9, weight: .medium))
                                .lineLimit(1)

                            HStack(spacing: 3) {
                                Text(op.formattedSpeed)
                                Text("·")
                                Text(op.formattedTimeRemaining)
                            }
                            .font(.system(size: 8, design: .rounded))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        }

                        // Mini progress bar
                        ProgressView(value: op.progress)
                            .frame(width: 60)
                            .controlSize(.small)
                    } else if let errOp = manager.operations.first(where: { $0.error != nil }) {
                        let _ = errOp  // referenced for body dependency only
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                        Text("Failed")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.orange)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isExpanded, arrowEdge: .bottom) {
                FileOperationExpandedView()
                    .frame(width: 340)
            }
        }
    }

    private func scheduleErrorDismissal(_ op: FileOperation) -> Bool {
        // Deprecated: the manager now schedules error auto-dismissal in
        // `cleanupFinished`. Kept as a no-op shim to avoid breaking call
        // sites that may still reference it; do not invoke from `body`.
        _ = op
        return true
    }
}

// MARK: - Expanded Progress View (popover)

struct FileOperationExpandedView: View {
    let manager = FileOperationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("File Operations")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(manager.operations.count) operation\(manager.operations.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Queue controls: pause/resume + throughput limit
            HStack(spacing: 8) {
                Button {
                    manager.togglePause()
                } label: {
                    Label(manager.isPaused ? "Resume" : "Pause",
                          systemImage: manager.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!manager.hasActiveOperations)

                if manager.queuedCount > 0 {
                    Text("\(manager.queuedCount) queued")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Menu {
                    Button("Unlimited") { manager.throttleBytesPerSecond = nil }
                    Button("100 MB/s") { manager.throttleBytesPerSecond = 100 * 1_000_000 }
                    Button("50 MB/s") { manager.throttleBytesPerSecond = 50 * 1_000_000 }
                    Button("10 MB/s") { manager.throttleBytesPerSecond = 10 * 1_000_000 }
                    Button("1 MB/s") { manager.throttleBytesPerSecond = 1_000_000 }
                } label: {
                    Label(limitLabel, systemImage: "speedometer")
                        .font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            if manager.isPaused {
                Text("Paused")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            Divider()

            // Operations list
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(manager.operations) { op in
                        FileOperationRowView(operation: op)
                    }
                }
            }
            .frame(maxHeight: 300)

            if manager.activeOperations.count > 1 {
                Divider()
                // Overall summary
                HStack {
                    Text("\(manager.activeOperations.count) active operations")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Cancel All") {
                        manager.activeOperations.forEach { $0.cancel() }
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .padding(.bottom, 4)
    }

    private var limitLabel: String {
        guard let limit = manager.throttleBytesPerSecond else { return "Unlimited" }
        return ByteCountFormatter.string(fromByteCount: limit, countStyle: .file) + "/s"
    }
}

// MARK: - Single Operation Row

struct FileOperationRowView: View {
    @Bindable var operation: FileOperation
    @State private var isExpanded = false

    private var canExpand: Bool {
        // Only meaningful while the op is live and there's more than one
        // top-level item — otherwise the per-item list adds no info.
        !operation.isFinished && !operation.isCancelled && operation.sourceURLs.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title row
            HStack {
                if canExpand {
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10)
                    }
                    .buttonStyle(.plain)
                }

                Image(systemName: operation.kind == .copy ? "doc.on.doc" : "arrow.right.doc.on.clipboard")
                    .font(.system(size: 10))
                    .foregroundColor(.accentColor)

                Text("\(operation.kind.rawValue) \(operation.filesTotal) item\(operation.filesTotal == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium))

                Spacer()

                if operation.isFinished {
                    if operation.error != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 10))
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 10))
                    }
                } else if !operation.isCancelled {
                    Button {
                        operation.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let error = operation.error {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                    .lineLimit(2)
            } else if !operation.isFinished && !operation.isCancelled {
                // Progress bar
                ProgressView(value: operation.progress)
                    .controlSize(.small)

                // Details row
                HStack(spacing: 0) {
                    Text(operation.currentFile)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("\(operation.formattedCopiedSize) / \(operation.formattedTotalSize)")

                    Text("  ·  ")

                    Text(operation.formattedSpeed)

                    Text("  ·  ")

                    Text(operation.formattedTimeRemaining)
                }
                .font(.system(size: 9, design: .rounded))
                .foregroundColor(.secondary)

                if isExpanded && canExpand {
                    FileOperationItemList(operation: operation)
                } else {
                    // File count
                    Text("\(operation.filesCompleted) of \(operation.filesTotal) files")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            } else if operation.isFinished && operation.error == nil {
                Text("Completed — \(operation.formattedTotalSize)")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            } else if operation.isCancelled {
                Text("Cancelled")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.02))
    }
}

// MARK: - Per-Item Pending List

/// Lists every top-level source item the operation is processing, with a
/// per-item status indicator (done / in-progress / pending). Lets the
/// user see exactly which items remain instead of just "N of M files".
private struct FileOperationItemList: View {
    @Bindable var operation: FileOperation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(operation.filesCompleted) of \(operation.filesTotal) items")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(operation.sourceURLs.count - operation.filesCompleted) remaining")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.top, 2)
            .padding(.bottom, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(operation.sourceURLs.enumerated()), id: \.offset) { index, url in
                        FileOperationItemRow(
                            url: url,
                            status: status(for: index)
                        )
                    }
                }
            }
            .frame(maxHeight: 140)
        }
    }

    private func status(for index: Int) -> FileOperationItemRow.Status {
        if index < operation.filesCompleted { return .done }
        if index == operation.filesCompleted { return .inProgress }
        return .pending
    }
}

private struct FileOperationItemRow: View {
    enum Status { case done, inProgress, pending }
    let url: URL
    let status: Status

    var body: some View {
        HStack(spacing: 6) {
            statusIcon
                .frame(width: 10, height: 10)

            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .foregroundColor(status == .pending ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9))
                .foregroundColor(.green)
        case .inProgress:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.6)
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.5))
        }
    }
}
