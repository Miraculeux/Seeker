import Foundation

struct SemanticModelDescriptor: Identifiable, Hashable, Sendable {
    enum Availability: Sendable {
        case downloadable
        case planned
    }

    let id: String
    let displayName: String
    let detail: String
    let imageSize: Int
    let availability: Availability
    let assets: [SemanticModelAsset]
    let runtime: SemanticModelRuntime
    let packageFormat: SemanticModelPackageFormat

    static let mobileCLIPS0 = SemanticModelDescriptor(
        id: "mobileclip-s0-fp16",
        displayName: "MobileCLIP-S0 (Core ML FP16)",
        detail: "Smallest and fastest · English optimized",
        imageSize: 256,
        availability: .downloadable,
        assets: Self.mobileCLIPAssets(
            prefix: "mobileclip_s0",
            imageManifestHash: "fe07dde983dae92c1799132816ce55f9ff8487f2681b530abf7222025aa27fa4",
            imageModelHash: "2c1afa132c41c6535817cc67894bd7484bc2cbd084ed5e2f12b24f611af17591",
            imageWeightHash: "87d8f63997bbd2f38ba7defeaaa2c571928bdece56aa9629542198b3ce906ed6",
            textManifestHash: "a7cb0864a627468a953afd107262097ad74a0fcf82e49df7e00b9c86385bb7db",
            textModelHash: "81eba836ff4dbc8ae021d70006288b533ba7eed3c2973d245b0d5ea047305bfd",
            textWeightHash: "34723e51445b2630106e94e1fdbebed80e7676b404fb839f4eb9bec97bdcad68"
        ),
        runtime: .mobileCLIP,
        packageFormat: .sourcePackages
    )

    static let mobileCLIPS2 = SemanticModelDescriptor(
        id: "mobileclip-s2-fp16",
        displayName: "MobileCLIP-S2 (Core ML FP16)",
        detail: "Recommended · balanced accuracy and speed · English optimized",
        imageSize: 256,
        availability: .downloadable,
        assets: Self.mobileCLIPAssets(
            prefix: "mobileclip_s2",
            imageManifestHash: "6a1a3f93b8dca6c237dbb5dc7b19bb3c987042d14860288304986c099d8796b6",
            imageModelHash: "2aeb3359f6cde65e9f9248ec2a742e9939bd4bbf48c2f55fcd255b4504d96a1b",
            imageWeightHash: "6cbc7fb06b6072c1cae9c4496d67e0e6217adbf726dfeb82e44d4efe87c34c00",
            textManifestHash: "ea6a189d82fee2ee36eadb99022cda66a7f6b50a4bf9cc1d9541c7ea3b4242a0",
            textModelHash: "b8651b6d030bae419a9548b41c8fae11f96b59cfa21b6e532a4c4434522b4b80",
            textWeightHash: "8e8d5454f104b6cbb58d98bf11e038ff1f1943599efea111260a832f094cd0ce"
        ),
        runtime: .mobileCLIP,
        packageFormat: .sourcePackages
    )

    static let sigLIP2Base = SemanticModelDescriptor(
        id: "siglip2-base-patch16-256-coreml-int8",
        displayName: "SigLIP 2 Base Multilingual (Core ML 8-bit)",
        detail: "Best for Chinese and multilingual search · about 356 MB",
        imageSize: 256,
        availability: .downloadable,
        assets: [
            .init(remotePath: "ImageEncoder.mlmodelc.zip", localPath: "archives/ImageEncoder.mlmodelc.zip", sha256: "f3255dad62bda6c50021b4eac3bf764423dd52b198005480273e800faa1babb8", origin: .sigLIP2),
            .init(remotePath: "TextEncoder.mlmodelc.zip", localPath: "archives/TextEncoder.mlmodelc.zip", sha256: "ba64d0cac0695b5c0cd18c898382a5455ed74ac666c27421ee94047a3561a72e", origin: .sigLIP2),
            .init(remotePath: "tokenizer.zip", localPath: "archives/tokenizer.zip", sha256: "c37f2a8e8555d8561109564c4f60ee962b0072abddcfcfd599d321469d6d1ef5", origin: .sigLIP2)
        ],
        runtime: .sigLIP2,
        packageFormat: .compiledArchives
    )

    static let all: [SemanticModelDescriptor] = [mobileCLIPS2, sigLIP2Base, mobileCLIPS0]
    static let defaultModel = mobileCLIPS2
    static let defaultSearchModel = sigLIP2Base
    static let defaultComparisonModel = mobileCLIPS2

    static func model(id: String) -> SemanticModelDescriptor {
        all.first(where: { $0.id == id }) ?? defaultModel
    }

    var cacheNamespace: String { "\(id):embedding-v1" }

