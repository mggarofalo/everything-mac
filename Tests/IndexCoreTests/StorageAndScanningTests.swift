import Foundation
import XCTest
@testable import IndexCore

final class ExcludeRulesTests: XCTestCase {
    func testAllRuleFamilies() {
        let rules = ExcludeRules(
            names: ["Private"], pathPrefixes: ["/Users/me/Secret/"],
            excludeHidden: true, excludeDevFolders: true, excludeVCSFolders: true,
            excludeTrash: true, excludeFilePatterns: ["*.tmp", "Thumbs.db", ""]
        )
        XCTAssertTrue(rules.shouldExclude(name: ".hidden", path: "/.hidden", isHidden: true))
        XCTAssertTrue(rules.shouldExclude(name: "Private", path: "/Private", isHidden: false))
        XCTAssertTrue(rules.shouldExclude(name: ".git", path: "/project/.git", isHidden: true))
        XCTAssertTrue(rules.shouldExclude(name: ".Trash", path: "/.Trash", isHidden: true))
        XCTAssertTrue(rules.shouldExclude(name: "node_modules", path: "/node_modules", isHidden: false))
        XCTAssertTrue(rules.shouldExclude(name: "build", path: "/project/build", isHidden: false,
                                          inProjectDir: true))
        XCTAssertFalse(rules.shouldExclude(name: "build", path: "/Documents/build", isHidden: false))
        XCTAssertTrue(rules.shouldExclude(name: "x", path: "/Users/me/Secret/x", isHidden: false))
        XCTAssertFalse(rules.shouldExclude(name: "x", path: "/Users/me/Secrets/x", isHidden: false))
        XCTAssertTrue(rules.shouldExcludeFile(name: "scratch.TMP"))
        XCTAssertTrue(rules.shouldExcludeFile(name: "thumbs.DB"))
        XCTAssertFalse(rules.shouldExcludeFile(name: "notes.md"))
        XCTAssertFalse(ExcludeRules().shouldExcludeFile(name: "anything"))
    }

    func testDisabledFamiliesAndRootPrefix() {
        let rules = ExcludeRules(excludeHidden: false, excludeDevFolders: false,
                                 excludeVCSFolders: false, excludeTrash: false)
        for name in [".hidden", ".git", ".Trash", "node_modules", "build"] {
            XCTAssertFalse(rules.shouldExclude(name: name, path: "/\(name)",
                                               isHidden: name.hasPrefix("."), inProjectDir: true))
        }
        XCTAssertTrue(ExcludeRules(pathPrefixes: ["/"]).shouldExclude(
            name: "file", path: "/file", isHidden: false
        ))
    }

    func testLegacyDecodingUsesSecureDefaults() throws {
        let legacy = #"{"names":["Custom"],"pathPrefixes":["/private"],"excludeHidden":true}"#
        let decoded = try JSONDecoder().decode(ExcludeRules.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.names, ["Custom"])
        XCTAssertTrue(decoded.excludeHidden)
        XCTAssertTrue(decoded.excludeDevFolders)
        XCTAssertTrue(decoded.excludeVCSFolders)
        XCTAssertTrue(decoded.excludeTrash)
        XCTAssertEqual(decoded.excludeFilePatterns, [])
        XCTAssertEqual(try JSONDecoder().decode(
            ExcludeRules.self, from: JSONEncoder().encode(decoded)
        ), decoded)
    }

    func testFingerprintIsStableAndSensitiveToEveryField() {
        let base = ExcludeRules(names: ["b", "a"], pathPrefixes: ["/x"],
                                excludeHidden: true, excludeFilePatterns: ["*.tmp"])
        XCTAssertEqual(base.fingerprint(), ExcludeRules(
            names: ["a", "b"], pathPrefixes: ["/x"], excludeHidden: true,
            excludeFilePatterns: ["*.tmp"]
        ).fingerprint())
        var variants = [base]
        variants[0].excludeHidden.toggle()
        var dev = base; dev.excludeDevFolders.toggle(); variants.append(dev)
        var vcs = base; vcs.excludeVCSFolders.toggle(); variants.append(vcs)
        var trash = base; trash.excludeTrash.toggle(); variants.append(trash)
        var names = base; names.names.insert("c"); variants.append(names)
        var paths = base; paths.pathPrefixes.append("/y"); variants.append(paths)
        var files = base; files.excludeFilePatterns.append("*.log"); variants.append(files)
        XCTAssertEqual(Set(variants.map { $0.fingerprint() }).count, variants.count)
    }
}

