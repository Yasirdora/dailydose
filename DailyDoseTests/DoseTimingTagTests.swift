import Foundation
import Testing
@testable import DailyDose

/// The clinical vocabulary's boundaries: scheduled → due now → late → missed,
/// with the late→missed line drawn by the user's DoseWindow preference.
@Suite("Dose timing tags")
struct DoseTimingTagTests {

    private let calendar = Fixture.calendar()
    /// A dose scheduled at 08:00 on a fixed day.
    private var scheduledAt: Date { Fixture.date(2026, 8, 17, 8, 0, calendar: calendar) }

    private func tag(at hour: Int, _ minute: Int, window: DoseWindow = .standard) -> DoseTimingTag {
        DoseCalculator.timingTag(
            for: scheduledAt,
            now: Fixture.date(2026, 8, 17, hour, minute, calendar: calendar),
            window: window,
            calendar: calendar
        )
    }

    @Test("Before the grace period the dose is scheduled")
    func scheduled() {
        #expect(tag(at: 7, 0) == .scheduled)
        #expect(tag(at: 7, 44) == .scheduled)   // grace opens 15 min before
    }

    @Test("From 15 minutes before to 30 after, the dose is due now")
    func dueNow() {
        #expect(tag(at: 7, 45) == .dueNow)
        #expect(tag(at: 8, 0) == .dueNow)
        #expect(tag(at: 8, 30) == .dueNow)
    }

    @Test("Beyond 30 minutes after, still inside the window, the dose is late")
    func late() {
        #expect(tag(at: 8, 31) == .late)
        #expect(tag(at: 9, 59) == .late)        // standard window: 2 hours
    }

    @Test("Past the window the dose is missed")
    func missed() {
        #expect(tag(at: 10, 1) == .missed)      // past the 2-hour deadline
        #expect(tag(at: 23, 0) == .missed)
    }

    @Test("The window preference moves the missed boundary")
    func windowPreference() {
        #expect(tag(at: 8, 45, window: .strict) == .late)
        #expect(tag(at: 9, 1, window: .strict) == .missed)   // strict: 1 hour
        #expect(tag(at: 11, 0, window: .relaxed) == .late)   // relaxed: 4 hours
        #expect(tag(at: 23, 30, window: .untilEndOfDay) == .late)
    }
}
