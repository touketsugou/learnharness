import SwiftMath

/// KaTeX-flavoured LaTeX → what SwiftMath can parse. The server's content is
/// written for KaTeX (the desktop renderer); SwiftMath rejects a whole formula
/// over one unknown command. Only commands with an exact (or display-size-only)
/// equivalent are rewritten; anything else is left for the caller's fallback.
enum LaTeXCompat {
	/// Control words replaced by a fixed string.
	private static let renames: [String: String] = [
		"dots": "\\ldots", "dotsc": "\\ldots",
		"dotsb": "\\cdots", "dotsm": "\\cdots", "dotsi": "\\cdots",
		"lvert": "|", "rvert": "|",
		"lVert": "\\|", "rVert": "\\|",
		"implies": "\\Longrightarrow", "impliedby": "\\Longleftarrow",
		"varnothing": "\\emptyset",
		"boldsymbol": "\\bm",
	]

	/// Two-argument commands → `{\style\command{a}{b}}`.
	private static let styled: [String: (style: String, command: String)] = [
		"dfrac": ("displaystyle", "frac"), "cfrac": ("displaystyle", "frac"), "tfrac": ("textstyle", "frac"),
		"dbinom": ("displaystyle", "binom"), "tbinom": ("textstyle", "binom"),
	]

	/// Delimiter sizing (`\big(`, `\Bigl\{`, ...): dropped, the delimiter stays.
	private static let sizing: Set<String> = Set(["big", "Big", "bigg", "Bigg"].flatMap { [$0, $0 + "l", $0 + "r", $0 + "m"] })

	static func rewrite(_ latex: String) -> String {
		let chars = Array(latex)
		var out = ""
		var i = 0
		while i < chars.count {
			let c = chars[i]
			guard c == "\\", i + 1 < chars.count else {
				out.append(c)
				i += 1
				continue
			}
			guard isLetter(chars[i + 1]) else {
				// Control symbol (`\{`, `\\`, `\,`): copied as is.
				out.append(c)
				out.append(chars[i + 1])
				i += 2
				continue
			}
			var end = i + 1
			while end < chars.count, isLetter(chars[end]) { end += 1 }
			let name = String(chars[(i + 1)..<end])
			if let replacement = renames[name] {
				out += replacement
				i = end
			} else if sizing.contains(name) {
				i = end
			} else if name == "operatorname" {
				out += "\\mathrm"
				i = end < chars.count && chars[end] == "*" ? end + 1 : end
			} else if name == "not", let negated = negation(chars, after: end) {
				out += negated.text
				i = negated.end
			} else if let form = styled[name], let first = argument(chars, from: end), let second = argument(chars, from: first.end) {
				out += "{\\\(form.style)\\\(form.command){\(rewrite(first.text))}{\(rewrite(second.text))}}"
				i = second.end
			} else {
				out += "\\" + name
				i = end
			}
		}
		return out
	}

	/// Symbols SwiftMath has no command for, registered once before rendering.
	static let registerSymbols: Void = {
		// MTMathAtom's initializer is internal: copy an atom and retype it.
		for (name, type, value) in [
			("intercal", MTMathAtomType.binaryOperator, "\u{22BA}"),
			("triangleq", .relation, "\u{225C}"),
			("coloneqq", .relation, "\u{2254}"),
		] {
			guard MTMathAtomFactory.atom(forLatexSymbol: name) == nil,
				  let atom = MTMathAtomFactory.atom(forLatexSymbol: "top") else { continue }
			atom.type = type
			atom.nucleus = value
			MTMathAtomFactory.add(latexSymbol: name, value: atom)
		}
	}()

	private static func isLetter(_ c: Character) -> Bool {
		c.isASCII && c.isLetter
	}

	private static func skipSpaces(_ chars: [Character], _ start: Int) -> Int {
		var i = start
		while i < chars.count, chars[i] == " " || chars[i] == "\n" || chars[i] == "\t" { i += 1 }
		return i
	}

	/// `\not\in` → `\notin`, `\not=` → `\neq`; nil leaves `\not` alone.
	private static func negation(_ chars: [Character], after start: Int) -> (text: String, end: Int)? {
		let i = skipSpaces(chars, start)
		guard i < chars.count else { return nil }
		if chars[i] == "=" { return ("\\neq", i + 1) }
		if chars[i] == "\\", i + 2 < chars.count, chars[i + 1] == "i", chars[i + 2] == "n",
		   i + 3 == chars.count || !isLetter(chars[i + 3]) {
			return ("\\notin", i + 3)
		}
		return nil
	}

	/// One TeX macro argument: a balanced `{...}` group (contents returned),
	/// a control sequence, or a single character.
	private static func argument(_ chars: [Character], from start: Int) -> (text: String, end: Int)? {
		let i = skipSpaces(chars, start)
		guard i < chars.count else { return nil }
		switch chars[i] {
		case "{":
			var depth = 0
			var j = i
			while j < chars.count {
				switch chars[j] {
				case "\\": j += 1
				case "{": depth += 1
				case "}":
					depth -= 1
					if depth == 0 { return (String(chars[(i + 1)..<j]), j + 1) }
				default: break
				}
				j += 1
			}
			return nil
		case "}":
			return nil
		case "\\":
			guard i + 1 < chars.count else { return nil }
			var end = i + 2
			if isLetter(chars[i + 1]) {
				while end < chars.count, isLetter(chars[end]) { end += 1 }
			}
			return (String(chars[i..<end]), end)
		default:
			return (String(chars[i]), i + 1)
		}
	}
}
