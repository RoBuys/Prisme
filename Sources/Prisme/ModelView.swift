import SwiftUI

/// "Modèle" view: tables as cards, relationships as lines. Drag a column onto another to link them.
struct ModelView: View {
    @Environment(AppState.self) private var state
    @State private var dragging: [String: CGSize] = [:]

    static let cardWidth: CGFloat = 210
    static let headerHeight: CGFloat = 32
    static let rowHeight: CGFloat = 22
    static let maxRows = 18

    var body: some View {
        if state.tables.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                Text(L("Aucune table")).font(.title3.weight(.semibold))
                Button(L("Obtenir des données…")) { state.importWithPanel() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: canvasSize.width, height: canvasSize.height)
                    Canvas { ctx, _ in drawRelationships(ctx) }
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .allowsHitTesting(false)
                    ForEach(state.tables) { t in
                        TableCard(table: t, onMove: { dragging[t.name] = $0 }, onMoveEnd: { commitMove(t.name, $0) })
                            .offset(x: position(t.name).x, y: position(t.name).y)
                    }
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    // MARK: Layout

    /// Star layout: tables on the "many" side on the left, lookup tables stacked on the right.
    private func defaultPosition(_ name: String) -> CGPoint {
        let facts = state.tables.filter { t in state.relationships.contains { $0.fromTable == t.name } }
        let column = facts.isEmpty ? state.tables : (facts.contains { $0.name == name } ? facts
            : state.tables.filter { t in !facts.contains { $0.name == t.name } })
        let x: CGFloat = facts.isEmpty || column.first.map({ f in facts.contains { $0.name == f.name } }) == true ? 40 : 40 + Self.cardWidth + 160
        var y: CGFloat = 40
        for t in column {
            if t.name == name { break }
            y += cardHeight(t) + 30
        }
        return CGPoint(x: x, y: y)
    }

    private func position(_ name: String) -> CGPoint {
        let p = state.modelLayout[name] ?? defaultPosition(name)
        let d = dragging[name] ?? .zero
        return CGPoint(x: max(0, p.x + d.width), y: max(0, p.y + d.height))
    }

    private func commitMove(_ name: String, _ d: CGSize) {
        let p = state.modelLayout[name] ?? defaultPosition(name)
        state.modelLayout[name] = CGPoint(x: max(0, p.x + d.width), y: max(0, p.y + d.height))
        dragging[name] = nil
        state.didChange()
    }

    private func cardHeight(_ t: DataTable) -> CGFloat {
        Self.headerHeight + CGFloat(min(t.columns.count, Self.maxRows)) * Self.rowHeight
            + (t.columns.count > Self.maxRows ? Self.rowHeight : 0) + 6
    }

    private var canvasSize: CGSize {
        var w: CGFloat = 900, h: CGFloat = 600
        for t in state.tables {
            let p = position(t.name)
            w = max(w, p.x + Self.cardWidth + 80)
            h = max(h, p.y + cardHeight(t) + 80)
        }
        return CGSize(width: w, height: h)
    }

    /// Vertical center of a column row inside its card (header center if the row is hidden).
    private func rowY(_ t: DataTable, _ column: String) -> CGFloat {
        let p = position(t.name)
        guard let i = t.columnIndex(column), i < Self.maxRows else { return p.y + Self.headerHeight / 2 }
        return p.y + Self.headerHeight + CGFloat(i) * Self.rowHeight + Self.rowHeight / 2
    }

    private func drawRelationships(_ ctx: GraphicsContext) {
        for r in state.relationships {
            guard let from = Engine.table(named: r.fromTable, in: state.tables),
                  let to = Engine.table(named: r.toTable, in: state.tables) else { continue }
            let pf = position(from.name), pt = position(to.name)
            let fromRight = pf.x + Self.cardWidth / 2 < pt.x + Self.cardWidth / 2
            let a = CGPoint(x: fromRight ? pf.x + Self.cardWidth : pf.x, y: rowY(from, r.fromColumn))
            let b = CGPoint(x: fromRight ? pt.x : pt.x + Self.cardWidth, y: rowY(to, r.toColumn))
            let bend = max(40, abs(b.x - a.x) / 2)
            var path = Path()
            path.move(to: a)
            path.addCurve(to: b, control1: CGPoint(x: a.x + (fromRight ? bend : -bend), y: a.y),
                          control2: CGPoint(x: b.x + (fromRight ? -bend : bend), y: b.y))
            let color = r.isActive ? Theme.accent : Color.gray
            ctx.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.8, dash: r.isActive ? [] : [5, 4]))
            // Cardinality markers: * on the many side, 1 on the one side.
            let off: CGFloat = fromRight ? 12 : -12
            ctx.draw(Text("*").font(.system(size: 13, weight: .bold)).foregroundStyle(color),
                     at: CGPoint(x: a.x + off, y: a.y - 9))
            ctx.draw(Text("1").font(.system(size: 11, weight: .bold)).foregroundStyle(color),
                     at: CGPoint(x: b.x - off, y: b.y - 9))
            // Filter direction arrow at the middle (from the one side toward the many side).
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            ctx.draw(Text(Image(systemName: fromRight ? "arrowtriangle.left.fill" : "arrowtriangle.right.fill"))
                .font(.system(size: 9)).foregroundStyle(color), at: mid)
        }
    }
}

