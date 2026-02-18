import AppKit
import SwiftUI

@main
struct MacNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = NotesStore()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configurePopover()
        configureStatusItem()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 900, height: 560)
        popover.contentViewController = NSHostingController(rootView: NotesRootView(store: store))
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "MacNotes")
        button.image?.isTemplate = true
        button.toolTip = "MacNotes"
        button.target = self
        button.action = #selector(handleStatusItemClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleStatusItemClick() {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }

        switch event.type {
        case .rightMouseUp:
            showContextMenu()
        default:
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        showPopover()
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let openTitle = popover.isShown ? "Hide Notes" : "Show Notes"
        let toggleItem = NSMenuItem(title: openTitle, action: #selector(toggleNotesWindow), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let newNoteItem = NSMenuItem(title: "New Note", action: #selector(createNoteFromMenu), keyEquivalent: "n")
        newNoteItem.target = self
        menu.addItem(newNoteItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit MacNotes", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func toggleNotesWindow() {
        togglePopover()
    }

    @objc private func createNoteFromMenu() {
        store.addNote(inFolder: nil)
        showPopover()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

struct Note: Identifiable, Codable, Equatable {
    let id: UUID
    var folder: String
    var body: String
    var richTextRTFBase64: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        folder: String = "General",
        body: String = "",
        richTextRTFBase64: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.folder = folder
        self.body = body
        self.richTextRTFBase64 = richTextRTFBase64
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var titleLine: String {
        let first = body.components(separatedBy: .newlines).first ?? ""
        return first.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum NoteFileCodec {
    private static let separator = "\n---\n"
    private static let formatMarker = "MACNOTES_V2"
    private static let defaultFolderName = "General"

    struct DecodedNotePayload {
        let folder: String
        let body: String
        let richTextRTFBase64: String?
    }

    static func encode(note: Note) -> String {
        let serializedRichText = note.richTextRTFBase64 ?? ""
        let header = [
            formatMarker,
            "folder:\(note.folder)",
            "rtf:\(serializedRichText)"
        ].joined(separator: "\n")
        return header + separator + note.body
    }

    static func decode(text: String) -> DecodedNotePayload {
        let chunks = text.components(separatedBy: separator)
        guard chunks.count >= 2 else {
            return DecodedNotePayload(folder: defaultFolderName, body: text, richTextRTFBase64: nil)
        }

        if chunks[0].hasPrefix(formatMarker) {
            let lines = chunks[0].split(separator: "\n")
            let folderLine = lines.first(where: { $0.hasPrefix("folder:") })
            let rtfLine = lines.first(where: { $0.hasPrefix("rtf:") })
            let rawFolder = folderLine.map { String($0.dropFirst("folder:".count)) } ?? defaultFolderName
            let rawRTF = rtfLine.map { String($0.dropFirst("rtf:".count)) }
            let rtfValue = (rawRTF?.isEmpty ?? true) ? nil : rawRTF
            let folderValue = rawFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? defaultFolderName
                : rawFolder
            return DecodedNotePayload(
                folder: folderValue,
                body: chunks.dropFirst().joined(separator: separator),
                richTextRTFBase64: rtfValue
            )
        }

        let headerLines = chunks[0].split(separator: "\n")
        let isLegacyHeader = headerLines.contains(where: { $0.hasPrefix("title:") }) ||
            headerLines.contains(where: { $0.hasPrefix("createdAt:") }) ||
            headerLines.contains(where: { $0.hasPrefix("updatedAt:") })

        if isLegacyHeader {
            return DecodedNotePayload(
                folder: defaultFolderName,
                body: chunks.dropFirst().joined(separator: separator),
                richTextRTFBase64: nil
            )
        }
        return DecodedNotePayload(folder: defaultFolderName, body: text, richTextRTFBase64: nil)
    }
}

@MainActor
final class NotesStore: ObservableObject {
    @Published var notes: [Note] = []
    @Published var folders: [String] = [NotesStore.defaultFolderName]
    @Published var selectedNoteID: Note.ID?

    private let notesDirectoryURL: URL
    private let foldersFileURL: URL
    private var saveTask: Task<Void, Never>?
    private static let defaultFolderName = "General"

    init() {
        self.notesDirectoryURL = NotesStore.makeStorageURL()
        self.foldersFileURL = notesDirectoryURL.appendingPathComponent("_folders.meta")

        load()

        if notes.isEmpty {
            let starter = Note(
                folder: NotesStore.defaultFolderName,
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

    func addNote(inFolder folder: String?) {
        let targetFolder = normalizeFolderName(folder)
        let note = Note(folder: targetFolder, body: "")
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        ensureFolderExists(targetFolder)
        scheduleSave()
    }

    func deleteNote(id: Note.ID) {
        notes.removeAll(where: { $0.id == id })

        if selectedNoteID == id {
            selectedNoteID = notes.sorted(by: { $0.updatedAt > $1.updatedAt }).first?.id
        }
        scheduleSave()
    }

    func updateNote(id: Note.ID, body: String, richTextRTFBase64: String?) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let existing = notes[index]

        guard existing.body != body || existing.richTextRTFBase64 != richTextRTFBase64 else { return }

        notes[index].body = body
        notes[index].richTextRTFBase64 = richTextRTFBase64
        notes[index].updatedAt = Date()
        scheduleSave()
    }

    func moveNote(id: Note.ID, toFolder folder: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let normalized = normalizeFolderName(folder)
        guard notes[index].folder != normalized else { return }
        notes[index].folder = normalized
        notes[index].updatedAt = Date()
        ensureFolderExists(normalized)
        scheduleSave()
    }

    @discardableResult
    func addFolder(name: String) -> String? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        ensureFolderExists(normalized)
        scheduleSave()
        return normalized
    }

    func sortedNotes(matching query: String, inFolder folder: String?) -> [Note] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderFiltered: [Note]
        if let folder, !folder.isEmpty {
            folderFiltered = notes.filter { $0.folder == folder }
        } else {
            folderFiltered = notes
        }

        let filtered = trimmed.isEmpty
            ? folderFiltered
            : folderFiltered.filter { note in
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
            self?.saveNow()
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

            let foldersText = folders.joined(separator: "\n")
            try foldersText.write(to: foldersFileURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Failed to save notes: %@", error.localizedDescription)
        }
    }

    private func load() {
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: notesDirectoryURL, withIntermediateDirectories: true)
            loadFolders(fileManager: fileManager)
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
                let decodedPayload = NoteFileCodec.decode(text: text)
                let note = Note(
                    id: id,
                    folder: normalizeFolderName(decodedPayload.folder),
                    body: decodedPayload.body,
                    richTextRTFBase64: decodedPayload.richTextRTFBase64,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
                loaded.append(note)
            }
            notes = loaded
            mergeFoldersFromNotes()
        } catch {
            notes = []
            folders = [Self.defaultFolderName]
        }
    }

    private func loadFolders(fileManager: FileManager) {
        guard fileManager.fileExists(atPath: foldersFileURL.path) else {
            folders = [Self.defaultFolderName]
            return
        }

        do {
            let raw = try String(contentsOf: foldersFileURL, encoding: .utf8)
            let loaded = raw
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            folders = loaded.isEmpty ? [Self.defaultFolderName] : loaded
            ensureFolderExists(Self.defaultFolderName)
        } catch {
            folders = [Self.defaultFolderName]
        }
    }

    private func mergeFoldersFromNotes() {
        for note in notes {
            ensureFolderExists(note.folder)
        }
    }

    private func normalizeFolderName(_ folder: String?) -> String {
        let trimmed = folder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? Self.defaultFolderName : trimmed
    }

    private func ensureFolderExists(_ folder: String) {
        if !folders.contains(folder) {
            folders.append(folder)
            folders.sort { lhs, rhs in
                if lhs == Self.defaultFolderName { return true }
                if rhs == Self.defaultFolderName { return false }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
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
    @AppStorage("sidebarWidth") private var sidebarWidth = 320.0
    @State private var query = ""
    @State private var selectedFolder = "All Notes"
    @State private var pendingDeleteNoteID: Note.ID?
    @State private var folderCreationTargetNoteID: Note.ID?
    @State private var isPresentingCreateFolderSheet = false
    @State private var sidebarResizeStartWidth = 320.0
    @State private var isResizingSidebar = false
    private let allFoldersLabel = "All Notes"
    private let minSidebarWidth = 250.0
    private let maxSidebarWidth = 560.0

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

    private func confirmDelete() {
        if let pendingDeleteNoteID {
            store.deleteNote(id: pendingDeleteNoteID)
        }
        pendingDeleteNoteID = nil
    }

    private func cancelDelete() {
        pendingDeleteNoteID = nil
    }

    private func openCreateFolder(targetNoteID: Note.ID?) {
        folderCreationTargetNoteID = targetNoteID
        isPresentingCreateFolderSheet = true
    }

    private func cancelCreateFolder() {
        isPresentingCreateFolderSheet = false
        folderCreationTargetNoteID = nil
    }

    private func createFolder(name: String) {
        if let createdFolder = store.addFolder(name: name) {
            if let folderCreationTargetNoteID {
                store.moveNote(id: folderCreationTargetNoteID, toFolder: createdFolder)
            } else {
                selectedFolder = createdFolder
            }
        }
        cancelCreateFolder()
    }

    private var activeFolderFilter: String? {
        selectedFolder == allFoldersLabel ? nil : selectedFolder
    }

    private func startResizeIfNeeded() {
        if !isResizingSidebar {
            isResizingSidebar = true
            sidebarResizeStartWidth = sidebarWidth
        }
    }

    private func applyResize(translation: CGFloat) {
        let proposed = sidebarResizeStartWidth + Double(translation)
        sidebarWidth = min(max(proposed, minSidebarWidth), maxSidebarWidth)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                FolderPickerBar(
                    selectedFolder: $selectedFolder,
                    allFoldersLabel: allFoldersLabel,
                    folders: store.folders,
                    onCreateFolder: {
                        openCreateFolder(targetNoteID: nil)
                    }
                )

                SidebarSearchBar(text: $query)

                Button {
                    store.addNote(inFolder: activeFolderFilter)
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
                    ForEach(store.sortedNotes(matching: query, inFolder: activeFolderFilter)) { note in
                        NoteRow(note: note)
                            .tag(note.id)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Menu("Move to Folder") {
                                    ForEach(store.folders, id: \.self) { folder in
                                        Button(folder) {
                                            store.moveNote(id: note.id, toFolder: folder)
                                        }
                                    }
                                }
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
            .frame(width: CGFloat(sidebarWidth))
            .padding(14)
            .glassPanel()
            .padding([.leading, .bottom, .top], 12)

            SidebarResizeHandle(isResizing: isResizingSidebar)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            startResizeIfNeeded()
                            applyResize(translation: value.translation.width)
                        }
                        .onEnded { _ in
                            isResizingSidebar = false
                        }
                )

            Group {
                if let note = store.selectedNote {
                    NoteEditorView(note: note) { body, richTextRTFBase64 in
                        store.updateNote(id: note.id, body: body, richTextRTFBase64: richTextRTFBase64)
                    } onMoveToFolder: { folder in
                        store.moveNote(id: note.id, toFolder: folder)
                    } onRequestCreateFolder: {
                        openCreateFolder(targetNoteID: note.id)
                    } onDelete: {
                        pendingDeleteNoteID = note.id
                    }
                    .environmentObject(store)
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
        .overlay {
            if pendingDeleteNoteID != nil {
                DeleteConfirmationOverlay(
                    message: "Are you sure you want to delete \(pendingDeleteNoteLabel)? This action cannot be undone.",
                    onDelete: confirmDelete,
                    onCancel: cancelDelete
                )
                .transition(.opacity)
                .zIndex(2)
            }
            if isPresentingCreateFolderSheet {
                CreateFolderOverlay(
                    onCreate: createFolder,
                    onCancel: cancelCreateFolder
                )
                .transition(.opacity)
                .zIndex(3)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: pendingDeleteNoteID != nil)
        .animation(.easeInOut(duration: 0.12), value: isPresentingCreateFolderSheet)
        .onChange(of: store.folders) { _ in
            if selectedFolder != allFoldersLabel && !store.folders.contains(selectedFolder) {
                selectedFolder = allFoldersLabel
            }
        }
    }
}

struct DeleteConfirmationOverlay: View {
    let message: String
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                Text("Delete note?")
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Spacer()
                    Button("Cancel") {
                        onCancel()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Delete") {
                        onDelete()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .frame(width: 400)
            .background(
                VisualEffectBlurView(material: .popover, blendingMode: .withinWindow)
                    .opacity(0.94)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.20), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 22, x: 0, y: 8)
        }
    }
}

struct FolderPickerBar: View {
    @Binding var selectedFolder: String
    let allFoldersLabel: String
    let folders: [String]
    let onCreateFolder: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button(allFoldersLabel) {
                    selectedFolder = allFoldersLabel
                }
                Divider()
                ForEach(folders, id: \.self) { folder in
                    Button {
                        selectedFolder = folder
                    } label: {
                        if selectedFolder == folder {
                            Label(folder, systemImage: "checkmark")
                        } else {
                            Text(folder)
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                    Text(selectedFolder)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)

            Button {
                onCreateFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .help("Create folder")
        }
    }
}

struct SidebarResizeHandle: View {
    let isResizing: Bool

    var body: some View {
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isResizing ? .white.opacity(0.42) : .white.opacity(0.18))
                .frame(width: 3)
                .padding(.vertical, 18)
        }
        .frame(width: 10)
        .contentShape(Rectangle())
    }
}

struct CreateFolderOverlay: View {
    @State private var folderName = ""
    let onCreate: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                Text("New Folder")
                    .font(.title3.weight(.semibold))

                TextField("Folder name", text: $folderName)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Spacer()
                    Button("Cancel") {
                        onCancel()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Create") {
                        onCreate(folderName)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(18)
            .frame(width: 360)
            .background(
                VisualEffectBlurView(material: .popover, blendingMode: .withinWindow)
                    .opacity(0.94)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.20), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 22, x: 0, y: 8)
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
    @EnvironmentObject private var store: NotesStore
    let note: Note
    let onChange: (String, String?) -> Void
    let onMoveToFolder: (String) -> Void
    let onRequestCreateFolder: () -> Void
    let onDelete: () -> Void

    @State private var noteContent: String
    @State private var richTextRTFBase64: String?
    @State private var hasSelection = false
    @State private var boldTrigger = 0
    @State private var underlineTrigger = 0
    @State private var increaseFontTrigger = 0
    @State private var decreaseFontTrigger = 0

    init(
        note: Note,
        onChange: @escaping (String, String?) -> Void,
        onMoveToFolder: @escaping (String) -> Void,
        onRequestCreateFolder: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.note = note
        self.onChange = onChange
        self.onMoveToFolder = onMoveToFolder
        self.onRequestCreateFolder = onRequestCreateFolder
        self.onDelete = onDelete
        _noteContent = State(initialValue: note.body)
        _richTextRTFBase64 = State(initialValue: note.richTextRTFBase64)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
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

                Menu {
                    ForEach(store.folders, id: \.self) { folder in
                        Button {
                            onMoveToFolder(folder)
                        } label: {
                            if folder == note.folder {
                                Label(folder, systemImage: "checkmark")
                            } else {
                                Text(folder)
                            }
                        }
                    }
                    Divider()
                    Button("New Folder...") {
                        onRequestCreateFolder()
                    }
                } label: {
                    Label(note.folder, systemImage: "folder")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

            RichTextEditor(
                text: $noteContent,
                richTextRTFBase64: $richTextRTFBase64,
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
            onChange(noteContent, richTextRTFBase64)
        }
        .onChange(of: richTextRTFBase64) { _ in
            onChange(noteContent, richTextRTFBase64)
        }
    }
}

@MainActor
struct RichTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var richTextRTFBase64: String?
    @Binding var hasSelection: Bool
    let boldTrigger: Int
    let underlineTrigger: Int
    let increaseFontTrigger: Int
    let decreaseFontTrigger: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ShortcutTextView(frame: .zero)
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

        if let serializedRTF = richTextRTFBase64,
           let rtfData = Data(base64Encoded: serializedRTF),
           let attributed = try? NSAttributedString(
               data: rtfData,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ) {
            textView.textStorage?.setAttributedString(attributed)
            text = textView.string
        }

        context.coordinator.syncSelectionState()
        context.coordinator.publishState()
        textView.onToggleBold = { [weak coordinator = context.coordinator] in
            coordinator?.toggleBoldForSelection()
        }
        textView.onToggleUnderline = { [weak coordinator = context.coordinator] in
            coordinator?.toggleUnderlineForSelection()
        }
        textView.onIncreaseFont = { [weak coordinator = context.coordinator] in
            coordinator?.adjustFontSizeForSelection(delta: 1)
        }
        textView.onDecreaseFont = { [weak coordinator = context.coordinator] in
            coordinator?.adjustFontSizeForSelection(delta: -1)
        }

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
        if textView.string != text, textView.window?.firstResponder !== textView {
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

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        weak var textView: ShortcutTextView?
        private var lastBoldTrigger = 0
        private var lastUnderlineTrigger = 0
        private var lastIncreaseFontTrigger = 0
        private var lastDecreaseFontTrigger = 0

        init(parent: RichTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            publishState()
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

        func publishState() {
            guard let textView else { return }
            let plainText = textView.string
            let rtfBase64 = serializedRTF(from: textView.textStorage) ?? parent.richTextRTFBase64
            if parent.text != plainText {
                parent.text = plainText
            }
            if parent.richTextRTFBase64 != rtfBase64 {
                parent.richTextRTFBase64 = rtfBase64
            }
        }

        private func serializedRTF(from storage: NSTextStorage?) -> String? {
            guard let storage, storage.length > 0 else { return nil }
            let range = NSRange(location: 0, length: storage.length)
            guard let data = try? storage.data(
                from: range,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            ) else {
                return nil
            }
            return data.base64EncodedString()
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

        func toggleBoldForSelection() {
            guard let textView else { return }
            guard
                let textStorage = textView.textStorage,
                let selectedRange = selectedRangeIfAny()
            else {
                toggleTypingBold(textView: textView)
                return
            }

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
            publishState()
        }

        func toggleUnderlineForSelection() {
            guard let textView else { return }
            guard
                let textStorage = textView.textStorage,
                let selectedRange = selectedRangeIfAny()
            else {
                toggleTypingUnderline(textView: textView)
                return
            }

            var allUnderlined = true
            textStorage.enumerateAttribute(.underlineStyle, in: selectedRange, options: []) { value, _, _ in
                let styleValue = (value as? NSNumber)?.intValue ?? (value as? Int) ?? 0
                if styleValue == 0 {
                    allUnderlined = false
                }
            }

            let targetStyle = allUnderlined ? 0 : NSUnderlineStyle.single.rawValue
            textStorage.addAttribute(.underlineStyle, value: targetStyle, range: selectedRange)
            publishState()
        }

        func adjustFontSizeForSelection(delta: CGFloat) {
            guard let textView else { return }
            guard
                let textStorage = textView.textStorage,
                let selectedRange = selectedRangeIfAny()
            else {
                adjustTypingFontSize(textView: textView, delta: delta)
                return
            }

            textStorage.beginEditing()
            textStorage.enumerateAttribute(.font, in: selectedRange, options: []) { value, range, _ in
                let currentFont = (value as? NSFont) ?? NSFont.systemFont(ofSize: 16)
                let nextSize = min(40, max(10, currentFont.pointSize + delta))
                let resized = NSFontManager.shared.convert(currentFont, toSize: nextSize)
                textStorage.addAttribute(.font, value: resized, range: range)
                textStorage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
            textStorage.endEditing()
            publishState()
        }

        private func toggleTypingBold(textView: NSTextView) {
            var attrs = textView.typingAttributes
            let currentFont = (attrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 16)
            let isBold = NSFontManager.shared.traits(of: currentFont).contains(.boldFontMask)
            let converted = isBold
                ? NSFontManager.shared.convert(currentFont, toNotHaveTrait: .boldFontMask)
                : NSFontManager.shared.convert(currentFont, toHaveTrait: .boldFontMask)
            let resized = NSFontManager.shared.convert(converted, toSize: currentFont.pointSize)
            attrs[.font] = resized
            attrs[.foregroundColor] = NSColor.labelColor
            textView.typingAttributes = attrs
        }

        private func toggleTypingUnderline(textView: NSTextView) {
            var attrs = textView.typingAttributes
            let currentStyle = (attrs[.underlineStyle] as? NSNumber)?.intValue ??
                (attrs[.underlineStyle] as? Int) ?? 0
            let nextStyle = currentStyle == 0 ? NSUnderlineStyle.single.rawValue : 0
            attrs[.underlineStyle] = nextStyle
            attrs[.foregroundColor] = NSColor.labelColor
            textView.typingAttributes = attrs
        }

        private func adjustTypingFontSize(textView: NSTextView, delta: CGFloat) {
            var attrs = textView.typingAttributes
            let currentFont = (attrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 16)
            let nextSize = min(40, max(10, currentFont.pointSize + delta))
            let resized = NSFontManager.shared.convert(currentFont, toSize: nextSize)
            attrs[.font] = resized
            attrs[.foregroundColor] = NSColor.labelColor
            textView.typingAttributes = attrs
        }
    }
}

final class ShortcutTextView: NSTextView {
    var onToggleBold: (() -> Void)?
    var onToggleUnderline: (() -> Void)?
    var onIncreaseFont: (() -> Void)?
    var onDecreaseFont: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .shift])
        let usesFormattingShortcut = flags.contains(.command) || flags.contains(.control)

        if usesFormattingShortcut, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "b":
                onToggleBold?()
                return
            case "u":
                onToggleUnderline?()
                return
            case "=", "+":
                onIncreaseFont?()
                return
            case "-", "_":
                onDecreaseFont?()
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
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
