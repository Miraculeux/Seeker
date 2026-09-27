import Foundation
import XCTest
@testable import Seeker

final class ApplicationAttributesTests: XCTestCase {
    func testEligibilityRequiresOnlyApplicationBundles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app")
        let folder = root.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let appItem = FileItem(url: app)
        XCTAssertTrue(ApplicationAttributes.canClear([appItem]))
        XCTAssertFalse(ApplicationAttributes.canClear([]))
        XCTAssertFalse(ApplicationAttributes.canClear([FileItem(url: folder)]))
        XCTAssertFalse(ApplicationAttributes.canClear([appItem, FileItem(url: folder)]))
    }

    func testValidationRejectsEmptyMissingNonAppFileAndSymlinkTargets() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app")
        let folder = root.appendingPathComponent("Applications")
        let file = root.appendingPathComponent("File.app")
        let link = root.appendingPathComponent("Link.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data().write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        XCTAssertEqual(try ApplicationAttributes.validatedPaths(for: [app]), [app.path])
        for urls in [[], [folder], [file], [link], [root.appendingPathComponent("Missing.app")],
                     [app, folder], [URL(string: "https://example.com/Example.app")!]] {
            XCTAssertThrowsError(try ApplicationAttributes.validatedPaths(for: urls))
        }
    }

    func testRecursiveClearingQuotesPathsAndPreservesUnselectedAppsAndLinkTargets() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Quotes ' \" \\ $HOME `id` $(id);\n.app")
        let second = root.appendingPathComponent("Second App.app")
        let untouched = root.appendingPathComponent("Unselected.app")
        let child = app.appendingPathComponent("Contents/nested/payload")
        try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: untouched, withIntermediateDirectories: false)
        try Data("payload".utf8).write(to: child)
        let external = root.appendingPathComponent("external")
        try Data("external payload".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: app.appendingPathComponent("external-link"), withDestinationURL: external
        )
        let attribute = "com.seeker.attribute-test"
        for url in [app, child, second, untouched, external] {
            let result = try run("/usr/bin/xattr", ["-w", attribute, "retained", url.path])
            XCTAssertEqual(result.status, 0, result.output)
        }
        // Exercise the production script and real xattr, but never request
        // administrator privileges or touch installed apps in regression tests.
        let script = ApplicationAttributes.script.replacingOccurrences(
            of: " with administrator privileges", with: ""
        )
        let paths = try ApplicationAttributes.validatedPaths(for: [app, second])
        let result = try run("/usr/bin/osascript", ["-e", script] + paths)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "cleared")
        for url in [app, child, second] {
            let attributes = try run("/usr/bin/xattr", [url.path])
            XCTAssertEqual(attributes.status, 0, attributes.output)
            XCTAssertEqual(attributes.output, "")
        }
        for url in [untouched, external] {
            let attributeValue = try run("/usr/bin/xattr", ["-p", attribute, url.path])
            XCTAssertEqual(attributeValue.status, 0, attributeValue.output)
            XCTAssertEqual(attributeValue.output, "retained")
        }
        XCTAssertEqual(try Data(contentsOf: child), Data("payload".utf8))
        XCTAssertEqual(try Data(contentsOf: external), Data("external payload".utf8))
    }

    func testScriptDistinguishesAuthorizationCancellationFromFailure() throws {
        let command = "do shell script shellCommand with administrator privileges"
        let cancelled = ApplicationAttributes.script.replacingOccurrences(
            of: command, with: "error number -128"
        )
        let cancellation = try run("/usr/bin/osascript", ["-e", cancelled])
        XCTAssertEqual(cancellation.status, 0, cancellation.output)
        XCTAssertEqual(cancellation.output, "cancelled")
        let failed = ApplicationAttributes.script.replacingOccurrences(
            of: command, with: "error \"Synthetic failure\" number 42"
        )
        let failure = try run("/usr/bin/osascript", ["-e", failed])
        XCTAssertNotEqual(failure.status, 0)
        XCTAssertTrue(failure.output.contains("Synthetic failure"))
    }

    @MainActor
    func testInvalidSelectionReportsErrorWithoutStartingMutation() {
        let model = FileExplorerViewModel(url: FileManager.default.temporaryDirectory)
        defer { model.cancelLoading() }
        model.clearApplicationAttributes([])
        XCTAssertTrue(model.showError)
        XCTAssertEqual(model.errorMessage, "Select one or more application bundles.")
        XCTAssertNil(model.fileMutationStatus)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeekerAttributes-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
