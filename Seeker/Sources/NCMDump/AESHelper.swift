import Foundation
import CommonCrypto

enum AESHelper {
    /// AES-128-ECB decrypt with PKCS#7 padding removal.
    /// Returns an empty array on failure (callers must treat empty as error).
    static func ecbDecrypt(key: [UInt8], data: [UInt8]) -> [UInt8] {
        let blockSize = kCCBlockSizeAES128
        guard key.count == kCCKeySizeAES128,
              data.count > 0,
              data.count % blockSize == 0 else { return [] }

        // PKCS#7 output is at most data.count bytes.
        let outputSize = data.count
        var output = [UInt8](repeating: 0, count: outputSize)
        var dataOutMoved: Int = 0

        let status = key.withUnsafeBufferPointer { keyPtr in
            data.withUnsafeBufferPointer { dataPtr in
                output.withUnsafeMutableBufferPointer { outPtr in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        // Let CommonCrypto validate and strip PKCS#7 padding;
                        // do NOT roll our own (avoids truncating unpadded plaintext
                        // and avoids a hand-built padding oracle).
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyPtr.baseAddress, kCCKeySizeAES128,
                        nil,
                        dataPtr.baseAddress, data.count,
                        outPtr.baseAddress, outputSize,
                        &dataOutMoved
                    )
                }
            }
        }

        guard status == kCCSuccess, dataOutMoved <= outputSize else { return [] }
        return Array(output[..<dataOutMoved])
    }
}
