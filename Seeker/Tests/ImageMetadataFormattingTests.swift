import XCTest
@testable import Seeker

final class ImageMetadataFormattingTests: XCTestCase {
    func testExposureTimeFormatsValidValues() {
        XCTAssertEqual(ImageMetadataFormatting.exposureTime(2), "2.0 s")
        XCTAssertEqual(ImageMetadataFormatting.exposureTime(0.5), "1/2 s")
        XCTAssertEqual(ImageMetadataFormatting.exposureTime(1.0 / 125.0), "1/125 s")
    }

    func testExposureTimeRejectsValuesThatPreviouslyTrapped() {
        XCTAssertNil(ImageMetadataFormatting.exposureTime(0))
        XCTAssertNil(ImageMetadataFormatting.exposureTime(-1))
        XCTAssertNil(ImageMetadataFormatting.exposureTime(.nan))
        XCTAssertNil(ImageMetadataFormatting.exposureTime(.infinity))
        XCTAssertNil(ImageMetadataFormatting.exposureTime(.leastNonzeroMagnitude))
    }

    func testWholeNumberFormattingRejectsNonFiniteMetadata() {
        XCTAssertEqual(ImageMetadataFormatting.truncatedWholeNumber(72.9), "72")
        XCTAssertEqual(ImageMetadataFormatting.roundedWholeNumber(49.6), "50")
        XCTAssertNil(ImageMetadataFormatting.truncatedWholeNumber(.nan))
        XCTAssertNil(ImageMetadataFormatting.roundedWholeNumber(.infinity))
    }
}
