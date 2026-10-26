import Foundation

struct CursorStoredTokenDecoder {
    func decode(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 16_384,
              value.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte)
                      || (48...57).contains(byte) || "-._~+/=".utf8.contains(byte)
              }) else {
            throw CursorUsageError.authenticationUnavailable
        }
        return value
    }

    func expirationDate(for token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let expiration = try? JSONDecoder().decode(Expiration.self, from: data),
              expiration.exp.isFinite, expiration.exp > 0 else { return nil }
        return Date(timeIntervalSince1970: expiration.exp)
    }

    private struct Expiration: Decodable {
        let exp: Double
    }
}
