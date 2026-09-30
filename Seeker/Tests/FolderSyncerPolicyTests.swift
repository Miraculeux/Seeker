import Foundation
import XCTest
@testable import Seeker

@MainActor
final class FolderSyncerPolicyTests: XCTestCase {
    private func analyzed(_ fixture: WorkflowFixture, direction: FolderSyncer.Direction,
                          hidden: Bool = false) async throws -> FolderSyncer {
        let syncer = FolderSyncer(rootA: fixture.url("A"), rootB: fixture.url("B"))
        syncer.direction = direction
        syncer.includeHidden = hidden
        syncer.analyze()
        do { try await waitForWorkflow { syncer.status == .ready } }
        catch { syncer.cancel(); throw error }
        return syncer
    }

    private func policyFixture() throws -> WorkflowFixture {
        let fixture = try WorkflowFixture()
        do {
            try fixture.write("A/a-only", "A")
            try fixture.write("B/b-only", "BB")
            try fixture.write("A/a-newer", "new A", mtime: 1_700_000_020)
            try fixture.write("B/a-newer", "old B")
            try fixture.write("A/b-newer", "old A")
            try fixture.write("B/b-newer", "new B", mtime: 1_700_000_020)
            try fixture.write("A/equal", "same")
            try fixture.write("B/equal", "same")
            return fixture
        } catch { fixture.cleanup(); throw error }
    }

    func testMirrorPlansDowngradeAndBOnlyDeletionWithoutTouchingDisk() async throws {
        let fixture = try policyFixture()
        defer { fixture.cleanup() }
        let syncer = try await analyzed(fixture, direction: .mirror)
        defer { syncer.cancel() }
        XCTAssertEqual(syncer.actions.map(\.relativePath), ["a-newer", "a-only", "b-newer", "b-only"])
        XCTAssertEqual(syncer.actions.map(\.kind), [.copyToB, .copyToB, .copyToB, .deleteB])
        let deletion = try XCTUnwrap(syncer.actions.last)
        XCTAssertNil(deletion.source)
        XCTAssertEqual(deletion.destination, fixture.url("B/b-only"))
        XCTAssertEqual(deletion.size, 2)
        XCTAssertEqual(syncer.totalBytes, 11)
        XCTAssertEqual(try fixture.contents("B/b-newer"), "new B")
        XCTAssertEqual(try fixture.contents("B/b-only"), "BB")
    }

    func testUpdateNeverDowngradesOrDeletesBOnlyFiles() async throws {
        let fixture = try policyFixture()
        defer { fixture.cleanup() }
        let syncer = try await analyzed(fixture, direction: .update)
        defer { syncer.cancel() }
        XCTAssertEqual(syncer.actions.map(\.relativePath), ["a-newer", "a-only"])
        XCTAssertTrue(syncer.actions.allSatisfy { $0.kind == .copyToB && $0.enabled })
        XCTAssertEqual(syncer.actions.map(\.source), [fixture.url("A/a-newer"), fixture.url("A/a-only")])
        XCTAssertEqual(syncer.actions.map(\.destination), [fixture.url("B/a-newer"), fixture.url("B/a-only")])
        XCTAssertEqual(syncer.totalBytes, 6)
        syncer.apply()
        try await waitForWorkflow { if case .finished = syncer.status { return true }; return false }
        XCTAssertEqual(syncer.status, .finished(applied: 2, failed: 0))
        XCTAssertNil(syncer.activeOperation)
        XCTAssertEqual(try fixture.contents("B/a-newer"), "new A")
        XCTAssertEqual(try fixture.contents("B/a-only"), "A")
        XCTAssertEqual(try fixture.contents("B/b-newer"), "new B")
        XCTAssertEqual(try fixture.contents("B/b-only"), "BB")
        XCTAssertEqual(try fixture.contents("A/b-newer"), "old A")
    }

    func testTwoWaySelectsNewerSideAndGroupsActionsByDirection() async throws {
        let fixture = try policyFixture()
        defer { fixture.cleanup() }
        let syncer = try await analyzed(fixture, direction: .twoWay)
        defer { syncer.cancel() }
        XCTAssertEqual(syncer.actions.map(\.relativePath), ["a-newer", "a-only", "b-newer", "b-only"])
        XCTAssertEqual(syncer.actions.map(\.kind), [.copyToB, .copyToB, .copyToA, .copyToA])
        XCTAssertEqual(syncer.actions.map(\.source), [
            fixture.url("A/a-newer"), fixture.url("A/a-only"),
            fixture.url("B/b-newer"), fixture.url("B/b-only")
        ])
        XCTAssertEqual(syncer.totalBytes, 13)
        syncer.apply()
        try await waitForWorkflow { if case .finished = syncer.status { return true }; return false }
        XCTAssertEqual(syncer.status, .finished(applied: 4, failed: 0))
        XCTAssertNil(syncer.activeOperation)
        for (path, expected) in [("a-newer", "new A"), ("a-only", "A"), ("b-newer", "new B"), ("b-only", "BB"), ("equal", "same")] {
            XCTAssertEqual(try fixture.contents("A/\(path)"), expected)
            XCTAssertEqual(try fixture.contents("B/\(path)"), expected)
        }
    }

