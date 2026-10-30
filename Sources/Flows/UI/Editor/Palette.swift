import SwiftUI

/// The blocks you can add: search first, then the few most people need, then
/// every category folded away, then the blocks you made.
///
/// Opening on a dozen blocks rather than seventy is the point. Everything is
/// a search away, and nothing has to be read past to find the common ones.
struct BlockPalette: View {
    @EnvironmentObject private var model: EditorModel
    @State private var query = ""
    @State private var open: Set<BlockCategory> = []
    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                TextField("Find a block", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.sans(12))
                    .focused($searching)
                    // Space, a few letters, Return: a block added without the mouse.
                    .onSubmit {
                        guard let first = definitions.first(where: matches) else { return }
                        model.add(first.id)
                        query = ""
                    }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .recessed(cornerRadius: 6)
            .padding(10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if query.isEmpty {
                        section("ESSENTIALS", definitions.filter(\.isEssential))
                        ForEach(categories, id: \.self) { category in
                            fold(category)
                        }
                    } else {
                        let found = definitions.filter(matches)
                        if found.isEmpty {
                            Text("Nothing called that").font(Theme.sans(11.5)).foregroundStyle(Theme.textMuted).padding(10)
                        }
                        ForEach(found) { PaletteRow(definition: $0) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 228)
        .background(Theme.machined)
        .onReceive(NotificationCenter.default.publisher(for: .flowEditorFindBlock)) { note in
            if note.object as? UUID == model.document.id { searching = true }
        }
    }

    /// Hats are hidden inside a packaged block, which has no trigger.
    private var definitions: [BlockDefinition] {
        let all = Catalog.all + model.registry.custom.map(\.definition)
        return model.isBlock ? all.filter { !$0.isHat } : all
    }

    private var categories: [BlockCategory] {
        BlockCategory.allCases.filter { category in definitions.contains { $0.category == category } }
    }

    private func matches(_ definition: BlockDefinition) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return definition.title.localizedCaseInsensitiveContains(needle)
            || definition.phrase.localizedCaseInsensitiveContains(needle)
            || definition.help.localizedCaseInsensitiveContains(needle)
            || definition.category.label.localizedCaseInsensitiveContains(needle)
    }

    private func section(_ title: String, _ items: [BlockDefinition]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.mono(8.5, .semibold)).tracking(1.1).foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 2)
            ForEach(items) { PaletteRow(definition: $0) }
        }
    }

    private func fold(_ category: BlockCategory) -> some View {
        let isOpen = open.contains(category)
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                if isOpen { open.remove(category) } else { open.insert(category) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7.5, weight: .bold)).frame(width: 9)
                    Image(systemName: category.glyph).font(.system(size: 10)).foregroundStyle(category.tint)
                    Text(category.label.uppercased()).font(Theme.mono(9, .semibold)).tracking(0.9)
                    Spacer()
                    Text("\(definitions.filter { $0.category == category }.count)")
                        .font(Theme.mono(8.5)).foregroundStyle(Theme.textMuted)
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                ForEach(definitions.filter { $0.category == category }) { PaletteRow(definition: $0) }
            }
        }
        .padding(.top, 2)
    }
}

/// One block in the palette: drag it out, or double-click to add it.
private struct PaletteRow: View {
    let definition: BlockDefinition
    @EnvironmentObject private var model: EditorModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: definition.glyph)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(definition.tint)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(definition.tint.opacity(0.13)))
            VStack(alignment: .leading, spacing: 1) {
                Text(definition.title).font(Theme.sans(12, .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if hovering, definition.phrase != definition.title {
                    Text(definition.phrase.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: ""))
                        .font(Theme.sans(10)).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.white.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(definition.help.isEmpty ? definition.title : definition.help)
        .onTapGesture(count: 2) { model.add(definition.id) }
        .onDrag {
            let payload = DragPayload.new(definition: definition.id)
            model.dragging = payload
            return payload.provider
        }
    }
}

extension Notification.Name {
    /// Space on the canvas: put the cursor in the palette's search.
    static let flowEditorFindBlock = Notification.Name("flowEditorFindBlock")
}
