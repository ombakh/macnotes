import AppKit
import SwiftUI

@main
struct MacNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = NotesStore()

    var body: some Scene {
        MenuBarExtra("Glass Notes", systemImage: "note.text") {
            NotesRootView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct Note: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var body: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        body: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

private enum NoteFileCodec {
    private static let separator = "\n---\n"
    private static let formatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let formatterPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func encode(note: Note) -> String {
        let titleLine = "title:\(note.title.replacingOccurrences(of: "\n", with: " "))"
        let createdLine = "createdAt:\(formatterWithFractional.string(from: note.createdAt))"
        let updatedLine = "updatedAt:\(formatterWithFractional.string(from: note.updatedAt))"
        return [titleLine, createdLine, updatedLine].joined(separator: "\n") + separator + note.body
    }

    static func decode(
        id: UUID,
        text: String,
        fallbackCreatedAt: Date,
        fallbackUpdatedAt: Date
    ) -> Note {
        let chunks = text.components(separatedBy: separator)
        guard chunks.count >= 2 else {
            return Note(
                id: id,
                title: "",
                body: text,
                createdAt: fallbackCreatedAt,
                updatedAt: fallbackUpdatedAt
            )
        }

        let metadata = chunks[0].split(separator: "\n")
        let body = chunks.dropFirst().joined(separator: separator)
        var title = ""
        var createdAt = fallbackCreatedAt
        var updatedAt = fallbackUpdatedAt

        for line in metadata {
            if line.hasPrefix("title:") {
                title = String(line.dropFirst("title:".count))
            } else if line.hasPrefix("createdAt:") {
                let rawDate = String(line.dropFirst("createdAt:".count))
                createdAt = parseDate(rawDate) ?? createdAt
            } else if line.hasPrefix("updatedAt:") {
                let rawDate = String(line.dropFirst("updatedAt:".count))
                updatedAt = parseDate(rawDate) ?? updatedAt
            }
        }

        return Note(
            id: id,
            title: title,
            body: body,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func parseDate(_ rawDate: String) -> Date? {
        formatterWithFractional.date(from: rawDate) ?? formatterPlain.date(from: rawDate)
    }
}

@MainActor
final class NotesStore: ObservableObject {
    @Published var notes: [Note] = []
    @Published var selectedNoteID: Note.ID?

    private let notesDirectoryURL: URL
    private var saveTask: Task<Void, Never>?

    init() {
        self.notesDirectoryURL = NotesStore.makeStorageURL()

        load()

        if notes.isEmpty {
            let starter = Note(
                title: "",
                body: "Start writing quick notes from your menu bar."
            )
            notes = [starter]
            selectedNoteID = starter.id
            saveNow()
        } else {
            selectedNoteID = notes.sorted(by: { $0.updatedAt > $1.updatedAt }).first?.id
        }
    }

    var selectedNote: Note? {
        guard let selectedNoteID else { return nil }
        return notes.first(where: { $0.id == selectedNoteID })
    }

    func addNote() {
        let note = Note(title: "")
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        scheduleSave()
    }

    func deleteNote(id: Note.ID) {
        notes.removeAll(where: { $0.id == id })

        if selectedNoteID == id {
            selectedNoteID = notes.sorted(by: { $0.updatedAt > $1.updatedAt }).first?.id
        }
        scheduleSave()
    }

    func updateNote(id: Note.ID, title: String, body: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let existing = notes[index]

        guard existing.title != title || existing.body != body else { return }

        notes[index].title = title
        notes[index].body = body
        notes[index].updatedAt = Date()
        scheduleSave()
    }

    func sortedNotes(matching query: String) -> [Note] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmed.isEmpty
            ? notes
            : notes.filter { note in
                note.title.localizedCaseInsensitiveContains(trimmed) ||
                note.body.localizedCaseInsensitiveContains(trimmed)
            }
        return filtered.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    private func saveNow() {
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: notesDirectoryURL, withIntermediateDirectories: true)

            var expectedFiles = Set<String>()
            for note in notes {
                let filename = "\(note.id.uuidString).txt"
                expectedFiles.insert(filename)
                let fileURL = notesDirectoryURL.appendingPathComponent(filename)
                let text = NoteFileCodec.encode(note: note)
                try text.write(to: fileURL, atomically: true, encoding: .utf8)
            }

            let existingFiles = try fileManager.contentsOfDirectory(at: notesDirectoryURL, includingPropertiesForKeys: nil)
            for fileURL in existingFiles where fileURL.pathExtension.lowercased() == "txt" {
                if !expectedFiles.contains(fileURL.lastPathComponent) {
                    try? fileManager.removeItem(at: fileURL)
                }
            }
        } catch {
            NSLog("Failed to save notes: %@", error.localizedDescription)
        }
    }

    private func load() {
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: notesDirectoryURL, withIntermediateDirectories: true)
            let files = try fileManager.contentsOfDirectory(
                at: notesDirectoryURL,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]
            )

            var loaded: [Note] = []

            for fileURL in files where fileURL.pathExtension.lowercased() == "txt" {
                let filename = fileURL.deletingPathExtension().lastPathComponent
                guard let id = UUID(uuidString: filename) else { continue }

                let values = try? fileURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let createdAt = values?.creationDate ?? Date()
                let updatedAt = values?.contentModificationDate ?? createdAt
                let text = try String(contentsOf: fileURL, encoding: .utf8)
                let note = NoteFileCodec.decode(
                    id: id,
                    text: text,
                    fallbackCreatedAt: createdAt,
                    fallbackUpdatedAt: updatedAt
                )
                loaded.append(note)
            }
            notes = loaded
        } catch {
            notes = []
        }
    }

    private static func makeStorageURL() -> URL {
        let fileManager = FileManager.default
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let folder = projectRoot.appendingPathComponent("SavedNotes", isDirectory: true)

        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            NSLog("Failed to create notes folder: %@", error.localizedDescription)
        }
        return folder
    }
}

