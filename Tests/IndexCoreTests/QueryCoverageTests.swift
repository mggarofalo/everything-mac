import Foundation
import XCTest
@testable import IndexCore

final class StructuredQueryCoverageTests: XCTestCase {
    func testEveryPredicateParses() {
        let cases: [(String, Query.FilterExpression)] = [
            ("name:Report", .predicate(.text("Report"))),
            ("path:Desktop/Report", .predicate(.path("Desktop/Report"))),
            ("in:/Users/me", .predicate(.directory("/Users/me"))),
            ("filetype:md,pdf", .predicate(.fileTypes(["md", "pdf"]))),
            ("ext:swift", .predicate(.fileTypes(["swift"]))),
            (#"regex:^report\.pdf$"#, .predicate(.regularExpression(#"^report\.pdf$"#))),
            (#"rx:^report\.pdf$"#, .predicate(.regularExpression(#"^report\.pdf$"#))),
            ("type:folder", .predicate(.kind(.folder))),
            ("size:>=1kb", .predicate(.size(.atLeast(1_024)))),
        ]
        for (source, expression) in cases {
            let plan = Query(text: source).plan
            XCTAssertTrue(plan.isValid, source)
            XCTAssertEqual(plan.filterExpression, expression, source)
        }
        XCTAssertNotNil(Query(text: "modified:today").plan.filterExpression)
        XCTAssertEqual(Query(text: "limit:12").plan.limit, 12)
        XCTAssertEqual(Query(text: "limit:12").plan.filterExpression, .predicate(.all))
    }

    func testMalformedStructuredQueriesHaveMessages() {
        let invalid = [
            "name:\"unterminated", "AND report", "report OR", "report XOR", "NOT",
            "()", "(report", "report)", "unknown:value", "name:", "in:relative",
            "filetype:md,", "regex:[", "type:device", "size:huge",
            "modified:yesterday", "limit:0",
        ]
        for source in invalid {
            let plan = Query(text: source).plan
            XCTAssertFalse(plan.isValid, source)
            XCTAssertNotNil(plan.validationMessage, source)
        }
    }

    func testDirectiveRemovalPreservesBooleanMeaning() {
        XCTAssertEqual(Query(text: "limit:2 AND report").plan.filterExpression,
                       .predicate(.text("report")))
        XCTAssertEqual(Query(text: "limit:2 OR report").plan.filterExpression,
                       .predicate(.text("report")))
        XCTAssertEqual(Query(text: "limit:2 XOR report").plan.filterExpression,
                       .predicate(.text("report")))
        XCTAssertEqual(Query(text: "limit:1 XOR limit:2").plan.filterExpression, .predicate(.all))
        XCTAssertEqual(Query(text: "NOT limit:2").plan.filterExpression, .predicate(.all))
        XCTAssertEqual(Query(text: "\"AND\"").plan.filterExpression, nil)
        XCTAssertEqual(Query(text: "one AND two AND three").plan.filterExpression,
                       .and([.predicate(.text("one")), .predicate(.text("two")),
                             .predicate(.text("three"))]))
    }

    func testSlashParserErrorAndQuotedValueCoverage() {
        XCTAssertEqual(Query(text: #"/not "Old Reports" invoice"#).plan.excludedTerms,
                       ["Old Reports"])
        XCTAssertEqual(Query(text: #"/in "/Users/me/My Files" report"#).plan.directories,
                       ["/Users/me/My Files"])
        for source in ["/filetype", "/limit nope", "/modified nope", "/size nope",
                       "/type nope", "/in relative", "/or report", "/regex"] {
            XCTAssertFalse(Query(text: source).plan.isValid, source)
        }
        XCTAssertFalse(Query(text: "report /or other /regex x").plan.isValid)
    }
}

final class QueryEngineCoverageTests: XCTestCase {
    func testStructuredPredicatesAndBooleanEvaluation() {
        let fixture = Fixture()
        let engine = QueryEngine()
        XCTAssertEqual(engine.search(Query(text: "name:report"), in: fixture.store),
                       [fixture.report, fixture.reportArchive])
        XCTAssertEqual(engine.search(Query(text: "path:Archive\\report"), in: fixture.store),
                       [fixture.reportArchive])
        XCTAssertEqual(engine.search(Query(text: "in:/"), in: fixture.store).count,
                       fixture.store.liveCount)
        XCTAssertEqual(engine.search(Query(text: "filetype:PDF"), in: fixture.store),
                       [fixture.report, fixture.otherPDF])
        XCTAssertEqual(engine.search(Query(text: #"regex:^REPORT\.PDF$"#,
                                           caseInsensitive: false), in: fixture.store),
                       [fixture.report])
        XCTAssertEqual(engine.search(Query(text: "type:folder"), in: fixture.store),
                       [fixture.root, fixture.docs, fixture.archive])
        XCTAssertEqual(engine.search(Query(text: "size:>=20"), in: fixture.store),
                       [fixture.reportArchive, fixture.otherPDF])
        XCTAssertEqual(engine.search(Query(text: "modified:1970-01-01"), in: fixture.store).count,
                       fixture.store.liveCount)
        XCTAssertEqual(engine.search(Query(text: "NOT filetype:pdf"), in: fixture.store),
                       [fixture.root, fixture.docs, fixture.archive, fixture.reportArchive,
                        fixture.notes, fixture.resume])
        XCTAssertEqual(engine.search(Query(text: "filetype:pdf XOR name:notes"), in: fixture.store),
                       [fixture.report, fixture.notes, fixture.otherPDF])
    }

    func testWholeWordCaseAndWildcardFallbacks() {
        let fixture = Fixture()
        let engine = QueryEngine()
        XCTAssertEqual(engine.search(Query(text: "report", wholeWord: true), in: fixture.store),
                       [fixture.report])
        XCTAssertEqual(engine.search(Query(text: "report*", wholeWord: true), in: fixture.store),
                       [fixture.report, fixture.reportArchive])
        XCTAssertEqual(engine.search(Query(text: "REPORT", caseInsensitive: false), in: fixture.store),
                       [fixture.report])
        XCTAssertEqual(engine.search(Query(text: "résumé", caseInsensitive: true), in: fixture.store),
                       [fixture.resume])
        XCTAssertEqual(engine.search(Query(text: "RÉSUMÉ", caseInsensitive: false), in: fixture.store), [])
        XCTAssertEqual(engine.search(Query(text: "Docs/REPORT.PDF", matchPath: true,
                                           caseInsensitive: false), in: fixture.store),
                       [fixture.report])
    }

    func testSlashFiltersUnconstrainedAndMissingScope() {
        var fixture = Fixture()
        fixture.store.markDeleted(fixture.otherPDF)
        let engine = QueryEngine()
        XCTAssertEqual(engine.search(Query(text: ""), in: fixture.store),
                       [fixture.root, fixture.docs, fixture.archive, fixture.report,
                        fixture.reportArchive, fixture.notes, fixture.resume])
        XCTAssertEqual(engine.search(Query(text: "/filetype c"), in: fixture.store), [])
        XCTAssertEqual(engine.search(Query(text: "/filetype md /not Archive"), in: fixture.store),
                       [fixture.notes])
        XCTAssertEqual(engine.search(Query(text: "/type file /size >15 /modified 30000d"),
                                     in: fixture.store), [fixture.reportArchive])
        XCTAssertEqual(engine.search(Query(text: "/in /missing report"), in: fixture.store), [])
        XCTAssertEqual(engine.search(Query(text: "/in /Docs"), in: fixture.store),
                       [fixture.docs, fixture.archive, fixture.report,
                        fixture.reportArchive, fixture.notes, fixture.resume])
        XCTAssertEqual(engine.search(Query(text: "/filetype md /or report"), in: fixture.store),
                       [fixture.report, fixture.reportArchive, fixture.notes])
        XCTAssertTrue(engine.search(Query(text: "report OR", usesRegularExpression: false),
                                    in: fixture.store).isEmpty)
    }

    func testComponentIndexAndRegexCandidatePaths() {
        let fixture = Fixture()
        var index = ComponentSearchIndex()
        XCTAssertTrue(index.rebuild(with: fixture.store))
        let engine = QueryEngine()
        XCTAssertEqual(engine.search(Query(text: #"/regex ^REPORT\.PDF$"#), in: fixture.store,
                                     componentIndex: index), [fixture.report])
        XCTAssertEqual(engine.search(Query(text: #"/regex report|notes"#), in: fixture.store,
                                     componentIndex: index),
                       [fixture.report, fixture.reportArchive, fixture.notes])
        XCTAssertTrue(engine.search(Query(text: #"/regex "#), in: fixture.store,
                                    componentIndex: index).isEmpty)
        XCTAssertTrue(engine.search(Query(text: #"/regex ["#), in: fixture.store,
                                    componentIndex: index).isEmpty)
    }

    func testLargeFallbackSearchUsesParallelChunks() {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        for index in 0..<100_100 {
            _ = store.append(name: index == 100_099 ? "parallel-needle.txt" : "item-\(index).txt",
                             parent: root, size: 1, mtime: 0, isDir: false, volID: 1)
        }
        let engine = QueryEngine()
        XCTAssertEqual(engine.search(Query(text: "*needle*"), in: store), [100_100])
        XCTAssertEqual(engine.search(Query(text: "needle|absent", usesRegularExpression: true),
                                     in: store), [100_100])
    }

    private struct Fixture {
        var store: FileStore
        let root: UInt32
        let docs: UInt32
        let archive: UInt32
        let report: UInt32
        let reportArchive: UInt32
        let notes: UInt32
        let resume: UInt32
        let otherPDF: UInt32

        init() {
            var value = FileStore()
            root = value.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 20_001, isDir: true, volID: 1)
            docs = value.append(name: "Docs", parent: root, size: 0,
                                mtime: 20_002, isDir: true, volID: 1)
            archive = value.append(name: "Archive", parent: docs, size: 0,
                                   mtime: 20_003, isDir: true, volID: 1)
            report = value.append(name: "REPORT.PDF", parent: docs, size: 10,
                                  mtime: 20_004, isDir: false, volID: 1)
            reportArchive = value.append(name: "reportold.txt", parent: archive, size: 20,
                                         mtime: 20_005, isDir: false, volID: 1)
            notes = value.append(name: "notes.md", parent: docs, size: 15,
                                 mtime: 20_006, isDir: false, volID: 1)
            resume = value.append(name: "Résumé.txt", parent: docs, size: 12,
                                  mtime: 20_007, isDir: false, volID: 1)
            otherPDF = value.append(name: "other.pdf", parent: root, size: 30,
                                    mtime: 20_008, isDir: false, volID: 1)
            store = value
        }
    }
}

final class ComponentSearchIndexCoverageTests: XCTestCase {
    func testUnsupportedEmptyCaseSensitiveAndCancelledQueries() {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        let exact = store.append(name: "MarvelReport.txt", parent: root, size: 1,
                                 mtime: 0, isDir: false, volID: 1)
        var index = ComponentSearchIndex()
        XCTAssertTrue(index.rebuild(with: store))
        XCTAssertNil(index.candidates(for: Query(text: "ma*vel"), in: store))
        XCTAssertNil(index.candidates(for: Query(text: "ma"), in: store))
        XCTAssertEqual(index.candidates(for: Query(text: "missing"), in: store), [])
        XCTAssertEqual(index.candidates(for: Query(text: "Marvel", caseInsensitive: false),
                                        in: store), [exact])
        XCTAssertEqual(index.candidates(for: Query(text: "marvel", caseInsensitive: false),
                                        in: store), [])
        XCTAssertEqual(index.candidates(for: Query(text: "marvel"), in: store,
                                        isCancelled: { true }), [])
        XCTAssertFalse(index.rebuild(with: store, isCancelled: { true }))
    }

    func testSynchronizationResetAndBothCompactionPaths() {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        for number in 0..<140 {
            _ = store.append(name: "shared-value-\(number).txt", parent: root, size: 1,
                             mtime: 0, isDir: false, volID: 1)
        }
        var index = ComponentSearchIndex()
        XCTAssertTrue(index.synchronize(with: store))
        index.compactStorage()
        XCTAssertEqual(index.candidates(for: Query(text: "shared"), in: store)?.count, 140)

        let appended = store.append(name: "shared-new.txt", parent: root, size: 1,
                                    mtime: 0, isDir: false, volID: 1)
        XCTAssertTrue(index.synchronize(with: store))
        index.compactStorage()
        XCTAssertTrue(index.candidates(for: Query(text: "shared-new"), in: store)?.contains(appended) == true)
        index.compactStorage()

        var smaller = FileStore()
        _ = smaller.append(name: "/", parent: FileStore.noParent, size: 0,
                           mtime: 0, isDir: true, volID: 1)
        XCTAssertTrue(index.synchronize(with: smaller))
        XCTAssertEqual(index.indexedRecordCount, 1)
    }
}
