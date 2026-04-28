import CryptoKit
import Foundation

#if canImport(DeviceCheck)
import DeviceCheck
#endif

enum AppAttestError: LocalizedError {
    case unavailable
    case invalidChallenge

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "App Attest is unavailable on this device."
        case .invalidChallenge:
            return "The relay challenge could not be decoded."
        }
    }
}

actor AppAttestManager {
    static let shared = AppAttestManager()

    private let keyIDDefaultsKey = "chat94.AppAttestKeyID"

    nonisolated var isSupported: Bool {
        #if canImport(DeviceCheck)
        DCAppAttestService.shared.isSupported
        #else
        false
        #endif
    }

    func attest(challengeBase64: String) async throws -> String {
        #if canImport(DeviceCheck)
        guard isSupported else { throw AppAttestError.unavailable }
        guard let challengeData = Data(base64Encoded: challengeBase64) else {
            throw AppAttestError.invalidChallenge
        }

        let clientDataHash = Data(SHA256.hash(data: challengeData))
        let keyID = try await appAttestKeyID()
        let attestation = try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
        return attestation.base64EncodedString()
        #else
        throw AppAttestError.unavailable
        #endif
    }

    #if canImport(DeviceCheck)
    private func appAttestKeyID() async throws -> String {
        if let existing = UserDefaults.standard.string(forKey: keyIDDefaultsKey), !existing.isEmpty {
            return existing
        }

        let keyID = try await DCAppAttestService.shared.generateKey()
        UserDefaults.standard.set(keyID, forKey: keyIDDefaultsKey)
        return keyID
    }
    #endif
}
