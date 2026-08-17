import Foundation
import HealthKit

/// A medication found in Apple Health, ready for review.
struct HealthMedication: Identifiable, Hashable, Sendable {
    /// Stable across refetches — derived from the clinical name rather than a
    /// fresh `UUID()`, so selection survives a reload and duplicates can be
    /// detected reliably.
    let id: String
    let name: String
    let clinicalName: String
    let form: String
    let hasSchedule: Bool
}

/// Read-only bridge to Apple Health's medications.
///
/// Compliance posture, unchanged and deliberate:
/// · Read-only — nothing is ever written back (App Review 5.1.3 ii).
/// · Data stays on device and is never used for advertising (5.1.3 i).
/// · `NSHealthShareUsageDescription` is declared in build settings.
/// · Health integration must be named in the App Store description.
@MainActor
final class HealthKitService {
    static let shared = HealthKitService()

    private let store = HKHealthStore()

    /// The medications API needs iOS 26 *and* health data on this device.
    static var isSupported: Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// Medications are HealthKit *objects*, not samples, so the sample-based
    /// authorization call rejects them — they need the per-object API, which
    /// presents the per-medication picker.
    ///
    /// HealthKit intentionally never reveals whether read access was granted;
    /// we query afterwards and treat an empty result as "nothing to import".
    @available(iOS 26.0, *)
    func requestReadAuthorization() async throws {
        _ = try await store.requestPerObjectReadAuthorization(
            for: HKObjectType.userAnnotatedMedicationType(), predicate: nil
        )
    }

    @available(iOS 26.0, *)
    func fetchMedications() async throws -> [HealthMedication] {
        let medications = try await HKUserAnnotatedMedicationQueryDescriptor().result(for: store)
        return medications
            .filter { !$0.isArchived }
            .map { entry in
                let clinical = entry.medication.displayText
                let nickname = entry.nickname?.trimmingCharacters(in: .whitespaces)
                return HealthMedication(
                    id: clinical.lowercased(),
                    name: (nickname?.isEmpty == false) ? nickname! : clinical,
                    clinicalName: clinical,
                    form: Self.describe(entry.medication.generalForm),
                    hasSchedule: entry.hasSchedule
                )
            }
    }

    @available(iOS 26.0, *)
    private static func describe(_ form: HKMedicationGeneralForm) -> String {
        switch form {
        case .capsule: String(localized: "capsule")
        case .tablet: String(localized: "tablet")
        case .liquid: String(localized: "liquid")
        case .topical: String(localized: "topical")
        case .cream: String(localized: "cream")
        case .device: String(localized: "device")
        case .drops: String(localized: "drops")
        case .foam: String(localized: "foam")
        case .gel: String(localized: "gel")
        case .inhaler: String(localized: "inhaler")
        case .injection: String(localized: "injection")
        case .lotion: String(localized: "lotion")
        case .ointment: String(localized: "ointment")
        case .patch: String(localized: "patch")
        case .powder: String(localized: "powder")
        case .spray: String(localized: "spray")
        case .suppository: String(localized: "suppository")
        default: String(localized: "medication")
        }
    }
}
