import Foundation
import XCTest
@testable import Seeker

final class OpenWithAppsCacheTests: XCTestCase {
    func testDuplicateBundleIdentifiersPreferApplicationsCopy() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let applications = try fixture.directory("Applications")
        let derivedDataApp = try makeApp(
            in: fixture,
            path: "DerivedData/IINA.app",
            bundleIdentifier: "com.colliderli.iina"
        )
        let installedApp = try makeApp(
            in: fixture,
            path: "Applications/IINA.app",
            bundleIdentifier: "com.colliderli.iina"
        )

        let apps = OpenWithAppsCache.preferredUniqueApps(
            from: [derivedDataApp, installedApp],
            applicationsDirectory: applications
        )

        XCTAssertEqual(apps, [installedApp.standardizedFileURL])
    }

    func testDistinctBundleIdentifiersArePreserved() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let applications = try fixture.directory("Applications")
        let first = try makeApp(
            in: fixture,
            path: "Build/First.app",
            bundleIdentifier: "com.example.first"
        )
        let second = try makeApp(
            in: fixture,
            path: "Build/Second.app",
            bundleIdentifier: "com.example.second"
        )

        let apps = OpenWithAppsCache.preferredUniqueApps(
            from: [first, second],
            applicationsDirectory: applications
        )

        XCTAssertEqual(apps, [first.standardizedFileURL, second.standardizedFileURL])
    }

    func testBundlesWithoutIdentifiersAreDeduplicatedOnlyByPath() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let applications = try fixture.directory("Applications")
        let first = try fixture.directory("Build/First.app")
        let second = try fixture.directory("Build/Second.app")

        let apps = OpenWithAppsCache.preferredUniqueApps(
            from: [first, first, second],
            applicationsDirectory: applications
        )

        XCTAssertEqual(apps, [first.standardizedFileURL, second.standardizedFileURL])
    }

    private func makeApp(
        in fixture: WorkflowFixture,
        path: String,
        bundleIdentifier: String
    ) throws -> URL {
        let appURL = fixture.url(path)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": appURL.deletingPathExtension().lastPathComponent,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return appURL
    }
}
