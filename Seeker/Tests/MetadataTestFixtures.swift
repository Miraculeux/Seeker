import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Tiny synthetic containers exercise metadata codecs, not media playback.
enum MetadataTestFixtures {
    static func makeDirectory() throws -> URL {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = project.appendingPathComponent(".build/metadata-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static let payload = Data((0..<257).map { UInt8(truncatingIfNeeded: $0 * 37) })

    static func integer(_ value: UInt64, width: Int = 4, littleEndian: Bool = false) -> Data {
        let bytes = (0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        return Data(littleEndian ? bytes : Array(bytes.reversed()))
    }

    static func atom(_ type: String, _ body: Data) -> Data {
        integer(UInt64(body.count + 8)) + Data(type.utf8) + body
    }

    static func chunk(_ type: String, _ body: Data, width: Int = 4,
                      littleEndian: Bool = false) -> Data {
        Data(type.utf8) + integer(UInt64(body.count), width: width, littleEndian: littleEndian)
            + body + (body.count.isMultiple(of: 2) ? Data() : Data([0]))
    }

    static func element(_ id: [UInt8], _ body: Data) -> Data {
        for width in 1...8 where UInt64(body.count) < (UInt64(1) << (width * 7)) - 1 {
            var size = integer(UInt64(body.count), width: width)
            size[0] |= UInt8(0x80 >> (width - 1))
            return Data(id) + size + body
        }
        preconditionFailure("Synthetic EBML body too large")
    }

    static func container(for ext: String) -> Data {
        switch ext.lowercased() {
        case "mp3":
            return payload
        case "flac":
            return Data("fLaC".utf8) + Data([0x80, 0, 0, 34]) + Data(count: 34) + payload
        case "m4a", "m4b", "mp4", "m4v", "mov", "alac":
            return atom("ftyp", Data("isom".utf8) + integer(0) + Data("isom".utf8))
                + atom("moov", Data()) + atom("mdat", payload)
        case "aiff", "aif", "aifc":
            let body = chunk("COMM", Data(count: 18)) + chunk("SSND", Data(count: 8) + payload)
            return Data("FORM".utf8) + integer(UInt64(body.count + 4))
                + Data((ext == "aifc" ? "AIFC" : "AIFF").utf8) + body
        case "mka", "mkv", "webm":
            return element([0x1A, 0x45, 0xDF, 0xA3], Data())
                + element([0x18, 0x53, 0x80, 0x67],
                          element([0x1F, 0x43, 0xB6, 0x75], payload))
        case "avi":
            let body = chunk("LIST", Data("movi".utf8) + payload, littleEndian: true)
            return Data("RIFF".utf8) + integer(UInt64(body.count + 4), littleEndian: true)
                + Data("AVI ".utf8) + body
        case "dsf":
            var format = Data("fmt ".utf8) + integer(52, width: 8, littleEndian: true)
            for value: UInt64 in [1, 0, 2, 2, 2_822_400, 1] {
                format += integer(value, littleEndian: true)
            }
            format += integer(UInt64(payload.count * 4), width: 8, littleEndian: true)
            format += integer(4096, littleEndian: true) + integer(0, littleEndian: true)
            let body = format + Data("data".utf8)
                + integer(UInt64(payload.count + 12), width: 8, littleEndian: true) + payload
            return Data("DSD ".utf8) + integer(28, width: 8, littleEndian: true)
                + integer(UInt64(body.count + 28), width: 8, littleEndian: true)
                + integer(0, width: 8, littleEndian: true) + body
        case "dff":
            let body = chunk("DSD ", payload, width: 8)
            return Data("FRM8".utf8) + integer(UInt64(body.count + 4), width: 8)
                + Data("DSD ".utf8) + body
        default:
            preconditionFailure("Unknown synthetic container")
        }
    }

    static func imageData(type: UTType = .tiff, properties: [CFString: Any] = [:]) throws -> Data {
        var pixelBytes: [UInt8] = []
        for index in 0..<12 {
            let red: UInt8 = UInt8(index * 19)
            let green: UInt8 = UInt8(255 - index * 17)
            let blue: UInt8 = UInt8(index * 11)
            let pixel: [UInt8] = [red, green, blue, 255]
            pixelBytes.append(contentsOf: pixel)
        }
        let pixels: Data = Data(pixelBytes)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 4, height: 3, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func properties(at url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    static func decodedPixels(at url: URL) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }
}
