import Foundation
import Security

/// Keeps the database key in the login keychain.
///
/// The key is stored and read through Apple's `/usr/bin/security` tool rather than by Clipcairn
/// itself. A self-signed app without a Team ID is identified in the keychain by its code hash,
/// which changes with every build, so reading its own item would ask for the login password after
/// each update. Items created by `security` are bound to that Apple tool instead, so no prompt.
/// Trade-off: other programs running as this user can read the key through the same tool.
enum KeyStore {
    private static let service = "com.cracya01.clipcairn"
    /// Item created through `security` (current).
    private static let account = "database-key-cli"
    /// Item created by Clipcairn 0.1 directly; read once to migrate.
    private static let legacyAccount = "database-key"
    private static let tool = "/usr/bin/security"

    enum KeyError: Error, CustomStringConvertible {
        case tool(Int32, String)
        case random(Int32)
        case badKey
        var description: String {
            switch self {
            case let .tool(code, msg): return "钥匙串操作失败（security 退出码 \(code)）：\(msg)"
            case .random(let s): return "生成随机密钥失败 \(s)"
            case .badKey: return "钥匙串里的数据库密钥格式不对"
            }
        }
    }

    /// Returns the key, migrating it from the legacy item if needed. nil = no key anywhere.
    static func read() throws -> Data? {
        if let k = try readCLI() { return k }
        if let old = readLegacy() {
            // One-time move; reading the legacy item may show one keychain prompt.
            try save(old)
            return old
        }
        return nil
    }

    static func create() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let r = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard r == errSecSuccess else { throw KeyError.random(r) }
        let key = Data(bytes)
        try save(key)
        return key
    }

    // MARK: security tool

    private static func run(_ args: [String]) throws -> (Int32, String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus,
                String(decoding: o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func readCLI() throws -> Data? {
        let (code, out, err) = try run(["find-generic-password", "-s", service, "-a", account, "-w"])
        if code == 44 { return nil }                       // errSecItemNotFound
        guard code == 0 else { throw KeyError.tool(code, err) }
        guard let d = Data(base64Encoded: out), d.count == 32 else { throw KeyError.badKey }
        return d
    }

    private static func save(_ key: Data) throws {
        let (code, _, err) = try run(["add-generic-password", "-U", "-s", service, "-a", account,
                                      "-l", "Clipcairn database key", "-w", key.base64EncodedString()])
        guard code == 0 else { throw KeyError.tool(code, err) }
    }

    private static func readLegacy() -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: legacyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data, d.count == 32 else { return nil }
        return d
    }
}
