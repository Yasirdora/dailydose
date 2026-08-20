#if DEBUG
import Foundation
import os

/// Temporary instrumentation: what the scanner actually hands over.
///
/// **Why this exists.** A quantity is only read where the number and the noun
/// it counts share a printed line — the rule that stops the "400" in
/// "Ibuprofen AL 400" reaching the "Filmtabletten" printed beneath it. That
/// rule depends on knowing where the lines are, and a real US dispensing label
/// delivered `Rx # 0010140712`, `Jane Doe` and `Tacrolimus 1mg Cap (ACC)` —
/// three separately printed lines — inside **one** recognised item.
///
/// What that proves is that the scanner groups by proximity, which was already
/// assumed. What it does *not* settle is the separator: the name field showed
/// them space-joined, but `String.singleLine` flattens newlines to spaces
/// before a name is ever formed, so the observed output is exactly what a
/// transcript containing `\n` would produce too. The two cases need opposite
/// fixes and only the log can tell them apart.
///
/// **What to look for.** Point the camera at a dispensing label and at a German
/// carton, then read the console for `scan-probe`. Every recognised item logs
/// its transcript with newlines printed as a literal `\n`, plus its vertical
/// band. Two questions:
///
/// 1. Does a multi-line item's transcript contain `\n`, or spaces? If `\n`, the
///    line rule stands as written. If spaces, no amount of geometry can split
///    that item — the fragment is the atom — and the line rule has to be
///    replaced by something that does not need line boundaries at all.
/// 2. Do fragments that share a printed line report similar `y` values? That is
///    what `ScannedFragment.lines(from:)` assumes when it rejoins them.
///
/// Delete this file once both are answered.
///
/// - Warning: This logs raw transcripts, which on a dispensing label includes
///   the patient's and the prescriber's names — precisely what §1 of the
///   privacy rules forbids persisting, logging or exporting. It is compiled
///   only into `DEBUG` builds and never ships, but point it at a label you are
///   willing to see in your own console, and delete the file when the two
///   questions above are answered.
@MainActor
enum ScanTranscriptProbe {

    private static let log = Logger(subsystem: "com.ysr.dailydose", category: "scan-probe")

    /// The last set logged, so a live camera producing thirty callbacks a
    /// second does not produce thirty identical log entries.
    private static var lastLogged: [String] = []

    static func record(_ fragments: [ScannedFragment]) {
        let texts = fragments.map(\.text)
        guard texts != lastLogged, !texts.isEmpty else { return }
        lastLogged = texts

        log.notice("scan-probe: \(fragments.count, privacy: .public) item(s)")
        for (index, fragment) in fragments.enumerated() {
            // The escaping is the whole point — a real newline in the console
            // would look exactly like the merge we are trying to rule out.
            let escaped = fragment.text
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
            log.notice(
                """
                scan-probe[\(index, privacy: .public)] y=\(Int(fragment.verticalCenter), privacy: .public) \
                h=\(Int(fragment.height), privacy: .public) x=\(Int(fragment.left), privacy: .public) \
                text=\"\(escaped, privacy: .public)\"
                """
            )
        }
        let rebuilt = ScannedFragment.lines(from: fragments)
        log.notice("scan-probe: rebuilt into \(rebuilt.count, privacy: .public) line(s)")
        for (index, line) in rebuilt.enumerated() {
            log.notice("scan-probe line[\(index, privacy: .public)]=\"\(line, privacy: .public)\"")
        }
    }
}
#endif
