#if os(macOS)
import SwiftUI

struct MailPaletteCommand: Identifiable {
    let id = UUID()
    var title: String
    var symbol: String
    var shortcut: String
    var perform: @MainActor () -> Void
}

struct MailCommandPalette: View {
    @Environment(\.dismiss) private var dismiss
    var commands: [MailPaletteCommand]
    var select: (MailPaletteCommand) -> Void
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool

    private var filtered: [MailPaletteCommand] {
        commands.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type an action…", text: $query).font(.title3).textFieldStyle(.plain).focused($focused)
                    .onSubmit { activateSelection() }
                    .onKeyPress(.downArrow) { selectedIndex = min(selectedIndex + 1, max(filtered.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selectedIndex = max(selectedIndex - 1, 0); return .handled }
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
            }.padding(18)
            Divider()
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, command in
                            Button { select(command); dismiss() } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: command.symbol).foregroundStyle(.secondary).frame(width: 20)
                                    Text(command.title)
                                    Spacer()
                                    Text(command.shortcut).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }.padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
                                    .background(index == selectedIndex ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain).id(index)
                        }
                        if filtered.isEmpty { Text("No matching actions").foregroundStyle(.secondary).padding(24) }
                    }.padding(8)
                }.onChange(of: selectedIndex) { _, index in reader.scrollTo(index) }
            }
            Divider()
            HStack {
                Text("↑↓ to choose · Return to run · Esc to close").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(12)
        }.frame(width: 560, height: 400)
            .onAppear { focused = true }
            .onChange(of: query) { _, _ in selectedIndex = 0 }
    }

    private func activateSelection() {
        guard filtered.indices.contains(selectedIndex) else { return }
        select(filtered[selectedIndex]); dismiss()
    }
}
#endif
