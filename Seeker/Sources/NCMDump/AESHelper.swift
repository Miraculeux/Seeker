import Foundation
import CommonCrypto

enum AESHelper {
    static func ecbDecrypt(key: [UInt8], data: [UInt8]) -> [UInt8] {
        let blockSize = kCCBlockSizeAES128
        let numBlocks = data.count / blockSize
        guard numBlocks > 0 else { return [] }

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

        guard status == kCCSuccess else { return [] }

        // Remove PKCS7 padding
        if dataOutMoved > 0 {
            let pad = Int(output[dataOutMoved - 1])
            if pad > 0, pad <= blockSize {
                dataOutMoved -= pad
            }
        }

        return Array(output[..<dataOutMoved])
    }
}