final class FileStoreTests: XCTestCase {
    func testRecordAccessPathsAndChildren() {
        var store = FileStore()
        XCTAssertNil(store.idForDirPath("/missing"))
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 1, isDir: true, volID: 7)
        let folder = store.append(name: "Folder", parent: root, size: 0,
                                  mtime: 2, isDir: true, volID: 7)
        let file = store.append(name: "Report.PDF", parent: folder, size: 42,
                                mtime: 3, isDir: false, volID: 7)
        XCTAssertEqual(store.rootID, root)
        XCTAssertEqual(store.count, 3)
        XCTAssertEqual(store.liveCount, 3)
        XCTAssertEqual(store.name(of: file), "Report.PDF")
        XCTAssertEqual(String(decoding: store.nameBytesSlice(of: file), as: UTF8.self), "Report.PDF")
        XCTAssertEqual(store.path(of: root), "/")
        XCTAssertEqual(store.path(of: file), "/Folder/Report.PDF")
        XCTAssertEqual(store.parent(of: file), folder)
        XCTAssertEqual(store.size(of: file), 42)
        XCTAssertEqual(store.mtime(of: file), 3)
        XCTAssertFalse(store.isDir(of: file))
        XCTAssertEqual(store.volID(of: file), 7)
        XCTAssertEqual(store.childIDs(of: root), [folder])
        XCTAssertEqual(store.childID(named: "Report.PDF", under: folder), file)
        XCTAssertEqual(store.idForDirPath("/Folder/Report.PDF"), file)
        XCTAssertNil(store.idForDirPath("/Other"))
        XCTAssertNil(store.idForDirPath("relative"))

        XCTAssertTrue(store.extensionMatches(Array("pdf".utf8), of: file))
        XCTAssertFalse(store.extensionMatches(Array("md".utf8), of: file))
        let hidden = store.append(name: ".gitignore", parent: folder, size: 1,
                                  mtime: 0, isDir: false, volID: 7)
        XCTAssertFalse(store.extensionMatches(Array("gitignore".utf8), of: hidden))

        store.updateMetadata(of: file, size: 84, mtime: 6)
        XCTAssertEqual(store.size(of: file), 84)
        XCTAssertEqual(store.mtime(of: file), 6)
        XCTAssertNil(store.reconcileMtime(of: folder))
        store.setReconcileMtime(folder, 123)
        XCTAssertEqual(store.reconcileMtime(of: folder), 123)
    }

    func testDeletionIsIdempotentAndFiltersChildren() {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        let child = store.append(name: "child", parent: root, size: 0,
                                 mtime: 0, isDir: false, volID: 1)
        store.markDeleted(child)
        store.markDeleted(child)
        XCTAssertEqual(store.deletedCount, 1)
        XCTAssertEqual(store.liveCount, 1)
        XCTAssertTrue(store.hasDeletions)
        XCTAssertFalse(store.isLive(child))
        XCTAssertEqual(store.childIDs(of: root), [])
        XCTAssertNil(store.childID(named: "child", under: root))
    }

    func testNameAndKindOrdering() {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        let beta = store.append(name: "beta.TXT", parent: root, size: 0,
                                mtime: 0, isDir: false, volID: 1)
        let alpha = store.append(name: "Alpha.md", parent: root, size: 0,
                                 mtime: 0, isDir: false, volID: 1)
        let folder = store.append(name: "z-folder", parent: root, size: 0,
                                  mtime: 0, isDir: true, volID: 1)
        let alphaText = store.append(name: "alpha.txt", parent: root, size: 0,
                                     mtime: 0, isDir: false, volID: 1)
        XCTAssertTrue(store.nameSortsBefore(alpha, beta))
        XCTAssertTrue(store.kindSortsBefore(folder, alpha))
        XCTAssertTrue(store.kindSortsBefore(alpha, alphaText))
        XCTAssertTrue(store.kindSortsBefore(alphaText, beta))
    }

    func testBinaryRoundTripAndMalformedData() {
        var store = FileStore()
        let root = store.append(name: "/scope", parent: FileStore.noParent, size: 0,
                                mtime: 1, isDir: true, volID: 2)
        _ = store.append(name: "file.txt", parent: root, size: 9,
                         mtime: 2, isDir: false, volID: 2)
        let data = store.serializedBinary()
        let loaded = FileStore(binary: data)
        XCTAssertEqual(loaded?.count, 2)
        XCTAssertEqual(loaded?.path(of: 1), "/scope/file.txt")
        XCTAssertNil(FileStore(binary: Data()))
        XCTAssertNil(FileStore(binary: Data("BAD!".utf8)))
        XCTAssertNil(FileStore(binary: data.prefix(10)))
        XCTAssertEqual(store.compacted().count, store.count)
    }
}

