import SwiftUI
import AppKit
import PhotosUI
import QuickLook
import UniformTypeIdentifiers

// MARK: - Turning picks into drafts

/// Reads what the open panel or the Photos picker hands back into an
/// ``AttachmentDraft``. The Mac twin of the iOS `AttachmentLoader`; kept
/// separate because the two pickers and image types are platform-bound.
enum MacAttachmentLoader {
    static func draft(from url: URL) -> AttachmentDraft? {
        // The open panel grants access to exactly what was chosen, and only
        // for as long as the scope is held.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        return AttachmentDraft(
            fileName: url.lastPathComponent,
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            data: data
        )
    }

    static func draft(from item: PhotosPickerItem) async -> AttachmentDraft? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let type = item.supportedContentTypes.first
        let isVideo = type?.conforms(to: .movie) == true
        return AttachmentDraft(
            fileName: "\(isVideo ? "Video" : "Photo") \(stampFormatter.string(from: .now)).\(type?.preferredFilenameExtension ?? "jpg")",
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            data: data
        )
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    static func icon(for draft: AttachmentDraft) -> String {
        let type = UTType(mimeType: draft.mimeType)
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .movie) == true { return "film" }
        if type?.conforms(to: .audio) == true { return "waveform" }
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        return "doc"
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

// MARK: - Thumbnail

/// The picture for an image whose bytes really are an image; its kind's glyph
/// for everything else.
struct MacAttachmentThumbnail: View {
    let media: TodoMedia
    var size: CGFloat = 36

