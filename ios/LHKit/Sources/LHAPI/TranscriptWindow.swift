import Foundation

/// The tail of a transcript a session shows: everything after its first
/// hidden parts. A session opens on its last `page` parts and shows `page`
/// more each time the learner reaches the top; parts that arrive later
/// always show. Counts are of all parts, drawn or not.
public enum TranscriptWindow {
	public static let page = 30

	/// Where the shown transcript starts.
	public struct Start: Sendable, Equatable {
		/// The first shown message.
		public var message: Int
		/// The first shown part of that message.
		public var part: Int
		/// The parts before it.
		public var hiddenParts: Int

		public init(message: Int, part: Int, hiddenParts: Int) {
			self.message = message
			self.part = part
			self.hiddenParts = hiddenParts
		}
	}

	public static func partCount(in messages: [NativeViewMessage]) -> Int {
		messages.reduce(0) { $0 + $1.parts.count }
	}

	/// The hidden part count a session opens with.
	public static func opening(_ messages: [NativeViewMessage]) -> Int {
		max(0, partCount(in: messages) - page)
	}

	/// The start with `hidden` parts hidden. The last `page` parts always show
	/// (a transcript that got shorter), and a learner message shows whole.
	public static func start(hiding hidden: Int, in messages: [NativeViewMessage]) -> Start {
		var remaining = min(hidden, opening(messages))
		var before = 0
		for (index, message) in messages.enumerated() {
			if remaining < message.parts.count {
				if message.role == .user { return Start(message: index, part: 0, hiddenParts: before) }
				return Start(message: index, part: remaining, hiddenParts: before + remaining)
			}
			remaining -= message.parts.count
			before += message.parts.count
		}
		return Start(message: messages.count, part: 0, hiddenParts: before)
	}

	/// The number of parts before the part with this id; nil when none has it.
	public static func partsBefore(partID: String, in messages: [NativeViewMessage]) -> Int? {
		var before = 0
		for message in messages {
			if let index = message.parts.firstIndex(where: { $0.id == partID }) { return before + index }
			before += message.parts.count
		}
		return nil
	}
}
