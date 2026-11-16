import Foundation
import LHAPI

/// The session list's type filter.
enum SessionFilter: Hashable, CaseIterable {
	case teaching
	case practice
	case all

	var title: String {
		switch self {
		case .teaching: "Teaching"
		case .practice: "Practice"
		case .all: "All"
		}
	}

	func includes(_ chat: ChatListItem) -> Bool {
		switch self {
		case .teaching: chat.kind != .practice
		case .practice: chat.kind == .practice
		case .all: true
		}
	}
}

/// The session list split for display: sessions waiting on the learner (an
/// open question or problem) first, then the rest; each newest first.
struct SessionListSections: Equatable {
	var waiting: [ChatListItem]
	var recent: [ChatListItem]

	static func waits(_ chat: ChatListItem) -> Bool { chat.pendingQuestion || chat.pendingProblem }

	init(waiting: [ChatListItem], recent: [ChatListItem]) {
		self.waiting = waiting
		self.recent = recent
	}

	/// `query` matches titles, ignoring case and diacritics; blank matches all.
	init(chats: [ChatListItem], filter: SessionFilter, query: String) {
		let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
		let shown = chats
			.filter { filter.includes($0) }
			.filter { needle.isEmpty || $0.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
			.sorted { RelativeAge.date($0.updatedAt) ?? .distantPast > RelativeAge.date($1.updatedAt) ?? .distantPast }
		waiting = shown.filter(Self.waits)
		recent = shown.filter { !Self.waits($0) }
	}

	var isEmpty: Bool { waiting.isEmpty && recent.isEmpty }
}

/// "2H AGO": how long ago a session was updated, in the list's short form.
enum RelativeAge {
	static func date(_ iso: String) -> Date? {
		ISO8601DateFormatter.lhFractional.date(from: iso) ?? plain.date(from: iso)
	}

	nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

	/// "NOW" under a minute, then minutes, hours, days, weeks; nil if unparseable.
	static func label(updatedAt: String, now: Date = Date()) -> String? {
		guard let date = date(updatedAt) else { return nil }
		let seconds = max(0, now.timeIntervalSince(date))
		let minute = 60.0, hour = 3600.0, day = 86400.0, week = 604_800.0
		if seconds < minute { return "NOW" }
		if seconds < hour { return "\(Int(seconds / minute))M AGO" }
		if seconds < day { return "\(Int(seconds / hour))H AGO" }
		if seconds < week { return "\(Int(seconds / day))D AGO" }
		return "\(Int(seconds / week))W AGO"
	}
}
