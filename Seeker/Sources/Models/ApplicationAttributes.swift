import Foundation

enum ApplicationAttributes {
    enum Outcome: Equatable {
        case cleared
        case cancelled
    }

    enum Failure: LocalizedError {
        case invalidSelection
        case invalidApplication(String)
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidSelection:
                return "Select one or more application bundles."
            case .invalidApplication(let path):
                return "Not a local application directory, or the application is a symbolic link: \(path)"
            case .commandFailed(let details):
                return "Could not clear extended attributes. Some attributes may already have been removed.\n\(details)"
            }
        }
    }

    static func canClear(_ items: [FileItem]) -> Bool {
        !items.isEmpty && items.allSatisfy {
            $0.url.isFileURL && $0.isDirectory && $0.isPackage
                && $0.url.pathExtension.lowercased() == "app"
        }
    }

    static func validatedPaths(for urls: [URL]) throws -> [String] {
        guard !urls.isEmpty else { throw Failure.invalidSelection }
        return try urls.map { url in
            guard url.isFileURL, url.pathExtension.lowercased() == "app",
                  !url.path.contains("\0") else {
                throw Failure.invalidApplication(url.path)
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink == false else {
                throw Failure.invalidApplication(url.path)
            }
            return url.standardizedFileURL.path
        }
    }

    // Paths are argv data, not AppleScript source. AppleScript quotes each
    // shell argument; -s prevents recursive clearing from following symlinks.
    static let script = """
    on run argv
        set shellCommand to "/usr/bin/xattr -cr -s"
        repeat with targetPath in argv
            set shellCommand to shellCommand & " " & quoted form of targetPath
        end repeat
        try
            do shell script shellCommand with administrator privileges
            return "cleared"
        on error errorMessage number errorNumber
            if errorNumber is -128 then return "cancelled"
            error errorMessage number errorNumber
        end try
    end run
    """

    static func clear(_ urls: [URL]) throws -> Outcome {
        let paths = try validatedPaths(for: urls)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + paths
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw Failure.commandFailed(message.isEmpty ? "Exit status: \(process.terminationStatus)" : message)
        }
        switch message {
        case "cleared": return .cleared
        case "cancelled": return .cancelled
        default: throw Failure.commandFailed("Unexpected response: \(message)")
        }
    }
}
