import Foundation
import XCTest
@testable import IndexCore

final class IndexCoreTests: XCTestCase {
    func testSlashCommandParsing() {
        XCTAssertEqual(Query(text: "/filetype md docx").expression,
                       .fileTypes(["md", "docx"]))
        XCTAssertEqual(Query(text: "/filetype .MD").expression,
                       .fileTypes(["MD"]))
        XCTAssertEqual(Query(text: #"/regex ^handoff\.md$"#).expression,
                       .regularExpression(#"^handoff\.md$"#))
        XCTAssertEqual(Query(text: "report", usesRegularExpression: true).expression,
                       .regularExpression("report"))
        XCTAssertEqual(Query(text: "/regexical notes").expression,
                       .terms(["/regexical", "notes"]))
    }

    func testFileTypeAndRegularExpressionSearch() {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        let desktop = store.append(name: "Desktop", parent: root, size: 0,
                                   mtime: 0, isDir: true, volID: 1)
        let markdown = store.append(name: "handoff.md", parent: desktop, size: 1,
                                    mtime: 0, isDir: false, volID: 1)
        let uppercase = store.append(name: "NOTES.MD", parent: root, size: 1,
                                     mtime: 0, isDir: false, volID: 1)
        let document = store.append(name: "proposal.docx", parent: root, size: 1,
                                    mtime: 0, isDir: false, volID: 1)
        var index = ComponentSearchIndex()
        XCTAssertTrue(index.rebuild(with: store))
        let engine = QueryEngine()

        XCTAssertEqual(engine.search(Query(text: "/filetype md"), in: store,
                                     componentIndex: index), [markdown, uppercase])
        XCTAssertEqual(engine.search(Query(text: "/filetype doc md"), in: store,
                                     componentIndex: index), [markdown, uppercase])
        XCTAssertEqual(engine.search(Query(text: "/filetype doc docx"), in: store,
                                     componentIndex: index), [document])
        XCTAssertEqual(engine.search(Query(text: #"/regex ^handoff\.md$"#), in: store,
                                     componentIndex: index), [markdown])
        XCTAssertEqual(engine.search(Query(text: #"/regex .*handoff\.md$"#), in: store,
                                     componentIndex: index), [markdown])
        XCTAssertEqual(engine.search(Query(text: "/regex handoff|proposal"), in: store,
                                     componentIndex: index), [markdown, document])
        XCTAssertEqual(engine.search(Query(text: #"/regex \u0068andoff\.md$"#), in: store,
                                     componentIndex: index), [markdown])
        XCTAssertEqual(engine.search(Query(text: #"Desktop/.+\.md$"#, matchPath: true,
                                            usesRegularExpression: true),
                                     in: store, componentIndex: index), [markdown])
        XCTAssertEqual(engine.search(Query(text: "[", usesRegularExpression: true),
                                     in: store, componentIndex: index), [])
    }

    func testPlainMatchPathTermsPropagateThroughAncestors() {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        let users = store.append(name: "Users", parent: root, size: 0,
                                 mtime: 0, isDir: true, volID: 1)
        let michael = store.append(name: "michael", parent: users, size: 0,
                                   mtime: 0, isDir: true, volID: 1)
        let projects = store.append(name: "Projects", parent: michael, size: 0,
                                    mtime: 0, isDir: true, volID: 1)
        let alpha = store.append(name: "Alpha", parent: projects, size: 0,
                                 mtime: 0, isDir: true, volID: 1)
        let file = store.append(name: "HARDENING.md", parent: alpha, size: 1,
                                mtime: 0, isDir: false, volID: 1)
        let engine = QueryEngine()

        XCTAssertTrue(engine.search(Query(text: "projects", matchPath: true), in: store).contains(file))
        XCTAssertTrue(engine.search(Query(text: "michael hardening", matchPath: true), in: store).contains(file))
        XCTAssertFalse(engine.search(Query(text: "projects", matchPath: false), in: store).contains(file))
        XCTAssertTrue(engine.search(Query(text: "Alpha/HARDENING.md", matchPath: true), in: store).contains(file))
        XCTAssertFalse(engine.search(Query(text: "PROJECTS", matchPath: true,
                                           caseInsensitive: false), in: store).contains(file))
    }

    func testComponentIndexPreservesSubstringAndPathSemantics() {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        let desktop = store.append(name: "Desktop", parent: root, size: 0,
                                   mtime: 0, isDir: true, volID: 1)
        let document = store.append(name: "marvel-presentation-layer.md", parent: desktop,
                                    size: 1, mtime: 0, isDir: false, volID: 1)
        let unrelated = store.append(name: "presentation-notes.md", parent: root,
                                     size: 1, mtime: 0, isDir: false, volID: 1)
        var index = ComponentSearchIndex()
        XCTAssertTrue(index.rebuild(with: store))
        let engine = QueryEngine()

        XCTAssertEqual(engine.search(Query(text: "desktop marvel present", matchPath: true),
                                     in: store, componentIndex: index), [document])
        XCTAssertEqual(engine.search(Query(text: "Desktop/marvel-present", matchPath: true),
                                     in: store, componentIndex: index), [document])
        XCTAssertEqual(engine.search(Query(text: "Desktop\\marvel-present", matchPath: true),
                                     in: store, componentIndex: index), [document])
        XCTAssertEqual(engine.search(Query(text: "marvel present", matchPath: false),
                                     in: store, componentIndex: index), [document])
        XCTAssertEqual(engine.search(Query(text: "presentation", matchPath: false),
                                     in: store, componentIndex: index), [document, unrelated])
        XCTAssertEqual(engine.search(Query(text: "desktop", matchPath: false,
                                           caseInsensitive: false),
                                     in: store, componentIndex: index), [])
        XCTAssertEqual(engine.search(Query(text: "marvel", matchPath: false,
                                           caseInsensitive: false),
                                     in: store, componentIndex: index), [document])
        XCTAssertLessThan(index.compressedByteCount, index.postingIDCount * MemoryLayout<UInt32>.size)
    }

    func testComponentIndexSynchronizesAppendsAndIgnoresDeletes() {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        let old = store.append(name: "old-marvel.txt", parent: root, size: 1,
                               mtime: 0, isDir: false, volID: 1)
        var index = ComponentSearchIndex()
        XCTAssertTrue(index.rebuild(with: store))
        let added = store.append(name: "new-marvel.txt", parent: root, size: 1,
                                 mtime: 0, isDir: false, volID: 1)
        store.markDeleted(old)
        XCTAssertTrue(index.synchronize(with: store))

        XCTAssertEqual(QueryEngine().search(Query(text: "marvel"), in: store,
                                            componentIndex: index), [added])
        XCTAssertEqual(index.indexedRecordCount, store.count)
    }

    func testSearchCancellationStopsIndexedWork() {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        for index in 0..<10_000 {
            _ = store.append(name: "common-file-\(index).txt", parent: root, size: 1,
                             mtime: 0, isDir: false, volID: 1)
        }
        var componentIndex = ComponentSearchIndex()
        XCTAssertTrue(componentIndex.rebuild(with: store))

        let result = QueryEngine().search(Query(text: "common"), in: store,
                                          componentIndex: componentIndex,
                                          isCancelled: { true })
        XCTAssertTrue(result.isEmpty)
    }

    func testExclusionPrefixesRespectPathComponents() {
        let rules = ExcludeRules(pathPrefixes: ["/Users/me/Secret", "/Volumes/Work/"])

        XCTAssertTrue(rules.shouldExclude(name: "file", path: "/Users/me/Secret/file", isHidden: false))
        XCTAssertTrue(rules.shouldExclude(name: "file", path: "/Volumes/Work/file", isHidden: false))
        XCTAssertFalse(rules.shouldExclude(name: "file", path: "/Users/me/Secret2/file", isHidden: false))
        XCTAssertFalse(rules.shouldExclude(name: "file", path: "/Volumes/Workspace/file", isHidden: false))

        let rootRules = ExcludeRules(pathPrefixes: ["/"])
        XCTAssertTrue(rootRules.shouldExclude(name: "file", path: "/Users/me/file", isHidden: false))
    }

    func testCompactionRemovesTombstonesAndPreservesPaths() {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        let kept = store.append(name: "kept", parent: root, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        _ = store.append(name: "note.txt", parent: kept, size: 4,
                         mtime: 10, isDir: false, volID: 1)
        let deleted = store.append(name: "deleted", parent: root, size: 0,
                                   mtime: 0, isDir: true, volID: 1)
        let deletedChild = store.append(name: "secret.txt", parent: deleted, size: 8,
                                        mtime: 20, isDir: false, volID: 1)
        store.markDeleted(deletedChild)
        store.markDeleted(deleted)

        let compacted = store.compacted()

        XCTAssertEqual(compacted.count, 3)
        XCTAssertEqual(compacted.liveCount, 3)
        XCTAssertEqual(compacted.deletedCount, 0)
        XCTAssertNotNil(compacted.idForDirPath("/kept/note.txt"))
        XCTAssertNil(compacted.idForDirPath("/deleted"))
    }

    func testRefreshMetadataAndSameNameTypeReplacement() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EverythingMacTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let itemURL = rootURL.appendingPathComponent("item")
        try Data("one".utf8).write(to: itemURL)
        var store = FileStore()
        try Scanner(rules: ExcludeRules()).scan(rootPath: rootURL.path, into: &store, volID: 1)
        let originalID = try XCTUnwrap(store.idForDirPath(itemURL.path))

        try Data("a larger replacement".utf8).write(to: itemURL)
        XCTAssertTrue(LiveMonitor.refreshMetadata(path: itemURL.path, in: &store))
        XCTAssertEqual(store.size(of: originalID), UInt64("a larger replacement".utf8.count))

        try FileManager.default.removeItem(at: itemURL)
        try FileManager.default.createDirectory(at: itemURL, withIntermediateDirectories: false)
        try Data("child".utf8).write(to: itemURL.appendingPathComponent("child.txt"))
        XCTAssertTrue(LiveMonitor.reconcile(directory: rootURL.path, in: &store,
                                            rules: ExcludeRules(), volID: 1))

        let replacementID = try XCTUnwrap(store.idForDirPath(itemURL.path))
        XCTAssertNotEqual(replacementID, originalID)
        XCTAssertTrue(store.isDir(of: replacementID))
        XCTAssertNotNil(store.idForDirPath(itemURL.appendingPathComponent("child.txt").path))
    }

    func testCacheIsPrivateAndRoundTripsCheckpoint() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EverythingMacCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let cacheURL = rootURL.appendingPathComponent("index.idx")

        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        let secret = store.append(name: "deleted-secret-name.txt", parent: root, size: 1,
                                  mtime: 1, isDir: false, volID: 1)
        store.markDeleted(secret)
        try IndexCache.save(store, to: cacheURL, lastEventID: 42, rulesFingerprint: 99)

        let attributes = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let (loaded, eventID, fingerprint) = try IndexCache.load(from: cacheURL)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(eventID, 42)
        XCTAssertEqual(fingerprint, 99)
        XCTAssertNil(try Data(contentsOf: cacheURL).range(of: Data("deleted-secret-name.txt".utf8)))
    }

    func testLiveMonitorReportsStructuralEventWithCheckpoint() throws {
        let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("EverythingMacEventsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let resolvedRootURL = rootURL.resolvingSymlinksInPath()
        let createdURL = resolvedRootURL.appendingPathComponent("created.txt")
        let received = expectation(description: "FSEvents create notification")

        let monitor = LiveMonitor { changes in
            if changes.contains(where: {
                $0.path == createdURL.path && $0.structural && $0.eventID > 0
            }) {
                received.fulfill()
            }
        }
        XCTAssertTrue(monitor.start(paths: [resolvedRootURL.path]))
        usleep(100_000)
        try Data("event".utf8).write(to: createdURL)
        monitor.flush()

        wait(for: [received], timeout: 5)
        monitor.stop()
    }
}
