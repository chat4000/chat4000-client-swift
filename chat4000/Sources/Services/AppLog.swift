// chat4000
// Copyright (C) 2026 NeonNode Limited
// Licensed under GPL-3.0. See LICENSE file for details.

import Foundation

enum AppLog {
    private static let queue = DispatchQueue(label: "com.neonnode.chat4000.applog")
    private static let maxBytes = 10 * 1024 * 1024
    private static let trimToBytes = 5 * 1024 * 1024

    enum Level: String { case info = "INFO", debug = "DEBUG" }

    // Verbose logging is opt-in via either:
    //   - env var (Xcode scheme):  CHAT4000_VERBOSE=1
    //   - persistent flag (Mac):   defaults write com.neonnode.chat94app CHAT4000_VERBOSE -bool true
    //                              (disable: defaults delete com.neonnode.chat94app CHAT4000_VERBOSE)
    static var isVerbose: Bool {
        // VERBOSE-BY-DEFAULT, all builds — including the prod DMG (chat4000macprod)
        // and the iOS App Store build (chat4000iphoneappstore). The crypto/key-share
        // path is entirely DEBUG-level, and field bugs (device rotation / room-key
        // sharing to a stale device → silent UTD) are undiagnosable without it on
        // real installs. The DEBUG firehose is tamed where it would flood: the rust
        // crypto trace drops the giant session-state dumps (see CryptoTracingLogger),
        // and the file rotates at 10 MB. Kill switch (no rebuild needed): set the
        // env var CHAT4000_VERBOSE=0 (the UserDefaults flag proved unreliable through
        // cfprefsd, so the env var is the supported off-switch).
        #if DEBUG
        return true
        #else
        if ProcessInfo.processInfo.environment["CHAT4000_VERBOSE"] == "0" { return false }
        return true
        #endif
    }

    static func log(_ message: @autoclosure () -> String) {
        write(.info, message())
    }

    static func log(_ format: String, _ args: CVarArg...) {
        write(.info, String(format: format, locale: Locale(identifier: "en_US_POSIX"), arguments: args))
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard isVerbose else { return }
        write(.debug, message())
    }

    static func debug(_ format: String, _ args: CVarArg...) {
        guard isVerbose else { return }
        write(.debug, String(format: format, locale: Locale(identifier: "en_US_POSIX"), arguments: args))
    }

    static var logFileURL: URL? {
        guard let baseLibrary = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let logsDir = baseLibrary.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir.appendingPathComponent("chat4000.log")
    }

    private static func write(_ level: Level, _ message: String) {
        let line = "\(Date().ISO8601Format()) [\(level.rawValue)] \(message)"
        Foundation.NSLog("%@", line)
        appendToFile(line)
    }

    private static func appendToFile(_ line: String) {
        guard let logFileURL else { return }

        queue.async {
            let data = Data((line + "\n").utf8)

            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                try? data.write(to: logFileURL, options: .atomic)
                return
            }

            do {
                // forUpdating (read+write), NOT forWritingTo: rotate() below reads
                // the file back to trim it, and readToEnd() on a write-only handle
                // fails with EBADF ("Bad file descriptor") — which made rotation
                // throw on every append once the log passed maxBytes.
                let handle = try FileHandle(forUpdating: logFileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)

                let size = (try? handle.offset()) ?? 0
                if size > maxBytes {
                    try rotate(handle: handle, fileURL: logFileURL)
                }
            } catch {
                Foundation.NSLog("chat4000 AppLog append failed: %@", error.localizedDescription)
            }
        }
    }

    private static func rotate(handle: FileHandle, fileURL: URL) throws(AppError) {
        do {
            try handle.seek(toOffset: 0)
            let total = try handle.readToEnd() ?? Data()
            let keepFrom = max(0, total.count - trimToBytes)
            var trimmed = total.subdata(in: keepFrom..<total.count)

            if let firstNewline = trimmed.firstIndex(of: 0x0A), firstNewline + 1 < trimmed.count {
                trimmed = trimmed.subdata(in: (firstNewline + 1)..<trimmed.count)
            }

            try trimmed.write(to: fileURL, options: .atomic)
        } catch is CancellationError {
            throw AppError.cancelled
        } catch {
            throw AppError.storage("log rotate: \(error.localizedDescription)")
        }
    }
}
