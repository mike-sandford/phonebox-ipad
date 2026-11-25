import Foundation
import Security

/// A computer this iPad is paired with. The certificate fingerprint (lowercase hex SHA-256) is its id and its pin.
struct Pc: Codable, Equatable {
    var id: String
    var name: String
    var hosts: [String]
    var port: Int
    var token: String
    var macs: [String]
}

/// The paired computers, kept in the Keychain (this device only, readable after the first unlock so the kiosk works
/// after a reboot). The active computer's id is not secret and lives in UserDefaults.
final class PcStore {
    private let service = "phonebox.pcs"
    private let account = "pcs"
    private let activeKey = "activePc"
    private let lock = NSLock()
    private var cached: [Pc]?

    var all: [Pc] {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let list = load()
        cached = list
        return list
    }

    var active: Pc? {
        let list = all
        let id = UserDefaults.standard.string(forKey: activeKey)
        return list.first { $0.id == id } ?? list.first
    }

    /// Adds or replaces [pc] (same certificate) and makes it the active one.
    func upsert(_ pc: Pc) {
        update { list in list.filter { $0.id != pc.id } + [pc] }
        UserDefaults.standard.set(pc.id, forKey: activeKey)
    }

    func select(_ id: String) -> Bool {
        guard all.contains(where: { $0.id == id }) else { return false }
        UserDefaults.standard.set(id, forKey: activeKey)
        return true
    }

    func forget(_ id: String) {
        let wasActive = active?.id == id
        update { list in list.filter { $0.id != id } }
        if wasActive { UserDefaults.standard.set(all.first?.id, forKey: activeKey) }
    }

    private func update(_ change: ([Pc]) -> [Pc]) {
        lock.lock(); defer { lock.unlock() }
        let list = change(cached ?? load())
        cached = list
        save(list)
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func load() -> [Pc] {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return [] }
        return (try? JSONDecoder().decode([Pc].self, from: data)) ?? []
    }

    private func save(_ list: [Pc]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = query
            add.merge(attrs) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