    @Environment(AppStore.self) private var store
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: media.contentTypeMismatch ? "exclamationmark.triangle" : media.icon)
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(media.contentTypeMismatch ? Brand.warning : .secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 6))
        .task(id: media.id) {
            guard media.isPreviewableImage, image == nil,
                  let data = try? await store.mediaData(for: media) else { return }
            image = NSImage(data: data)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Section in the task editor

/// Every attachment on one task, with the controls to add and remove them.
/// Reads the task live from the store, so finished uploads and the partner's
/// removals appear while the sheet is open.
struct MacAttachmentsSection: View {
    let listId: String
    let todoId: String

    @Environment(AppStore.self) private var store

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showingFileImporter = false
    @State private var uploading: [AttachmentDraft] = []
    @State private var errorMessage: String?
    @State private var pendingRemoval: TodoMedia?
    @State private var previewURL: URL?
    @State private var suspicious: TodoMedia?

    private var list: TodoList? { store.list(id: listId) }
    private var todo: Todo? { list?.todos.first { $0.id == todoId } }
    private var allowance: MediaAllowance? { list?.mediaAllowance }

    private var remaining: Int {
        guard let allowance, allowance.enabled else { return 0 }
        let onTask = todo?.mediaRemaining ?? max(0, allowance.filesPerTask - (todo?.media.count ?? 0))
        return max(0, min(onTask, allowance.remainingOnList) - uploading.count)
    }

    var body: some View {
        if let allowance, allowance.enabled, let todo {
            Section {
                ForEach(todo.media) { media in
                    row(for: media)
                }
                ForEach(uploading) { draft in
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small).frame(width: 36)
                        Text(draft.fileName).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("Uploading…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    PhotosPicker(
                        selection: $photoItems,
                        maxSelectionCount: max(1, remaining),
                        matching: .any(of: [.images, .videos])
                    ) {
                        Label("Add Photo…", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("Add File…", systemImage: "doc.badge.plus")
                    }
                }
                .disabled(remaining == 0)
            } header: {
                Text("Attachments")
            } footer: {
                Text(errorMessage ?? footer(allowance))
                    .foregroundStyle(errorMessage == nil ? Color.secondary : Brand.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                Task {
                    for item in items {
                        if let draft = await MacAttachmentLoader.draft(from: item) { upload(draft) }
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                guard case .success(let urls) = result else { return }
                for url in urls {
                    if let draft = MacAttachmentLoader.draft(from: url) { upload(draft) }
                }
            }
            .quickLookPreview($previewURL)
            .confirmationDialog(
                "Remove this attachment?",
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                presenting: pendingRemoval
            ) { media in
                Button("Remove “\(media.fileName)”", role: .destructive) {
                    Task { await store.removeMedia(media) }
                }
            } message: { _ in
                Text("It's deleted for both of you, and can't be brought back.")
            }
            .alert(
                "This file may not be what it says",
                isPresented: Binding(get: { suspicious != nil }, set: { if !$0 { suspicious = nil } }),
                presenting: suspicious
            ) { media in
                Button("Open Anyway") { Task { await open(media, confirmed: true) } }
                Button("Cancel", role: .cancel) {}
            } message: { media in
                Text("“\(media.fileName)” doesn't contain the kind of data its name suggests. Only open it if you trust who added it.")
            }
        }
    }

    private func footer(_ allowance: MediaAllowance) -> String {
        if remaining == 0 && uploading.isEmpty {
            return String(localized: "This task has as many attachments as it can hold. Remove one to add another.")
        }
        return String(localized: "Up to \(allowance.filesPerTask) per task, \(MacAttachmentLoader.bytes(allowance.maxFileBytes)) each. Both of you can see and remove them.")
    }

    private func row(for media: TodoMedia) -> some View {
        HStack(spacing: 10) {
            MacAttachmentThumbnail(media: media)
            VStack(alignment: .leading, spacing: 1) {
                Text(media.fileName).lineLimit(1).truncationMode(.middle)
                Text(detail(for: media))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button("Open") { Task { await open(media, confirmed: false) } }
            Button(role: .destructive) {
                pendingRemoval = media
            } label: {
                Image(systemName: "trash")
            }
            .help("Remove this attachment")
            .accessibilityLabel("Remove \(media.fileName)")
        }
        .contextMenu {
            Button("Open") { Task { await open(media, confirmed: false) } }
            Button("Remove…", role: .destructive) { pendingRemoval = media }
        }
    }

    private func detail(for media: TodoMedia) -> String {
        var parts = [MacAttachmentLoader.bytes(media.sizeBytes)]
        if let uploader = media.uploadedBy {
            if uploader == store.currentUserId {
                parts.append(String(localized: "added by you"))
            } else if let person = store.partner(id: uploader) {
                parts.append(String(localized: "added by \(person.identityLabel)"))
            }
        }
        return parts.joined(separator: " · ")
    }

    private func upload(_ draft: AttachmentDraft) {
        errorMessage = nil
        if let allowance, allowance.maxFileBytes > 0, draft.sizeBytes > allowance.maxFileBytes {
            errorMessage = String(localized: "“\(draft.fileName)” is \(MacAttachmentLoader.bytes(draft.sizeBytes)). Files can be up to \(MacAttachmentLoader.bytes(allowance.maxFileBytes)).")
            return
        }
        guard remaining > 0 else {
            errorMessage = String(localized: "This task can't take any more attachments. Remove one to add another.")
            return
        }
        uploading.append(draft)
        Task {
            defer { uploading.removeAll { $0.id == draft.id } }
            do {
                try await store.attachMedia(listId: listId, todoId: todoId, draft: draft)
            } catch {
                errorMessage = error.userMessage
            }
        }
    }

    /// Quick Look, which already shows images, video, audio and PDFs.
    private func open(_ media: TodoMedia, confirmed: Bool) async {
        if media.contentTypeMismatch && !confirmed {
            suspicious = media
            return
        }
        do {
            let data = try await store.mediaData(for: media)
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent(media.id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(media.fileName)
            try data.write(to: file, options: .atomic)
            previewURL = file
        } catch {
            errorMessage = error.userMessage
        }
    }
}

// MARK: - Drafts on a new task

/// Files queued in the add bar for a task that does not exist yet.
struct MacDraftAttachmentStrip: View {
    @Binding var drafts: [AttachmentDraft]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(drafts) { draft in
                    HStack(spacing: 4) {
                        Image(systemName: MacAttachmentLoader.icon(for: draft))
                        Text(draft.fileName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 160)
                        Button {
                            drafts.removeAll { $0.id == draft.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(draft.fileName)")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}
