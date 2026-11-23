// by zayd/cold @ zayd.wtf

import Foundation
import MetricKit

/// Receives MetricKit diagnostics, including the memory-exception reports iOS 27 delivers when
/// a keyboard extension is terminated for exceeding its memory budget, and stores them as JSON
/// under Application Support/Diagnostics for the device evidence bundle.
final class MetricsRecorder: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsRecorder()

    private var directory: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            store(payload.jsonRepresentation(), prefix: "diagnostic")
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            store(payload.jsonRepresentation(), prefix: "metrics")
        }
    }

    /// Number of stored reports, for the Diagnostics screen.
    var storedReportCount: Int {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
        return files.filter { $0.hasSuffix(".json") }.count
    }

    private func store(_ data: Data, prefix: String) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? data.write(to: directory.appendingPathComponent("\(prefix)-\(stamp).json"), options: .atomic)
    }
}
