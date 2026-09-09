import Foundation
import XCTest
@testable import IndexCore

final class GlobTests: XCTestCase {
    func testSubstringMatching() {
        XCTAssertTrue(Glob.matches(pattern: "port", in: "Report.pdf", caseInsensitive: true))
        XCTAssertFalse(Glob.matches(pattern: "port", in: "REPORT.pdf", caseInsensitive: false))
        XCTAssertTrue(Glob.matches(pattern: "é", in: "Résumé", caseInsensitive: true))
        XCTAssertTrue(Glob.matches(pattern: "", in: "anything", caseInsensitive: false))
        XCTAssertFalse(Glob.matches(pattern: "longer", in: "long", caseInsensitive: false))
    }

    func testWildcardMatchingAndBacktracking() {
        XCTAssertTrue(Glob.matches(pattern: "*.swift", in: "Query.swift", caseInsensitive: true))
        XCTAssertTrue(Glob.matches(pattern: "a*b?d", in: "axxxbyd", caseInsensitive: false))
        XCTAssertTrue(Glob.matches(pattern: "**", in: "anything", caseInsensitive: false))
        XCTAssertFalse(Glob.matches(pattern: "a?c", in: "ac", caseInsensitive: false))
        XCTAssertFalse(Glob.matches(pattern: "*.md", in: "notes.txt", caseInsensitive: true))
    }

    func testWholeWordBoundaries() {
        XCTAssertTrue(Glob.containsWholeWord("report", in: "final-report.md", caseInsensitive: true))
        XCTAssertTrue(Glob.containsWholeWord("", in: "anything", caseInsensitive: false))
        XCTAssertFalse(Glob.containsWholeWord("port", in: "reporting", caseInsensitive: true))
        XCTAssertFalse(Glob.containsWholeWord("longer", in: "short", caseInsensitive: false))
        XCTAssertTrue(Glob.containsWholeWord("résumé", in: "My Résumé.pdf", caseInsensitive: true))
    }

    func testASCIIFastPathMatchesStringSemantics() {
        XCTAssertEqual(Glob.asciiLowerBytes("AbC*?"), Array("abc*?".utf8))
        XCTAssertNil(Glob.asciiLowerBytes("café"))

        let storage = Array("xxReport.SWIFTyy".utf8)
        let report = storage[2..<14]
        XCTAssertTrue(Glob.matchesASCII(patternLowerBytes: Array("port".utf8), in: report))
        XCTAssertTrue(Glob.matchesASCII(patternLowerBytes: Array("r*.swift".utf8), in: report))
        XCTAssertFalse(Glob.matchesASCII(patternLowerBytes: Array("*.md".utf8), in: report))
        XCTAssertTrue(Glob.matchesASCII(patternLowerBytes: [], in: report))
        XCTAssertFalse(Glob.matchesASCII(patternLowerBytes: Array("a very long value".utf8), in: report))
    }
}

final class QueryValueParserTests: XCTestCase {
    func testPathsTypesAndLimits() {
        XCTAssertEqual(QueryValueParser.absolutePath("/"), "/")
        XCTAssertEqual(QueryValueParser.absolutePath("/tmp/"), "/tmp")
        XCTAssertTrue(QueryValueParser.absolutePath("~/Desktop")?.hasSuffix("/Desktop") == true)
        XCTAssertNil(QueryValueParser.absolutePath("relative/path"))

        XCTAssertEqual(QueryValueParser.fileTypes(".MD,docx"), ["MD", "docx"])
        XCTAssertNil(QueryValueParser.fileTypes("md,"))
        XCTAssertEqual(QueryValueParser.fileKind("FILES"), .file)
        XCTAssertEqual(QueryValueParser.fileKind("directories"), .folder)
        XCTAssertNil(QueryValueParser.fileKind("device"))
        XCTAssertEqual(QueryValueParser.limit("20000"), 10_000)
        XCTAssertNil(QueryValueParser.limit("0"))
        XCTAssertNil(QueryValueParser.limit("many"))
    }

    func testSizeGrammarAndBoundaries() {
        XCTAssertEqual(QueryValueParser.size("1.5kb"), .exactly(1_536))
        XCTAssertEqual(QueryValueParser.size(">1mb"), .greaterThan(1_048_576))
        XCTAssertEqual(QueryValueParser.size(">=2gb"), .atLeast(2_147_483_648))
        XCTAssertEqual(QueryValueParser.size("<10b"), .lessThan(10))
        XCTAssertEqual(QueryValueParser.size("<=10"), .atMost(10))
        XCTAssertEqual(QueryValueParser.size("=7"), .exactly(7))
        XCTAssertEqual(QueryValueParser.size("1kb..2kb"), .range(1_024, 2_048))
        XCTAssertNil(QueryValueParser.size("2kb..1kb"))
        XCTAssertNil(QueryValueParser.size("-1"))
        XCTAssertNil(QueryValueParser.size("1xb"))
        XCTAssertNil(QueryValueParser.size("999999999999999999999999tb"))

        XCTAssertTrue(Query.SizeConstraint.lessThan(2).contains(1))
        XCTAssertTrue(Query.SizeConstraint.atMost(2).contains(2))
        XCTAssertTrue(Query.SizeConstraint.exactly(2).contains(2))
        XCTAssertTrue(Query.SizeConstraint.atLeast(2).contains(3))
        XCTAssertTrue(Query.SizeConstraint.greaterThan(2).contains(3))
        XCTAssertTrue(Query.SizeConstraint.range(2, 4).contains(3))
    }

