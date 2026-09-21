import Foundation
import os.log

final class KnownHostsManager: @unchecked Sendable {
    static let shared = KnownHostsManager()

    struct Entry: Codable {
        let host: String
        let port: Int
        let fingerprint: String
        let keyType: Int
        let addedAt: Date
        var lastSeenAt: Date

        var id: String { "\(host):\(port)" }
    }

    private let storageKey = "vvterm.knownHosts"
    private let logger = Logger.forCategory("KnownHosts")
    private let lock = NSLock()

    /// Pending (unconfirmed) first-use keys, keyed like the persistent store.
    /// They are written only after the user confirms the trust affordance.
    private var pendingEntries: [String: Entry] = [:]

    private init() {}

    // MARK: - Pending (first-use) entries

    /// Record the key presented by a host that has no saved pin. Nothing is
    /// persisted until `confirmPending` is called.
    func recordPending(entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        pendingEntries[hostKey(host: entry.host, port: entry.port)] = entry
        logger.info("Recorded pending host key for \(entry.host):\(entry.port) — awaiting user confirmation")
    }

    func pendingEntry(for host: String, port: Int) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return pendingEntries[hostKey(host: host, port: port)]
    }

    /// Persist the pending first-use key, but only when it still matches the
    /// fingerprint the user reviewed in the prompt.
    ///
    /// The prompt can race: another pane can overwrite the single pending
    /// entry between the failure and the confirmation. Saving only on a match
    /// means a stale entry is never pinned; a mismatch discards the pending
    /// entry and the caller fails closed (the next attempt re-records the
    /// currently presented key and prompts again).
    @discardableResult
    func confirmPending(host: String, port: Int, expectedFingerprint: String) -> Bool {
        lock.lock()
        let key = hostKey(host: host, port: port)
        guard let pending = pendingEntries[key] else {
            lock.unlock()
            return false
        }
        guard pending.fingerprint == expectedFingerprint else {
            pendingEntries.removeValue(forKey: key)
            lock.unlock()
            logger.error(
                "Refusing to save host key for \(host):\(port) — pending fingerprint does not match the reviewed fingerprint"
            )
            return false
        }
        pendingEntries.removeValue(forKey: key)
        lock.unlock()
        save(entry: pending)
        logger.info("User confirmed new host key for \(host):\(port)")
        return true
    }

    func discardPending(host: String, port: Int) {
        lock.lock()
        defer { lock.unlock() }
        pendingEntries.removeValue(forKey: hostKey(host: host, port: port))
    }

    func entry(for host: String, port: Int) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return loadAll()[hostKey(host: host, port: port)]
    }

    func updateSeen(host: String, port: Int) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadAll()
        let key = hostKey(host: host, port: port)
        if var entry = entries[key] {
            entry.lastSeenAt = Date()
            entries[key] = entry
            saveAll(entries)
        }
    }

    func save(entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadAll()
        entries[entry.id] = entry
        saveAll(entries)
    }

    func remove(host: String, port: Int) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadAll()
        let key = hostKey(host: host, port: port)
        guard entries.removeValue(forKey: key) != nil else { return }
        saveAll(entries)
        logger.info("Removed known host entry for \(host):\(port)")
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: storageKey)
        pendingEntries.removeAll()
        logger.info("Removed all known host entries")
    }

    func entries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return loadAll().values.sorted { lhs, rhs in
            if lhs.host == rhs.host {
                return lhs.port < rhs.port
            }
            return lhs.host < rhs.host
        }
    }

    private func hostKey(host: String, port: Int) -> String {
        "\(host):\(port)"
    }

    private func loadAll() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private func saveAll(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else {
            logger.error("Failed to encode known hosts store")
            return
        }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
