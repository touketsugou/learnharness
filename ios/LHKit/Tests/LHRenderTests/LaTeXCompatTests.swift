import Foundation
import SwiftMath
import Testing
@testable import LHRender

@Suite("KaTeX → SwiftMath compatibility")
struct LaTeXCompatTests {
	let rewrite = LaTeXCompat.rewrite

	@Test func styledFractionsAndBinomials() {
		#expect(rewrite("\\dfrac{a}{b}") == "{\\displaystyle\\frac{a}{b}}")
		#expect(rewrite("\\cfrac{a}{b}") == "{\\displaystyle\\frac{a}{b}}")
		#expect(rewrite("\\tfrac{a}{b}") == "{\\textstyle\\frac{a}{b}}")
		#expect(rewrite("\\dbinom{n}{k}") == "{\\displaystyle\\binom{n}{k}}")
		#expect(rewrite("\\tbinom{n}{k}") == "{\\textstyle\\binom{n}{k}}")
	}

	@Test func fractionArgumentsFollowTeXRules() {
		#expect(rewrite("\\dfrac12") == "{\\displaystyle\\frac{1}{2}}")
		#expect(rewrite("\\dfrac \\alpha {x}") == "{\\displaystyle\\frac{\\alpha}{x}}")
		#expect(rewrite("\\dfrac{\\dfrac{a}{b}}{c}") == "{\\displaystyle\\frac{{\\displaystyle\\frac{a}{b}}}{c}}")
		#expect(rewrite("\\dfrac{\\{x\\}}{\\dots}") == "{\\displaystyle\\frac{\\{x\\}}{\\ldots}}")
		#expect(rewrite("\\dfrac{a}") == "\\dfrac{a}")
	}

	@Test func dots() {
		#expect(rewrite("z_1,\\dots,z_{10}") == "z_1,\\ldots,z_{10}")
		#expect(rewrite("\\dotsc") == "\\ldots")
		#expect(rewrite("\\dotsb \\dotsm \\dotsi") == "\\cdots \\cdots \\cdots")
	}

	@Test func operatorNames() {
		#expect(rewrite("\\operatorname{softmax}(x)") == "\\mathrm{softmax}(x)")
		#expect(rewrite("\\operatorname*{argmax}_x") == "\\mathrm{argmax}_x")
	}

	@Test func renamedSymbols() {
		#expect(rewrite("\\lvert x \\rvert") == "| x |")
		#expect(rewrite("\\left\\lVert x \\right\\rVert") == "\\left\\| x \\right\\|")
		#expect(rewrite("a \\implies b \\impliedby c") == "a \\Longrightarrow b \\Longleftarrow c")
		#expect(rewrite("\\varnothing") == "\\emptyset")
		#expect(rewrite("\\boldsymbol{\\theta}") == "\\bm{\\theta}")
	}

	@Test func negations() {
		#expect(rewrite("x \\not\\in A") == "x \\notin A")
		#expect(rewrite("a \\not= b") == "a \\neq b")
		#expect(rewrite("\\not\\subset") == "\\not\\subset")
		#expect(rewrite("\\not\\infty") == "\\not\\infty")
	}

	@Test func delimiterSizingIsDropped() {
		#expect(rewrite("\\big( x \\big)") == "( x )")
		#expect(rewrite("\\Bigl\\{ x \\Bigr\\}") == "\\{ x \\}")
		#expect(rewrite("\\bigg| \\Biggm|") == "| |")
	}

	@Test func leavesEscapesAndLongerNamesAlone() {
		#expect(rewrite("a \\\\dots") == "a \\\\dots")
		#expect(rewrite("\\dotsx \\bigcup \\bigoplus") == "\\dotsx \\bigcup \\bigoplus")
		#expect(rewrite("\\{ \\, \\| \\$") == "\\{ \\, \\| \\$")
	}

	@Test func supportedLaTeXIsUnchanged() {
		for latex in ["\\frac{a}{b}", "\\sum_{i=1}^{n} x_i^2", "\\mathrm{ReLU}(z)", "\\left( x \\right)", "> 0", "p_i = 1"] {
			#expect(rewrite(latex) == latex)
		}
	}

	@Test(arguments: [
		"z_1,\\dots,z_{10}",
		"p_i = \\dfrac{e^{z_i}}{\\sum_j e^{z_j}}",
		"p_i = \\dfrac{\\mathrm{ReLU}(z_i)}{\\sum_j \\mathrm{ReLU}(z_j)}",
		"\\operatorname*{argmax}_x \\lVert x \\rVert \\implies \\varnothing",
		"\\boldsymbol{\\theta} \\not\\in \\big( \\tbinom{n}{k} \\big)",
		"A^\\intercal \\triangleq B \\coloneqq C",
	])
	func rewrittenLaTeXParses(_ latex: String) {
		_ = LaTeXCompat.registerSymbols
		var error: NSError?
		_ = MTMathListBuilder.build(fromString: rewrite(latex), error: &error)
		#expect(error == nil, "\(latex): \(error?.localizedDescription ?? "")")
	}
}
