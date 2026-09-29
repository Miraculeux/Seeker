import AppKit
import XCTest
@testable import Seeker

@MainActor
final class SidebarIconTests: XCTestCase {
    func testBuiltInSidebarSymbolsAreAvailable() {
        let items = SidebarDefaults.defaultItems().filter { !$0.isUserFavorite }
        let favorites = items.filter { $0.section == .favorites }
        XCTAssertEqual(favorites.map(\.icon), [
            "pencil.and.ruler", "menubar.dock.rectangle", "doc", "arrow.down.circle",
        ])
        XCTAssertEqual(items.first { $0.id == "loc_root" }?.icon, "internaldrive")
        XCTAssertEqual(items.first { $0.id == "loc_home" }?.icon, "house")
        XCTAssertEqual(items.first { $0.id == "loc_trash" }?.icon, "trash")
        for item in items {
            XCTAssertNotNil(
                NSImage(systemSymbolName: item.icon, accessibilityDescription: nil),
                "Missing sidebar symbol: \(item.icon)"
            )
        }
    }

    func testApplicationsUsesTemplateSystemGlyph() throws {
        let image = try XCTUnwrap(SidebarRow.nativeApplicationsIcon)
        XCTAssertTrue(image.isTemplate)
        XCTAssertTrue(image.isValid)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testBuiltInFavoritesNavigateToTheirOwnBreadcrumbEndpoint() throws {
        let favorites = SidebarDefaults.defaultItems().filter {
            $0.section == .favorites && !$0.isUserFavorite
        }
        let model = FileExplorerViewModel()
        defer { model.cancelLoading() }

        for favorite in favorites {
            model.navigateTo(favorite.url)
            XCTAssertEqual(
                model.currentURL.standardizedFileURL,
                favorite.url.standardizedFileURL,
                "\(favorite.name) must navigate to its own directory"
            )
            let endpoint = try XCTUnwrap(model.pathComponents.last)
            XCTAssertEqual(endpoint.0, favorite.name)
            XCTAssertEqual(endpoint.1.standardizedFileURL, favorite.url.standardizedFileURL)
        }
    }
}
