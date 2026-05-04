import Foundation
import CXXHash

/// Thin Swift wrapper around xxHash3 (XXH3) from the bundled CXXHash C
/// target. xxHash3 is a non-cryptographic hash designed by Yann Collet
/// that achieves ~30 GB/s single-core throughput on modern hardware,
/// making it ideal for content-based file deduplication where the
/// adversarial-collision resistance of SHA / BLAKE is unnecessary.
///
/// We use the 64-bit variant: 2^-64 collision probability is more than
/// enough for duplicate detection (with sub-MB sample sizes the false-
/// positive rate is astronomically low). Callers that want extra
/// safety can verify the final candidate group with byte-by-byte
/// comparison \u2014 see `DuplicateFinder` for the layered strategy.
enum XXHash3 {

    /// Hash an arbitrary byte buffer. Single-shot variant (one C call).
    static func hash(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        guard let base = bytes.baseAddress else { return 0 }
        return UInt64(XXH3_64bits(base, bytes.count))
    }

    /// Hash a `Data` value. Goes through `withUnsafeBytes` so we never
    /// copy the underlying storage.
    static func hash(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { hash($0) }
    }

    /// Streaming hasher. Use this when the input is too large to load
    /// into memory at once (e.g. multi-GB files): allocate one, feed
    /// chunks via `update`, then call `finalize` to get the digest.
    final class Streaming {
        private var state: OpaquePointer?

        init() {
            state = XXH3_createState()
            if let state { XXH3_64bits_reset(state) }
        }

        deinit {
            if let state { XXH3_freeState(state) }
        }

        func update(_ bytes: UnsafeRawBufferPointer) {
            guard let state, let base = bytes.baseAddress, !bytes.isEmpty else { return }
            _ = XXH3_64bits_update(state, base, bytes.count)
        }

        func update(_ data: Data) {
            data.withUnsafeBytes { update($0) }
        }

        func finalize() -> UInt64 {
            guard let state else { return 0 }
            return UInt64(XXH3_64bits_digest(state))
        }
    }

    /// Convenience: stream-hash a file from disk in fixed-size chunks
    /// without ever loading more than `chunkSize` bytes into memory.
    /// Returns `nil` if the file cannot be opened.
    static func hashFile(at url: URL, chunkSize: Int = 1 << 20) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let hasher = Streaming()
        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(chunk)
        }
        return hasher.finalize()
    }

    /// Hash the first `count` bytes of a file. Used as a cheap second-
    /// stage filter in duplicate detection: files of identical size
    /// often differ in their headers (different format, different
    /// encoding parameters), so a small head-hash eliminates most
    /// collisions before paying for the full-file sweep.
    static func hashFileHead(at url: URL, byteCount: Int = 4096) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: byteCount), !chunk.isEmpty else { return nil }
        return hash(chunk)
    }
}
