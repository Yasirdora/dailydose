import SwiftUI

/// AuroraBloom — a one-breath spectrum wave that celebrates a moment.
///
/// A full-spectrum aurora sweeps left → right across the top of the screen,
/// inhales once, exhales, and exits off the right edge as it dissolves.
/// The journey begins and ends on a configurable anchor hue (ours is cyan),
/// so the first and last impression always belong to the app, not the effect.
///
/// Usage — one breath per event, keyed so repeats re-trigger:
///
///     .background(alignment: .top) {
///         if breath > breathDone, !reduceMotion {
///             AuroraBloom().id(breath)
///         }
///     }
///
/// The host owns the lifecycle: mount it when the moment happens, remove it
/// after `AuroraBloom.lifespan` seconds. The view itself is a pure function
/// of elapsed time — nothing to clean up, no timers, no state.
///
/// Design notes (hard-won, do not regress):
/// - Ticks at the display's native refresh rate. Capping to 30fps made the
///   arrival visibly stutter.
/// - Smoothstep easing everywhere — zero velocity at both ends of every
///   motion. Linear ramps read as "rendered", not "alive".
/// - Screen blend in dark mode (light on darkness, Gemini-style), normal
///   blend at reduced opacity in light mode.
/// - The exit keeps travelling in the direction of the flow: light doesn't
///   stop, it leaves.
struct AuroraBloom: View {

    /// Total visible life in seconds. Remove the view after this; the final
    /// ~0.1s is fully transparent, so the lift-away is never seen.
    static let lifespan: TimeInterval = 4.3

    /// Hue (0…1) the journey opens and closes on. Daily Dose uses 0.52 (cyan).
    var anchorHue: Double = 0.52
    /// Seconds for one full turn of the spectrum wheel. Slightly shorter
    /// than the visible life, so the anchor hue returns before the end.
    var spectrumPeriod: Double = 3.6
    /// Peak strength, dark / light appearance.
    var intensityDark: Double = 0.55
    var intensityLight: Double = 0.35

    /// When this breath began — the lifecycle (arrive, hold, dissolve) is a
    /// pure function of elapsed time, so there is nothing to clean up.
    private let started = Date()

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // No minimumInterval — tick at the display's full refresh rate.
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(started)
            // Arrive slowly over 1.2s, hold, then a long 2s exhale — the
            // last visible trace fades well before the view lifts away.
            let envelope = Self.smoothstep(elapsed / 1.2)
                         * (1 - Self.smoothstep((elapsed - 2.2) / 2.0))

            GeometryReader { geo in
                let w = geo.size.width
                let dark = colorScheme == .dark

                // One continuous hue wheel. The right side trails the left
                // by a fraction of a cycle, so colour visibly travels
                // left → right — a wave, not a shimmer.
                let cycle = elapsed / spectrumPeriod
                let hueLeft  = (anchorHue + cycle).truncatingRemainder(dividingBy: 1)
                let hueMid   = (anchorHue + cycle - 0.07).truncatingRemainder(dividingBy: 1)
                let hueRight = (anchorHue + cycle - 0.14).truncatingRemainder(dividingBy: 1)

                // The breath: one slow sinusoidal swell riding the envelope.
                let breath = 0.82 + 0.18 * sin(elapsed * .pi / 1.05)

                // Suspended in water: gentle vertical sway, slow drift.
                let sway = sin(elapsed * .pi / 1.6) * 14
                let drift = sin(elapsed * .pi / 2.3) * w * 0.04

                // The exit: keep travelling with the flow, off the right
                // edge, easing in with the same smoothstep as the fade.
                let exitDrift = Self.smoothstep((elapsed - 2.2) / 2.0) * w * 0.55

                ZStack {
                    RadialGradient(colors: [glow(hueLeft, dark: dark), glow(hueLeft, dark: dark).opacity(0.4), .clear],
                                   center: .topLeading, startRadius: 0, endRadius: w * 1.15)
                        .offset(x: drift, y: sway)
                    RadialGradient(colors: [glow(hueMid, dark: dark), glow(hueMid, dark: dark).opacity(0.4), .clear],
                                   center: .top, startRadius: 0, endRadius: w * 1.2)
                        .offset(x: -drift * 0.5, y: -sway * 0.6)
                    RadialGradient(colors: [glow(hueRight, dark: dark), glow(hueRight, dark: dark).opacity(0.4), .clear],
                                   center: .topTrailing, startRadius: 0, endRadius: w * 1.15)
                        .offset(x: drift * 0.7, y: sway * 0.8)
                }
                .offset(x: exitDrift)
                .blur(radius: 70)
                .saturation(1.05)
                .blendMode(dark ? .screen : .normal)
                .opacity(envelope * breath * (dark ? intensityDark : intensityLight))
                .frame(width: w, height: 420, alignment: .top)
                .clipped()
            }
        }
        .frame(height: 420)
        .mask(LinearGradient(colors: [.white, .white.opacity(0.9), .clear],
                             startPoint: .top, endPoint: .bottom))
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func glow(_ hue: Double, dark: Bool) -> Color {
        Color(hue: (hue + 1).truncatingRemainder(dividingBy: 1),
              saturation: 0.8,
              brightness: dark ? 0.9 : 0.7)
    }

    /// Hermite smoothstep — zero velocity at both ends, so nothing ever
    /// starts or stops abruptly. The maths of "gentle".
    private static func smoothstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

#Preview {
    ZStack {
        Color(.systemBackground).ignoresSafeArea()
        AuroraBloom()
    }
    .preferredColorScheme(.dark)
}
