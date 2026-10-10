import Foundation

/// A saved recipient.
struct Contact: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var address: String
}

/// The address book, kept on this phone only.
@MainActor
final class ContactBook: ObservableObject {
    @Published private(set) var contacts: [Contact] = []

    private static let key = "zapp.contacts"

    init() {
        if Demo.scene != nil {
            contacts = [Contact(name: "Alice", address: Demo.friend)]
            return
        }
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Contact].self, from: data) {
            contacts = saved
        }
    }

    /// Adds or updates (by id); sorted by name.
    func save(_ contact: Contact) {
        var contact = contact
        contact.name = contact.name.trimmingCharacters(in: .whitespacesAndNewlines)
        contact.address = contact.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[i] = contact
        } else {
            contacts.append(contact)
        }
        contacts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
    }

    func delete(_ ids: [UUID]) {
        contacts.removeAll { ids.contains($0.id) }
        persist()
    }

    func named(_ address: String) -> Contact? {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return contacts.first { $0.address == a }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(contacts) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
