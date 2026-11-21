// AuthGate.swift
// BOTB Judges Edition - First-launch private access.
//
// Mirrors engine/auth_model.py:
//   - first launch: owner sets a PIN; store salt + PBKDF2 verifier ONLY
//     (in the Keychain, never the PIN itself)
//   - unlock: constant-time verifier comparison
//   - exponential lockout after consecutive failures

import SwiftUI
import CryptoKit
import Security

enum AuthModel {
    static let algo = "PBKDF2-HMAC-SHA256"
    static let iterations: UInt32 = 100_000
    static let saltBytes = 16
    static let pinMin = 4
    static let pinMax = 12
    static let failuresBeforeLock = 5
    static let baseLockSeconds = 30.0

    enum AuthError: Error { case badPIN, keychainFailure }

    struct Credential: Codable, Equatable {
        var algo: String
        var iterations: UInt32
        var saltHex: String
        var verifierHex: String
    }

    static func pbkdf2(password: Data, salt: Data, rounds: UInt32) -> Data {
        let key = SymmetricKey(data: password)
        var block = Data(salt)
        block.append(contentsOf: [0, 0, 0, 1])
        var u = Data(HMAC<SHA256>.authenticationCode(for: block, using: key))
        var t = [UInt8](u)
        if rounds > 1 {
            for _ in 1..<Int(rounds) {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                for i in t.indices { t[i] ^= u[i] }
            }
        }
        return Data(t)
    }

    static func createCredential(pin: String) throws -> Credential {
        guard pin.count >= pinMin, pin.count <= pinMax, pin.allSatisfy(\.isNumber) else {
            throw AuthError.badPIN
        }
        var salt = [UInt8](repeating: 0, count: saltBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, saltBytes, &salt)
        guard status == errSecSuccess else { throw AuthError.keychainFailure }
        let verifier = pbkdf2(password: Data(pin.utf8), salt: Data(salt), rounds: iterations)
        return Credential(algo: algo, iterations: iterations,
                          saltHex: Data(salt).map { String(format: "%02x", $0) }.joined(),
                          verifierHex: verifier.map { String(format: "%02x", $0) }.joined())
    }

    static func verify(credential: Credential, pin: String) -> Bool {
        guard credential.algo == algo,
              pin.count >= pinMin, pin.count <= pinMax,
              let saltData = credential.saltHex.hexDecoded,
              let expData = credential.verifierHex.hexDecoded else { return false }
        let candidate = pbkdf2(password: Data(pin.utf8), salt: saltData,
                               rounds: credential.iterations)
        guard candidate.count == expData.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(candidate, expData) { diff |= a ^ b }
        return diff == 0
    }
}

