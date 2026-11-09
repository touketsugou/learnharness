import SwiftMath
import Testing
import UIKit
@testable import LHRender

@Suite("SwiftMath binary/unary typing across space and style atoms")
struct MathAtomFixTests {
	/// Atom types of `latex`'s top-level list after the fix, spaces and styles dropped.
	private func types(_ latex: String) -> [MTMathAtomType] {
		let list = MTMathListBuilder.build(fromString: latex)
		MathAtomFix.apply(list)
		return (list?.atoms ?? []).map(\.type).filter { $0 != .space && $0 != .style }
	}

	@Test func signAfterRelationAcrossSpaceIsUnary() {
		#expect(types("a = \\, -x") == [.variable, .relation, .unaryOperator, .variable])
		#expect(types("a = \\quad -x") == [.variable, .relation, .unaryOperator, .variable])
		#expect(types("a = \\displaystyle -x") == [.variable, .relation, .unaryOperator, .variable])
	}

	@Test func operatorBeforeRelationAcrossSpaceIsUnary() {
		#expect(types("a + \\, = b") == [.variable, .unaryOperator, .relation, .variable])
	}

	@Test func ordinaryBinaryOperatorsStayBinary() {
		#expect(types("a - \\, b") == [.variable, .binaryOperator, .variable])
		#expect(types("a = b - c") == [.variable, .relation, .variable, .binaryOperator, .variable])
	}

	@Test func nestedListsAreFixed() {
		let list = MTMathListBuilder.build(fromString: "\\frac{a = \\; -1}{2}")
		MathAtomFix.apply(list)
		let numerator = (list?.atoms.first as? MTFraction)?.numerator?.atoms.map(\.type).filter { $0 != .space }
		#expect(numerator == [.variable, .relation, .unaryOperator, .number])
	}

	/// These tripped SwiftMath's spacing `assert`, crashing the Debug test process.
	@MainActor @Test(arguments: [
		"a = \\, -x",
		"a = \\quad -x",
		"a = {\\displaystyle -x}",
		"a + \\, = b",
		"\\frac{a = \\; -1}{2}",
		"x^{= \\, -1}",
		"\\begin{aligned} a &= \\, -b \\end{aligned}",
	])
	func rendersWithoutCrashing(latex: String) {
		for display in [true, false] {
			#expect(MathRenderer.typeset(latex, fontSize: 17, color: .label, display: display) != nil)
		}
	}
}