    func testModifiedDateGrammar() throws {
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-09-09T12:00:00Z"))
        XCTAssertNotNil(QueryValueParser.modified("today", now: now))
        XCTAssertNotNil(QueryValueParser.modified("7d", now: now))
        XCTAssertNotNil(QueryValueParser.modified("0d", now: now))
        XCTAssertNotNil(QueryValueParser.modified("2026-09-01", now: now))
        XCTAssertNotNil(QueryValueParser.modified("2026-09-01..2026-09-09", now: now))
        XCTAssertNil(QueryValueParser.modified("-2d", now: now))
        XCTAssertNil(QueryValueParser.modified("2026-09-09..2026-09-01", now: now))
        XCTAssertNil(QueryValueParser.modified("not-a-date", now: now))

        XCTAssertTrue(Query.ModifiedConstraint.since(10).contains(10))
        XCTAssertTrue(Query.ModifiedConstraint.range(10, 20).contains(15))
        XCTAssertFalse(Query.ModifiedConstraint.range(10, 20).contains(21))
    }
}

final class RegexLiteralExtractorTests: XCTestCase {
    func testChoosesLongestRequiredLiteral() {
        XCTAssertEqual(RegexLiteralExtractor.requiredLiteral(in: #"^report-[0-9]+\.pdf$"#), "report-")
        XCTAssertEqual(RegexLiteralExtractor.requiredLiteral(in: #"foo.*longer\.txt"#), "longer.txt")
        XCTAssertEqual(RegexLiteralExtractor.requiredLiteral(in: #"a?required"#), "required")
        XCTAssertEqual(RegexLiteralExtractor.requiredLiteral(in: #"a*required"#), "required")
        XCTAssertEqual(RegexLiteralExtractor.requiredLiteral(in: #"a{0,2}required"#), "required")
        XCTAssertEqual(RegexLiteralExtractor.requiredLiteral(in: #"a{2}required"#), "arequired")
        XCTAssertEqual(RegexLiteralExtractor.requiredLiteral(in: #"file\+name"#), "file+name")
    }

    func testConservativelyRejectsAmbiguousPatterns() {
        XCTAssertNil(RegexLiteralExtractor.requiredLiteral(in: "foo|bar"))
        XCTAssertNil(RegexLiteralExtractor.requiredLiteral(in: "(foo)"))
        XCTAssertNil(RegexLiteralExtractor.requiredLiteral(in: #"\d+report"#))
        XCTAssertNil(RegexLiteralExtractor.requiredLiteral(in: #"\1report"#))
        XCTAssertEqual(RegexLiteralExtractor.requiredLiteral(in: "unterminated[abc"), "unterminated")
        XCTAssertEqual(RegexLiteralExtractor.requiredLiteral(in: "trailing\\"), "trailing")
        XCTAssertEqual(RegexLiteralExtractor.requiredLiteral(in: "a{"), "a")
    }
}

final class SortedRecordIDTests: XCTestCase {
    func testUnionAndSymmetricDifference() {
        XCTAssertEqual(SortedRecordIDs.union([1, 3, 5], [2, 3, 6], isCancelled: { false }),
                       [1, 2, 3, 5, 6])
        XCTAssertEqual(SortedRecordIDs.symmetricDifference(
            [1, 3, 5], [2, 3, 6], isCancelled: { false }
        ), [1, 2, 5, 6])
        XCTAssertEqual(SortedRecordIDs.union([], [2], isCancelled: { false }), [2])
        XCTAssertEqual(SortedRecordIDs.union([1], [], isCancelled: { false }), [1])
        XCTAssertTrue(SortedRecordIDs.union([1], [2], isCancelled: { true }).isEmpty)
    }

    func testParallelResultsPreserveChunkOrder() {
        let results = ParallelSearchResults(chunkCount: 3)
        results.store([4, 5], forChunk: 2)
        results.store([0, 1], forChunk: 0)
        results.store([2, 3], forChunk: 1)
        XCTAssertEqual(results.joined(), [0, 1, 2, 3, 4, 5])
    }
}

final class FileRecordTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let record = FileRecord(id: 3, name: "Résumé.pdf", path: "/Résumé.pdf", parent: 0,
                                size: 42, mtime: 99, isDir: false, volID: 7)
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(FileRecord.self, from: data), record)
    }
}
