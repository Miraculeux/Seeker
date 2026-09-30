import Foundation
import XCTest
@testable import Seeker

final class SemanticModelCatalogTests: XCTestCase {
    func testLookupReturnsEveryKnownDescriptorAndFallsBackForUnknownIDs() {
        XCTAssertEqual(Set(SemanticModelDescriptor.all.map(\.id)).count, SemanticModelDescriptor.all.count)
        for descriptor in SemanticModelDescriptor.all {
            XCTAssertEqual(SemanticModelDescriptor.model(id: descriptor.id), descriptor)
        }
        for id in ["", "unknown-model", SemanticModelDescriptor.mobileCLIPS0.id.uppercased()] {
            XCTAssertEqual(SemanticModelDescriptor.model(id: id), SemanticModelDescriptor.defaultModel)
        }
    }

    func testDefaultsAreDownloadableAndRuntimeMatchesPackageFamily() {
        XCTAssertEqual(SemanticModelDescriptor.defaultModel, .sigLIP2Base)
        XCTAssertEqual(SemanticModelDescriptor.defaultSearchModel, .sigLIP2Base)
        XCTAssertEqual(SemanticModelDescriptor.defaultComparisonModel, .sigLIP2Base)
        for descriptor in SemanticModelDescriptor.all {
            guard case .downloadable = descriptor.availability else {
                XCTFail("Catalog model \(descriptor.id) is unexpectedly unavailable")
                continue
            }
            XCTAssertEqual(descriptor.imageSize, 256)
        }
        for descriptor in [SemanticModelDescriptor.mobileCLIPS0, .mobileCLIPS2] {
            XCTAssertEqual(descriptor.packageFormat, .sourcePackages)
            XCTAssertEqual(descriptor.runtime, .mobileCLIP)
            XCTAssertEqual(descriptor.runtime.tokenizer, .clipBPE)
            XCTAssertEqual(descriptor.runtime.imageScaling, .centerCrop)
            XCTAssertEqual(descriptor.runtime.textInput, "text")
        }
        XCTAssertEqual(SemanticModelDescriptor.sigLIP2Base.packageFormat, .compiledArchives)
        XCTAssertEqual(SemanticModelDescriptor.sigLIP2Base.runtime, .sigLIP2)
        XCTAssertEqual(SemanticModelRuntime.sigLIP2.tokenizer, .sigLIP2BPE)
        XCTAssertEqual(SemanticModelRuntime.sigLIP2.imageScaling, .stretch)
        XCTAssertEqual(SemanticModelRuntime.sigLIP2.textInput, "tokens")
    }

    func testCacheNamespacesAreVersionedAndIsolatedAcrossModels() {
        let namespaces = SemanticModelDescriptor.all.map(\.cacheNamespace)
        XCTAssertEqual(Set(namespaces).count, SemanticModelDescriptor.all.count)
        for descriptor in SemanticModelDescriptor.all {
            XCTAssertEqual(descriptor.cacheNamespace, "\(descriptor.id):embedding-v1")
        }
    }

    func testAssetsHaveUniqueRelativeDestinationsAndSHA256Checksums() {
        for descriptor in SemanticModelDescriptor.all {
            XCTAssertFalse(descriptor.assets.isEmpty)
            XCTAssertEqual(Set(descriptor.assets.map(\.localPath)).count, descriptor.assets.count)
            for asset in descriptor.assets {
                XCTAssertFalse(asset.remotePath.isEmpty)
                XCTAssertFalse(asset.localPath.hasPrefix("/"))
                XCTAssertFalse(asset.localPath.split(separator: "/").contains(".."))
                XCTAssertEqual(asset.sha256.count, 64)
                XCTAssertTrue(asset.sha256.allSatisfy { "0123456789abcdef".contains($0) })
            }
        }
        for descriptor in [SemanticModelDescriptor.mobileCLIPS0, .mobileCLIPS2] {
            let tokenizerAssets = descriptor.assets.filter {
                if case .tokenizer = $0.origin { return true }
                return false
            }
            XCTAssertEqual(Set(tokenizerAssets.map(\.localPath)), ["vocab.json", "merges.txt"])
        }
        for asset in SemanticModelDescriptor.sigLIP2Base.assets {
            guard case .sigLIP2 = asset.origin else {
                XCTFail("SigLIP asset uses the wrong download origin")
                continue
            }
            XCTAssertTrue(asset.localPath.hasPrefix("archives/"))
            XCTAssertTrue(asset.remotePath.hasSuffix(".zip"))
        }
    }

    func testOfficialDownloadSourcesSelectOriginSpecificURLsWithoutNetworking() {
        let expected: [(SemanticModelDownloadSource, SemanticModelAsset.Origin, String)] = [
            (.modelScope, .model, "https://modelscope.cn/models/apple/coreml-mobileclip/resolve/master/"),
            (.huggingFace, .model, "https://huggingface.co/apple/coreml-mobileclip/resolve/main/"),
            (.modelScope, .sigLIP2, "https://hf-mirror.com/zidage/siglip2-base-coreml-macos/resolve/main/"),
            (.huggingFace, .sigLIP2, "https://huggingface.co/zidage/siglip2-base-coreml-macos/resolve/main/"),
            (.modelScope, .tokenizer, "https://huggingface.co/openai/clip-vit-base-patch32/resolve/main/"),
            (.huggingFace, .tokenizer, "https://huggingface.co/openai/clip-vit-base-patch32/resolve/main/")
        ]
        for (source, origin, url) in expected {
            XCTAssertEqual(source.baseURL(customURL: "ignored", origin: origin)?.absoluteString, url)
            XCTAssertEqual(source.id, source.rawValue)
            XCTAssertFalse(source.displayName.isEmpty)
        }
    }

    func testCustomMirrorTrimsWhitespaceAndNormalizesTrailingSlashForEveryOrigin() {
        for origin in [SemanticModelAsset.Origin.model, .tokenizer, .sigLIP2] {
            for customURL in [" \nhttps://example.invalid/models\t", "https://example.invalid/models/"] {
                XCTAssertEqual(
                    SemanticModelDownloadSource.custom.baseURL(customURL: customURL, origin: origin)?.absoluteString,
                    "https://example.invalid/models/"
                )
            }
        }
        XCTAssertNil(SemanticModelDownloadSource.custom.baseURL(customURL: "http://[", origin: .model))
        XCTAssertEqual(SemanticModelDownloadSource.allCases.map(\.id), ["modelScope", "huggingFace", "custom"])
    }
}
