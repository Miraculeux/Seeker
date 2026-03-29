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
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                        Text("Failed")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.orange)
                        let _ = scheduleErrorDismissal(errOp)
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
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            FileOperationManager.shared.operations.removeAll { $0.id == op.id }
        }
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
}

// MARK: - Single Operation Row

struct FileOperationRowView: View {
    @Bindable var operation: FileOperation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title row
            HStack {
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

                // File count
                Text("\(operation.filesCompleted) of \(operation.filesTotal) files")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.7))
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
