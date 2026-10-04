import Foundation

public enum IndexCache {
    struct CacheError: Error {}

    // EMC4: magic, event ID, scope/rules fingerprint, UInt32 issue-byte count,
    // JSON recovery issues, then the binary FileStore. Older formats rebuild.
    // Binary, not JSON: a whole-disk index is millions of records, and JSON
    // encode/decode of that takes tens of seconds and stalls every launch. The
    // binary form saves in ~1s and restores via memcpy.
    private static let magic = Array("EMC4".utf8)

    public static func save(_ store: FileStore, to url: URL, lastEventID: UInt64,
                            rulesFingerprint: UInt64, issues: [ScanIssue] = []) throws {
        var data = Data()
        data.append(contentsOf: magic)
        var evid = lastEventID
        withUnsafeBytes(of: &evid) { data.append(contentsOf: $0) }
        var fp = rulesFingerprint
        withUnsafeBytes(of: &fp) { data.append(contentsOf: $0) }
        let recovery = try JSONEncoder().encode(issues)
        var recoverySize = UInt32(recovery.count)
        withUnsafeBytes(of: &recoverySize) { data.append(contentsOf: $0) }
        data.append(recovery)
        data.append(store.serializedBinary())
        try data.write(to: url, options: .atomic)
        // The cache contains names and paths collected with Full Disk Access.
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
    }

    public static func load(from url: URL) throws -> (FileStore, UInt64, UInt64) {
        let snapshot = try loadSnapshot(from: url)
        return (snapshot.store, snapshot.eventID, snapshot.fingerprint)
    }

    public static func loadSnapshot(from url: URL) throws ->
        (store: FileStore, eventID: UInt64, fingerprint: UInt64, issues: [ScanIssue]) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe) // memory-mapped
        let header = magic.count + 8 + 8 + 4
        guard data.count >= header, Array(data[0..<magic.count]) == magic else { throw CacheError() }
        let evid = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: magic.count, as: UInt64.self) }
        let fp = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: magic.count + 8, as: UInt64.self) }
        let size = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: magic.count + 16, as: UInt32.self) }
        let end = header + Int(size)
        guard end <= data.count else { throw CacheError() }
        let issues = try JSONDecoder().decode([ScanIssue].self, from: data.subdata(in: header..<end))
        guard let store = FileStore(binary: data.subdata(in: end..<data.count)) else { throw CacheError() }
        return (store, evid, fp, issues)
    }
}
