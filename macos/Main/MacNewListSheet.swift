import SwiftUI

/// Creating a list.
///
/// Sharing is an explicit choice rather than an optional field left blank,
/// exactly as on iOS: "leave this empty to keep it private" is easy to misread,
/// and inviting somebody by accident is awkward to undo.
struct MacNewListSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var isShared = false
    @State private var partnerRef = ""
    @State private var isFavorite = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    /// How the server will read what was typed — an address or a handle.
    private var reference: PartnerReference? { PartnerReference(partnerRef) }

    private var canSubmit: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty
            && (!isShared || reference?.isPlausible == true)
            && !isSubmitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New list").font(.title2.weight(.semibold))

            if let errorMessage {
                MacBanner(kind: .error, title: errorMessage)
            }

            Form {
                TextField("Name", text: $label)
                    .focused($nameFocused)

                Toggle("Add to favourites", isOn: $isFavorite)

                Section {
                    Picker("Who's this for?", selection: $isShared) {
                        Text("Just me").tag(false)
                        Text("Share it").tag(true)
                    }
                    .pickerStyle(.radioGroup)

                    if isShared {
                        TextField("Email address or @username", text: $partnerRef)
                            .autocorrectionDisabled()
                        // The hint follows what is being typed, because the two
                        // routes differ for somebody with no account and the
                        // difference is not guessable.
                        Text(partnerHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { nameFocused = true }
    }

    private var partnerHint: String {
        switch reference {
        case .email:
            "If they don't have twodos yet, we'll email them an invitation."
        case .username:
            "Usernames only reach people who already have twodos. To invite somebody new, use their email address."
        case nil:
            "Their email address, or their @username if they've chosen one."
        }
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await store.createList(
                    label: label.trimmingCharacters(in: .whitespaces),
                    favorite: isFavorite,
                    partner: isShared ? reference : nil
                )
                dismiss()
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}
