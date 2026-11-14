import PrivateNotesStore
import SwiftUI

/// The three panels: folders, note list, editor.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var folderSelection: FolderSelection? = .allNotes
    @State private var noteSelection: UUID?
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            FolderListView(selection: $folderSelection)
        } content: {
            NoteListView(
                folder: folderSelection ?? .allNotes,
                selection: $noteSelection,
                searchText: $searchText
            )
        } detail: {
            if let id = noteSelection, model.note(id) != nil {
                NoteEditorView(noteID: id)
                    .id(id)
            } else {
                ContentUnavailableView("No Note Selected", systemImage: "note.text")
            }
        }
        .onChange(of: folderSelection) { _, newValue in
            // A deleted folder leaves nothing selected; fall back to All Notes.
            if case .folder(let id)? = newValue, !model.folders.contains(where: { $0.id == id }) {
                folderSelection = .allNotes
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct FolderListView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: FolderSelection?

    @State private var showingNewFolder = false
    @State private var folderBeingRenamed: Folder?
    @State private var folderBeingDeleted: Folder?
    @State private var nameField = ""

    var body: some View {
        List(selection: $selection) {
            Label("All Notes", systemImage: "tray.full")
                .tag(FolderSelection.allNotes)

            Section("Folders") {
                ForEach(model.sortedFolders) { folder in
                    Label(folder.name, systemImage: "folder")
                        .tag(FolderSelection.folder(folder.id))
                        .contextMenu {
                            Button("Rename…") {
                                nameField = folder.name
                                folderBeingRenamed = folder
                            }
                            Button("Delete…", role: .destructive) {
                                folderBeingDeleted = folder
                            }
                        }
                }
            }

            if model.unreadableCount > 0 {
                Section {
                    Label(
                        "\(model.unreadableCount) item(s) in the vault couldn't be opened",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Folders")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        #endif
        .toolbar {
            ToolbarItem {
                Button {
                    nameField = ""
                    showingNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            }
            ToolbarItem {
                Button {
                    model.lock()
                } label: {
                    Label("Lock", systemImage: "lock")
                }
                .help("Lock Private Notes")
            }
        }
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Name", text: $nameField)
            Button("Create") {
                if let id = model.addFolder(named: nameField) {
                    selection = .folder(id)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Rename Folder",
            isPresented: Binding(
                get: { folderBeingRenamed != nil },
                set: { if !$0 { folderBeingRenamed = nil } }
            ),
            presenting: folderBeingRenamed
        ) { folder in
            TextField("Name", text: $nameField)
            Button("Rename") {
                model.renameFolder(folder.id, to: nameField)
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete this folder?",
            isPresented: Binding(
                get: { folderBeingDeleted != nil },
                set: { if !$0 { folderBeingDeleted = nil } }
            ),
            titleVisibility: .visible,
            presenting: folderBeingDeleted
        ) { folder in
            Button("Delete Folder", role: .destructive) {
                if selection == .folder(folder.id) {
                    selection = .allNotes
                }
                model.deleteFolder(folder.id)
            }
        } message: { folder in
            Text("“\(folder.name)” will be removed. Its notes are kept and stay under All Notes.")
        }
    }
}

struct NoteListView: View {
    @Environment(AppModel.self) private var model
    let folder: FolderSelection
    @Binding var selection: UUID?
    @Binding var searchText: String

    @State private var noteBeingDeleted: Note?

    private var visibleNotes: [Note] {
        model.notes(in: folder, matching: searchText)
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(visibleNotes) { note in
                NoteRow(note: note)
                    .tag(note.id)
                    .contextMenu {
                        Button(note.isPinned ? "Unpin" : "Pin") {
                            model.togglePinned(note.id)
                        }
                        Menu("Move to") {
                            Button("No Folder") {
                                model.moveNote(note.id, toFolder: nil)
                            }
                            .disabled(note.folderID == nil)
                            ForEach(model.sortedFolders) { destination in
                                Button(destination.name) {
                                    model.moveNote(note.id, toFolder: destination.id)
                                }
                                .disabled(note.folderID == destination.id)
                            }
                        }
                        Button("Delete…", role: .destructive) {
                            noteBeingDeleted = note
                        }
                    }
            }
        }
        .overlay {
            if visibleNotes.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView("No Notes", systemImage: "note.text")
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .searchable(text: $searchText)
        .navigationTitle(model.folderName(folder))
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    searchText = ""
                    selection = model.addNote(in: folder)
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
            }
        }
        .confirmationDialog(
            "Delete this note?",
            isPresented: Binding(
                get: { noteBeingDeleted != nil },
                set: { if !$0 { noteBeingDeleted = nil } }
            ),
            titleVisibility: .visible,
            presenting: noteBeingDeleted
        ) { note in
            Button("Delete Note", role: .destructive) {
                if selection == note.id {
                    selection = nil
                }
                model.deleteNote(note.id)
            }
        } message: { _ in
            Text("This can't be undone.")
        }
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(note.title.isEmpty ? "New Note" : note.title)
                    .font(.headline)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(note.modifiedAt, format: .dateTime.month(.abbreviated).day().year())
                Text(note.preview.isEmpty ? "No additional text" : note.preview)
                    .lineLimit(1)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Plain-text editor for one note. Rich text and images come later.
struct NoteEditorView: View {
    @Environment(AppModel.self) private var model
    let noteID: UUID
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .onAppear {
                text = model.note(noteID)?.body ?? ""
                loaded = true
            }
            .onChange(of: text) { _, newValue in
                if loaded {
                    model.updateBody(noteID, newValue)
                }
            }
            .onDisappear {
                model.flushPendingSaves()
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }
}
