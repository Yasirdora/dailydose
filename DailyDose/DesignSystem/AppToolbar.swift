import SwiftUI

/// The chrome every browsing screen shares.
///
/// ## Why this is one file
///
/// Toolbar consistency that depends on someone remembering to match another
/// screen is consistency that decays. Before this, Today's add button was green
/// glass and Meds' was an unstyled glyph; Settings existed on Today only; and
/// History had no toolbar at all. Each was a reasonable local decision and the
/// result was four screens that didn't look related.
///
/// Defining the buttons once and applying them as modifiers makes the
/// consistency structural: a new screen gets the right chrome by asking for it,
/// and changing the treatment changes it everywhere.
///
/// ## The grammar
///
/// Trailing edge, left to right: **screen-specific actions, then Settings.**
/// Settings is always the last item, always the same glyph, always the same
/// place — so it becomes a location people learn rather than one they hunt for.
///
/// The Scan tab is deliberately exempt. It's a full-bleed camera surface, and
/// camera apps don't carry app chrome; a gear floating over a viewfinder is
/// noise on the one screen that should be pure.

// MARK: - Settings

/// The Settings button and the sheet it presents, as one reusable view.
///
/// Owns its own presentation state so a screen only has to place the button,
/// not wire up a sheet.
struct SettingsToolbarButton: View {
    @State private var isPresented = false

    var body: some View {
        Button {
            Haptics.tap()
            isPresented = true
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.medium))
                .frame(minWidth: 26, minHeight: 26)
                .contentShape(.rect)
        }
        .accessibilityLabel(String(localized: "Settings"))
        .sheet(isPresented: $isPresented) { SettingsView() }
    }
}

extension View {
    /// Places the Settings button at the trailing edge.
    ///
    /// Apply this **after** any screen-specific toolbar items so Settings ends
    /// up rightmost — SwiftUI merges `.toolbar` modifiers in application order.
    func appSettingsToolbar() -> some View {
        toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsToolbarButton()
            }
        }
    }
}

// MARK: - Add medication

/// The add button, identical on every screen that offers one.
///
/// Tinted with the app accent rather than the "taken" green. Green carries a
/// specific meaning here — a dose is done — and it's used on the Taken button,
/// the taken badge and the completion ring. Spending it on an unrelated action
/// blunts a colour language that is otherwise unusually disciplined.
struct AddMedicationToolbarButton: View {
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: "plus")
                .fontWeight(.semibold)
        }
        .addButtonStyle()
        .accessibilityLabel(String(localized: "Add medication"))
    }
}

/// A plain toolbar glyph button — the default treatment for every secondary
/// action, so calendar, share and settings all look like siblings.
///
/// The glyphs are deliberately a size up from the default: inside a shared
/// capsule they must hold their own beside the glass-prominent add button,
/// and a small glyph next to a large green circle reads as a mistake.
struct ToolbarGlyphButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(minWidth: 26, minHeight: 26)
                .contentShape(.rect)
        }
        .accessibilityLabel(label)
    }
}

// MARK: - Conditional search

/// Applies `.searchable` only when it earns its place.
///
/// A search field above two medications is clutter; above fifteen it's the
/// fastest way to find one. `.searchable` can't be applied conditionally
/// inline without duplicating the whole view, so it gets a modifier.
private struct SearchableWhen: ViewModifier {
    let isEnabled: Bool
    @Binding var text: String
    let prompt: String

    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $text, prompt: prompt)
        } else {
            content
        }
    }
}

extension View {
    func searchable(when isEnabled: Bool, text: Binding<String>, prompt: String) -> some View {
        modifier(SearchableWhen(isEnabled: isEnabled, text: text, prompt: prompt))
    }
}