    private static func mobileCLIPAssets(
        prefix: String,
        imageManifestHash: String,
        imageModelHash: String,
        imageWeightHash: String,
        textManifestHash: String,
        textModelHash: String,
        textWeightHash: String
    ) -> [SemanticModelAsset] {
        let imagePackage = "\(prefix)_image.mlpackage"
        let textPackage = "\(prefix)_text.mlpackage"
        return [
            .init(remotePath: "\(imagePackage)/Manifest.json", localPath: "image.mlpackage/Manifest.json", sha256: imageManifestHash, origin: .model),
            .init(remotePath: "\(imagePackage)/Data/com.apple.CoreML/model.mlmodel", localPath: "image.mlpackage/Data/com.apple.CoreML/model.mlmodel", sha256: imageModelHash, origin: .model),
            .init(remotePath: "\(imagePackage)/Data/com.apple.CoreML/weights/weight.bin", localPath: "image.mlpackage/Data/com.apple.CoreML/weights/weight.bin", sha256: imageWeightHash, origin: .model),
            .init(remotePath: "\(textPackage)/Manifest.json", localPath: "text.mlpackage/Manifest.json", sha256: textManifestHash, origin: .model),
            .init(remotePath: "\(textPackage)/Data/com.apple.CoreML/model.mlmodel", localPath: "text.mlpackage/Data/com.apple.CoreML/model.mlmodel", sha256: textModelHash, origin: .model),
            .init(remotePath: "\(textPackage)/Data/com.apple.CoreML/weights/weight.bin", localPath: "text.mlpackage/Data/com.apple.CoreML/weights/weight.bin", sha256: textWeightHash, origin: .model),
            .init(remotePath: "vocab.json", localPath: "vocab.json", sha256: "5047b556ce86ccaf6aa22b3ffccfc52d391ea4accdab9c2f2407da5b742d4363", origin: .tokenizer),
            .init(remotePath: "merges.txt", localPath: "merges.txt", sha256: "f526393189112391ce6f9795d4695f704121ce452c3aad1f5335cc41337eba85", origin: .tokenizer)
        ]
    }
}

struct SemanticModelRuntime: Hashable, Sendable {
    enum Tokenizer: Hashable, Sendable {
        case clipBPE
        case sigLIP2BPE
    }

    enum ImageScaling: Hashable, Sendable {
        case centerCrop
        case stretch
    }

    let imageInput: String
    let textInput: String
    let embeddingOutput: String
    let tokenizer: Tokenizer
    let imageScaling: ImageScaling

    static let mobileCLIP = SemanticModelRuntime(
        imageInput: "image",
        textInput: "text",
        embeddingOutput: "final_emb_1",
        tokenizer: .clipBPE,
        imageScaling: .centerCrop
    )

    static let sigLIP2 = SemanticModelRuntime(
        imageInput: "image",
        textInput: "tokens",
        embeddingOutput: "embedding",
        tokenizer: .sigLIP2BPE,
        imageScaling: .stretch
    )
}

enum SemanticModelPackageFormat: Hashable, Sendable {
    case sourcePackages
    case compiledArchives
}

struct SemanticModelAsset: Hashable, Sendable {
    enum Origin: Sendable {
        case model
        case tokenizer
        case sigLIP2
    }

    let remotePath: String
    let localPath: String
    let sha256: String
    let origin: Origin
}

enum SemanticModelDownloadSource: String, CaseIterable, Identifiable, Sendable {
    case modelScope
    case huggingFace
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .modelScope: return "ModelScope / CN Mirror"
        case .huggingFace: return "Hugging Face"
        case .custom: return "Custom Mirror"
        }
    }

    func baseURL(customURL: String, origin: SemanticModelAsset.Origin) -> URL? {
        switch (self, origin) {
        case (.modelScope, .model):
            return URL(string: "https://modelscope.cn/models/apple/coreml-mobileclip/resolve/master/")
        case (.modelScope, .sigLIP2):
            return URL(string: "https://hf-mirror.com/zidage/siglip2-base-coreml-macos/resolve/main/")
        case (.huggingFace, .sigLIP2):
            return URL(string: "https://huggingface.co/zidage/siglip2-base-coreml-macos/resolve/main/")
        case (.modelScope, .tokenizer), (.huggingFace, .tokenizer):
            return URL(string: "https://huggingface.co/openai/clip-vit-base-patch32/resolve/main/")
        case (.huggingFace, .model):
            return URL(string: "https://huggingface.co/apple/coreml-mobileclip/resolve/main/")
        case (.custom, _):
            guard var value = URL(string: customURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            if !value.absoluteString.hasSuffix("/") { value.appendPathComponent("") }
            return value
        }
    }
}
