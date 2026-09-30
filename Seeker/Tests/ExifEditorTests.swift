import CoreLocation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Seeker

final class ExifEditorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try MetadataTestFixtures.makeDirectory()
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private var cameraProperties: [CFString: Any] {
        [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Synthetic camera",
                kCGImagePropertyTIFFModel: "Fixture model"
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "Fixture lens",
                kCGImagePropertyExifBodySerialNumber: "TEST-SERIAL-ONLY",
                kCGImagePropertyExifExposureTime: 1.0 / 125.0,
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifISOSpeedRatings: [200],
                kCGImagePropertyExifFocalLength: 49.6,
                kCGImagePropertyExifUserComment: "Synthetic private comment"
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 12.5,
                kCGImagePropertyGPSLatitudeRef: "S",
                kCGImagePropertyGPSLongitude: 24.25,
                kCGImagePropertyGPSLongitudeRef: "W",
                kCGImagePropertyGPSAltitude: 7.5,
                kCGImagePropertyGPSAltitudeRef: 1
            ]
        ]
    }

    private func fixture(properties: [CFString: Any] = [:], type: UTType = .tiff) throws -> URL {
        let ext = try XCTUnwrap(type.preferredFilenameExtension)
        let url = root.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try MetadataTestFixtures.imageData(type: type, properties: properties).write(to: url)
        return url
    }

    private func dictionary(_ key: CFString, at url: URL) throws -> [CFString: Any] {
        try MetadataTestFixtures.properties(at: url)[key] as? [CFString: Any] ?? [:]
    }

    private func assertNoStagingFiles(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains { $0.contains(".seeker-tmp-") }, file: file, line: line)
    }

    private func containsNull(_ value: Any) -> Bool {
        if value is NSNull { return true }
        if let dictionary = value as? [CFString: Any] {
            return dictionary.values.contains { containsNull($0) }
        }
        if let array = value as? [Any] {
            return array.contains { containsNull($0) }
        }
        return false
    }

    private func assertPrivacyRemoval(type: UTType,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try fixture(properties: cameraProperties, type: type)
        let initialSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let initialType = try XCTUnwrap(CGImageSourceGetType(initialSource))
        XCTAssertEqual(initialType as String, type.identifier, file: file, line: line)
        let initialExif = try dictionary(kCGImagePropertyExifDictionary, at: url)
        XCTAssertEqual(try XCTUnwrap(initialExif[kCGImagePropertyExifBodySerialNumber] as? String),
                       "TEST-SERIAL-ONLY", file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(initialExif[kCGImagePropertyExifUserComment] as? String),
                       "Synthetic private comment", file: file, line: line)
        let initial = ExifEditor.read(from: url)
        let location = try XCTUnwrap(initial.location)
        XCTAssertEqual(location.latitude, -12.5, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(location.longitude, -24.25, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(initial.altitude), -7.5, accuracy: 0.000001,
                       file: file, line: line)
        let camera = ExifEditor.readCameraInfo(from: url)
        XCTAssertEqual(try XCTUnwrap(camera.make), "Synthetic camera", file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(camera.model), "Fixture model", file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(camera.lensModel), "Fixture lens", file: file, line: line)

        try ExifEditor.stripPrivacyFields(at: url)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let resultType = try XCTUnwrap(CGImageSourceGetType(source))
        XCTAssertEqual(resultType as String, type.identifier, file: file, line: line)
        let properties = try MetadataTestFixtures.properties(at: url)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary], file: file, line: line)
        XCTAssertFalse(containsNull(properties), file: file, line: line)
        let exif = try dictionary(kCGImagePropertyExifDictionary, at: url)
        XCTAssertNil(exif[kCGImagePropertyExifBodySerialNumber], file: file, line: line)
        XCTAssertNil(exif[kCGImagePropertyExifUserComment], file: file, line: line)
        let metadata = ExifEditor.read(from: url)
        XCTAssertNil(metadata.location, file: file, line: line)
        XCTAssertNil(metadata.altitude, file: file, line: line)
        XCTAssertEqual(metadata.userComment, "", file: file, line: line)
        let result = ExifEditor.readCameraInfo(from: url)
        XCTAssertEqual(result.make, camera.make, file: file, line: line)
        XCTAssertEqual(result.model, camera.model, file: file, line: line)
        XCTAssertEqual(result.lensModel, camera.lensModel, file: file, line: line)
        XCTAssertEqual(result.exposureTime, camera.exposureTime, file: file, line: line)
        XCTAssertEqual(result.fNumber, camera.fNumber, file: file, line: line)
        XCTAssertEqual(result.iso, camera.iso, file: file, line: line)
        XCTAssertEqual(result.pixelDimensions, "4 × 3", file: file, line: line)
        try assertNoStagingFiles(file: file, line: line)
    }

    func testEditableMetadataEqualityIncludesCoordinatesAndIndependentCopies() {
        var original = EditableMetadata.empty
        original.imageDescription = "Synthetic image"
        original.location = CLLocationCoordinate2D(latitude: 12.5, longitude: -24.25)
        original.altitude = -7.5
        var copy = original
        XCTAssertEqual(copy, original)
        copy.location?.longitude = 24.25
        XCTAssertNotEqual(copy, original)
        copy = original
        copy.altitude = nil
        XCTAssertNotEqual(copy, original)
        copy = original
        copy.keywords.append("test")
        XCTAssertNotEqual(copy, original)
        XCTAssertTrue(original.keywords.isEmpty)
        XCTAssertEqual(original.location?.longitude, -24.25)
    }

    func testUnreadableInputsReturnEmptyReadsAndWritesFailWithoutCreatingOutput() throws {
        let missing = root.appendingPathComponent("missing.tiff")
        let invalid = root.appendingPathComponent("invalid.tiff")
        let bytes = Data("synthetic non-image".utf8)
        try bytes.write(to: invalid)
        for source in [missing, invalid] {
            XCTAssertEqual(ExifEditor.read(from: source), .empty)
            let camera = ExifEditor.readCameraInfo(from: source)
            XCTAssertNil(camera.make)
            XCTAssertNil(camera.pixelDimensions)
            let output = root.appendingPathComponent("copy.tiff")
            XCTAssertThrowsError(try ExifEditor.write(.empty, from: source, to: output)) { error in
                switch (source == missing, error) {
                case (true, ExifEditorError.sourceUnreadable),
                     (false, ExifEditorError.unsupportedType):
                    break
                default:
                    XCTFail("Unexpected error for \(source.lastPathComponent): \(error)")
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertThrowsError(try ExifEditor.stripPrivacyFields(at: source)) { error in
                switch (source == missing, error) {
                case (true, ExifEditorError.sourceUnreadable),
                     (false, ExifEditorError.unsupportedType):
                    break
                default:
                    XCTFail("Unexpected strip error for \(source.lastPathComponent): \(error)")
                }
            }
        }
        XCTAssertEqual(try Data(contentsOf: invalid), bytes)
        try assertNoStagingFiles()
    }

    func testCameraInfoFormatsSyntheticExposureAndDimensions() throws {
        let url = try fixture(properties: cameraProperties)
        let info = ExifEditor.readCameraInfo(from: url)
        XCTAssertEqual(info.make, "Synthetic camera")
        XCTAssertEqual(info.model, "Fixture model")
        XCTAssertEqual(info.lensModel, "Fixture lens")
        XCTAssertEqual(info.bodySerialNumber, "TEST-SERIAL-ONLY")
        XCTAssertEqual(info.exposureTime, "1/125 s")
        XCTAssertEqual(info.fNumber, "f/2.8")
        XCTAssertEqual(info.iso, "ISO 200")
        XCTAssertEqual(info.focalLength, "50 mm")
        XCTAssertEqual(info.pixelDimensions, "4 × 3")
    }

    func testSaveCopyTrimsTextMirrorsIPTCAndPreservesSourceAndPixels() throws {
        let source = try fixture(properties: cameraProperties)
        let originalBytes = try Data(contentsOf: source)
        let originalPixels = try MetadataTestFixtures.decodedPixels(at: source)
        let output = root.appendingPathComponent("edited-copy.tiff")
        var input = ExifEditor.read(from: source)
        input.imageDescription = "  Synthetic description \n"
        input.artist = "\t Fixture artist "
        input.copyright = " Test copyright "
        input.software = " Fixture software "
        input.userComment = " New comment "
        input.keywords = ["fixture", "metadata"]
        input.rating = 4
        input.dateTimeOriginal = Date(timeIntervalSince1970: 1_700_000_000)
        try ExifEditor.write(input, from: source, to: output)

        let result = ExifEditor.read(from: output)
        XCTAssertEqual(result.imageDescription, "Synthetic description")
        XCTAssertEqual(result.artist, "Fixture artist")
        XCTAssertEqual(result.copyright, "Test copyright")
        XCTAssertEqual(result.software, "Fixture software")
        XCTAssertEqual(result.userComment, "New comment")
        XCTAssertEqual(result.keywords, ["fixture", "metadata"])
        XCTAssertEqual(result.rating, 4)
        XCTAssertEqual(result.dateTimeOriginal, input.dateTimeOriginal)
        let iptc = try dictionary(kCGImagePropertyIPTCDictionary, at: output)
        XCTAssertEqual(iptc[kCGImagePropertyIPTCCaptionAbstract] as? String, "Synthetic description")
        XCTAssertEqual(iptc[kCGImagePropertyIPTCByline] as? [String], ["Fixture artist"])
        XCTAssertEqual(iptc[kCGImagePropertyIPTCCopyrightNotice] as? String, "Test copyright")
        let exif = try dictionary(kCGImagePropertyExifDictionary, at: output)
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String,
                       exif[kCGImagePropertyExifDateTimeDigitized] as? String)
        XCTAssertEqual(ExifEditor.readCameraInfo(from: output).bodySerialNumber, "TEST-SERIAL-ONLY")
        XCTAssertEqual(ExifEditor.readCameraInfo(from: output).model, "Fixture model")
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertEqual(try MetadataTestFixtures.decodedPixels(at: output), originalPixels)
        try assertNoStagingFiles()
    }

    func testClearingEditableFieldsInPlaceRemovesMirrorsDatesAndGPS() throws {
        let url = try fixture(properties: cameraProperties)
        var input = ExifEditor.read(from: url)
        input.imageDescription = "Description"
        input.artist = "Artist"
        input.copyright = "Copyright"
        input.software = "Software"
        input.keywords = ["fixture"]
        input.rating = 3
        input.dateTimeOriginal = Date(timeIntervalSince1970: 1_700_000_000)
        try ExifEditor.write(input, from: url, to: url)
        XCTAssertEqual(ExifEditor.read(from: url).artist, "Artist")
        XCTAssertNotNil(ExifEditor.read(from: url).location)
        let pixels = try MetadataTestFixtures.decodedPixels(at: url)

        var cleared = EditableMetadata.empty
        cleared.imageDescription = " \n\t "
        cleared.artist = " \t "
        try ExifEditor.write(cleared, from: url, to: url)
        XCTAssertEqual(ExifEditor.read(from: url), .empty)
        let props = try MetadataTestFixtures.properties(at: url)
        XCTAssertNil(props[kCGImagePropertyGPSDictionary])
        let tiff = try dictionary(kCGImagePropertyTIFFDictionary, at: url)
        XCTAssertNil(tiff[kCGImagePropertyTIFFArtist])
        XCTAssertNil(tiff[kCGImagePropertyTIFFDateTime])
        let exif = try dictionary(kCGImagePropertyExifDictionary, at: url)
        XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(exif[kCGImagePropertyExifDateTimeDigitized])
        let iptc = try dictionary(kCGImagePropertyIPTCDictionary, at: url)
        XCTAssertNil(iptc[kCGImagePropertyIPTCCaptionAbstract])
        XCTAssertNil(iptc[kCGImagePropertyIPTCByline])
        XCTAssertNil(iptc[kCGImagePropertyIPTCCopyrightNotice])
        XCTAssertNil(iptc[kCGImagePropertyIPTCKeywords])
        XCTAssertNil(iptc[kCGImagePropertyIPTCStarRating])
        XCTAssertNil(iptc[kCGImagePropertyIPTCDateCreated])
        XCTAssertNil(iptc[kCGImagePropertyIPTCTimeCreated])
        XCTAssertNil(iptc[kCGImagePropertyIPTCDigitalCreationDate])
        XCTAssertNil(iptc[kCGImagePropertyIPTCDigitalCreationTime])
        XCTAssertEqual(ExifEditor.readCameraInfo(from: url).make, "Synthetic camera")
        XCTAssertEqual(try MetadataTestFixtures.decodedPixels(at: url), pixels)
        try assertNoStagingFiles()
    }

    func testGPSRoundTripsBothHemispheresAndAltitudeSigns() throws {
        for (latitude, longitude, altitude, latRef, lonRef, altRef) in [
            (12.5, 24.25, 7.5, "N", "E", 0),
            (-12.5, -24.25, -7.5, "S", "W", 1),
            (0.0, 0.0, 0.0, "N", "E", 0)
        ] {
            let source = try fixture()
            let output = root.appendingPathComponent("\(UUID().uuidString).tiff")
            var input = EditableMetadata.empty
            input.location = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            input.altitude = altitude
            try ExifEditor.write(input, from: source, to: output)
            let result = ExifEditor.read(from: output)
            XCTAssertEqual(try XCTUnwrap(result.location).latitude, latitude, accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(result.location).longitude, longitude, accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(result.altitude), altitude, accuracy: 0.000001)
            let gps = try dictionary(kCGImagePropertyGPSDictionary, at: output)
            XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef] as? String, latRef)
            XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef] as? String, lonRef)
            XCTAssertEqual(gps[kCGImagePropertyGPSAltitudeRef] as? Int, altRef)
        }
        let source = try fixture(properties: cameraProperties)
        var input = ExifEditor.read(from: source)
        input.altitude = nil
        try ExifEditor.write(input, from: source, to: source)
        XCTAssertNotNil(ExifEditor.read(from: source).location)
        XCTAssertNil(ExifEditor.read(from: source).altitude)
    }

    func testPrivacyStrippingRemovesSensitiveFieldsButPreservesCameraAndPixels() throws {
        let url = try fixture(properties: cameraProperties)
        let before = ExifEditor.read(from: url)
        XCTAssertEqual(before.userComment, "Synthetic private comment")
        XCTAssertNotNil(before.location)
        XCTAssertEqual(before.altitude, -7.5)
        let camera = ExifEditor.readCameraInfo(from: url)
        XCTAssertEqual(camera.bodySerialNumber, "TEST-SERIAL-ONLY")
        let pixels = try MetadataTestFixtures.decodedPixels(at: url)

        try ExifEditor.stripPrivacyFields(at: url)
        let after = ExifEditor.read(from: url)
        XCTAssertNil(after.location)
        XCTAssertNil(after.altitude)
        XCTAssertEqual(after.userComment, "")
        let props = try MetadataTestFixtures.properties(at: url)
        XCTAssertFalse(containsNull(props))
        XCTAssertNil(props[kCGImagePropertyGPSDictionary])
        let exif = try dictionary(kCGImagePropertyExifDictionary, at: url)
        XCTAssertNil(exif[kCGImagePropertyExifBodySerialNumber])
        XCTAssertNil(exif[kCGImagePropertyExifUserComment])
        let result = ExifEditor.readCameraInfo(from: url)
        XCTAssertNil(result.bodySerialNumber)
        XCTAssertEqual(result.make, camera.make)
        XCTAssertEqual(result.model, camera.model)
        XCTAssertEqual(result.lensModel, camera.lensModel)
        XCTAssertEqual(result.exposureTime, camera.exposureTime)
        XCTAssertEqual(result.fNumber, camera.fNumber)
        XCTAssertEqual(result.iso, camera.iso)
        XCTAssertEqual(try MetadataTestFixtures.decodedPixels(at: url), pixels)
        try ExifEditor.stripPrivacyFields(at: url)
        XCTAssertEqual(ExifEditor.read(from: url), after)
        try assertNoStagingFiles()
    }

    func testJPEGPrivacyRemovalPreservesFormatDimensionsAndCameraMetadata() throws {
        try assertPrivacyRemoval(type: .jpeg)
    }

    func testPNGPrivacyRemovalPreservesFormatDimensionsAndCameraMetadata() throws {
        try assertPrivacyRemoval(type: .png)
    }

    func testUnwritableDestinationFailsWithoutChangingSourceOrLeavingStagingFiles() throws {
        let source = try fixture(properties: cameraProperties)
        let bytes = try Data(contentsOf: source)
        let output = root.appendingPathComponent("nonexistent-parent/output.tiff")
        XCTAssertThrowsError(try ExifEditor.write(.empty, from: source, to: output)) { error in
            guard case ExifEditorError.writeFailed = error else {
                return XCTFail("Expected writeFailed, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try assertNoStagingFiles()
    }

    func testIPTCFieldsAndRatingClampingSurviveImageIOSerialization() throws {
        for (rating, expected) in [(-2, 0), (3, 3), (9, 5)] {
            let url = try fixture(properties: [
                kCGImagePropertyIPTCDictionary: [
                    kCGImagePropertyIPTCCaptionAbstract: "IPTC description",
                    kCGImagePropertyIPTCByline: ["IPTC artist"],
                    kCGImagePropertyIPTCCopyrightNotice: "IPTC copyright",
                    kCGImagePropertyIPTCKeywords: ["one", "two"],
                    kCGImagePropertyIPTCStarRating: rating
                ]
            ])
            let inputIPTC = try dictionary(kCGImagePropertyIPTCDictionary, at: url)
            XCTAssertEqual(inputIPTC[kCGImagePropertyIPTCStarRating] as? Int, rating)
            let result = ExifEditor.read(from: url)
            XCTAssertEqual(result.imageDescription, "IPTC description")
            XCTAssertEqual(result.artist, "IPTC artist")
            XCTAssertEqual(result.copyright, "IPTC copyright")
            XCTAssertEqual(result.keywords, ["one", "two"])
            XCTAssertEqual(result.rating, expected)
        }
    }
}
