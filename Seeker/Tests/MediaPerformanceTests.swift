import Foundation
import XCTest
@testable import Seeker

final class MediaPerformanceTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private let tags = [(key: "TITLE", value: "Synthetic streaming regression"),
                        (key: "ARTIST", value: "Seeker test"),
                        (key: "TRACKNUMBER", value: "3")]
    private let cover = (data: Data([0xFF, 0xD8, 0xFF, 0x00, 0xFE]), mime: "image/jpeg")

    override func setUpWithError() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = project.appendingPathComponent(".build/media-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try fm.removeItem(at: root) }
    }

    private var payload: Data {
        Data((0..<(2 * 1024 * 1024 + 137)).map { UInt8(truncatingIfNeeded: $0 * 37) })
    }

    private func be(_ n: UInt64, _ width: Int = 4) -> Data {
        Data((0..<width).reversed().map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) })
    }

    private func le(_ n: UInt64, _ width: Int = 4) -> Data {
        Data((0..<width).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) })
    }

    private func number(_ data: Data, at: Int, width: Int, little: Bool = false) -> UInt64 {
        let bytes = Array(data[at..<(at + width)])
        return (little ? Array(bytes.reversed()) : bytes).reduce(0) { $0 << 8 | UInt64($1) }
    }

    private func atom(_ type: String, _ body: Data, wide: Bool = false) -> Data {
        (wide ? be(1) + Data(type.utf8) + be(UInt64(body.count + 16), 8)
              : be(UInt64(body.count + 8)) + Data(type.utf8)) + body
    }

    private func chunk(_ type: String, _ body: Data, width: Int = 4, little: Bool = false) -> Data {
        Data(type.utf8) + (little ? le(UInt64(body.count), width) : be(UInt64(body.count), width))
            + body + (body.count % 2 == 1 ? Data([0]) : Data())
    }

    private func ebmlSize(_ n: UInt64) -> Data {
        for width in 1...8 where n < (UInt64(1) << (width * 7)) - 1 {
            var bytes = be(n, width)
            bytes[0] |= UInt8(0x80 >> (width - 1))
            return bytes
        }
        preconditionFailure("Fixture exceeds EBML size range")
    }

    private func element(_ id: Data, _ body: Data) -> Data {
        id + ebmlSize(UInt64(body.count)) + body
    }

    private func fixture(_ name: String, _ bytes: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        return url
    }

    private func assertMode(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o640, file: file, line: line)
    }

    private func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    private func oldID3() -> Data {
        ID3v2File.encodeTag(frames: [
            ID3Frame(id: "TIT2", data: ID3Frame.encodeText("old"))
        ], padding: 0)
    }

    func testMP3TagOnlyReadAndStreamingWritePreserveAudioAndTrailer() throws {
        let audio = payload
        let trailer = Data("TAG".utf8) + Data(repeating: 0x6B, count: 125)
        for tagged in [false, true] {
            let url = try fixture("audio-\(tagged).mp3", (tagged ? oldID3() : Data()) + audio + trailer)
            XCTAssertTrue(try ID3v2File.read(url).body.isEmpty)
            try ID3v2File.write(url: url, entries: tags, cover: cover)
            let parsed = try ID3v2File.parse(read(url), url: url)
            XCTAssertEqual(parsed.body, audio + trailer)
            XCTAssertEqual(parsed.decoded().cover?.data, cover.data)
            XCTAssertTrue(parsed.decoded().entries.contains { $0.key == "TITLE" && $0.value == tags[0].value })
            try assertMode(url)
        }
    }

    func testLargeMP3ReadDoesNotRetainAudio() throws {
        let url = try fixture("large.mp3", oldID3())
        let output = try FileHandle(forWritingTo: url)
        try output.truncate(atOffset: 256 * 1024 * 1024)
        try output.close()
        let parsed = try ID3v2File.read(url)
        XCTAssertTrue(parsed.body.isEmpty)
        XCTAssertEqual(parsed.decoded().entries.first?.value, "old")
    }

    func testFLACRewritePreservesAudioWithGrowingAndReusablePadding() throws {
        let audio = payload
        let url = try fixture("audio.flac",
            Data("fLaC".utf8) + Data([0x80, 0, 0, 34]) + Data(count: 34) + audio)
        for title in ["short", String(repeating: "Long", count: 1500), "short again"] {
            var parsed = try FlacFile.read(url)
            parsed.setVorbisComment(VorbisComment(vendor: "regression", entries: [("TITLE", title)]))
            try parsed.write()
            let updated = try FlacFile.read(url)
            XCTAssertEqual(updated.vorbisComment.entries.first?.value, title)
            XCTAssertEqual(try read(url).dropFirst(updated.audioOffset), audio)
            try assertMode(url)
        }
    }

    func testAIFFRewritePreservesChunksAndOddPadding() throws {
        let body = chunk("COMM", Data(repeating: 3, count: 18))
            + chunk("SSND", payload) + chunk("ODD!", Data([1, 2, 3]))
        let url = try fixture("audio.aiff",
            Data("FORM".utf8) + be(UInt64(body.count + 4)) + Data("AIFF".utf8) + body)
        for _ in 0..<2 {
            try AIFFFile.write(url: url, entries: tags, cover: cover)
            let bytes = try read(url)
            XCTAssertEqual(bytes.subdata(in: 12..<(12 + body.count)), body)
            XCTAssertEqual(number(bytes, at: 4, width: 4), UInt64(bytes.count - 8))
            XCTAssertEqual(try AIFFFile.read(url).decoded().cover?.data, cover.data)
            try assertMode(url)
        }
    }

    func testDFFRewritePreservesAudioAndTechnicalInfo() throws {
        let prop = Data("SND ".utf8) + chunk("FS  ", be(2_822_400), width: 8)
            + chunk("CHNL", be(2, 2), width: 8)
        let body = chunk("PROP", prop, width: 8) + chunk("DSD ", payload, width: 8)
            + chunk("ODD!", Data([7, 8, 9]), width: 8)
        let url = try fixture("audio.dff",
            Data("FRM8".utf8) + be(UInt64(body.count + 4), 8) + Data("DSD ".utf8) + body)
        for _ in 0..<2 {
            try DFFFile.write(url: url, entries: tags, cover: cover)
            let bytes = try read(url)
            XCTAssertEqual(bytes.subdata(in: 16..<(16 + body.count)), body)
            XCTAssertEqual(number(bytes, at: 4, width: 8), UInt64(bytes.count - 12))
            let parsed = try DFFFile.read(url)
            XCTAssertEqual(parsed.techInfo.sampleRate, 2_822_400)
            XCTAssertEqual(parsed.techInfo.channels, 2)
            XCTAssertEqual(parsed.decoded().cover?.data, cover.data)
            try assertMode(url)
        }
    }

    private func dsfFormat(channelType: UInt64, channels: UInt64, sampleRate: UInt64,
                           bitOrder: UInt64, sampleCount: UInt64) -> Data {
        var format = Data("fmt ".utf8) + le(52, 8)
        format += le(1) + le(0) + le(channelType) + le(channels)
        format += le(sampleRate) + le(bitOrder) + le(sampleCount, 8)
        format += le(4096) + le(0)
        return format
    }

    func testDSFTechnicalInfoUsesFormatOffsetsAnd64BitSampleCount() throws {
        // DSD256 header values from the reported file; sample count exceeds UInt32.
        let sampleCount: UInt64 = 0x000000018ECB4600
        for bitOrder: UInt64 in [1, 8] {
            let format = dsfFormat(channelType: 2, channels: 2, sampleRate: 11_289_600,
                                   bitOrder: bitOrder, sampleCount: sampleCount)
            let url = try fixture("header-\(bitOrder).dsf", Data("DSD ".utf8)
                + le(28, 8) + le(80, 8) + le(0, 8) + format)
            let parsed = try DSFFile.read(url)
            let info = TechnicalInfoService.finalize(
                TechnicalInfoService.from(dsf: parsed, fileSize: 80))
            XCTAssertEqual(info.container, "DSF")
            XCTAssertEqual(info.codec, "DSD")
            XCTAssertTrue(info.isDSD)
            XCTAssertEqual(info.channels, 2)
            XCTAssertEqual(info.sampleRate, 11_289_600)
            XCTAssertEqual(info.bitsPerSample, 1)
            XCTAssertEqual(info.bitrate, 22_579_200)
            let duration = try XCTUnwrap(info.durationSeconds)
            XCTAssertEqual(duration, 592.638685, accuracy: 0.000001)
            XCTAssertEqual(Int(duration) / 60, 9)
            XCTAssertEqual(Int(duration) % 60, 52)
            XCTAssertNil(parsed.id3Tag)
        }
    }

    func testDSFChannelCountIsNotChannelType() throws {
        let format = dsfFormat(channelType: 6, channels: 5, sampleRate: 2_822_400,
                               bitOrder: 1, sampleCount: 4_233_600)
        let url = try fixture("multichannel.dsf", Data("DSD ".utf8)
            + le(28, 8) + le(80, 8) + le(0, 8) + format)
        let info = try DSFFile.read(url).techInfo
        XCTAssertEqual(info.channels, 5)
        XCTAssertEqual(info.sampleRate, 2_822_400)
        XCTAssertEqual(info.durationSeconds, 1.5)
        XCTAssertEqual(info.bitrate, 14_112_000)
    }

    func testDSFRewritePreservesAudioAndPatchesPointers() throws {
        let audio = payload
        let sampleCount = UInt64(audio.count) * 4
        let body = dsfFormat(channelType: 2, channels: 2, sampleRate: 2_822_400,
                             bitOrder: 1, sampleCount: sampleCount)
            + Data("data".utf8) + le(UInt64(audio.count + 12), 8) + audio
        let url = try fixture("audio.dsf", Data("DSD ".utf8) + le(28, 8)
            + le(UInt64(28 + body.count), 8) + le(0, 8) + body)
        let originalInfo = try DSFFile.read(url).techInfo
        for _ in 0..<2 {
            try DSFFile.write(url: url, entries: tags, cover: cover)
            let bytes = try read(url)
            XCTAssertEqual(bytes.subdata(in: 28..<(28 + body.count)), body)
            XCTAssertEqual(number(bytes, at: 12, width: 8, little: true), UInt64(bytes.count))
            XCTAssertEqual(number(bytes, at: 20, width: 8, little: true), UInt64(28 + body.count))
            let parsed = try DSFFile.read(url)
            XCTAssertEqual(parsed.decoded().cover?.data, cover.data)
            XCTAssertEqual(parsed.techInfo, originalInfo)
            try assertMode(url)
        }
    }

    func testAVIRewritePreservesMediaAndPadding() throws {
        let body = chunk("LIST", Data("movi".utf8) + payload, little: true)
            + chunk("JUNK", Data([3, 4, 5]), little: true)
        let url = try fixture("video.avi",
            Data("RIFF".utf8) + le(UInt64(body.count + 4)) + Data("AVI ".utf8) + body)
        for _ in 0..<2 {
            try AVIFile.write(url: url, entries: tags)
            let bytes = try read(url)
            XCTAssertEqual(bytes.subdata(in: 12..<(12 + body.count)), body)
            XCTAssertEqual(number(bytes, at: 4, width: 4, little: true), UInt64(bytes.count - 8))
            XCTAssertTrue(try AVIFile.read(url).entries.contains { $0.key == "TITLE" && $0.value == tags[0].value })
            try assertMode(url)
        }
    }

    private func moov(_ offsets: [UInt64], wide: Bool = false) -> Data {
        let table32 = Data(count: 4) + be(UInt64(offsets.count)) + offsets.reduce(Data()) { $0 + be($1) }
        let table64 = Data(count: 4) + be(UInt64(offsets.count)) + offsets.reduce(Data()) { $0 + be($1, 8) }
        return atom("moov", atom("trak", atom("mdia", atom("minf",
            atom("stbl", atom("stco", table32) + atom("co64", table64))))), wide: wide)
    }

    func testMP4PreservesMediaAndOffsetsAcrossMoovLayouts() throws {
        let audio = payload
        for layout in 0..<4 {
            let ftyp = atom("ftyp", Data("isom".utf8))
            let mdat = atom("mdat", audio)
            let wide = layout >= 2
            let before = layout == 0 || layout == 3
            let dummy = moov([0, 0], wide: wide)
            let first = UInt64(ftyp.count + (before ? dummy.count : 0) + 8)
            let second = first + UInt64(mdat.count + (layout == 1 ? dummy.count : 0))
            let movie = moov([first, second], wide: wide)
            let original: Data
            if before { original = ftyp + movie + mdat + mdat }
            else if layout == 1 { original = ftyp + mdat + movie + mdat }
            else { original = ftyp + mdat + mdat + movie }
            let url = try fixture("video-\(layout).mp4", original)
            for artwork in [MP4File.Cover(data: cover.data, mime: cover.mime), nil] {
                try MP4File.write(url: url, entries: tags, cover: artwork)
                let bytes = try read(url)
                var p = 0
                var offsets: [UInt64] = []
                while p + 8 <= bytes.count {
                    let size = Int(number(bytes, at: p, width: 4))
                    guard size >= 8, size <= bytes.count - p else {
                        XCTFail("Invalid output atom size"); return
                    }
                    if bytes.subdata(in: (p + 4)..<(p + 8)) == Data("mdat".utf8) {
                        XCTAssertEqual(bytes.subdata(in: (p + 8)..<(p + size)), audio)
                        offsets.append(UInt64(p + 8))
                    }
                    p += size
                }
                XCTAssertEqual(offsets.count, 2)
                guard offsets.count == 2 else { return }
                for (kind, width) in [("stco", 4), ("co64", 8)] {
                    let range = try XCTUnwrap(bytes.range(of: Data(kind.utf8)))
                    let start = range.lowerBound + 12
                    XCTAssertEqual(number(bytes, at: start, width: width), offsets[0])
                    XCTAssertEqual(number(bytes, at: start + width, width: width), offsets[1])
                }
                XCTAssertEqual(try MP4File.read(url).decoded().cover?.data, artwork?.data)
                try assertMode(url)
            }
        }
    }

    func testMatroskaPreservesClusterAndCueOffsetsAndReusesTrailingMetadata() throws {
        let ebml = element(Data([0x1A, 0x45, 0xDF, 0xA3]), Data())
        let cluster = element(Data([0x1F, 0x43, 0xB6, 0x75]), payload)
        let cues = element(Data([0x1C, 0x53, 0xBB, 0x6B]), Data([0x80]))
        let seek = element(Data([0x11, 0x4D, 0x9B, 0x74]), Data([0xEC, 0x80]))
        let original = ebml + element(Data([0x18, 0x53, 0x80, 0x67]), seek + cluster + cues)
        let url = try fixture("video.mkv", original)
        let clusterOffset = try XCTUnwrap(original.range(of: cluster)).lowerBound
        let cuesOffset = try XCTUnwrap(original.range(of: cues)).lowerBound
        var savedSize: Int?
        for _ in 0..<2 {
            try MatroskaFile.write(url: url, entries: tags, cover: cover)
            let bytes = try read(url)
            if let savedSize { XCTAssertEqual(bytes.count, savedSize) }
            savedSize = bytes.count
            XCTAssertEqual(bytes.subdata(in: clusterOffset..<(clusterOffset + cluster.count)), cluster)
            XCTAssertEqual(bytes.subdata(in: cuesOffset..<(cuesOffset + cues.count)), cues)
            let parsed = try MatroskaFile.read(url)
            XCTAssertTrue(parsed.entries.contains { $0.key == "TITLE" && $0.value == tags[0].value })
            XCTAssertEqual(parsed.cover?.data, cover.data)
            try assertMode(url)
        }
    }

    func testShortReadRollsBackAndCleansStagingFile() throws {
        let original = oldID3() + payload
        let url = try fixture("failure.mp3", original)
        XCTAssertThrowsError(try MediaFileIO.rewrite(url) { input, size, output in
            try MediaFileIO.copy(input, to: output, range: 0..<(size + 1))
        })
        XCTAssertEqual(try read(url), original)
        try assertMode(url)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.contains(".tmp-") })
    }

    func testMalformedContainersFailWithoutReplacingOriginals() throws {
        func rejected(_ name: String, bytes: Data, write: (URL) throws -> Void) throws {
            let url = try fixture(name, bytes)
            XCTAssertThrowsError(try write(url), name)
            XCTAssertEqual(try read(url), bytes, name)
            try assertMode(url)
        }
        try rejected("bad.mp3", bytes: oldID3().prefix(10)) {
            try ID3v2File.write(url: $0, entries: tags, cover: nil)
        }
        try rejected("bad.aiff", bytes: Data("FORM".utf8) + be(20) + Data("AIFFSSND".utf8) + be(999)) {
            try AIFFFile.write(url: $0, entries: tags, cover: nil)
        }
        try rejected("bad.dff", bytes: Data("FRM8".utf8) + be(20, 8) + Data("DSD DSD ".utf8) + be(999, 8)) {
            try DFFFile.write(url: $0, entries: tags, cover: nil)
        }
        try rejected("bad.avi", bytes: Data("RIFF".utf8) + le(20) + Data("AVI LIST".utf8) + le(999)) {
            try AVIFile.write(url: $0, entries: tags)
        }
        try rejected("bad.dsf", bytes: Data("DSD ".utf8) + le(28, 8) + le(28, 8) + le(1, 8)) {
            try DSFFile.write(url: $0, entries: tags, cover: nil)
        }
        try rejected("bad.mp4", bytes: atom("ftyp", Data("isom".utf8))) {
            try MP4File.write(url: $0, entries: tags, cover: nil)
        }
        let ebml = element(Data([0x1A, 0x45, 0xDF, 0xA3]), Data())
        try rejected("bad.mkv", bytes: ebml + Data([0x18, 0x53, 0x80, 0x67, 0x8F])) {
            try MatroskaFile.write(url: $0, entries: tags, cover: nil)
        }
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.contains(".tmp-") })
    }
}
