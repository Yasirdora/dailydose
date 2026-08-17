import SwiftUI
import AVFoundation

/// Auditions a bundled notification sound in-app.
///
/// A picker that can't be heard is a guessing game — the user would have to
/// wait for a real dose reminder to find out what they chose. Selecting a row
/// plays it immediately, the way every system sound picker on the platform
/// behaves.
@MainActor
@Observable
final class SoundPreviewPlayer {
    private var player: AVAudioPlayer?
    private(set) var playing: NotificationSound?

    func play(_ sound: NotificationSound) {
        stop()
        guard let name = sound.resourceName,
              let url = Bundle.main.url(forResource: name, withExtension: "wav")
        else { return }

        // `.ambient` respects the silent switch and never interrupts audio the
        // user is already listening to — auditioning a chime should not pause
        // someone's podcast.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        player?.play()
        playing = sound

        let duration = player?.duration ?? 1
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, self.playing == sound else { return }
            self.playing = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }
}

/// The sound list, in the platform's grammar: a checkmark on the current
/// choice, a tap to select *and* hear it.
struct SoundPickerView: View {
    let title: String
    @Binding var selection: NotificationSound
    /// Explains what this sound is actually for, since the same picker is
    /// reused for dose reminders and refill alerts.
    var footer: String?

    @Environment(\.dismiss) private var dismiss
    @State private var preview = SoundPreviewPlayer()

    var body: some View {
        List {
            Section {
                ForEach(NotificationSound.allCases) { sound in
                    Button {
                        selection = sound
                        preview.play(sound)
                        Haptics.select()
                    } label: {
                        row(sound)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        selection == sound ? [.isButton, .isSelected] : .isButton
                    )
                    .accessibilityHint(sound == .none
                        ? String(localized: "Reminders will arrive silently")
                        : String(localized: "Selects and plays this sound"))
                }
            } footer: {
                if let footer { Text(footer) }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { preview.stop() }
    }

    private func row(_ sound: NotificationSound) -> some View {
        HStack(spacing: 12) {
            // The checkmark occupies its slot whether or not it's shown, so
            // rows never shift as the selection moves.
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .opacity(selection == sound ? 1 : 0)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(sound.title).foregroundStyle(.primary)
                if let subtitle = sound.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if preview.playing == sound {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
    }
}

/// The row that opens the picker, showing the current choice inline — the
/// `Sound   Chime ›` pattern.
struct SoundRow: View {
    let title: String
    let sound: NotificationSound

    var body: some View {
        LabeledContent {
            Text(sound.title).foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: sound == .none ? "speaker.slash" : "speaker.wave.2")
        }
    }
}
