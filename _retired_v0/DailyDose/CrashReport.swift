import Foundation
import UIKit

/// Development diagnostics: captures uncaught exceptions (the kind HealthKit
/// raises for provisioning/usage problems, which Swift `do/catch` cannot see)
/// and stores them on-device. After a crash, the next launch surfaces the
/// report in Settings → Diagnostics so it can be screenshotted or copied.
/// Everything stays on the device; nothing is transmitted anywhere.
enum CrashReport {
    private static var logURL: URL {
        URL.documentsDirectory.appending(path: "daily-dose-last-crash.txt")
    }

    static func install() {
        // The handler must not capture any context, so the path is rebuilt
        // locally instead of referencing `logURL`.
        NSSetUncaughtExceptionHandler { exception in
            let url = URL.documentsDirectory.appending(path: "daily-dose-last-crash.txt")
            let report = """
            Daily Dose crash — \(Date.now.formatted(date: .long, time: .standard))
            \(exception.name.rawValue)
            \(exception.reason ?? "(no reason)")

            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            try? report.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func pendingReport() -> String? {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    static func clear() {
        try? FileManager.default.removeItem(at: logURL)
    }
}