final class ScannerTests: XCTestCase {
    func testScannerAppliesRulesAndDoesNotFollowSymlinks() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("Package.swift"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("build"),
                                                withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("build/generated.swift"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("kept.tmp"),
                                                withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("scratch.tmp"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("loop"), withDestinationURL: root
        )

        var store = FileStore()
        let rules = ExcludeRules(excludeDevFolders: true, excludeVCSFolders: true,
                                 excludeTrash: true, excludeFilePatterns: ["*.tmp"])
        try Scanner(rules: rules).scan(rootPath: root.path + "/", into: &store, volID: 9)
        XCTAssertEqual(store.path(of: store.rootID), root.path)
        XCTAssertNotNil(store.idForDirPath(root.appendingPathComponent("Package.swift").path))
        XCTAssertNil(store.idForDirPath(root.appendingPathComponent("build").path))
        XCTAssertNil(store.idForDirPath(root.appendingPathComponent("scratch.tmp").path))
        XCTAssertNotNil(store.idForDirPath(root.appendingPathComponent("kept.tmp").path))
        let link = try XCTUnwrap(store.idForDirPath(root.appendingPathComponent("loop").path))
        XCTAssertFalse(store.isDir(of: link))
        XCTAssertEqual(store.volID(of: link), 9)
    }

    func testParallelScannerMatchesScopedScanner() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in ["a", "a/nested", "b"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory),
                                                    withIntermediateDirectories: true)
        }
        try Data("a".utf8).write(to: root.appendingPathComponent("a/one.txt"))
        try Data("b".utf8).write(to: root.appendingPathComponent("b/two.md"))

        var serial = FileStore()
        try Scanner(rules: ExcludeRules()).scan(rootPath: root.path, into: &serial, volID: 1)
        let parallel = ParallelScanner.scan(rootPath: root.path, rules: ExcludeRules(),
                                            workerCount: 2)
        XCTAssertEqual(paths(in: parallel), paths(in: serial))
    }

    private func paths(in store: FileStore) -> Set<String> {
        Set((0..<store.count).map { store.path(of: UInt32($0)) })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EverythingMacTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class IndexCacheFailureTests: XCTestCase {
    func testRejectsMissingWrongAndTruncatedCaches() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EverythingMacCacheFailure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try IndexCache.load(from: root.appendingPathComponent("missing")))
        let badMagic = root.appendingPathComponent("bad-magic")
        try Data("not a cache".utf8).write(to: badMagic)
        XCTAssertThrowsError(try IndexCache.load(from: badMagic))
        let badStore = root.appendingPathComponent("bad-store")
        var header = Data("EMC3".utf8)
        header.append(Data(repeating: 0, count: 16))
        header.append(Data("BAD!".utf8))
        try header.write(to: badStore)
        XCTAssertThrowsError(try IndexCache.load(from: badStore))
    }
}

final class SearchResultSortingTests: XCTestCase {
    func testEverySortKeyInBothDirections() {
        let (store, ids) = sortingStore()
        let engine = QueryEngine()
        XCTAssertEqual(engine.sort(ids, by: .name, ascending: true, in: store), [ids[1], ids[0], ids[2]])
        XCTAssertEqual(engine.sort(ids, by: .name, ascending: false, in: store), [ids[2], ids[0], ids[1]])
        XCTAssertEqual(engine.sort(ids, by: .size, ascending: true, in: store), [ids[2], ids[1], ids[0]])
        XCTAssertEqual(engine.sort(ids, by: .mtime, ascending: true, in: store), [ids[0], ids[2], ids[1]])
        XCTAssertEqual(engine.sort(ids, by: .kind, ascending: true, in: store), [ids[2], ids[1], ids[0]])
        XCTAssertEqual(Set(engine.sort(ids, by: .path, ascending: true, in: store)), Set(ids))
    }

    func testSortedPrefixMatchesFullSortAndCancels() {
        let (store, ids) = sortingStore()
        let engine = QueryEngine()
        for key in [QueryEngine.SortKey.name, .path, .size, .mtime, .kind] {
            for ascending in [true, false] {
                XCTAssertEqual(
                    engine.sortedPrefix(ids, by: key, ascending: ascending, limit: 2, in: store),
                    Array(engine.sort(ids, by: key, ascending: ascending, in: store).prefix(2))
                )
            }
        }
        XCTAssertEqual(engine.sortedPrefix(ids, by: .name, ascending: true, limit: 10, in: store),
                       engine.sort(ids, by: .name, ascending: true, in: store))
        XCTAssertEqual(engine.sortedPrefix(ids, by: .name, ascending: true, limit: 0, in: store), [])
        XCTAssertTrue(engine.sortedPrefix(ids, by: .name, ascending: true, limit: 2,
                                          in: store, isCancelled: { true }).isEmpty)
    }

    private func sortingStore() -> (FileStore, [UInt32]) {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        let beta = store.append(name: "beta.txt", parent: root, size: 30,
                                mtime: 1, isDir: false, volID: 1)
        let alpha = store.append(name: "alpha.md", parent: root, size: 20,
                                 mtime: 3, isDir: false, volID: 1)
        let folder = store.append(name: "folder", parent: root, size: 0,
                                  mtime: 2, isDir: true, volID: 1)
        return (store, [beta, alpha, folder])
    }
}
