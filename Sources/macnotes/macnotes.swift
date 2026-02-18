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
    var body: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        body: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var titleLine: String {
        let first = body.components(separatedBy: .newlines).first ?? ""
        return first.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum NoteFileCodec {
    static func encode(note: Note) -> String {
        note.body
    }

    static func decodeBody(text: String) -> String {
        let separator = "\n---\n"
        let chunks = text.components(separatedBy: separator)
        guard chunks.count >= 2 else { return text }

        let headerLines = chunks[0].split(separator: "\n")
        let isLegacyHeader = headerLines.contains(where: { $0.hasPrefix("title:") }) ||
            headerLines.contains(where: { $0.hasPrefix("createdAt:") }) ||
            headerLines.contains(where: { $0.hasPrefix("updatedAt:") })

        if isLegacyHeader {
            return chunks.dropFirst().joined(separator: separator)
        }
        return text
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
        let note = Note(body: "")
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

    func updateNote(id: Note.ID, body: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let existing = notes[index]

        guard existing.body != body else { return }

        notes[index].body = body
        notes[index].updatedAt = Date()
        scheduleSave()
    }

    func sortedNotes(matching query: String) -> [Note] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmed.isEmpty
            ? notes
            : notes.filter { note in
                note.titleLine.localizedCaseInsensitiveContains(trimmed) ||
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
                let note = Note(
                    id: id,
                    body: NoteFileCodec.decodeBody(text: text),
                    createdAt: createdAt,
                    updatedAt: updatedAt
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
    @State private var pendingDeleteNoteID: Note.ID?
    private let sidebarWidth: CGFloat = 320

    private var isShowingDeleteAlert: Binding<Bool> {
        Binding(
            get: { pendingDeleteNoteID != nil },
            set: { showing in
                if !showing {
                    pendingDeleteNoteID = nil
                }
            }
        )
    }

    private var pendingDeleteNoteLabel: String {
        guard
            let pendingDeleteNoteID,
            let note = store.notes.first(where: { $0.id == pendingDeleteNoteID })
        else {
            return "this note"
        }
        let title = note.titleLine
        return title.isEmpty ? "this note" : "\"\(title)\""
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                SidebarSearchBar(text: $query)

                Button {
                    store.addNote()
                } label: {
                    Label("New Note", systemImage: "plus.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.white.opacity(0.2))
                .foregroundStyle(.white)
                .help("New note")

                List(selection: $store.selectedNoteID) {
                    ForEach(store.sortedNotes(matching: query)) { note in
                        NoteRow(note: note)
                            .tag(note.id)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button(role: .destructive) {
                                    pendingDeleteNoteID = note.id
                                } label: {
                                    Label("Delete Note", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
            .frame(width: sidebarWidth)
            .padding(14)
            .glassPanel()
            .padding([.leading, .bottom, .top], 12)

            Group {
                if let note = store.selectedNote {
                    NoteEditorView(note: note) { body in
                        store.updateNote(id: note.id, body: body)
                    } onDelete: {
                        pendingDeleteNoteID = note.id
                    }
                    .id(note.id)
                } else {
                    EmptyStateView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding([.trailing, .bottom, .top], 12)
        }
        .frame(width: 900, height: 560)
        .background(LiquidGlassBackground())
        .alert("Delete note?", isPresented: isShowingDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let pendingDeleteNoteID {
                    store.deleteNote(id: pendingDeleteNoteID)
                }
                pendingDeleteNoteID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteNoteID = nil
            }
        } message: {
            Text("Are you sure you want to delete \(pendingDeleteNoteLabel)? This action cannot be undone.")
        }
    }
}

struct SidebarSearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))

            TextField("Search notes", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.65))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            VisualEffectBlurView(material: .menu, blendingMode: .behindWindow)
                .opacity(0.26)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
    }
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        Text(note.titleLine.isEmpty ? "New Note" : note.titleLine)
            .font(.headline)
            .foregroundStyle(note.titleLine.isEmpty ? .secondary : .primary)
            .lineLimit(1)
            .padding(.vertical, 8)
    }
}

struct NoteEditorView: View {
    let note: Note
    let onChange: (String) -> Void
    let onDelete: () -> Void

    @State private var noteContent: String
    @State private var hasSelection = false
    @State private var boldTrigger = 0
    @State private var underlineTrigger = 0
    @State private var increaseFontTrigger = 0
    @State private var decreaseFontTrigger = 0

    init(note: Note, onChange: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        self.note = note
        self.onChange = onChange
        self.onDelete = onDelete
        _noteContent = State(initialValue: note.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Formatting")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        boldTrigger += 1
                    } label: {
                        Image(systemName: "bold")
                    }
                    .help("Toggle bold on selected text")
                    .disabled(!hasSelection)

                    Button {
                        underlineTrigger += 1
                    } label: {
                        Image(systemName: "underline")
                    }
                    .help("Toggle underline on selected text")
                    .disabled(!hasSelection)

                    Button {
                        decreaseFontTrigger += 1
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                    }
                    .help("Decrease font size on selected text")
                    .disabled(!hasSelection)

                    Button {
                        increaseFontTrigger += 1
                    } label: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .help("Increase font size on selected text")
                    .disabled(!hasSelection)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

            Text("The first line of your note is used as the title.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(hasSelection ? "Formatting applies to selected text." : "Select text to apply bold, underline, or font-size changes.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            RichTextEditor(
                text: $noteContent,
                hasSelection: $hasSelection,
                boldTrigger: boldTrigger,
                underlineTrigger: underlineTrigger,
                increaseFontTrigger: increaseFontTrigger,
                decreaseFontTrigger: decreaseFontTrigger
            )
            .background(
                VisualEffectBlurView(material: .menu, blendingMode: .behindWindow)
                    .opacity(0.20)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
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
        .onChange(of: noteContent) { _ in
            onChange(noteContent)
        }
    }
}

struct RichTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var hasSelection: Bool
    let boldTrigger: Int
    let underlineTrigger: Int
    let increaseFontTrigger: Int
    let decreaseFontTrigger: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        let baseFont = NSFont.systemFont(ofSize: 16, weight: .regular)
        textView.typingAttributes = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor
        ]
        textView.insertionPointColor = .labelColor

        context.coordinator.textView = textView
        context.coordinator.syncSelectionState()

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.syncSelectionState()
        context.coordinator.handleTriggers(
            boldTrigger: boldTrigger,
            underlineTrigger: underlineTrigger,
            increaseFontTrigger: increaseFontTrigger,
            decreaseFontTrigger: decreaseFontTrigger
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        weak var textView: NSTextView?
        private var lastBoldTrigger = 0
        private var lastUnderlineTrigger = 0
        private var lastIncreaseFontTrigger = 0
        private var lastDecreaseFontTrigger = 0

        init(parent: RichTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            syncSelectionState()
        }

        func syncSelectionState() {
            guard let textView else { return }
            let hasSelection = textView.selectedRange().length > 0
            if parent.hasSelection != hasSelection {
                parent.hasSelection = hasSelection
            }
        }

        func handleTriggers(
            boldTrigger: Int,
            underlineTrigger: Int,
            increaseFontTrigger: Int,
            decreaseFontTrigger: Int
        ) {
            if boldTrigger != lastBoldTrigger {
                lastBoldTrigger = boldTrigger
                toggleBoldForSelection()
            }

            if underlineTrigger != lastUnderlineTrigger {
                lastUnderlineTrigger = underlineTrigger
                toggleUnderlineForSelection()
            }

            if increaseFontTrigger != lastIncreaseFontTrigger {
                lastIncreaseFontTrigger = increaseFontTrigger
                adjustFontSizeForSelection(delta: 1)
            }

            if decreaseFontTrigger != lastDecreaseFontTrigger {
                lastDecreaseFontTrigger = decreaseFontTrigger
                adjustFontSizeForSelection(delta: -1)
            }
        }

        private func selectedRangeIfAny() -> NSRange? {
            guard let textView else { return nil }
            let selectedRange = textView.selectedRange()
            return selectedRange.length > 0 ? selectedRange : nil
        }

        private func toggleBoldForSelection() {
            guard
                let textView,
                let textStorage = textView.textStorage,
                let selectedRange = selectedRangeIfAny()
            else { return }

            var allBold = true
            textStorage.enumerateAttribute(.font, in: selectedRange, options: []) { value, _, _ in
                let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: 16)
                if !NSFontManager.shared.traits(of: font).contains(.boldFontMask) {
                    allBold = false
                }
            }

            textStorage.beginEditing()
            textStorage.enumerateAttribute(.font, in: selectedRange, options: []) { value, range, _ in
                let currentFont = (value as? NSFont) ?? NSFont.systemFont(ofSize: 16)
                let converted = allBold
                    ? NSFontManager.shared.convert(currentFont, toNotHaveTrait: .boldFontMask)
                    : NSFontManager.shared.convert(currentFont, toHaveTrait: .boldFontMask)
                let resized = NSFontManager.shared.convert(converted, toSize: currentFont.pointSize)
                textStorage.addAttribute(.font, value: resized, range: range)
                textStorage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
            textStorage.endEditing()
        }

        private func toggleUnderlineForSelection() {
            guard
                let textView,
                let textStorage = textView.textStorage,
                let selectedRange = selectedRangeIfAny()
            else { return }

            var allUnderlined = true
            textStorage.enumerateAttribute(.underlineStyle, in: selectedRange, options: []) { value, _, _ in
                let styleValue = (value as? NSNumber)?.intValue ?? (value as? Int) ?? 0
                if styleValue == 0 {
                    allUnderlined = false
                }
            }

            let targetStyle = allUnderlined ? 0 : NSUnderlineStyle.single.rawValue
            textStorage.addAttribute(.underlineStyle, value: targetStyle, range: selectedRange)
        }

        private func adjustFontSizeForSelection(delta: CGFloat) {
            guard
                let textView,
                let textStorage = textView.textStorage,
                let selectedRange = selectedRangeIfAny()
            else { return }

            textStorage.beginEditing()
            textStorage.enumerateAttribute(.font, in: selectedRange, options: []) { value, range, _ in
                let currentFont = (value as? NSFont) ?? NSFont.systemFont(ofSize: 16)
                let nextSize = min(40, max(10, currentFont.pointSize + delta))
                let resized = NSFontManager.shared.convert(currentFont, toSize: nextSize)
                textStorage.addAttribute(.font, value: resized, range: range)
                textStorage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
            textStorage.endEditing()
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

struct VisualEffectBlurView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.material = material
        view.blendingMode = blendingMode
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct LiquidGlassBackground: View {
    var body: some View {
        ZStack {
            VisualEffectBlurView(material: .hudWindow, blendingMode: .behindWindow)
                .opacity(0.32)

            LinearGradient(
                colors: [
                    Color.white.opacity(0.08),
                    Color.white.opacity(0.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color(red: 0.45, green: 0.74, blue: 0.97).opacity(0.08))
                .frame(width: 420, height: 420)
                .blur(radius: 75)
                .offset(x: -210, y: -190)

            Circle()
                .fill(Color(red: 0.56, green: 0.93, blue: 0.84).opacity(0.07))
                .frame(width: 360, height: 360)
                .blur(radius: 70)
                .offset(x: 230, y: 210)
        }
    }
}

extension View {
    func glassPanel() -> some View {
        self
            .background(
                VisualEffectBlurView(material: .hudWindow, blendingMode: .behindWindow)
                    .opacity(0.24)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.20), .white.opacity(0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 3)
    }
}
