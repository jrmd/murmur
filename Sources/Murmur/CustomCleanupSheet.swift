import MurmurCore
import SwiftUI

/// Pick a GGUF from a Hugging Face repo and write the system prompt Murmur runs it with.
struct CustomCleanupSheet: View {
    @ObservedObject var controller: AppController
    let existing: CustomCleanupModel?
    @Environment(\.dismiss) private var dismiss

    private enum Lookup: Equatable { case idle, loading, failed(String) }

    @State private var link = ""
    @State private var repo = ""
    @State private var files: [HuggingFace.File] = []
    @State private var file = ""
    /// The commit the file list came from, so the download is pinned to the bytes the user picked.
    @State private var revision: String?
    @State private var prompt = CustomCleanupModel.defaultPrompt
    @State private var lookup = Lookup.idle

    private var selectedFile: HuggingFace.File? { files.first { $0.name == file } }
    private var canSave: Bool { !repo.isEmpty && selectedFile != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && lookup != .loading }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Custom clean-up model").font(.title3.weight(.semibold))
                Text("Paste a Hugging Face model page that has GGUF files. Murmur downloads one file and runs it on your Mac. Check the model’s licence on its page first.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("https://huggingface.co/owner/model-GGUF", text: $link)
                        .textFieldStyle(.roundedBorder).onSubmit { Task { await find() } }
                    Button("Find files") { Task { await find() } }.disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || lookup == .loading)
                }
                switch lookup {
                case .loading: ProgressView().controlSize(.small)
                case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(OB.amberText).fixedSize(horizontal: false, vertical: true)
                case .idle: EmptyView()
                }
                if !files.isEmpty {
                    Picker("File", selection: $file) {
                        ForEach(files, id: \.name) { Text(Self.label($0)).tag($0.name) }
                    }
                    if let size = selectedFile?.size, size > 2_500_000_000 {
                        Text("This is a large file. Smaller models respond faster, which matters for dictation.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("System prompt").font(.headline)
                    Spacer()
                    Button("Reset to default") { prompt = CustomCleanupModel.defaultPrompt }.controlSize(.small).disabled(prompt == CustomCleanupModel.defaultPrompt)
                }
                TextEditor(text: $prompt).font(.system(size: 12, design: .monospaced)).frame(height: 150)
                    .padding(4).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8)).scrollContentBackground(.hidden)
                Text("Your dictation is sent as the user message. \(CustomCleanupModel.vocabularyPlaceholder) is replaced with your dictionary’s spellings, and a line containing it is left out when the dictionary is empty.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save and download") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!canSave)
            }
        }
        .padding(20).frame(width: 560)
        .tint(.murmurCoral)
        .onAppear {
            guard let existing else { return }
            link = existing.repoURL.absoluteString; repo = existing.repo; prompt = existing.systemPrompt; revision = existing.revision
            files = [HuggingFace.File(name: existing.fileName, size: existing.sizeBytes)]; file = existing.fileName
        }
    }

    private static func label(_ file: HuggingFace.File) -> String {
        guard let size = file.size else { return file.name }
        return "\(file.name) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }

    private func find() async {
        guard let reference = HuggingFace.parse(link) else {
            lookup = .failed(String(localized: "That doesn’t look like a Hugging Face link. Paste a model page URL or owner/name.", comment: "Error in the custom clean-up sheet when the pasted link is not a Hugging Face model page.")); return
        }
        lookup = .loading
        do {
            let found = try await HuggingFace.listGGUFRepository(repo: reference.repo)
            guard !found.files.isEmpty else { lookup = .failed(String(localized: "\(reference.repo) has no GGUF files Murmur can run. Look for a repo with “GGUF” in its name.", comment: "Error in the custom clean-up sheet when the Hugging Face repo has no usable GGUF file. The placeholder is the repo name.")); return }
            repo = reference.repo; files = found.files; revision = found.revision
            file = found.files.first { $0.name == reference.fileName }?.name ?? HuggingFace.preferred(found.files)?.name ?? found.files[0].name
            lookup = .idle
        } catch {
            lookup = .failed(error.localizedDescription)
        }
    }

    private func save() {
        guard let selectedFile else { return }
        // Editing the prompt of the model you already have keeps the commit it was downloaded from.
        let unchanged = existing?.repo == repo && existing?.fileName == selectedFile.name
        let model = CustomCleanupModel(repo: repo, fileName: selectedFile.name, systemPrompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                       sizeBytes: selectedFile.size, revision: unchanged ? existing?.revision : revision)
        dismiss()
        Task { await controller.saveCustomCleanup(model) }
    }
}
