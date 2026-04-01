import Foundation

public struct MusicMetadata {
    public let name: String
    public let album: String
    public let artist: String
    public let format: String
    public let bitrate: Int
    public let duration: Int

    public init?(json: [String: Any]) {
        self.name = json["musicName"] as? String ?? ""
        self.album = json["album"] as? String ?? ""
        self.format = json["format"] as? String ?? ""
        self.bitrate = json["bitrate"] as? Int ?? 0
        self.duration = json["duration"] as? Int ?? 0

        // artist is [[name, id], ...]
        if let artists = json["artist"] as? [[Any]] {
            self.artist = artists.compactMap { arr in
                arr.first as? String
            }.joined(separator: "/")
        } else {
            self.artist = ""
        }
    }
}
