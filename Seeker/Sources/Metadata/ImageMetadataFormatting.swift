import Foundation

enum ImageMetadataFormatting {
    static func exposureTime(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        if seconds >= 1 {
            return String(format: "%.1f s", seconds)
        }

        let denominator = (1.0 / seconds).rounded()
        guard denominator.isFinite else { return nil }
        return String(format: "1/%.0f s", denominator)
    }

    static func truncatedWholeNumber(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        return String(format: "%.0f", value.rounded(.towardZero))
    }

    static func roundedWholeNumber(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        return String(format: "%.0f", value.rounded())
    }
}
