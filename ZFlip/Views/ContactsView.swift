import SwiftUI

/// The address book: browse, add, edit, delete. With `pick`, tapping a contact
/// chooses it (from Send) instead of editing it.
struct ContactsView: View {
    @EnvironmentObject var book: ContactBook
    @EnvironmentObject var wallet: WalletModel
    @Environment(\.dismiss) private var dismiss
    var pick: ((Contact) -> Void)?

    @State private var editing: Contact?
    @State private var adding = false

    var body: some View {
        List {
            if book.contacts.isEmpty {
                Text("No contacts yet. Add one with +, or save an address from Send.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            ForEach(book.contacts) { contact in
                Button {
                    if let pick {
                        pick(contact)
                        dismiss()
                    } else {
                        editing = contact
                    }
                } label: {
                    HStack(spacing: 12) {
                        Text(String(contact.name.prefix(1)).uppercased())
                            .font(.headline).foregroundStyle(.black)
                            .frame(width: 36, height: 36)
                            .background(Theme.zcash).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(contact.name).font(.subheadline.weight(.semibold))
                            Text(short(contact.address)).font(.caption.monospaced()).foregroundStyle(Theme.muted)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in book.delete(offsets.map { book.contacts[$0].id }) }
        }
        .navigationTitle("Address book")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .backArrow()
        .toolbar {
            Button { adding = true } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $adding) {
            ContactEditor(contact: Contact(name: "", address: ""))
        }
        .sheet(item: $editing) { contact in
            ContactEditor(contact: contact)
        }
    }

    private func short(_ a: String) -> String {
        a.count > 22 ? "\(a.prefix(12))…\(a.suffix(8))" : a
    }
}

/// Name and address, checked before saving.
struct ContactEditor: View {
    @EnvironmentObject var book: ContactBook
    @EnvironmentObject var wallet: WalletModel
    @Environment(\.dismiss) private var dismiss
    @State var contact: Contact

    private var validAddress: Bool { wallet.validate(address: contact.address.trimmingCharacters(in: .whitespaces)) }
    private var canSave: Bool { !contact.name.trimmingCharacters(in: .whitespaces).isEmpty && validAddress }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Alice", text: $contact.name)
                }
                Section {
                    TextField("u1… or t1…", text: $contact.address, axis: .vertical)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Paste") {
                        if let s = UIPasteboard.general.string { contact.address = s }
                    }
                } header: {
                    Text("Zcash address")
                } footer: {
                    if !contact.address.isEmpty && !validAddress {
                        Text("Not a valid Zcash address for this network.").foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(book.contacts.contains { $0.id == contact.id } ? "Edit contact" : "New contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        book.save(contact)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
