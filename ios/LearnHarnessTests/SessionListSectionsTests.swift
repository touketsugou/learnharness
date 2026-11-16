import Foundation
import LHAPI
import Testing
@testable import LearnHarness

@Suite("Session list sections")
struct SessionListSectionsTests {
	func chat(_ id: String, _ title: String, kind: String = "teach", updated: String, question: Bool = false, problem: Bool = false) throws -> ChatListItem {
		let json = """
		{"id":"\(id)","title":"\(title)","createdAt":"\(updated)","updatedAt":"\(updated)","kind":"\(kind)","messageCount":3,
		 "pendingQuestion":\(question),"pendingProblem":\(problem),"busy":false,"compacting":false}
		"""
		return try JSONDecoder().decode(ChatListItem.self, from: Data(json.utf8))
	}

	@Test func waitingSessionsComeFirstNewestFirst() throws {
		let chats = [
			try chat("a", "Old waiting", updated: "2026-11-10T10:00:00.000Z", question: true),
			try chat("b", "Recent idle", updated: "2026-11-15T10:00:00.000Z"),
			try chat("c", "New waiting", kind: "practice", updated: "2026-11-14T10:00:00.000Z", problem: true),
			try chat("d", "Old idle", updated: "2026-11-01T10:00:00Z"),
		]
		let sections = SessionListSections(chats: chats, filter: .all, query: "")
		#expect(sections.waiting.map(\.id) == ["c", "a"])
		#expect(sections.recent.map(\.id) == ["b", "d"])
	}

	@Test func filterAndSearch() throws {
		let chats = [
			try chat("a", "Gradient descent", updated: "2026-11-10T10:00:00.000Z", question: true),
			try chat("b", "Eigenvalues", kind: "practice", updated: "2026-11-15T10:00:00.000Z"),
		]
		#expect(SessionListSections(chats: chats, filter: .practice, query: "").recent.map(\.id) == ["b"])
		#expect(SessionListSections(chats: chats, filter: .teaching, query: "").waiting.map(\.id) == ["a"])
		#expect(SessionListSections(chats: chats, filter: .teaching, query: "").recent.isEmpty)
		let found = SessionListSections(chats: chats, filter: .all, query: "  GRADIENT ")
		#expect(found.waiting.map(\.id) == ["a"] && found.recent.isEmpty)
		#expect(SessionListSections(chats: chats, filter: .all, query: "zzz").isEmpty)
	}

	@Test func relativeAgeBoundaries() {
		let now = ISO8601DateFormatter().date(from: "2026-11-16T12:00:00Z")!
		#expect(RelativeAge.label(updatedAt: "2026-11-16T11:59:30.000Z", now: now) == "NOW")
		#expect(RelativeAge.label(updatedAt: "2026-11-16T11:55:00Z", now: now) == "5M AGO")
		#expect(RelativeAge.label(updatedAt: "2026-11-16T10:00:00.000Z", now: now) == "2H AGO")
		#expect(RelativeAge.label(updatedAt: "2026-11-15T11:00:00.000Z", now: now) == "1D AGO")
		#expect(RelativeAge.label(updatedAt: "2026-10-26T12:00:00.000Z", now: now) == "3W AGO")
		#expect(RelativeAge.label(updatedAt: "2026-11-17T12:00:00.000Z", now: now) == "NOW")
		#expect(RelativeAge.label(updatedAt: "yesterday", now: now) == nil)
	}
}

@Suite("Plan progress")
struct PlanProgressTests {
	func plan(nodes: Int, current: String?, visited: [String]) throws -> NativePlan {
		let nodeList = (0..<nodes).map { "{\"id\":\"n\($0)\",\"title\":\"N\($0)\"}" }.joined(separator: ",")
		let currentJSON = current.map { "\"\($0)\"" } ?? "null"
		let visitedJSON = visited.map { "\"\($0)\"" }.joined(separator: ",")
		let json = "{\"tree\":{\"nodes\":[\(nodeList)],\"edges\":[],\"version\":1},\"current\":\(currentJSON),\"visited\":[\(visitedJSON)]}"
		return try JSONDecoder().decode(NativePlan.self, from: Data(json.utf8))
	}

	@Test func countsVisitedPlusCurrent() throws {
		let step = PlanProgress.step(try plan(nodes: 9, current: "n2", visited: ["n0", "n1"]))
		#expect(step.n == 3 && step.m == 9)
	}

	@Test func currentAlreadyVisitedCountsOnce() throws {
		#expect(PlanProgress.step(try plan(nodes: 4, current: "n1", visited: ["n0", "n1"])).n == 2)
	}

	@Test func noCurrent() throws {
		#expect(PlanProgress.step(try plan(nodes: 4, current: nil, visited: ["n0"])).n == 1)
	}

	@Test func neverPastTheTotal() throws {
		#expect(PlanProgress.step(try plan(nodes: 2, current: "x", visited: ["n0", "n1", "y"])).n == 2)
	}

	@Test func subtitles() throws {
		let p = try plan(nodes: 9, current: "n2", visited: ["n0", "n1"])
		#expect(PlanProgress.subtitle(kind: .teach, phase: .teach, plan: p) == "Teaching · Step 3 of 9")
		#expect(PlanProgress.subtitle(kind: .practice, phase: nil, plan: nil) == "Practice")
		#expect(PlanProgress.subtitle(kind: .teach, phase: .probe, plan: nil) == "Probe")
		#expect(PlanProgress.subtitle(kind: .teach, phase: .plan, plan: nil) == "Planning")
		#expect(PlanProgress.subtitle(kind: .teach, phase: nil, plan: nil) == "Teaching")
	}
}
