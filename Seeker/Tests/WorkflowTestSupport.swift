import Foundation
import XCTest
@testable import Seeker

/// All writes stay inside a unique disposable directory on the repository volume.
struct WorkflowFixture {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".workflow-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    @discardableResult
    func directory(_ path: String) throws -> URL {
        let target = url(path)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    @discardableResult
    func write(_ path: String, _ contents: String, mtime: TimeInterval = 1_700_000_000) throws -> URL {
        let target = url(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: target)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)],
                                             ofItemAtPath: target.path)
        return target
    }

    func contents(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }

    func cleanup(file: StaticString = #filePath, line: UInt = #line) {
        do { try FileManager.default.removeItem(at: root) }
        catch { XCTFail("Fixture cleanup failed: \(error)", file: file, line: line) }
    }
}

@MainActor
func waitForWorkflow(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw NSError(domain: "WorkflowTests.Timeout", code: 1)
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
func completeWorkflowOperation(_ operation: FileOperation) async throws {
    do {
        try await waitForWorkflow { operation.isFinished }
        await operation.task?.value
    } catch {
        operation.cancel()
        await operation.task?.value
        throw error
    }
}
