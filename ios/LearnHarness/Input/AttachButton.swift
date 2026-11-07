import LHAPI
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The paperclip (web AttachFilesButton): photos or files are uploaded to the
/// server and their quoted server paths are appended to the draft.
struct AttachButton: View {
	@Binding var text: String
	@Environment(AppModel.self) private var app
	@State private var showPhotos = false
	@State private var showFiles = false
	@State private var photoItems: [PhotosPickerItem] = []
	@State private var uploading = false
	@State private var error: String?

	var body: some View {
		Group {
			if uploading {
				ProgressView().frame(width: 32, height: 32)
			} else {
				Menu {
					Button("Photo Library", systemImage: "photo.on.rectangle") { showPhotos = true }
					Button("Files", systemImage: "folder") { showFiles = true }
				} label: {
					Image(systemName: "paperclip").font(.title3).frame(width: 32, height: 32)
				}
				.accessibilityLabel("Attach files")
			}
		}
		.photosPicker(isPresented: $showPhotos, selection: $photoItems, matching: .images)
		.fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
			switch result {
			case .success(let urls): Task { await attach(Attachments.files(urls)) }
			case .failure(let failure): error = failure.localizedDescription
			}
		}
		.onChange(of: photoItems) { _, items in
			guard !items.isEmpty else { return }
			photoItems = []
			Task { await attach(await Attachments.photos(items)) }
		}
		.alert("Couldn’t attach", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(error ?? "")
		}
	}

	private func attach(_ prepared: Attachments.Prepared) async {
		guard let client = app.client else { return }
		uploading = true
		defer { uploading = false }
		var paths: [String] = []
		var problems = prepared.problems
		// One request per file keeps each within the server's 25 MB request bound.
		for file in prepared.files {
			do {
				paths += try await client.upload([file]).map(\.path)
			} catch {
				problems.append("\(file.name): \((error as? APIError)?.message ?? error.localizedDescription)")
			}
		}
		if !paths.isEmpty {
			text = DraftText.append(paths.map(FilePathQuoting.quote).joined(separator: " "), to: text)
		}
		if !problems.isEmpty { error = problems.joined(separator: "\n") }
	}
}

/// Reading picked items into upload payloads.
enum Attachments {
	static let maxBytes = 25 * 1024 * 1024

	struct Prepared {
		var files: [UploadFile] = []
		var problems: [String] = []
	}

	/// Photos: PNG and GIF keep their bytes; everything else (HEIC, …) is
	/// re-encoded as JPEG at full size so the agent's image tools can read it.
	static func photos(_ items: [PhotosPickerItem]) async -> Prepared {
		var prepared = Prepared()
		for (index, item) in items.enumerated() {
			let name = "photo-\(index + 1)"
			guard let data = try? await item.loadTransferable(type: Data.self) else {
				prepared.problems.append("\(name): the photo couldn’t be read.")
				continue
			}
			let type = item.supportedContentTypes.first
			let file: UploadFile?
			if type?.conforms(to: .png) == true {
				file = UploadFile(name: name + ".png", mimeType: "image/png", data: data)
			} else if type?.conforms(to: .gif) == true {
				file = UploadFile(name: name + ".gif", mimeType: "image/gif", data: data)
			} else if let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) {
				file = UploadFile(name: name + ".jpg", mimeType: "image/jpeg", data: jpeg)
			} else {
				file = nil
			}
			guard let file else {
				prepared.problems.append("\(name): the photo couldn’t be converted.")
				continue
			}
			add(file, to: &prepared)
		}
		return prepared
	}

	/// Files from the Files app upload unchanged.
	static func files(_ urls: [URL]) -> Prepared {
		var prepared = Prepared()
		for url in urls {
			let scoped = url.startAccessingSecurityScopedResource()
			defer { if scoped { url.stopAccessingSecurityScopedResource() } }
			guard let data = try? Data(contentsOf: url) else {
				prepared.problems.append("\(url.lastPathComponent): the file couldn’t be read.")
				continue
			}
			let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
			add(UploadFile(name: url.lastPathComponent, mimeType: mime, data: data), to: &prepared)
		}
		return prepared
	}

	private static func add(_ file: UploadFile, to prepared: inout Prepared) {
		if file.data.count > maxBytes {
			prepared.problems.append("\(file.name) is larger than 25 MB.")
		} else {
			prepared.files.append(file)
		}
	}
}
