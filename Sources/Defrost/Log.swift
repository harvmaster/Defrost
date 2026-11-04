import Foundation

/// Tiny append-only log at ~/Library/Logs/Defrost.log. It is written only when
/// something happens, and trimmed at launch when it grows past 1 MB.
enum Log {
    static let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Defrost.log")
    private static let queue = DispatchQueue(label: "defrost.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func trimIfNeeded() {
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
