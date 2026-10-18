import Foundation
import XCTest
@testable import Seeker

@MainActor
final class ActivePaneRoutingTests: XCTestCase {
    func testClosingRightPaneActivatesLeftPane() throws {
        try withState { state, _ in
            state.activePane = .right

            state.showDualPane = false

            XCTAssertEqual(state.activePane, .left)
            XCTAssertTrue(state.activeExplorer === state.leftPane.activeTab)
        }
    }

    func testSinglePaneRejectsLateRightPaneActivation() throws {
        try withState { state, _ in
            state.activePane = .right
            state.showDualPane = false

            // A mouse-down callback queued before the right pane disappeared.
            state.activePane = .right

            XCTAssertEqual(state.activePane, .left)
            XCTAssertTrue(state.activePaneState === state.leftPane)
            XCTAssertTrue(state.inactivePaneState === state.rightPane)
        }
    }

    func testDuplicateFinderUsesVisibleSelectedDirectoryAfterLateActivation() throws {
        try withState { state, fixture in
            state.activePane = .right
            state.showDualPane = false
            state.activePane = .right

            state.openDuplicateFinder()

            XCTAssertEqual(state.duplicateFinderRoots?.map(\.path), [fixture.url("left/selected").path])
        }
    }

    func testDuplicateFinderUsesVisibleCurrentDirectoryWithoutSelection() throws {
        try withState { state, fixture in
            state.leftPane.activeTab.selectedFileIDs = []
            state.showDualPane = false
            state.activePane = .right

            state.openDuplicateFinder()

            XCTAssertEqual(state.duplicateFinderRoots, [fixture.url("left")])
        }
    }

    func testAcrossPanesDuplicateFinderIgnoresHiddenPane() throws {
        try withState { state, fixture in
            state.showDualPane = false
            state.activePane = .right

            state.openDuplicateFinderAcrossPanes()

            XCTAssertEqual(state.duplicateFinderRoots?.map(\.path), [fixture.url("left/selected").path])
        }
    }

    func testDualPaneDuplicateFinderKeepsActivePanePriority() throws {
        try withState { state, fixture in
            state.activePane = .right

            state.openDuplicateFinder()
            XCTAssertEqual(state.duplicateFinderRoots?.map(\.path), [fixture.url("right/selected").path])

            state.openDuplicateFinderAcrossPanes()
            XCTAssertEqual(state.duplicateFinderRoots?.map(\.path), [
                fixture.url("right/selected").path, fixture.url("left/selected").path
            ])
        }
    }

    func testReopeningRightPanePreservesItsDirectoryAndSelection() throws {
        try withState { state, fixture in
            state.activePane = .right
            state.showDualPane = false
            state.activePane = .right

            state.showDualPane = true

            XCTAssertEqual(state.activePane, .left)
            XCTAssertEqual(state.rightPane.activeTab.currentURL, fixture.url("right"))
            XCTAssertEqual(
                state.rightPane.activeTab.selectedFile?.url.path,
                fixture.url("right/selected").path
            )
            state.activePane = .right
            XCTAssertTrue(state.activeExplorer === state.rightPane.activeTab)
        }
    }

    func testOtherSearchToolsAlsoUseVisiblePane() throws {
        try withState { state, fixture in
            state.showDualPane = false
            state.activePane = .right

            state.openSearch()
            state.openSemanticSearch()

            XCTAssertEqual(state.fileSearchRoot?.path, fixture.url("left/selected").path)
            XCTAssertEqual(state.semanticSearchRequest?.targetDirectory, fixture.url("left"))
        }
    }

    private func withState(_ body: (AppState, WorkflowFixture) throws -> Void) throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let savedDualPane = SettingsManager.shared.showDualPane
        defer { SettingsManager.shared.showDualPane = savedDualPane }
        let state = AppState()
        defer {
            for pane in [state.leftPane, state.rightPane] {
                for tab in pane.tabs { tab.cancelLoading() }
            }
        }
        state.showDualPane = true
        for (name, pane) in [("left", state.leftPane), ("right", state.rightPane)] {
            let selected = FileItem(url: try fixture.directory("\(name)/selected"))
            let model = pane.activeTab
            model.cancelLoading()
            model.currentURL = fixture.url(name)
            model.files = [selected]
            model.handleFileClick(selected, command: false, shift: false)
        }
        try body(state, fixture)
    }
}
