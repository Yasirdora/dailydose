import SwiftUI
import UIKit

/// Everything that used to be a wall of text in the middle of Settings.
///
/// The manifesto and the medical disclaimer are both worth saying properly —
/// but inline they made About the visually heaviest section on the screen, and
/// a block of body text in a settings list is text nobody reads. As a page
/// someone chooses to open, it gets read.
struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.missed)

                    Text(String(localized: "Medication reminders are healthcare, not a subscription."))
                        .font(.title3.weight(.bold))

                    Text(String(localized: "Daily Dose is free and unlimited. There is no account, no server and no tracking — your medications and your history stay on this device and nowhere else."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }

            Section(String(localized: "How it works")) {
                point(
                    icon: "bell.badge",
                    title: String(localized: "One reminder per moment"),
                    detail: String(localized: "Medications due at the same time arrive as a single notification, not a pile of them.")
                )
                point(
                    icon: "hand.tap",
                    title: String(localized: "Log in one tap"),
                    detail: String(localized: "Taken or Skip straight from the notification. A reminder you can't act on is one you learn to ignore.")
                )
                point(
                    icon: "moon.zzz",
                    title: String(localized: "Quiet at night"),
                    detail: String(localized: "Your scheduled reminders always arrive. Follow-ups and refill alerts hold back during quiet hours.")
                )
                point(
                    icon: "chart.bar",
                    title: String(localized: "An honest record"),
                    detail: String(localized: "Doses you never logged are recorded as missed, so your history reflects what actually happened.")
                )
            }

            dataSourcesSection

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(String(localized: "Not a medical device"), systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.due)
                    Text(String(localized: """
                        Daily Dose helps you keep track of medication you have already \
                        been prescribed. It does not give medical advice, does not check \
                        for drug interactions, and is not a substitute for your doctor or \
                        pharmacist. Always follow the instructions you were given.
                        """))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            } header: {
                Text(String(localized: "Important"))
            }
        }
        .navigationTitle(String(localized: "About Daily Dose"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Where the drug data came from, and the FDA's own words about it.
    ///
    /// Two things are being honoured here. The dataset is public domain (CC0),
    /// so attribution is courtesy rather than a licence term — but naming your
    /// sources is how a medical app earns the benefit of the doubt. And the FDA
    /// asks that its data not be presented as validated for clinical use, which
    /// is a request worth repeating in their register rather than paraphrasing
    /// into something softer.
    ///
    /// The export date is shown deliberately. Data with no date on it invites
    /// more trust than it has earned, and a directory built in August cannot
    /// know about a product listed in September.
    @ViewBuilder
    private var dataSourcesSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(String(localized: "US drug names"), systemImage: "shippingbox")
                    .font(.headline)
                Text(String(localized: """
                    Product names, strengths and forms for US medications come from                     the FDA's National Drug Code Directory, which is in the public                     domain. It is included in the app as a file.
                    """))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let formatted = directoryDate {
                    Text(String(localized: "Data from \(formatted)."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                // The FDA's own caution, in their register rather than ours.
                Text(String(localized: """
                    The FDA notes that this data is unvalidated and should not be                     relied on to make decisions about medical care. Daily Dose never                     sends your medications anywhere to look them up — the answers                     are already on your phone.
                    """))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        } header: {
            Text(String(localized: "Data sources"))
        }
    }

    /// The bundled directory's export date, read from the file itself rather
    /// than hardcoded — a constant here would go stale the first time somebody
    /// rebuilt the index and forgot to edit this screen.
    private var directoryDate: String? {
        guard let stamp = DrugDirectory.bundled?.exportDate, stamp > 0 else { return nil }
        var components = DateComponents()
        components.year = stamp / 10_000
        components.month = (stamp / 100) % 100
        components.day = stamp % 100
        guard let date = Calendar.current.date(from: components) else { return nil }
        return date.formatted(.dateTime.day().month(.wide).year())
    }

    private func point(icon: String, title: String, detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(Theme.accent)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// How long a dose stays actionable.
struct DoseWindowPicker: View {
    @Binding var window: DoseWindow

    var body: some View {
        List {
            Section {
                ForEach(DoseWindow.allCases) { option in
                    Button {
                        window = option
                        Haptics.select()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .opacity(window == option ? 1 : 0)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title).foregroundStyle(.primary)
                                Text(option.explanation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(window == option ? [.isButton, .isSelected] : .isButton)
                }
            } footer: {
                // Says what actually changes, not what the control does.
                Text(String(localized: "A dose you haven't logged by then counts as missed in your history. Changing this updates the last week's record straight away."))
            }
        }
        .navigationTitle(String(localized: "Dose Window"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Feedback

/// Builds a `mailto:` with the version and device already filled in.
///
/// Costs nothing and turns "it doesn't work" into a report someone can act on.
enum FeedbackMail {
    static let address = "support@dailydose.app"

    static var url: URL? {
        let subject = "Daily Dose feedback"
        let body = """


        —————
        Please keep the details below — they help track down the problem.

        App: \(Bundle.main.shortVersionString)
        iOS: \(UIDevice.current.systemVersion)
        Device: \(deviceModel)
        """

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }

    /// The hardware identifier ("iPhone16,2"), which is far more useful for a
    /// bug report than the marketing name the user would have to look up.
    private static var deviceModel: String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }
}
