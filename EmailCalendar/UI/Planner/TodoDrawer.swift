#if os(macOS)
import SwiftUI

/// A quiet to-do list. Drop mail on a to-do to link it, or on the add field to make a new to-do from it.
struct TodoDrawer: View {
    @Environment(AppStore.self) private var store
    @State private var newTitle = ""
    @FocusState private var fieldFocused: Bool
    @State private var addTarget = false
    @AppStorage("todo.showsDone") private var showsDone = false
    @State private var flashing: String?

    var body: some View {
        let open = store.planner.openTodos, done = store.planner.doneTodos
        VStack(alignment: .leading, spacing: 0) {
            DrawerHeader(title: "To-do") {
                if !open.isEmpty { Text("\(open.count)").monospacedDigit() }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        addField.padding(.bottom, 10)
                        if open.isEmpty {
                            Text("Nothing left to do.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                        }
                        ForEach(open) { todo in
                            TodoRow(todo: todo, isFlashing: flashing == todo.id).id(todo.id)
                        }
                        if !done.isEmpty {
                            Button { withAnimation(.easeOut(duration: 0.18)) { showsDone.toggle() } } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                                        .rotationEffect(.degrees(showsDone ? 90 : 0))
                                    Text("COMPLETED \(done.count)")
                                }
                                .font(.system(size: 11.5, weight: .bold)).foregroundStyle(Theme.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).padding(.top, 14)
                            .accessibilityLabel(showsDone ? "Hide completed to-dos" : "Show completed to-dos")
                            if showsDone {
                                ForEach(done) { todo in TodoRow(todo: todo, isFlashing: flashing == todo.id).id(todo.id) }
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 28)
                }
                .scrollIndicators(.never)
                .onChange(of: store.plannerReveal) { _, reveal in
                    guard let reveal, case .todo(let id) = reveal.target else { return }
                    if done.contains(where: { $0.id == id }) { showsDone = true }
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    flashing = id
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        if flashing == id { withAnimation(.easeOut(duration: 0.4)) { flashing = nil } }
                    }
                }
            }
        }
        .onChange(of: store.todoFieldRequest) { _, request in if request != nil { fieldFocused = true } }
    }

    private var addField: some View {
        HStack(spacing: 9) {
            Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
            TextField("Add a to-do", text: $newTitle)
                .textFieldStyle(.plain).font(.system(size: 14))
                .focused($fieldFocused)
                .onSubmit(add)
                .onKeyPress(.escape) { newTitle = ""; fieldFocused = false; return .handled }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(addTarget ? Theme.accent.opacity(0.18) : Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(fieldFocused || addTarget ? Theme.accent : Theme.line, lineWidth: fieldFocused || addTarget ? 1.5 : 1)
        }
        .threadDropTarget(isTargeted: $addTarget) { ids in Task { await store.addTodos(fromThreadIDs: ids) } }
        .help("Type a to-do, or drop an email here to make one from it")
    }

    private func add() {
        let title = newTitle
        newTitle = ""
        Task { await store.addTodo(title: title) }
        fieldFocused = true
    }
}

/// Check circle, title, note and linked mail. Note and delete appear on hover; double-click renames.
private struct TodoRow: View {
    @Environment(AppStore.self) private var store
    let todo: TodoItem
    let isFlashing: Bool
    @State private var hovering = false
    @State private var dropTarget = false
    @State private var renaming = false
    @State private var editingNote = false
    @State private var titleDraft = ""
    @State private var noteDraft = ""
    @FocusState private var focus: Field?
    private enum Field { case title, note }

    private var links: [MailLink] { store.links(to: .todo(todo.id)) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { Task { await store.setDone(todo, !todo.isDone) } } label: {
                ZStack {
                    Circle().strokeBorder(todo.isDone ? Theme.yes : Theme.secondary.opacity(0.7), lineWidth: 1.5)
                    if todo.isDone {
                        Circle().fill(Theme.yes)
                        Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.white)
                    }
                }
                .frame(width: 18, height: 18).contentShape(Circle())
            }
            .buttonStyle(.plain).padding(.top, 1)
            .accessibilityLabel(todo.isDone ? "Mark not done" : "Mark done")

