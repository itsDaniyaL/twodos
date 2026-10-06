import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers

// MARK: - Turning picks into drafts

/// Reads whatever the system pickers hand back into an ``AttachmentDraft``.
///
/// The MIME type sent with an upload is only ever *declared* — the server sniffs
/// the bytes and decides the kind itself — but declaring the right one is what
/// lets the record flag a file whose bytes disagree with its name.
enum AttachmentLoader {
    static func draft(from item: PhotosPickerItem) async -> AttachmentDraft? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let type = item.supportedContentTypes.first
        let ext = type?.preferredFilenameExtension ?? "jpg"
        let isVideo = type?.conforms(to: .movie) == true
        let stamp = stampFormatter.string(from: .now)
        return AttachmentDraft(
            fileName: "\(isVideo ? "Video" : "Photo") \(stamp).\(ext)",
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            data: data
        )
    }

    /// "2026-10-06 at 14.05.12" — sortable, and free of the colons some file
    /// systems refuse.
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    /// A file from the Files picker. Outside the app's container, so it has to
    /// be opened under its security scope and read before that scope ends.
    static func draft(from url: URL) -> AttachmentDraft? {
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

    /// The icon a draft gets before the server has said what it is.
    static func icon(for draft: AttachmentDraft) -> String {
        let type = UTType(mimeType: draft.mimeType)
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .movie) == true { return "film" }
        if type?.conforms(to: .audio) == true { return "waveform" }
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        return "doc"
    }
}

extension Format {
    /// "4.2 MB" — the same units the server's limit messages use.
    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

// MARK: - Thumbnail

/// A square preview of one attachment: the picture itself for an image whose
/// bytes really are an image, its kind's glyph for everything else.
struct AttachmentThumbnail: View {
    let media: TodoMedia
    var size: CGFloat = 44

    @Environment(AppStore.self) private var store
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: media.contentTypeMismatch ? "exclamationmark.triangle" : media.icon)
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(media.contentTypeMismatch ? Brand.warning : .secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .task(id: media.id) {
            // Only an image whose sniffed type agrees with its name is decoded
            // inline; anything else keeps its glyph.
            guard media.isPreviewableImage, image == nil,
                  let data = try? await store.mediaData(for: media) else { return }
            image = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: size * 3, height: size * 3))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Section in the task editor

/// Every attachment on one task, with the controls to add and remove them.
///
/// Reads the task live from the store rather than holding a copy, so an upload
/// that finishes — or a file the partner removes — shows up while the sheet is
/// open.
struct AttachmentsSection: View {
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
    @State private var openingId: String?

    private var list: TodoList? { store.list(id: listId) }
    private var todo: Todo? { list?.todos.first { $0.id == todoId } }
    private var allowance: MediaAllowance? { list?.mediaAllowance }

    /// Files this task can still take, counting the ones on their way up.
    private var remaining: Int {
        guard let allowance, allowance.enabled else { return 0 }
        let onTask = todo?.mediaRemaining ?? max(0, allowance.filesPerTask - (todo?.media.count ?? 0))
        return max(0, min(onTask, allowance.remainingOnList) - uploading.count)
    }

    var body: some View {
        if let allowance, allowance.enabled, let todo {
            GlassSection(title: "Attachments", footer: footer(allowance)) {
                ForEach(todo.media) { media in
                    row(for: media)
                    GlassDivider()
                }
                ForEach(uploading) { draft in
                    uploadingRow(draft)
                    GlassDivider()
                }
                addButtons
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                Task {
                    for item in items {
                        if let draft = await AttachmentLoader.draft(from: item) { upload(draft) }
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
                    if let draft = AttachmentLoader.draft(from: url) { upload(draft) }
                }
            }
            .quickLookPreview($previewURL)
            .confirmationDialog(
                "Remove this attachment?",
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible,
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
                Button("Open anyway") { Task { await open(media, confirmed: true) } }
                Button("Cancel", role: .cancel) {}
            } message: { media in
                Text("“\(media.fileName)” doesn't contain the kind of data its name suggests. Only open it if you trust who added it.")
            }
        }
    }

    private func footer(_ allowance: MediaAllowance) -> String {
        if let errorMessage { return errorMessage }
        return String(localized: "Up to \(allowance.filesPerTask) per task, \(Format.bytes(allowance.maxFileBytes)) each. Both of you can see and remove them.")
    }

    private func row(for media: TodoMedia) -> some View {
        HStack(spacing: 12) {
            AttachmentThumbnail(media: media)
            VStack(alignment: .leading, spacing: 2) {
                Text(media.fileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(Format.bytes(media.sizeBytes))
                    if let who = uploaderName(media) { Text("· \(who)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if openingId == media.id {
                ProgressView().controlSize(.small)
            }
            Button {
                pendingRemoval = media
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15))
                    .foregroundStyle(Brand.danger)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(media.fileName)")
        }
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .onTapGesture { Task { await open(media, confirmed: false) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the file")
    }

    private func uploadingRow(_ draft: AttachmentDraft) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                ProgressView()
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.fileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Uploading · \(Format.bytes(draft.sizeBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 10)
    }

    private var addButtons: some View {
        HStack(spacing: 10) {
            PhotosPicker(
                selection: $photoItems,
                maxSelectionCount: max(1, remaining),
                matching: .any(of: [.images, .videos])
            ) {
                Label("Photo", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            Button {
                showingFileImporter = true
            } label: {
                Label("File", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.glass)
        .controlSize(.regular)
        .disabled(remaining == 0)
        .padding(Metrics.cardPadding)
        .overlay(alignment: .bottom) {
            if remaining == 0 {
                Text("This task has as many attachments as it can hold.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
            }
        }
    }

    private func uploaderName(_ media: TodoMedia) -> String? {
        guard let uploader = media.uploadedBy else { return nil }
        if uploader == store.currentUserId { return String(localized: "added by you") }
        return store.partner(id: uploader).map { String(localized: "added by \($0.identityLabel)") }
    }

    private func upload(_ draft: AttachmentDraft) {
        errorMessage = nil
        // Checked here as well as on the server, so a file that cannot fit is
        // refused before it has spent the user's data allowance going up.
        if let allowance, allowance.maxFileBytes > 0, draft.sizeBytes > allowance.maxFileBytes {
            errorMessage = String(localized: "“\(draft.fileName)” is \(Format.bytes(draft.sizeBytes)). Files can be up to \(Format.bytes(allowance.maxFileBytes)).")
            Haptics.error()
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
                Haptics.error()
                errorMessage = error.userMessage
            }
        }
    }

    /// Opens the file in Quick Look, which already knows how to show images,
    /// video, audio and PDFs natively.
    private func open(_ media: TodoMedia, confirmed: Bool) async {
        if media.contentTypeMismatch && !confirmed {
            suspicious = media
            return
        }
        openingId = media.id
        defer { openingId = nil }
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

/// The files queued on the add bar for a task that does not exist yet.
struct DraftAttachmentStrip: View {
    @Binding var drafts: [AttachmentDraft]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(drafts) { draft in
                    HStack(spacing: 6) {
                        Image(systemName: AttachmentLoader.icon(for: draft))
                            .font(.caption.weight(.semibold))
                        Text(draft.fileName)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 140)
                        Button {
                            withAnimation(Motion.content) { drafts.removeAll { $0.id == draft.id } }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(draft.fileName)")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
    }
}
