// chat4000
// Copyright (C) 2026 NeonNode Limited
// Licensed under GPL-3.0. See LICENSE file for details.

import Foundation

enum DevLog {
    private static let queue = DispatchQueue(label: "com.neonnode.chat4000.devlog")

    static var isEnabled: Bool {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        return bundleId.hasSuffix(".dev")
    }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        write(message())
    }

    static func log(_ format: String, _ args: CVarArg...) {
        guard isEnabled else { return }
        write(String(format: format, locale: Locale(identifier: "en_US_POSIX"), arguments: args))
    }

    static var logFileURL: URL? {
        guard isEnabled else { return nil }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("chat4000-dev.log")
    }

    private static func write(_ message: String) {
        let line = "\(Date().ISO8601Format()) \(message)"
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
                let handle = try FileHandle(forWritingTo: logFileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                Foundation.NSLog("chat4000 DevLog append failed: %@", error.localizedDescription)
            }
        }
    }
}
