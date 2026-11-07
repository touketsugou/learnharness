import Testing
@testable import LearnHarness

@Suite("File chips")
struct FileChipTests {
	@Test func uploadPrefixIsHidden() {
		#expect(FilePathText.chipName(for: "/data/uploads/2026-11/e2691eb5-05f7-4ba5-b1a6-d0268d654d94-kepler-notes.md") == "kepler-notes.md")
		#expect(FilePathText.chipName(for: "/data/uploads/2026-11/fb345e01-125b-4157-a145-fab47afad57c-photo-1.jpg") == "photo-1.jpg")
	}

	@Test func otherNamesStayAsTheyAre() {
		#expect(FilePathText.chipName(for: "/Users/me/notes/kepler.md") == "kepler.md")
		#expect(FilePathText.chipName(for: "~/Desktop/report-2026-11-07.pdf") == "report-2026-11-07.pdf")
		// A bare UUID-dash name keeps its text rather than becoming empty.
		#expect(FilePathText.chipName(for: "/x/e2691eb5-05f7-4ba5-b1a6-d0268d654d94-") == "e2691eb5-05f7-4ba5-b1a6-d0268d654d94-")
	}

	@Test func chipTextUsesTheShortName() {
		let text = FilePathText.attributed("see `/data/uploads/2026-11/e2691eb5-05f7-4ba5-b1a6-d0268d654d94-kepler-notes.md` please")
		#expect(String(text.characters) == "see 📎 kepler-notes.md please")
	}
}
