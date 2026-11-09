import SwiftMath

/// Works around a SwiftMath (1.7.3) typing bug. `MTMathList.finalized` decides
/// whether `+`/`-` is binary from the atom right before it, but the typesetter
/// spaces atoms skipping `\,`/`\quad`/`\displaystyle`. So `a = \, -x` keeps the
/// `-` binary next to a relation, which has no spacing and trips an `assert`
/// (a crash in Debug builds). Applying the same rules while skipping space and
/// style atoms, before typesetting, keeps the two in agreement.
enum MathAtomFix {
	static func apply(_ list: MTMathList?) {
		guard let list else { return }
		var prev: MTMathAtom?
		for atom in list.atoms {
			sublists(of: atom).forEach(apply)
			switch atom.type {
			case .space, .style:
				continue
			case .binaryOperator:
				if prev.map({ precedesUnary($0.type) }) ?? true { atom.type = .unaryOperator }
			case .relation, .punctuation, .close:
				if prev?.type == .binaryOperator { prev?.type = .unaryOperator }
			default:
				break
			}
			prev = atom
		}
		if prev?.type == .binaryOperator { prev?.type = .unaryOperator }
	}

	/// SwiftMath's `isNotBinaryOperator` (internal there).
	private static func precedesUnary(_ type: MTMathAtomType) -> Bool {
		switch type {
		case .binaryOperator, .relation, .open, .punctuation, .largeOperator: true
		default: false
		}
	}

	private static func sublists(of atom: MTMathAtom) -> [MTMathList?] {
		var lists = [atom.subScript, atom.superScript]
		switch atom {
		case let atom as MTFraction: lists += [atom.numerator, atom.denominator]
		case let atom as MTRadical: lists += [atom.radicand, atom.degree]
		case let atom as MTInner: lists.append(atom.innerList)
		case let atom as MTOverLine: lists.append(atom.innerList)
		case let atom as MTUnderLine: lists.append(atom.innerList)
		case let atom as MTAccent: lists.append(atom.innerList)
		case let atom as MTMathColor: lists.append(atom.innerList)
		case let atom as MTMathTextColor: lists.append(atom.innerList)
		case let atom as MTMathColorbox: lists.append(atom.innerList)
		case let atom as MTMathTable: lists += atom.cells.joined().map(Optional.some)
		default: break
		}
		return lists
	}
}
