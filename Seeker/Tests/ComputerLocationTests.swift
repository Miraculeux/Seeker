import Foundation
import XCTest
@testable import Seeker

@MainActor
final class ComputerLocationTests: XCTestCase {
    func testHiddenMountPathsExcludeTimeMachineStagingOnly() {
        for path in ["/Volumes/.timemachine", "/Volumes/.timemachine/server/backup", "/Volumes/.hidden"] {
            XCTAssertTrue(ComputerLocation.isHiddenMount(URL(fileURLWithPath: path)), path)
        }
        for path in ["/", "/Volumes/990plus", "/Volumes/Data", "/Volumes/TimeMachine"] {
            XCTAssertFalse(ComputerLocation.isHiddenMount(URL(fileURLWithPath: path)), path)
        }
    }

    func testSidebarContainsComputerAndSameVisibleDisksAsOverview() throws {
        let locations = SidebarDefaults.defaultItems().filter { $0.section == .locations }
        let computer = try XCTUnwrap(locations.first { $0.id == "loc_computer" })
        XCTAssertEqual(computer.name, Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
        XCTAssertEqual(computer.icon, "macmini.fill")
        XCTAssertTrue(ComputerLocation.isRoot(computer.url))
        XCTAssertFalse(computer.isEjectable)
        XCTAssertEqual(locations.filter { $0.id == "loc_root" }.count, 1)
        XCTAssertFalse(locations.contains { ComputerLocation.isHiddenMount($0.url) && !$0.isTrash })

        let disks = locations.filter { $0.icon == "internaldrive" || $0.icon == "externaldrive" }
        let files = try ComputerLocation.files()
        XCTAssertEqual(Set(disks.map(\.url.path)), Set(files.map(\.url.path)))
        XCTAssertEqual(Set(disks.map(\.name)), Set(files.map(\.name)))
        XCTAssertEqual(files.filter { $0.url.path == "/" }.count, 1)
        XCTAssertEqual(files.first { $0.url.path == "/" }?.name, FileManager.default.displayName(atPath: "/"))
        XCTAssertTrue(files.allSatisfy { $0.isDirectory && !$0.isHidden })
    }

    func testComputerListingIgnoresShowHiddenFilesAndKeepsNavigation() async throws {
        let savedState = DirectoryViewStateStore.shared.state(for: ComputerLocation.url)
        defer {
            if let savedState {
                DirectoryViewStateStore.shared.setState(savedState, for: ComputerLocation.url)
            } else {
                DirectoryViewStateStore.shared.removeState(for: ComputerLocation.url)
            }
        }
        let model = FileExplorerViewModel(url: ComputerLocation.url)
        defer { model.cancelLoading() }
        let expectedPaths = Set(try ComputerLocation.volumes().map(\.path))
        for showHidden in [false, true] {
            model.showHiddenFiles = showHidden
            model.loadFiles()
            let files = try await model.sortedChildren(of: ComputerLocation.url)
            XCTAssertEqual(Set(files.map(\.url.path)), expectedPaths)
            XCTAssertFalse(files.contains { ComputerLocation.isHiddenMount($0.url) })
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while Set(model.files.map(\.url.path)) != expectedPaths, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(Set(model.files.map(\.url.path)), expectedPaths)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.tabTitle, ComputerLocation.name)
        XCTAssertFalse(model.canGoUp)
        XCTAssertEqual(model.pathComponents.map(\.0), [ComputerLocation.name])
        model.goUp()
        XCTAssertTrue(ComputerLocation.isRoot(model.currentURL))

        let startupDisk = try XCTUnwrap(model.files.first { $0.url.path == "/" })
        model.openItem(startupDisk)
        XCTAssertEqual(model.currentURL.path, "/")
        XCTAssertTrue(model.canGoUp)
        XCTAssertEqual(model.pathComponents.map(\.0), [ComputerLocation.name, startupDisk.name])
        model.goBack()
        XCTAssertTrue(ComputerLocation.isRoot(model.currentURL))
        model.goForward()
        XCTAssertEqual(model.currentURL.path, "/")
        model.goUp()
        XCTAssertTrue(ComputerLocation.isRoot(model.currentURL))
    }
}
