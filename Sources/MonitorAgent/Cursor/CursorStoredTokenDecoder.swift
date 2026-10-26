import CommonCrypto
import Foundation
import Security

struct CursorStoredTokenDecoder {
    private static let envelopePrefix = "cursor-safe-storage:v1:"
    private let readPassword: () throws -> Data

    init(readPassword: @escaping () throws -> Data = Self.readKeychainPassword) {
        self.readPassword = readPassword
    }

    func decode(_ storedValue: String) throws -> String {
        let value = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("cursor-safe-storage:") else {
            return try validatedToken(value)
        }
        guard value.hasPrefix(Self.envelopePrefix),
              let payload = Data(base64Encoded: String(value.dropFirst(Self.envelopePrefix.count))),
              payload.starts(with: Data("v10".utf8)) else {
            throw CursorUsageError.authenticationUnavailable
        }
        let ciphertext = Data(payload.dropFirst(3))
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else {
            throw CursorUsageError.authenticationUnavailable
        }

        do {
            let password = try readPassword()
            guard !password.isEmpty else { throw CursorUsageError.authenticationUnavailable }
            let salt = Array("saltysalt".utf8)
            var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
            let derivationStatus = password.withUnsafeBytes { passwordBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                    salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1_003, &key, key.count
                )
            }
            guard derivationStatus == kCCSuccess else {
                throw CursorUsageError.authenticationUnavailable
            }

            let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
            var plaintext = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
            let outputCapacity = plaintext.count
            var outputCount = 0
            let status = ciphertext.withUnsafeBytes { ciphertextBytes in
                CCCrypt(
                    CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding), key, key.count, iv,
                    ciphertextBytes.baseAddress, ciphertext.count,
                    &plaintext, outputCapacity, &outputCount
                )
            }
            guard status == kCCSuccess,
                  let token = String(bytes: plaintext.prefix(outputCount), encoding: .utf8) else {
                throw CursorUsageError.authenticationUnavailable
            }
            return try validatedToken(token)
        } catch {
            throw CursorUsageError.authenticationUnavailable
        }
    }

    private func validatedToken(_ value: String) throws -> String {
        guard !value.isEmpty,
              !value.hasPrefix("cursor-safe-storage:"),
              value.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte)
                      || (48...57).contains(byte) || "-._~+/=".utf8.contains(byte)
              }) else {
            throw CursorUsageError.authenticationUnavailable
        }
        return value
    }

    private static func readKeychainPassword() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Cursor Safe Storage",
            kSecAttrAccount as String: "Cursor Key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let password = result as? Data,
              !password.isEmpty else {
            throw CursorUsageError.authenticationUnavailable
        }
        return password
    }
}
