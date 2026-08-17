import Foundation
import HealthKit

/// A medication found in Apple Health, ready for the user to review and import.
struct HealthImportCandidate: Identifiable, Hashable {
    let id: String            // HealthKit medication concept identifier
    let name: String          // nickname if set, else the clinical display text
    let clinicalName: String  // full clinical description
    let form: String          // "tablet", "capsule", "liquid", …
    let hasSchedule: Bool
}

/// Read-only bridge to Apple Health's medications (WWDC25 Medications API, iOS 26+).
///
/// App Store compliance notes (research, 2026-08-10):
/// · Read-only scope — we never write to HealthKit (5.1.3 ii "no false data").
/// · Data stays on-device; never used for ads/mining (5.1.3 i).
/// · Specific NSHealthShareUsageDescription is declared in build settings.
/// · Health app integration must be mentioned in the App Store description.
/// · A public privacy policy URL is required before submission (launch checklist).
final class HealthKitManager {
    static let shared = HealthKitManager()
    private let store = HKHealthStore()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// The medications API requires iOS 26; callers must gate with #available first.
    static var medicationsAPISupported: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    // MARK: - Authorization

    /// Requests read access to medications (minimal scope).
    /// Medications are OBJECTS, not samples (WWDC25), so the sample-based
    /// `requestAuthorization(toShare:read:)` throws "Authorization … is
    /// disallowed" for them — they must use the per-object API, which
    /// presents the per-medication picker sheet. Authorizing a medication
    /// also grants its dose events automatically.
    /// Note: HealthKit intentionally does not reveal whether the user granted
    /// read access — we simply query afterward and handle an empty result.
    @available(iOS 26.0, *)
    func requestReadAuthorization() async throws {
        let medType = HKObjectType.userAnnotatedMedicationType()
        _ = try await store.requestPerObjectReadAuthorization(for: medType, predicate: nil)
    }

    // MARK: - Fetching

    @available(iOS 26.0, *)
    func fetchMedications() async throws -> [HealthImportCandidate] {
        let medications = try await HKUserAnnotatedMedicationQueryDescriptor().result(for: store)
        return medications
            .filter { !$0.isArchived }
            .map { med in
                let clinical = med.medication.displayText
                let nickname = med.nickname?.trimmingCharacters(in: .whitespaces)
                let name = (nickname?.isEmpty == false) ? nickname! : clinical
                return HealthImportCandidate(
                    id: UUID().uuidString,
                    name: name,
                    clinicalName: clinical,
                    form: Self.describe(form: med.medication.generalForm),
                    hasSchedule: med.hasSchedule
                )
            }
    }

    @available(iOS 26.0, *)
    private static func describe(form: HKMedicationGeneralForm) -> String {
        switch form {
        case .capsule: return "capsule"
        case .tablet: return "tablet"
        case .liquid: return "liquid"
        case .topical: return "topical"
        case .cream: return "cream"
        case .device: return "device"
        case .drops: return "drops"
        case .foam: return "foam"
        case .gel: return "gel"
        case .inhaler: return "inhaler"
        case .injection: return "injection"
        case .lotion: return "lotion"
        case .ointment: return "ointment"
        case .patch: return "patch"
        case .powder: return "powder"
        case .spray: return "spray"
        case .suppository: return "suppository"
        default: return "medication"
        }
    }
}
