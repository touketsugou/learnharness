import Foundation

/// Splits display-normalized Markdown (the server already rewrote legacy
/// \(...\) / \[...\] to dollar math) into Markdown chunks and display-math
/// blocks, and lifts inline math out of the Markdown so the parser never sees
/// it. Mirrors remark-math with singleDollarTextMath: `$$` on its own line
/// fences display math; `$...$` / `$$...$$` inside text is inline math.
/// Fenced code and inline code spans are never touched; `\$` stays literal.
public enum MathSegmenter {
	public static let placeholderStart: Character = "\u{E000}"
	public static let placeholderEnd: Character = "\u{E001}"

	public enum Chunk: Equatable, Sendable {
		/// Markdown with inline math replaced by placeholders (index into `inlineMath`).
		case markdown(String, inlineMath: [String])
		case displayMath(String)
	}

	public static func placeholder(_ index: Int) -> String {
		"\(placeholderStart)\(index)\(placeholderEnd)"
	}

	public static func segment(_ source: String) -> [Chunk] {
		let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		var chunks: [Chunk] = []
		var buffer: [(text: String, code: Bool)] = []
		var fence: (marker: Character, count: Int)?
		var index = 0

		func flush() {
			guard !buffer.isEmpty else { return }
			var math: [String] = []
			var out: [String] = []
			var prose: [String] = []
			func flushProse() {
				guard !prose.isEmpty else { return }
				out.append(liftInlineMath(prose.joined(separator: "\n"), into: &math))
				prose.removeAll()
			}
			for line in buffer {
				if line.code { flushProse(); out.append(line.text) } else { prose.append(line.text) }
			}
			flushProse()
			let text = out.joined(separator: "\n")
			if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				chunks.append(.markdown(text, inlineMath: math))
			}
			buffer.removeAll()
		}

		while index < lines.count {
			let line = lines[index]
			if let open = fence {
				buffer.append((line, true))
				if closesFence(line, open) { fence = nil }
				index += 1
				continue
			}
			if let open = opensFence(line) {
				fence = open
				buffer.append((line, true))
				index += 1
				continue
			}
			if isMathFence(line) {
				flush()
				var body: [String] = []
				index += 1
				while index < lines.count, !isMathFence(lines[index]) {
					body.append(lines[index])
					index += 1
				}
				index += 1 // past the closer (an unclosed fence runs to the end, as in remark-math)
				let latex = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
				if !latex.isEmpty { chunks.append(.displayMath(latex)) }
				continue
			}
			buffer.append((line, false))
			index += 1
		}
		flush()
		return chunks
	}

	// MARK: Lines

	private static func leadingSpaces(_ line: String) -> Int {
		line.prefix { $0 == " " }.count
	}

	private static func opensFence(_ line: String) -> (marker: Character, count: Int)? {
		guard leadingSpaces(line) <= 3 else { return nil }
		let trimmed = line.drop { $0 == " " }
		guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
		let count = trimmed.prefix { $0 == marker }.count
		guard count >= 3 else { return nil }
		if marker == "`", trimmed.dropFirst(count).contains("`") { return nil }
		return (marker, count)
	}

	private static func closesFence(_ line: String, _ open: (marker: Character, count: Int)) -> Bool {
		guard leadingSpaces(line) <= 3 else { return false }
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		return trimmed.count >= open.count && trimmed.allSatisfy { $0 == open.marker }
	}

	private static func isMathFence(_ line: String) -> Bool {
		leadingSpaces(line) <= 3 && line.trimmingCharacters(in: .whitespaces) == "$$"
	}

	// MARK: Inline

	/// Replace inline math with placeholders; skip code spans and escapes.
	/// Math never crosses a blank line.
	static func liftInlineMath(_ text: String, into math: inout [String]) -> String {
		let chars = Array(text)
		var out = ""
		var i = 0
		func run(of character: Character, at start: Int) -> Int {
			var j = start
			while j < chars.count, chars[j] == character { j += 1 }
			return j - start
		}
		func blankLineBetween(_ from: Int, _ to: Int) -> Bool {
			var k = from
			while k < to {
				if chars[k] == "\n" {
					var m = k + 1
					while m < to, chars[m] == " " || chars[m] == "\t" { m += 1 }
					if m < chars.count, chars[m] == "\n" { return true }
				}
				k += 1
			}
			return false
		}
		while i < chars.count {
			let c = chars[i]
			if c == "\\", i + 1 < chars.count {
				out.append(c)
				out.append(chars[i + 1])
				i += 2
				continue
			}
			if c == "`" {
				let n = run(of: "`", at: i)
				var j = i + n
				var closed: Int?
				while j < chars.count {
					if chars[j] == "`" {
						let m = run(of: "`", at: j)
						if m == n { closed = j; break }
						j += m
					} else { j += 1 }
				}
				if let closed, !blankLineBetween(i, closed) {
					out.append(contentsOf: chars[i..<(closed + n)])
					i = closed + n
				} else {
					out.append(contentsOf: chars[i..<(i + n)])
					i += n
				}
				continue
			}
			if c == "$" {
				let n = run(of: "$", at: i)
				guard n <= 2 else {
					out.append(contentsOf: chars[i..<(i + n)])
					i += n
					continue
				}
				var j = i + n
				var closed: Int?
				while j < chars.count {
					if chars[j] == "\\" { j += 2; continue }
					if chars[j] == "$" {
						let m = run(of: "$", at: j)
						if m == n { closed = j; break }
						j += m
						continue
					}
					j += 1
				}
				if let closed, !blankLineBetween(i, closed) {
					let body = String(chars[(i + n)..<closed])
					if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
						out += placeholder(math.count)
						math.append(body.trimmingCharacters(in: .whitespacesAndNewlines))
						i = closed + n
						continue
					}
				}
				out.append(contentsOf: chars[i..<(i + n)])
				i += n
				continue
			}
			out.append(c)
			i += 1
		}
		return out
	}

	/// Split a Markdown text node around placeholders: (text, mathIndex?) runs.
	public static func runs(in text: String) -> [(text: String, math: Int?)] {
		var result: [(String, Int?)] = []
		var current = ""
		var iterator = text.makeIterator()
		while let c = iterator.next() {
			guard c == placeholderStart else { current.append(c); continue }
			var digits = ""
			var closed = false
			while let d = iterator.next() {
				if d == placeholderEnd { closed = true; break }
				digits.append(d)
			}
			if closed, let index = Int(digits) {
				if !current.isEmpty { result.append((current, nil)); current = "" }
				result.append(("", index))
			} else {
				current.append(c)
				current += digits
			}
		}
		if !current.isEmpty { result.append((current, nil)) }
		return result
	}
}