    func testMetadataEqualityIgnoresContentAndSubsecondDifferences() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        try fixture.write("A/same", "AAAA", mtime: 1_700_000_000)
        try fixture.write("B/same", "BBBB", mtime: 1_700_000_000.5)
        let syncer = try await analyzed(fixture, direction: .mirror)
        defer { syncer.cancel() }
        XCTAssertTrue(syncer.actions.isEmpty, "Sync uses size and a one-second mtime tolerance, not content hashes")
        XCTAssertEqual(syncer.totalBytes, 0)
        syncer.apply()
        XCTAssertEqual(syncer.status, .finished(applied: 0, failed: 0))
        XCTAssertNil(syncer.activeOperation)
        XCTAssertEqual(try fixture.contents("A/same"), "AAAA")
        XCTAssertEqual(try fixture.contents("B/same"), "BBBB")
    }

    func testEqualTimestampSizeConflictHasDirectionSpecificPolicy() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        try fixture.write("A/conflict", "short")
        try fixture.write("B/conflict", "longer")
        let update = try await analyzed(fixture, direction: .update)
        let mirror = try await analyzed(fixture, direction: .mirror)
        let twoWay = try await analyzed(fixture, direction: .twoWay)
        defer { update.cancel(); mirror.cancel(); twoWay.cancel() }
        XCTAssertTrue(update.actions.isEmpty)
        XCTAssertEqual(mirror.actions.map(\.kind), [.copyToB])
        XCTAssertEqual(twoWay.actions.map(\.kind), [.copyToA])
        XCTAssertEqual(twoWay.actions.first?.source, fixture.url("B/conflict"))
        XCTAssertEqual(try fixture.contents("A/conflict"), "short")
        XCTAssertEqual(try fixture.contents("B/conflict"), "longer")
    }

    func testHiddenPolicyAndNestedRelativePathsArePreserved() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        try fixture.directory("B")
        try fixture.directory("A/empty")
        try fixture.write("A/deep/item", "normal")
        try fixture.write("A/.hidden", "hidden")
        try fixture.write("A/.hidden-directory/child", "inside")
        let visible = try await analyzed(fixture, direction: .update)
        let all = try await analyzed(fixture, direction: .update, hidden: true)
        defer { visible.cancel(); all.cancel() }
        XCTAssertEqual(visible.actions.map(\.relativePath), ["deep/item"])
        XCTAssertEqual(Set(all.actions.map(\.relativePath)), [".hidden", ".hidden-directory/child", "deep/item"])
        XCTAssertEqual(all.actions.count, 3)
        for action in all.actions {
            XCTAssertEqual(action.destination, fixture.url("B/\(action.relativePath)"))
            XCTAssertEqual(action.source, fixture.url("A/\(action.relativePath)"))
        }
    }

    func testDisabledMirrorDeletionAndCopyAreNotApplied() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        try fixture.write("A/new", "fresh")
        try fixture.write("A/disabled", "do not copy")
        try fixture.write("B/b-only", "do not trash")
        let syncer = try await analyzed(fixture, direction: .mirror)
        defer { syncer.cancel() }
        for index in syncer.actions.indices where syncer.actions[index].relativePath != "new" {
            syncer.actions[index].enabled = false
        }
        XCTAssertEqual(syncer.enabledActions.map(\.relativePath), ["new"])
        XCTAssertEqual(syncer.totalBytes, 5)
        syncer.apply()
        try await waitForWorkflow { if case .finished = syncer.status { return true }; return false }
        XCTAssertEqual(syncer.status, .finished(applied: 1, failed: 0))
        XCTAssertNil(syncer.activeOperation)
        XCTAssertNil(syncer.currentActivity)
        XCTAssertEqual(try fixture.contents("B/new"), "fresh")
        XCTAssertEqual(try fixture.contents("B/b-only"), "do not trash")
        XCTAssertFalse(fixture.exists("B/disabled"))
        XCTAssertEqual(try fixture.contents("A/disabled"), "do not copy")
    }

    func testCancelAnalysisThenReanalyzeDoesNotPublishStalePolicy() async throws {
        let fixture = try policyFixture()
        defer { fixture.cleanup() }
        let syncer = FolderSyncer(rootA: fixture.url("A"), rootB: fixture.url("B"))
        defer { syncer.cancel() }
        syncer.direction = .mirror
        syncer.analyze()
        XCTAssertEqual(syncer.status, .analyzing)
        syncer.cancel()
        XCTAssertEqual(syncer.status, .cancelled)
        XCTAssertTrue(syncer.actions.isEmpty)
        syncer.direction = .update
        syncer.analyze()
        try await waitForWorkflow { syncer.status == .ready }
        XCTAssertEqual(syncer.actions.map(\.relativePath), ["a-newer", "a-only"])
        XCTAssertFalse(syncer.actions.contains { $0.kind == .deleteB })
    }
}