extension String {
    /// Decodes a lowercase hex string into Data.
    var hexDecoded: Data? {
        guard count % 2 == 0, allSatisfy({ $0.isHexDigit }) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(count / 2)
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: 2)
            guard let byte = UInt8(self[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}

extension Array where Element == UInt8 {
    func chunked(_ size: Int) -> [[UInt8]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Keychain wrapper (verifier storage)

enum Keychain {
    static let service = "BOTBJudgesEdition.auth"

    static func save(_ data: Data, account: String) -> Bool {
        SecItemDelete([String(kSecClass): kSecClassGenericPassword,
                       String(kSecAttrService): service,
                       String(kSecAttrAccount): account] as CFDictionary)
        let attrs: [String: Any] = [String(kSecClass): kSecClassGenericPassword,
                                    String(kSecAttrService): service,
                                    String(kSecAttrAccount): account,
                                    String(kSecValueData): data,
                                    String(kSecAttrAccessible): kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [String(kSecClass): kSecClassGenericPassword,
                                    String(kSecAttrService): service,
                                    String(kSecAttrAccount): account,
                                    String(kSecReturnData): true,
                                    String(kSecMatchLimit): kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess ? (item as? Data) : nil
    }

    static func delete(account: String) {
        SecItemDelete([String(kSecClass): kSecClassGenericPassword,
                       String(kSecAttrService): service,
                       String(kSecAttrAccount): account] as CFDictionary)
    }
}

// MARK: - Session state and view

@MainActor
final class AuthSession: ObservableObject {
    enum Phase { case setup, locked, unlocked }
    @Published var phase: Phase = .locked
    @Published var errorText: String?
    @Published var consecutiveFailures = 0
    @Published var lockUntil: Date?

    private let account = "owner"

    init() {
        phase = Keychain.load(account: self.account) != nil ? .locked : .setup
    }

    var isLockedOut: Bool {
        if let until = lockUntil, until > Date() { return true }
        return false
    }

    func setup(pin: String, confirm: String) {
        guard pin == confirm else { errorText = "PIN entries do not match."; return }
        do {
            let cred = try AuthModel.createCredential(pin: pin)
            guard let encoded = try? JSONEncoder().encode(cred),
                  Keychain.save(encoded, account: account) else {
                errorText = "Keychain unavailable."; return
            }
            errorText = nil
            phase = .unlocked
        } catch {
            errorText = "PIN must be \(AuthModel.pinMin)-\(AuthModel.pinMax) digits."
        }
    }

    func unlock(pin: String) {
        if isLockedOut { return }
        guard let data = Keychain.load(account: account),
              let cred = try? JSONDecoder().decode(AuthModel.Credential.self, from: data) else {
            phase = .setup
            return
        }
        if AuthModel.verify(credential: cred, pin: pin) {
            consecutiveFailures = 0
            lockUntil = nil
            errorText = nil
            phase = .unlocked
        } else {
            consecutiveFailures += 1
            if consecutiveFailures >= AuthModel.failuresBeforeLock {
                let exponent = consecutiveFailures - AuthModel.failuresBeforeLock
                let seconds = min(AuthModel.baseLockSeconds * pow(2, Double(exponent)), 3600)
                lockUntil = Date().addingTimeInterval(seconds)
            }
            errorText = "Incorrect PIN (\(consecutiveFailures) failed attempts)."
        }
    }
}

struct AuthGate<Content: View>: View {
    @StateObject private var session = AuthSession()
    @ViewBuilder let content: () -> Content

    var body: some View {
        switch session.phase {
        case .setup: SetupView(session: session)
        case .locked: LockView(session: session)
        case .unlocked: content()
        }
    }
}

struct SetupView: View {
    @ObservedObject var session: AuthSession
    @State private var pin = ""
    @State private var confirm = ""

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield").font(.system(size: 56))
            Text("BOTB Judges Edition").font(.title.bold())
            Text("First launch: set the private access PIN.\nOnly a salted PBKDF2 verifier is stored on this device.")
                .multilineTextAlignment(.center)
                .font(.footnote)
                .foregroundStyle(.secondary)
            SecureField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder).keyboardType(.numberPad)
                .frame(maxWidth: 240)
            SecureField("Confirm PIN", text: $confirm)
                .textFieldStyle(.roundedBorder).keyboardType(.numberPad)
                .frame(maxWidth: 240)
            if let err = session.errorText {
                Text(err).font(.callout).foregroundStyle(.red)
            }
            Button("Set PIN and continue") { session.setup(pin: pin, confirm: confirm) }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

struct LockView: View {
    @ObservedObject var session: AuthSession
    @State private var pin = ""

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill").font(.system(size: 56))
            Text("Private access locked").font(.title.bold())
            SecureField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder).keyboardType(.numberPad)
                .frame(maxWidth: 240)
            if let err = session.errorText {
                Text(err).font(.callout).foregroundStyle(.red)
            }
            if session.isLockedOut, let until = session.lockUntil {
                Text("Locked until \(until.formatted(date: .omitted, time: .standard))")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Button("Unlock") { session.unlock(pin: pin) }
                .buttonStyle(.borderedProminent)
                .disabled(session.isLockedOut)
        }
        .padding()
    }
}
