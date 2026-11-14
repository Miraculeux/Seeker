import AppKit

@MainActor
enum FilePromiseImport {
    struct Outcome: Sendable {
        var urls: [URL] = []
        var errors: [String] = []
    }

    @MainActor
    private final class Batch {
        let receivers: [NSFilePromiseReceiver]
        let destination: URL
        let queue = OperationQueue()
        let completion: @MainActor (Outcome) -> Void
        var remaining = 0
        var outcome = Outcome()

        init(receivers: [NSFilePromiseReceiver], destination: URL,
             completion: @escaping @MainActor (Outcome) -> Void) {
            self.receivers = receivers
            self.destination = destination
            self.completion = completion
            queue.name = "Seeker.ReceiveFilePromises"
        }

        func start() {
            for receiver in receivers {
                receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue) { url, error in
                    Task { @MainActor in
                        if let error {
                            self.outcome.errors.append(error.localizedDescription)
                        } else if url.isFileURL,
                                  url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
                                    == self.destination.standardizedFileURL.resolvingSymlinksInPath().path {
                            self.outcome.urls.append(url)
                        } else {
                            self.outcome.errors.append("A promised file was delivered outside the receiving directory.")
                        }
                        self.remaining -= 1
                        if self.remaining == 0 { self.completion(self.outcome) }
                    }
                }
                // Legacy promises can deliver multiple files. Names are populated
                // only after receivePromisedFiles has called in the promise.
                remaining += max(1, receiver.fileNames.count)
            }
        }
    }

    static func receive(
        _ receivers: [NSFilePromiseReceiver], into destination: URL,
        completion: @escaping @MainActor (Outcome) -> Void
    ) {
        guard !receivers.isEmpty else {
            completion(Outcome(errors: ["The drop did not contain a readable file promise."]))
            return
        }
        // AppKit requires calling in promises synchronously during the drop.
        // Only their reader callbacks may run after performDragOperation returns.
        Batch(receivers: receivers, destination: destination, completion: completion).start()
    }
}
