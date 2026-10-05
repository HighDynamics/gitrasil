import XCTest
import GitrasilTestSupport
@testable import GitrasilCore

final class GraphLayoutTests: XCTestCase {

    private func subjects(_ rows: [GraphRow]) -> [String] {
        rows.map { row in
            if case .hidden(let n) = row.content { return "(\(n) hidden)" }
            return row.commit?.subject ?? "?"
        }
    }

    func testTrunkAheadForksLeftOfTheSpineFromTheMeeting() async throws {
        let repo = try await Topology.caseB()
        let graph = try await Derivations.historyGraph(runner: repo.runner)
        let rows = GraphLayout.rows(for: graph, expanded: false)

        XCTAssertEqual(subjects(rows), ["main-ahead-2", "main-ahead-1", "cw-1", "root"])
        XCTAssertEqual(rows.map(\.lane), [1, 1, 0, 0])
        XCTAssertEqual(rows[0].label, "main", "the lane's tip carries its branch label")
        XCTAssertEqual(rows[1].forkBaseSHA, graph.meetingCommit?.sha, "the lane's bottom joins the meeting")
        XCTAssertTrue(rows[2].isIdentity)
        XCTAssertTrue(rows[3].isMeeting)
    }

    func testTruncatedIntermediateCollapsesUnlessExpanded() async throws {
        let repo = try await Topology.truncatedIntermediate(count: 7)
        let graph = try await Derivations.historyGraph(runner: repo.runner)

        let collapsed = GraphLayout.rows(for: graph, expanded: false)
        XCTAssertEqual(subjects(collapsed), ["cw-1", "feature-7", "(6 hidden)", "root"])
        XCTAssertEqual(collapsed[1].label, "feature")

        let expanded = GraphLayout.rows(for: graph, expanded: true)
        XCTAssertEqual(expanded.count, 1 + 7 + 1)
        XCTAssertTrue(expanded.allSatisfy { $0.lane == 0 })
    }
}