struct TableCard: View {
    let table: DataTable
    let onMove: (CGSize) -> Void
    let onMoveEnd: (CGSize) -> Void
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "tablecells").foregroundStyle(Theme.accent)
                Text(table.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                Text("\(table.rows.count.formatted())").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: ModelView.headerHeight)
            .background(Theme.accent.opacity(0.10))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { onMove($0.translation) }
                .onEnded { onMoveEnd($0.translation) })
            ForEach(table.columns.prefix(ModelView.maxRows)) { c in
                ColumnRow(table: table, column: c)
            }
            if table.columns.count > ModelView.maxRows {
                Text(L("+ %@ autres colonnes", table.columns.count - ModelView.maxRows))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).frame(height: ModelView.rowHeight)
            }
        }
        .padding(.bottom, 6)
        .frame(width: ModelView.cardWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
    }
}

private struct ColumnRow: View {
    let table: DataTable
    let column: DataColumn
    @Environment(AppState.self) private var state
    @State private var targeted = false

    var body: some View {
        let field = FieldRef(table: table.name, column: column.name)
        let linked = state.relationships.contains {
            ($0.fromTable == table.name && $0.fromColumn == column.name) || ($0.toTable == table.name && $0.toColumn == column.name)
        }
        HStack(spacing: 6) {
            Image(systemName: column.type.symbol).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
            Text(column.name).font(.system(size: 12, weight: linked ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 0)
            if linked { Image(systemName: "link").font(.system(size: 9)).foregroundStyle(Theme.accent) }
        }
        .padding(.horizontal, 10)
        .frame(height: ModelView.rowHeight)
        .background(targeted ? Theme.accent.opacity(0.2) : .clear)
        .contentShape(Rectangle())
        .draggable(field.payload) {
            Label("\(table.name)[\(column.name)]", systemImage: "link")
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.2)))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let other = items.compactMap(FieldRef.init(payload:)).first, other.table != table.name else { return false }
            if let msg = state.addRelationship(other, field) { state.alertMessage = msg }
            return true
        } isTargeted: { targeted = $0 }
        .help(L("Glissez cette colonne sur une colonne d'une autre table pour créer une relation"))
    }
}

// MARK: - Relationships pane

struct RelationshipsPane: View {
    @Environment(AppState.self) private var state
    @State private var fromTable = ""
    @State private var fromColumn = ""
    @State private var toTable = ""
    @State private var toColumn = ""

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: L("Relations"))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if state.relationships.isEmpty {
                        Text(L("Aucune relation. Glissez une colonne sur une colonne d'une autre table, ou utilisez le formulaire ci-dessous."))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(state.relationships) { r in row(r) }
                    Button {
                        let n = state.detectRelationships()
                        state.alertMessage = n == 0 ? L("Aucune nouvelle relation détectée.")
                            : (n == 1 ? L("1 relation créée.") : L("%@ relations créées.", n))
                    } label: {
                        Label(L("Détecter automatiquement"), systemImage: "wand.and.stars")
                    }
                    .disabled(state.tables.count < 2)
                    Divider()
                    newRelationshipForm
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(.background)
    }

    private func row(_ r: Relationship) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(r.fromTable)[\(r.fromColumn)]").font(.system(size: 11, weight: .semibold))
                    HStack(spacing: 3) {
                        Text("*").bold()
                        Image(systemName: "arrow.right").font(.system(size: 9))
                        Text("1").bold()
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("\(r.toTable)[\(r.toColumn)]").font(.system(size: 11, weight: .semibold))
                }
                Spacer()
                Button { state.deleteRelationship(r.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Supprimer la relation"))
            }
            Toggle(L("Active"), isOn: Binding(get: { r.isActive }, set: { state.setRelationshipActive(r.id, $0) }))
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(r.isActive ? Theme.accent.opacity(0.08) : Color.primary.opacity(0.04)))
    }

    private var newRelationshipForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Nouvelle relation")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            tablePicker(L("Table"), $fromTable)
            columnPicker(fromTable, $fromColumn)
            Image(systemName: "arrow.down").font(.system(size: 10)).foregroundStyle(.secondary)
            tablePicker(L("Table liée"), $toTable)
            columnPicker(toTable, $toColumn)
            Button(L("Créer la relation")) {
                if let msg = state.addRelationship(FieldRef(table: fromTable, column: fromColumn),
                                                   FieldRef(table: toTable, column: toColumn)) {
                    state.alertMessage = msg
                }
            }
            .disabled(fromTable.isEmpty || toTable.isEmpty || fromColumn.isEmpty || toColumn.isEmpty || fromTable == toTable)
            Text(L("Le sens « plusieurs → un » est déterminé automatiquement d'après les valeurs uniques. Les filtres se propagent du côté « 1 » vers le côté « * »."))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .controlSize(.small)
    }

    private func tablePicker(_ label: String, _ selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            Text("—").tag("")
            ForEach(state.tables) { Text($0.name).tag($0.name) }
        }
        .font(.system(size: 11))
    }

    private func columnPicker(_ table: String, _ selection: Binding<String>) -> some View {
        Picker(L("Colonne"), selection: selection) {
            Text("—").tag("")
            ForEach(Engine.table(named: table, in: state.tables)?.columns ?? []) { Text($0.name).tag($0.name) }
        }
        .font(.system(size: 11))
        .disabled(table.isEmpty)
    }
}
