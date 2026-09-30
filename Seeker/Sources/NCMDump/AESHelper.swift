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

        let outputSize = data.count
        var output = [UInt8](repeating: 0, count: outputSize)
        var dataOutMoved: Int = 0

        let status = key.withUnsafeBufferPointer { keyPtr in
            data.withUnsafeBufferPointer { dataPtr in
                output.withUnsafeMutableBufferPointer { outPtr in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress, kCCKeySizeAES128,
                        nil,
                        dataPtr.baseAddress, data.count,
                        outPtr.baseAddress, outputSize,
                        &dataOutMoved
                    )
                }
            }
        }

        guard status == kCCSuccess, dataOutMoved == outputSize else { return [] }
        // CommonCrypto's ECB padding mode can accept invalid padding. Check
        // the complete final block without stopping at the first mismatch.
        let paddingByte = output[dataOutMoved - 1]
        let padding = Int(paddingByte)
        var mismatch: UInt8 = 0
        for offset in 1...blockSize {
            let mask: UInt8 = offset <= padding ? 0xFF : 0
            mismatch |= (output[dataOutMoved - offset] ^ paddingByte) & mask
        }
        guard (1...blockSize).contains(padding), mismatch == 0 else { return [] }
        return Array(output[..<(dataOutMoved - padding)])
    }
}
