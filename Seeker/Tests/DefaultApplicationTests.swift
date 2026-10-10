import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Seeker

@MainActor
final class DefaultApplicationTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let suiteName = "SeekerTests.DefaultApplication.\(UUID().uuidString)"
        let defaults: UserDefaults
        let original = URL(fileURLWithPath: "/Applications/Original.app")
        let chosen = URL(fileURLWithPath: "/Applications/Chosen.app")
        var handlers: [String: URL] = [:]
        var calls: [(URL, UTType)] = []
        var failure: NSError?
        var applyChanges = true

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            handlers[UTType.jpeg.identifier] = original
        }

        func manager() -> SettingsManager {
            SettingsManager(
                defaults: defaults,
                applicationForType: { self.handlers[$0.identifier] },
                setApplicationForType: { url, type in
                    self.calls.append((url, type))
                    if let failure = self.failure { throw failure }
                    if self.applyChanges { self.handlers[type.identifier] = url }
                }
            )
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    func testChangesSystemHandlerAndPersistsOnlyAfterSuccess() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager()

        try await manager.setDefaultApp(fixture.chosen, forExtension: "JPG")

        XCTAssertEqual(fixture.calls.count, 1)
        XCTAssertEqual(fixture.calls.first?.1, .jpeg)
        XCTAssertEqual(fixture.handlers[UTType.jpeg.identifier], fixture.chosen)
        XCTAssertEqual(manager.defaultAppPathsByExtension, ["jpg": fixture.chosen.path])
        XCTAssertEqual(manager.defaultApp(forExtension: "jpg"), fixture.chosen)
    }

    func testRemovalRestoresOriginalAcrossChangesAliasesAndReload() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager()
        try await manager.setDefaultApp(fixture.chosen, forExtension: "jpg")
        let replacement = URL(fileURLWithPath: "/Applications/Replacement.app")
        try await manager.setDefaultApp(replacement, forExtension: "jpeg")
        XCTAssertEqual(manager.defaultAppPathsByExtension["jpg"], replacement.path)

        let reloaded = fixture.manager()
        try await reloaded.setDefaultApp(nil, forExtension: "jpg")

        XCTAssertEqual(fixture.handlers[UTType.jpeg.identifier], fixture.original)
        XCTAssertTrue(reloaded.defaultAppPathsByExtension.isEmpty)
        XCTAssertEqual(fixture.calls.count, 3)
    }

    func testSystemFailureDoesNotSaveNewChoiceOrLosePreviousRecord() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager()
        fixture.failure = NSError(domain: "DefaultApplicationTests", code: 1)

        do {
            try await manager.setDefaultApp(fixture.chosen, forExtension: "jpg")
            XCTFail("Expected the system error")
        } catch {
            XCTAssertEqual((error as NSError).domain, "DefaultApplicationTests")
        }
        XCTAssertTrue(manager.defaultAppPathsByExtension.isEmpty)

        fixture.failure = nil
        try await manager.setDefaultApp(fixture.chosen, forExtension: "jpg")
        fixture.failure = NSError(domain: "DefaultApplicationTests", code: 2)
        do {
            try await manager.setDefaultApp(nil, forExtension: "jpg")
            XCTFail("Expected restoration to fail")
        } catch {
            XCTAssertEqual((error as NSError).code, 2)
        }
        XCTAssertEqual(manager.defaultAppPathsByExtension["jpg"], fixture.chosen.path)
        fixture.failure = nil
        try await fixture.manager().setDefaultApp(nil, forExtension: "jpg")
        XCTAssertEqual(fixture.handlers[UTType.jpeg.identifier], fixture.original)
    }

    func testUnappliedSystemChangeIsReportedAndNotPersisted() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.applyChanges = false
        let manager = fixture.manager()

        do {
            try await manager.setDefaultApp(fixture.chosen, forExtension: "jpg")
            XCTFail("Expected verification failure")
        } catch SettingsManager.DefaultAppError.verificationFailed {
            XCTAssertTrue(manager.defaultAppPathsByExtension.isEmpty)
        }
    }

    func testRemovalPreservesNewerFinderChoice() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager()
        try await manager.setDefaultApp(fixture.chosen, forExtension: "jpg")
        let external = URL(fileURLWithPath: "/Applications/FinderChoice.app")
        fixture.handlers[UTType.jpeg.identifier] = external

        XCTAssertEqual(manager.defaultApp(forExtension: "jpg"), external)
        try await manager.setDefaultApp(nil, forExtension: "jpg")

        XCTAssertEqual(fixture.handlers[UTType.jpeg.identifier], external)
        XCTAssertEqual(fixture.calls.count, 1)
        XCTAssertTrue(manager.defaultAppPathsByExtension.isEmpty)
    }

    func testLegacyRemovalDoesNotChangeSystemHandler() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager()
        manager.defaultAppPathsByExtension = ["jpg": fixture.chosen.path]

        XCTAssertEqual(manager.defaultApp(forExtension: "jpg"), fixture.original)
        try await manager.setDefaultApp(nil, forExtension: "jpg")

        XCTAssertTrue(fixture.calls.isEmpty)
        XCTAssertTrue(manager.defaultAppPathsByExtension.isEmpty)
    }

    func testRemovalRestoresOriginalWhenChosenHandlerIsNoLongerAvailable() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager()
        try await manager.setDefaultApp(fixture.chosen, forExtension: "jpg")
        fixture.handlers.removeAll()

        try await manager.setDefaultApp(nil, forExtension: "jpg")

        XCTAssertEqual(fixture.handlers[UTType.jpeg.identifier], fixture.original)
        XCTAssertTrue(manager.defaultAppPathsByExtension.isEmpty)
    }

    func testCorruptBackupFailsBeforeChangingSystemHandler() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(Data("invalid property list".utf8), forKey: "systemDefaultApps")
        let manager = fixture.manager()

        do {
            try await manager.setDefaultApp(fixture.chosen, forExtension: "jpg")
            XCTFail("Expected corrupt backup error")
        } catch is DecodingError {
            XCTAssertTrue(fixture.calls.isEmpty)
            XCTAssertTrue(manager.defaultAppPathsByExtension.isEmpty)
        }
    }

    func testConcurrentChangeIsRejectedWhileSystemConfirmationIsPending() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        var continuation: CheckedContinuation<Void, Never>?
        let manager = SettingsManager(
            defaults: fixture.defaults,
            applicationForType: { fixture.handlers[$0.identifier] },
            setApplicationForType: { url, type in
                await withCheckedContinuation { continuation = $0 }
                fixture.handlers[type.identifier] = url
            }
        )
        let firstChange = Task { try await manager.setDefaultApp(fixture.chosen, forExtension: "jpg") }
        while continuation == nil { await Task.yield() }

        do {
            try await manager.setDefaultApp(fixture.original, forExtension: "jpeg")
            XCTFail("Expected concurrent change error")
        } catch SettingsManager.DefaultAppError.changeInProgress {
            XCTAssertTrue(manager.defaultAppPathsByExtension.isEmpty)
        }
        continuation?.resume()
        try await firstChange.value
        XCTAssertEqual(manager.defaultAppPathsByExtension, ["jpg": fixture.chosen.path])
    }

    func testFileContentTypeIsUsedAndRememberedForRestoration() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager()

        try await manager.setDefaultApp(fixture.chosen, forExtension: "custom-image", contentType: .jpeg)
        try await fixture.manager().setDefaultApp(nil, forExtension: "custom-image")

        XCTAssertEqual(fixture.calls.map { $0.1 }, [.jpeg, .jpeg])
        XCTAssertEqual(fixture.handlers[UTType.jpeg.identifier], fixture.original)
    }

    func testMissingOriginalHandlerReportsRestorationError() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.handlers.removeAll()
        let manager = fixture.manager()
        try await manager.setDefaultApp(fixture.chosen, forExtension: "jpg")

        do {
            try await manager.setDefaultApp(nil, forExtension: "jpg")
            XCTFail("Expected missing original handler error")
        } catch SettingsManager.DefaultAppError.noOriginalApplication {
            XCTAssertEqual(manager.defaultAppPathsByExtension["jpg"], fixture.chosen.path)
            XCTAssertEqual(fixture.calls.count, 1)
        }
    }

    func testEmptyExtensionFailsExplicitlyWithoutChangingSystem() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }

        do {
            try await fixture.manager().setDefaultApp(fixture.chosen, forExtension: "")
            XCTFail("Expected invalid extension error")
        } catch SettingsManager.DefaultAppError.invalidExtension {
            XCTAssertTrue(fixture.calls.isEmpty)
        }
    }
}
