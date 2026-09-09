import Foundation

/// Simple file logger to ~/Library/Logs/MacDock.log for diagnostics.
enum Logger {
    static var fileURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MacDock.log")
    }
    private static let queue = DispatchQueue(label: "macdock.log")

    static func log(_ message: String) {
        let line = "[\(Date())] " + message + "\n"
        queue.async {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? line.data(using: .utf8)?.write(to: fileURL)
            }
        }
    }
}