            VStack(alignment: .leading, spacing: 5) {
                if renaming {
                    TextField("To-do", text: $titleDraft).textFieldStyle(.plain).focused($focus, equals: .title)
                        .onSubmit(commitTitle)
                        .onKeyPress(.escape) { renaming = false; return .handled }
                } else {
                    Text(todo.title)
                        .foregroundStyle(todo.isDone ? Theme.secondary : Theme.text)
                        .strikethrough(todo.isDone, color: Theme.secondary.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if editingNote {
                    TextField("Note", text: $noteDraft, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 12.5)).lineLimit(1...6)
                        .focused($focus, equals: .note)
                        .onSubmit(commitNote)
                        .onKeyPress(.escape) { editingNote = false; return .handled }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(Theme.unread.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                } else if !todo.note.isEmpty {
                    Label { Text(todo.note) } icon: { Image(systemName: "note.text").font(.system(size: 10.5)) }
                        .font(.system(size: 12.5)).foregroundStyle(noteColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture(count: 2, perform: beginNote)
                }
                if !links.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(links) { link in MailChip(link: link) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                iconButton(todo.note.isEmpty ? "note.text.badge.plus" : "note.text", help: todo.note.isEmpty ? "Add note" : "Edit note", action: beginNote)
                iconButton("trash", help: "Delete") { Task { await store.deleteTodo(todo) } }
            }
            .opacity(hovering || editingNote ? 1 : 0)
            .padding(.top, -3)
        }
        .font(.system(size: 14))
        .padding(.vertical, 8).padding(.leading, 10).padding(.trailing, 6)
        .background(background, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if store.linkingThreadID != nil || dropTarget || isFlashing {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: dropTarget || isFlashing ? [] : [4, 3]))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: beginRename)
        .onTapGesture { store.completeLinking(to: .todo(todo.id)) }
        .onHover { hovering = $0 }
        .threadDropTarget(isTargeted: $dropTarget) { ids in
            Task { for id in ids { await store.link(threadID: id, to: .todo(todo.id)) } }
        }
        .onChange(of: focus) { old, new in
            if old == .note, new != .note, editingNote { commitNote() }
            if old == .title, new != .title, renaming { commitTitle() }
        }
        .contextMenu {
            Button("Rename", action: beginRename)
            Button(todo.note.isEmpty ? "Add Note" : "Edit Note", action: beginNote)
            Button(todo.isDone ? "Mark Not Done" : "Mark Done") { Task { await store.setDone(todo, !todo.isDone) } }
            Divider()
            Button("Delete", role: .destructive) { Task { await store.deleteTodo(todo) } }
        }
    }

    private var noteColor: Color { Theme.dynamic(light: 0x946000, dark: 0xF5C46A) }

    private var background: Color {
        if dropTarget { return Theme.accent.opacity(0.18) }
        return hovering ? Theme.hover : .clear
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(HoverIconStyle()).help(help).accessibilityLabel(help)
    }

    private func beginRename() {
        titleDraft = todo.title; renaming = true
        DispatchQueue.main.async { focus = .title }
    }

    private func beginNote() {
        noteDraft = todo.note; editingNote = true
        DispatchQueue.main.async { focus = .note }
    }

    private func commitTitle() {
        renaming = false
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != todo.title else { return }
        var changed = todo; changed.title = title
        Task { await store.updateTodo(changed) }
    }

    private func commitNote() {
        editingNote = false
        let note = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note != todo.note else { return }
        var changed = todo; changed.note = note
        Task { await store.updateTodo(changed) }
    }
}

/// A linked email under a to-do: the sender's avatar and name; opens the thread.
private struct MailChip: View {
    @Environment(AppStore.self) private var store
    let link: MailLink
    @State private var hovering = false
    @State private var opening = false

    var body: some View {
        let thread = store.thread(id: link.threadID)
        Button {
            opening = true
            Task { await store.openLinkedThread(id: link.threadID); opening = false }
        } label: {
            HStack(spacing: 6) {
                Avatar(name: link.senderName, key: link.senderEmail, size: 16)
                Text(link.senderName).lineLimit(1)
            }
            .font(.system(size: 12))
            .padding(.leading, 2).padding(.trailing, 9).padding(.vertical, 2)
            .foregroundStyle(hovering ? Theme.text : Theme.secondary)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().stroke(hovering ? Theme.secondary.opacity(0.6) : Theme.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).disabled(opening)
        .onHover { hovering = $0 }
        .help(thread?.subject ?? link.subject)
        .contextMenu { Button("Remove Link") { Task { await store.unlink(link) } } }
    }
}

private struct HoverIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverIconLabel(configuration: configuration) }
    private struct HoverIconLabel: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? Theme.text : Theme.secondary)
                .background(hovering ? Theme.line : .clear, in: RoundedRectangle(cornerRadius: 6))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hovering = $0 }
        }
    }
}
#endif
