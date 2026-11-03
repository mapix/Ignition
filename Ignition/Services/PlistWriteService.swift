import Foundation
import AppKit

struct PlistWriteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PlistWriteService {

    /// Labels are also used as filenames when creating and exporting agents.
    static func validateLabel(_ label: String) throws {
        guard !label.isEmpty, label != ".", label != "..",
              !label.contains("/"), !label.contains("\\"),
              label.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw PlistWriteError(message: "Label must be a non-empty filename without path separators or control characters.")
        }
    }

    /// Validate plist contents before writing.
    static func validate(_ dict: [String: Any]) throws {
        guard let label = dict["Label"] as? String, !label.isEmpty else {
            throw PlistWriteError(message: "Plist must contain a non-empty 'Label' key.")
        }
        try validateLabel(label)

        // Must have Program or ProgramArguments
        let hasProgram = dict["Program"] is String
        let hasArgs = (dict["ProgramArguments"] as? [String])?.isEmpty == false
        if !hasProgram && !hasArgs {
            throw PlistWriteError(message: "Plist must contain 'Program' or 'ProgramArguments'.")
        }
    }

    /// Write plist to disk. Creates backup of existing file. Uses admin prompt for non-user domains.
    static func write(_ dict: [String: Any], to path: String, requiresAdmin: Bool) throws {
        try validate(dict)

        let data = try PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .xml,
            options: 0
        )

        let fm = FileManager.default

        if requiresAdmin {
            try writeWithAdmin(data: data, to: path)
        } else {
            // Backup existing file
            if fm.fileExists(atPath: path) {
                let backupPath = path + ".backup"
                try? fm.removeItem(atPath: backupPath)
                try? fm.copyItem(atPath: path, toPath: backupPath)
            }

            // Atomic write
            let url = URL(fileURLWithPath: path)
            try data.write(to: url, options: .atomic)
        }
    }

    /// Write using AppleScript admin prompt for global/system domains.
    private static func writeWithAdmin(data: Data, to path: String) throws {
        // Write to temp file first
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".plist")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let script = administratorCopyScript(from: tempURL.path, to: path)

        guard let appleScript = NSAppleScript(source: script) else {
            throw PlistWriteError(message: "Failed to create admin prompt.")
        }

        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)

        if let error = errorInfo {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "Admin write failed"
            throw PlistWriteError(message: msg)
        }
    }

    static func administratorCopyScript(from source: String, to destination: String) -> String {
        func stringLiteral(_ value: String) -> String {
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(escaped)\""
        }
        return """
        set sourcePath to \(stringLiteral(source))
        set destinationPath to \(stringLiteral(destination))
        do shell script ("/bin/cp " & quoted form of sourcePath & " " & quoted form of destinationPath) with administrator privileges
        """
    }

    /// Create a new plist file at the given path.
    static func create(_ dict: [String: Any], at path: String) throws {
        try validate(dict)
        let fm = FileManager.default

        // Ensure directory exists
        let dir = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        guard !fm.fileExists(atPath: path) else {
            throw PlistWriteError(message: "File already exists at \(path)")
        }

        try write(dict, to: path, requiresAdmin: false)
    }
}
