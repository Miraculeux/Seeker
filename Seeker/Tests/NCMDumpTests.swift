import CommonCrypto
import Foundation
import XCTest
@testable import Seeker

final class NCMDumpTests: XCTestCase {
    private let coreKey = Array("hzHRAmso5kInbaxW".utf8)
    private let metadataKey: [UInt8] = [
        0x23, 0x31, 0x34, 0x6C, 0x6A, 0x6B, 0x5F, 0x21,
        0x5C, 0x5D, 0x26, 0x30, 0x55, 0x3C, 0x27, 0x28
    ]

    private func encrypt(_ plaintext: [UInt8], key: [UInt8], padded: Bool = true) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: plaintext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = key.withUnsafeBytes { keyBytes in
            plaintext.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { result in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | (padded ? kCCOptionPKCS7Padding : 0)),
                        keyBytes.baseAddress, key.count, nil,
                        input.baseAddress, plaintext.count,
                        result.baseAddress, result.count, &moved
                    )
                }
            }
        }
        let success = CCCryptorStatus(kCCSuccess)
        XCTAssertEqual(status, success)
        guard status == success else { throw NSError(domain: "NCMDumpTests.AES", code: Int(status)) }
        return Array(output.prefix(moved))
    }

    private func le32(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private func be32(_ bytes: Data) -> Int {
        bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    private func directory() throws -> URL {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repository.appendingPathComponent(".ncmdump-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func file(_ bytes: Data, in root: URL, name: String = "synthetic.ncm") throws -> URL {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func keyHeader() throws -> Data {
        let key = try encrypt(Array("neteasecloudmusic".utf8) + [1, 2, 3, 4], key: coreKey)
        return Data("CTENFDAM".utf8) + Data([0, 0]) + le32(UInt32(key.count)) + Data(key.map { $0 ^ 0x64 })
    }

    private func flacBlock(_ type: UInt8, _ body: Data, last: Bool) -> Data {
        Data([type | (last ? 0x80 : 0), UInt8((body.count >> 16) & 255),
              UInt8((body.count >> 8) & 255), UInt8(body.count & 255)]) + body
    }

    private func flacBlocks(_ data: Data) throws -> ([(UInt8, Data)], Data) {
        var blocks: [(UInt8, Data)] = []
        var offset = 4
        while true {
            guard offset + 4 <= data.count else { throw NSError(domain: "NCMDumpTests.FLAC", code: 1) }
            let header = data[offset]
            let count = be32(data.subdata(in: (offset + 1)..<(offset + 4)))
            offset += 4
            guard offset + count <= data.count else { throw NSError(domain: "NCMDumpTests.FLAC", code: 2) }
            blocks.append((header & 127, data.subdata(in: offset..<(offset + count))))
            offset += count
            if header & 128 != 0 { return (blocks, Data(data.dropFirst(offset))) }
        }
    }

    func testAESNISTECBKnownBlockAndDecryption() throws {
        let key: [UInt8] = [0x2B, 0x7E, 0x15, 0x16, 0x28, 0xAE, 0xD2, 0xA6,
                            0xAB, 0xF7, 0x15, 0x88, 0x09, 0xCF, 0x4F, 0x3C]
        let plain: [UInt8] = [0x6B, 0xC1, 0xBE, 0xE2, 0x2E, 0x40, 0x9F, 0x96,
                              0xE9, 0x3D, 0x7E, 0x11, 0x73, 0x93, 0x17, 0x2A]
        let knownCipher: [UInt8] = [0x3A, 0xD7, 0x7B, 0xB4, 0x0D, 0x7A, 0x36, 0x60,
                                    0xA8, 0x9E, 0xCA, 0xF3, 0x24, 0x66, 0xEF, 0x97]
        let paddedCipher = try encrypt(plain, key: key)
        XCTAssertEqual(Array(paddedCipher.prefix(16)), knownCipher)
        XCTAssertEqual(AESHelper.ecbDecrypt(key: key, data: knownCipher + Array(paddedCipher.dropFirst(16))), plain)
    }

    func testAESPKCS7RoundTripsAtBlockBoundaries() throws {
        for count in [0, 1, 15, 16, 17, 31, 32, 100] {
            let plaintext = (0..<count).map { UInt8(truncatingIfNeeded: $0) }
            let encrypted = try encrypt(plaintext, key: coreKey)
            XCTAssertEqual(encrypted.count % 16, 0)
            XCTAssertEqual(AESHelper.ecbDecrypt(key: coreKey, data: encrypted), plaintext)
        }
    }

    func testAESInvalidKeysLengthsAndPaddingFailWithoutPartialPlaintext() throws {
        for key in [[], Array(repeating: UInt8(0), count: 15), Array(repeating: UInt8(0), count: 17)] {
            XCTAssertTrue(AESHelper.ecbDecrypt(key: key, data: Array(repeating: 0, count: 16)).isEmpty)
        }
        for count in [0, 1, 15, 17] {
            XCTAssertTrue(AESHelper.ecbDecrypt(key: coreKey, data: Array(repeating: 0, count: count)).isEmpty)
        }
        let invalidPlaintexts: [[UInt8]] = [
            Array(repeating: 0, count: 16),
            Array(repeating: 0, count: 15) + [17],
            Array(repeating: 0, count: 14) + [1, 2]
        ]
        for plaintext in invalidPlaintexts {
            let invalidPadding = try encrypt(plaintext, key: coreKey, padded: false)
            XCTAssertEqual(AESHelper.ecbDecrypt(key: coreKey, data: invalidPadding), [],
                           "Raw AES block with invalid PKCS#7 tail \(Array(plaintext.suffix(2)))")
        }
    }

    func testMusicMetadataExtractsFieldsAndSkipsMalformedArtistEntries() throws {
        let metadata = try XCTUnwrap(MusicMetadata(json: [
            "musicName": "Synthetic title", "album": "Test album", "format": "flac",
            "bitrate": 320_000, "duration": 123,
            "artist": [["First", 1], [], [2, "not a name"], ["第二", 2]] as [[Any]]
        ]))
        XCTAssertEqual(metadata.name, "Synthetic title")
        XCTAssertEqual(metadata.album, "Test album")
        XCTAssertEqual(metadata.format, "flac")
        XCTAssertEqual(metadata.bitrate, 320_000)
        XCTAssertEqual(metadata.duration, 123)
        XCTAssertEqual(metadata.artist, "First/第二")
    }

    func testMusicMetadataMissingAndWrongTypedFieldsHaveSafeDefaults() throws {
        let inputs: [[String: Any]] = [[:], [
            "musicName": 1, "album": NSNull(), "format": [], "bitrate": "320",
            "duration": "123", "artist": "not an array"
        ]]
        for json in inputs {
            let metadata = try XCTUnwrap(MusicMetadata(json: json))
            XCTAssertEqual(metadata.name, "")
            XCTAssertEqual(metadata.album, "")
            XCTAssertEqual(metadata.artist, "")
            XCTAssertEqual(metadata.format, "")
            XCTAssertEqual(metadata.bitrate, 0)
            XCTAssertEqual(metadata.duration, 0)
        }
    }

    func testID3WriterBuildsTextFramesWithSyncsafeSizeAndPreservesAudio() throws {
        let audio = Data([0xFF, 0xFB, 1, 2, 3])
        XCTAssertEqual(ID3Writer.writeTag(to: audio, title: "", artist: nil, album: nil,
                                         imageData: Data(), imageMimeType: nil), audio)
        let result = try XCTUnwrap(ID3Writer.writeTag(
            to: audio, title: String(repeating: "猫", count: 50), artist: "Artist", album: "Album",
            imageData: nil, imageMimeType: nil
        ))
        XCTAssertEqual(Data(result.prefix(6)), Data([0x49, 0x44, 0x33, 3, 0, 0]))
        let tagSize = result[6..<10].reduce(0) { ($0 << 7) | Int($1) }
        XCTAssertTrue(result[6..<10].allSatisfy { $0 < 128 })
        XCTAssertEqual(tagSize + 10 + audio.count, result.count)
        var offset = 10
        for (id, text) in [("TIT2", String(repeating: "猫", count: 50)), ("TPE1", "Artist"), ("TALB", "Album")] {
            XCTAssertEqual(String(data: result.subdata(in: offset..<(offset + 4)), encoding: .ascii), id)
            let size = be32(result.subdata(in: (offset + 4)..<(offset + 8)))
            XCTAssertEqual(size, text.utf16.count * 2 + 5)
            let payload = result.subdata(in: (offset + 10)..<(offset + 10 + size))
            XCTAssertEqual(ID3Frame.decodeText(payload), text)
            offset += 10 + size
        }
        XCTAssertEqual(Data(result.suffix(audio.count)), audio)
    }

    func testUnicodeID3v23TextUsesValidUTF16BOMAndRoundTripsThroughNativeReader() throws {
        let root = try directory()
        let title = "猫 🎵 café"
        let artist = "作曲家 / Björk"
        let album = "Synthetic α"
        let audio = Data([0xFF, 0xFB, 1, 2, 3])
        let tagged = try XCTUnwrap(ID3Writer.writeTag(
            to: audio, title: title, artist: artist, album: album, imageData: nil, imageMimeType: nil
        ))
        XCTAssertEqual(tagged[3], 3)
        let url = try file(tagged, in: root, name: "unicode.mp3")
        let parsed = try ID3v2File.read(url)
        XCTAssertEqual(parsed.frames.map(\.id), ["TIT2", "TPE1", "TALB"])
        for (frame, text) in zip(parsed.frames, [title, artist, album]) {
            XCTAssertEqual(Array(frame.data.prefix(3)), [0x01, 0xFF, 0xFE])
            XCTAssertEqual(Array(frame.data.suffix(2)), [0, 0])
            var expected = Data([0x01, 0xFF, 0xFE])
            for codeUnit in text.utf16 {
                expected.append(UInt8(truncatingIfNeeded: codeUnit))
                expected.append(UInt8(truncatingIfNeeded: codeUnit >> 8))
            }
            expected.append(contentsOf: [0, 0])
            XCTAssertEqual(frame.data, expected)
        }
        let decoded = Dictionary(uniqueKeysWithValues: parsed.decoded().entries.map { ($0.key, $0.value) })
        XCTAssertEqual(decoded["TITLE"], title)
        XCTAssertEqual(decoded["ARTIST"], artist)
        XCTAssertEqual(decoded["ALBUM"], album)
        let inMemory = try ID3v2File.parse(tagged, url: url)
        XCTAssertEqual(inMemory.body, audio)
    }

    func testID3WriterReplacesOldTagAndWritesFrontCoverPayload() throws {
        let audio = Data([1, 2, 3])
        let old = try XCTUnwrap(ID3Writer.writeTag(to: audio, title: "old", artist: nil,
                                                  album: nil, imageData: nil, imageMimeType: nil))
        let cover = Data([9, 8, 7])
        let new = try XCTUnwrap(ID3Writer.writeTag(to: old, title: nil, artist: nil,
                                                  album: nil, imageData: cover, imageMimeType: "image/png"))
        XCTAssertEqual(String(data: new.subdata(in: 10..<14), encoding: .ascii), "APIC")
        let expected = Data([0]) + Data("image/png".utf8) + Data([0, 3, 0]) + cover
        XCTAssertEqual(new.subdata(in: 20..<(new.count - audio.count)), expected)
        XCTAssertEqual(Data(new.suffix(audio.count)), audio)
        XCTAssertEqual(new.count, 10 + 10 + expected.count + audio.count)
    }

    func testID3MalformedOrTruncatedOldTagsAreNotStripped() throws {
        for original in [
            Data([0x49, 0x44, 0x33]),
            Data([0x49, 0x44, 0x33, 3, 0, 0, 0x80, 0, 0, 0, 9]),
            Data([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 127, 9])
        ] {
            let result = try XCTUnwrap(ID3Writer.writeTag(to: original, title: "new", artist: nil,
                                                         album: nil, imageData: nil, imageMimeType: nil))
            XCTAssertEqual(Data(result.suffix(original.count)), original)
        }
    }

    func testFLACWriterReplacesCommentsPreservesOtherBlocksAndAudio() throws {
        let streamInfo = Data(repeating: 0, count: 34)
        let audio = Data([0xFF, 0xF8, 9, 8, 7])
        let original = Data("fLaC".utf8) + flacBlock(0, streamInfo, last: false)
            + flacBlock(4, Data("old comments".utf8), last: false)
            + flacBlock(6, Data("old picture".utf8), last: true) + audio
        let rewritten = try XCTUnwrap(FLACWriter.writeMetadata(to: original, title: "猫", artist: "Artist",
                                                              album: "", imageData: nil, imageMimeType: nil))
        let (blocks, tail) = try flacBlocks(rewritten)
        XCTAssertEqual(blocks.map { $0.0 }, [0, 4])
        XCTAssertEqual(blocks[0].1, streamInfo)
        let vendor = Data("ncmdump-swift".utf8)
        let title = Data("TITLE=猫".utf8)
        let artist = Data("ARTIST=Artist".utf8)
        let expected = le32(UInt32(vendor.count)) + vendor + le32(2)
            + le32(UInt32(title.count)) + title + le32(UInt32(artist.count)) + artist
        XCTAssertEqual(blocks[1].1, expected)
        XCTAssertEqual(tail, audio)
    }

    func testFLACWriterPictureBlockUsesBigEndianLengthsAndLastBlockFlag() throws {
        let original = Data("fLaC".utf8) + flacBlock(0, Data(repeating: 0, count: 34), last: true)
        let image = Data([1, 2, 3, 4])
        let rewritten = try XCTUnwrap(FLACWriter.writeMetadata(to: original, title: nil, artist: nil,
                                                              album: nil, imageData: image, imageMimeType: nil))
        let (blocks, tail) = try flacBlocks(rewritten)
        XCTAssertEqual(blocks.map { $0.0 }, [0, 4, 6])
        XCTAssertTrue(tail.isEmpty)
        let picture = blocks[2].1
        XCTAssertEqual(be32(Data(picture.prefix(4))), 3)
        XCTAssertEqual(be32(picture.subdata(in: 4..<8)), 10)
        XCTAssertEqual(String(data: picture.subdata(in: 8..<18), encoding: .ascii), "image/jpeg")
        XCTAssertEqual(be32(picture.subdata(in: 38..<42)), image.count)
        XCTAssertEqual(Data(picture.suffix(image.count)), image)
    }

    func testFLACInvalidMarkersAndTruncatedStreamingHeadersFailSafely() throws {
        for data in [Data(), Data("fLaC".utf8), Data("not FLAC".utf8)] {
            XCTAssertNil(FLACWriter.writeMetadata(to: data, title: "test", artist: nil,
                                                  album: nil, imageData: nil, imageMimeType: nil))
        }
        let root = try directory()
        for data in [Data("not FLAC".utf8), Data("fLaC".utf8), Data("fLaC".utf8) + Data([0x80, 0, 0, 34, 1])] {
            let url = try file(data, in: root, name: "truncated.flac")
            XCTAssertThrowsError(try FLACWriter.rewriteFile(at: url, title: "test", artist: nil,
                                                           album: nil, imageData: nil, imageMimeType: nil))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testNCMRejectsMissingWrongMagicAndTruncatedHeaders() throws {
        let root = try directory()
        XCTAssertThrowsError(try NCMCrypt(path: root.appendingPathComponent("missing.ncm").path))
        for bytes in [Data(), Data("CTEN".utf8), Data("WRONGHDR".utf8),
                      Data("CTENFDAM".utf8), Data("CTENFDAM".utf8) + Data([0, 0, 1])] {
            let url = try file(bytes, in: root)
            XCTAssertThrowsError(try NCMCrypt(path: url.path))
        }
    }

    func testNCMRejectsOversizedKeyMetadataAndCoverLengths() throws {
        let root = try directory()
        let prefix = Data("CTENFDAM".utf8) + Data([0, 0])
        let key = try keyHeader()
        let coverPrefix = key + le32(0) + Data(repeating: 0, count: 5)
        let maxMetadata: UInt32 = 1 << 20
        let maxCover: UInt32 = 32 << 20
        var invalid: [Data] = []
        invalid.append(prefix + le32(0))
        invalid.append(prefix + le32(4097))
        invalid.append(prefix + le32(UInt32.max))
        invalid.append(key + le32(maxMetadata + 1))
        var oversizedCover = coverPrefix
        oversizedCover.append(le32(maxCover + 1))
        oversizedCover.append(le32(0))
        invalid.append(oversizedCover)
        var oversizedImage = coverPrefix
        oversizedImage.append(le32(maxCover))
        oversizedImage.append(le32(maxCover + 1))
        invalid.append(oversizedImage)
        var imageExceedsFrame = coverPrefix
        imageExceedsFrame.append(le32(1))
        imageExceedsFrame.append(le32(2))
        invalid.append(imageExceedsFrame)
        for bytes in invalid {
            let url = try file(bytes, in: root)
            XCTAssertThrowsError(try NCMCrypt(path: url.path)) { error in
                guard case NCMCryptError.brokenNCMFile = error else {
                    return XCTFail("Expected brokenNCMFile, got \(error)")
                }
            }
        }
    }

    func testNCMRejectsTruncatedFieldsAndInvalidEncryptedKey() throws {
        let root = try directory()
        let prefix = Data("CTENFDAM".utf8) + Data([0, 0])
        let shortKey = try encrypt(Array(repeating: 0, count: 17), key: coreKey)
        let key = try keyHeader()
        var invalid: [Data] = []
        invalid.append(prefix + le32(16) + Data([1]))
        invalid.append(prefix + le32(1) + Data([0]))
        let wrappedShortKey = Data(shortKey.map { $0 ^ UInt8(0x64) })
        var shortKeyHeader = prefix
        shortKeyHeader.append(le32(UInt32(shortKey.count)))
        shortKeyHeader.append(wrappedShortKey)
        invalid.append(shortKeyHeader)
        invalid.append(key + le32(4) + Data([1]))
        invalid.append(key + le32(0) + Data(repeating: 0, count: 4))
        var truncatedImage = key
        truncatedImage.append(le32(0))
        truncatedImage.append(Data(repeating: 0, count: 5))
        truncatedImage.append(le32(3))
        truncatedImage.append(le32(3))
        truncatedImage.append(Data([1]))
        invalid.append(truncatedImage)
        for bytes in invalid {
            let url = try file(bytes, in: root)
            XCTAssertThrowsError(try NCMCrypt(path: url.path))
        }
    }

    func testFullySyntheticNCMDecryptsAcrossStreamingBoundaryAndWritesMetadata() throws {
        let root = try directory()
        let json = try JSONSerialization.data(withJSONObject: [
            "musicName": "Synthetic title", "album": "Synthetic album", "format": "mp3",
            "artist": [["Synthetic artist", 1]]
        ])
        let encryptedMetadata = try encrypt(Array("music:".utf8) + Array(json), key: metadataKey)
        let encodedMetadata = Data("163 key(Don't modify):".utf8)
            + Data(Data(encryptedMetadata).base64EncodedString().utf8)
        let cover = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let audio = Data((0..<((1 << 18) + 257)).map { UInt8(truncatingIfNeeded: $0) })
        let sourceAudio = Data([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 0]) + audio

        var box = Array(UInt8.min...UInt8.max)
        let rc4Key: [UInt8] = [1, 2, 3, 4]
        var previous = 0
        for index in 0..<256 {
            let next = (Int(box[index]) + previous + Int(rc4Key[index % rc4Key.count])) & 255
            box.swapAt(index, next)
            previous = next
        }
        let encryptedAudio = Data(sourceAudio.enumerated().map { index, byte in
            let position = (index + 1) & 255
            let first = Int(box[position])
            let second = Int(box[(first + position) & 255])
            return byte ^ box[(first + second) & 255]
        })
        var bytes = try keyHeader()
        bytes.append(le32(UInt32(encodedMetadata.count)))
        bytes.append(Data(encodedMetadata.map { $0 ^ UInt8(0x63) }))
        bytes.append(Data(repeating: 0, count: 5))
        bytes.append(le32(UInt32(cover.count + 2)))
        bytes.append(le32(UInt32(cover.count)))
        bytes.append(cover)
        bytes.append(contentsOf: [0, 0])
        bytes.append(encryptedAudio)
        let url = try file(bytes, in: root)
        var crypt = try NCMCrypt(path: url.path)
        XCTAssertEqual(crypt.metadata?.name, "Synthetic title")
        XCTAssertEqual(crypt.metadata?.artist, "Synthetic artist")
        XCTAssertEqual(crypt.imageData, cover)
        try crypt.dump(outputDir: root.path)
        XCTAssertEqual(crypt.dumpFilepath, root.appendingPathComponent("synthetic.mp3").path)
        let expected = try XCTUnwrap(ID3Writer.writeTag(
            to: audio, title: "Synthetic title", artist: "Synthetic artist", album: "Synthetic album",
            imageData: cover, imageMimeType: "image/png"
        ))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: crypt.dumpFilepath)), expected)
    }
}
