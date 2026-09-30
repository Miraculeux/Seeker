import Foundation
import XCTest
@testable import Seeker

final class MediaMetadataTests: XCTestCase {
    func testCommonAccessorsAreCaseInsensitiveAndKeepFirstDuplicate() {
        let metadata = MediaMetadata(tags: [
            .init(key: "title", value: "First"), .init(key: "TITLE", value: "Second"),
            .init(key: "Artist", value: "Artist"), .init(key: "aLbUm", value: "Album"),
            .init(key: "tracknumber", value: "03"), .init(key: "discnumber", value: "2")
        ])
        XCTAssertEqual(metadata.title, "First")
        XCTAssertEqual(metadata.artist, "Artist")
        XCTAssertEqual(metadata.album, "Album")
        XCTAssertEqual(metadata.trackNumber, "03")
        XCTAssertEqual(metadata.discNumber, "2")
        XCTAssertNil(metadata.first("GENRE"))
    }

    func testEmptyAndMissingNumberValuesHaveNoDisplay() {
        for value in [nil, "", "   "] as [String?] {
            var metadata = MediaMetadata(tags: [.init(key: "TRACKTOTAL", value: "12")])
            if let value { metadata.tags.append(.init(key: "TRACKNUMBER", value: value)) }
            XCTAssertNil(metadata.trackDisplay)
            XCTAssertNil(metadata.discDisplay)
        }
        XCTAssertNil(MediaMetadata().title)
    }

    func testNumberDisplaysTrimWhitespaceAndPreserveLeadingZeros() {
        let metadata = MediaMetadata(tags: [
            .init(key: "TRACKNUMBER", value: " 03 "), .init(key: "TRACKTOTAL", value: " 12 "),
            .init(key: "DISCNUMBER", value: " 01 "), .init(key: "DISCTOTAL", value: " 02 ")
        ])
        XCTAssertEqual(metadata.trackDisplay, "03 / 12")
        XCTAssertEqual(metadata.discDisplay, "01 / 02")
        XCTAssertEqual(metadata.trackNumber, " 03 ")
    }

    func testEmbeddedTotalsTakePrecedenceOverSeparateTotals() {
        let metadata = MediaMetadata(tags: [
            .init(key: "TRACKNUMBER", value: " 3 / 12 "), .init(key: "TRACKTOTAL", value: "99"),
            .init(key: "DISCNUMBER", value: "1/2"), .init(key: "DISCTOTAL", value: "9")
        ])
        XCTAssertEqual(metadata.trackDisplay, "3 / 12")
        XCTAssertEqual(metadata.discDisplay, "1 / 2")
    }

    func testNonNumericAndMultiSlashValuesAreNotInventedOrDiscarded() {
        for (value, total, expected) in [
            (" Bonus ", "", "Bonus"), ("4", "  ", "4"), ("1/2/3", "9", "1/2/3")
        ] {
            let metadata = MediaMetadata(tags: [
                .init(key: "TRACKNUMBER", value: value), .init(key: "TRACKTOTAL", value: total)
            ])
            XCTAssertEqual(metadata.trackDisplay, expected)
        }
    }

    func testTagIdentityAndMetadataValueCopies() {
        let tag = MediaMetadata.Tag(key: "TITLE", value: "Synthetic")
        XCTAssertNotEqual(tag.id, MediaMetadata.Tag(key: tag.key, value: tag.value).id)
        let original = MediaMetadata(vendor: "Fixture", tags: [tag],
                                     coverArt: Data([1, 2]), coverMimeType: "image/png")
        var copy = original
        XCTAssertEqual(copy, original)
        copy.tags[0].value = "Changed"
        XCTAssertNotEqual(copy, original)
        XCTAssertEqual(original.title, "Synthetic")
        XCTAssertEqual(Set(StandardTagKey.allCases.map(\.rawValue)).count, StandardTagKey.allCases.count)
        XCTAssertTrue(StandardTagKey.allCases.allSatisfy { $0.rawValue == $0.rawValue.uppercased() })
    }
}