struct NotesRootView: View {
    @ObservedObject var store: NotesStore
    @State private var query = ""

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.white.opacity(0.78))
                        TextField("Search notes", text: $query)
                            .textFieldStyle(.plain)
                    }
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(.white.opacity(0.16), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(.white.opacity(0.26), lineWidth: 1)
                    )
                    Button {
                        store.addNote()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("New note")
                }

                List(selection: $store.selectedNoteID) {
                    ForEach(store.sortedNotes(matching: query)) { note in
                        NoteRow(note: note)
                            .tag(note.id)
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.deleteNote(id: note.id)
                                } label: {
                                    Label("Delete Note", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }
            .padding(12)
            .glassPanel()
            .padding([.leading, .bottom, .top], 12)
        } detail: {
            Group {
                if let note = store.selectedNote {
                    NoteEditorView(note: note) { title, body in
                        store.updateNote(id: note.id, title: title, body: body)
                    } onDelete: {
                        store.deleteNote(id: note.id)
                    }
                    .id(note.id)
                } else {
                    EmptyStateView()
                }
            }
            .padding([.trailing, .bottom, .top], 12)
        }
        .frame(width: 760, height: 520)
        .background(LiquidGlassBackground())
    }
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        let trimmedTitle = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 4) {
            if !trimmedTitle.isEmpty {
                Text(trimmedTitle)
                    .font(.headline)
                    .lineLimit(1)
            }
            Text(note.body.isEmpty ? " " : note.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct NoteEditorView: View {
    let note: Note
    let onChange: (String, String) -> Void
    let onDelete: () -> Void

    @State private var title: String
    @State private var noteContent: String

    init(note: Note, onChange: @escaping (String, String) -> Void, onDelete: @escaping () -> Void) {
        self.note = note
        self.onChange = onChange
        self.onDelete = onDelete
        _title = State(initialValue: note.title)
        _noteContent = State(initialValue: note.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Note")
                    .font(.title3.bold())
                Spacer()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

            TextField("Title (optional)", text: $title)
                .font(.title3.weight(.semibold))
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            TextEditor(text: $noteContent)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                )

            HStack {
                Text("Created \(note.createdAt.formatted(date: .abbreviated, time: .shortened))")
                Spacer()
                Text("Updated \(note.updatedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .glassPanel()
        .onChange(of: title) { _ in
            onChange(title, noteContent)
        }
        .onChange(of: noteContent) { _ in
            onChange(title, noteContent)
        }
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "note.text.badge.plus")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            Text("No note selected")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Create or select a note from the sidebar.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel()
    }
}

struct LiquidGlassBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.12, blue: 0.20),
                    Color(red: 0.09, green: 0.20, blue: 0.31),
                    Color(red: 0.15, green: 0.26, blue: 0.35)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color(red: 0.45, green: 0.74, blue: 0.97).opacity(0.48))
                .frame(width: 330, height: 330)
                .blur(radius: 55)
                .offset(x: -180, y: -160)

            Circle()
                .fill(Color(red: 0.56, green: 0.93, blue: 0.84).opacity(0.34))
                .frame(width: 290, height: 290)
                .blur(radius: 62)
                .offset(x: 210, y: 190)

            Rectangle()
                .fill(.ultraThinMaterial.opacity(0.25))
        }
    }
}

extension View {
    func glassPanel() -> some View {
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.55), .white.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.24), radius: 22, x: 0, y: 14)
    }
}
