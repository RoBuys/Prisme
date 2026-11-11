import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum AppMode { case report, data, model, powerbi }
enum Well: Equatable { case axis, legend, values, slot(Int) }

struct MeasureDraft: Identifiable {
    var id: UUID?
    var name: String
    var table: String
    var expression: String
    var format: MeasureFormat
    /// A calculated column rather than a measure; `originalName` is the column being edited.
    var isColumn = false
    var originalName: String?
}

struct StepDraft: Identifiable {
    let id = UUID()
    var step: TransformStep
    var table: String
}

struct CrossFilter: Equatable {
    var pageID: UUID
    var visualID: UUID
    var field: FieldRef
    var label: String
}

@Observable
final class AppState {
    static let shared = AppState()

    var tables: [DataTable] = []
    var relationships: [Relationship] = []
    var measures: [Measure] = []
    /// The measure being created or edited (drives the editor sheet).
    var measureDraft: MeasureDraft?
    /// The transformation step being set up (drives the step sheet), and errors of applied steps per table.
    var stepDraft: StepDraft?
    var stepErrors: [String: [UUID: String]] = [:]
    var modelLayout: [String: CGPoint] = [:]
    /// Report color theme (see `Theme.themes`).
    var theme = Theme.defaultName
    var pages: [ReportPage]
    var currentPageID: UUID
    var selectedVisualID: UUID?
    var crossFilter: CrossFilter?
    var mode: AppMode = .report
    var dataTableName: String?
    var fileURL: URL?
    var isDirty = false

    // MARK: Undo / redo (document snapshots; arrays are copy-on-write, so unchanged tables cost nothing)

    struct Snapshot {
        var tables: [DataTable]
        var pages: [ReportPage]
        var relationships: [Relationship]
        var measures: [Measure]
        var modelLayout: [String: CGPoint]
        var theme: String
        var currentPageID: UUID
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var lastSnapshot: Snapshot?
    private var lastChange = Date.distantPast
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private func snapshot() -> Snapshot {
        Snapshot(tables: tables, pages: pages, relationships: relationships, measures: measures,
                 modelLayout: modelLayout, theme: theme, currentPageID: currentPageID)
    }

    /// Records a change for undo and marks the document as modified.
    /// Changes less than 0.6 s apart (typing, for example) are merged into one undo step.
    func didChange() {
        let now = Date()
        if let last = lastSnapshot, now.timeIntervalSince(lastChange) > 0.6 {
            undoStack.append(last)
            if undoStack.count > 100 { undoStack.removeFirst() }
        }
        lastChange = now
        lastSnapshot = snapshot()
        redoStack.removeAll()
        isDirty = true
    }

    func resetHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        lastSnapshot = snapshot()
        lastChange = .distantPast
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(lastSnapshot ?? snapshot())
        restore(prev)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(lastSnapshot ?? snapshot())
        restore(next)
    }

    private func restore(_ s: Snapshot) {
        tables = s.tables
        pages = s.pages
        relationships = s.relationships
        measures = s.measures
        modelLayout = s.modelLayout
        theme = s.theme
        currentPageID = pages.contains { $0.id == s.currentPageID } ? s.currentPageID : pages[0].id
        if let id = selectedVisualID, visual(id) == nil { selectedVisualID = nil }
        crossFilter = nil
        if let n = dataTableName, !tables.contains(where: { $0.name == n }) { dataTableName = tables.first?.name }
        lastSnapshot = s
        lastChange = .distantPast
        isDirty = true
    }
    var isImporting = false
    var showFilters = false
    /// Interface language; changing it rebuilds the UI.
    var language: AppLanguage = Loc.language {
        didSet {
            Loc.language = language
            UserDefaults.standard.set(language.rawValue, forKey: "prisme.language")
        }
    }
    var alertMessage: String?

    static let reportType = UTType("local.prisme.report") ?? UTType(filenameExtension: "prisme", conformingTo: .json) ?? .json

    init() {
        let p = ReportPage(name: L("Page 1"))
        pages = [p]
        currentPageID = p.id
        resetHistory()
    }

    // MARK: Accessors

    var pageIndex: Int { pages.firstIndex { $0.id == currentPageID } ?? 0 }
    var currentPage: ReportPage { pages[pageIndex] }

    var selectedVisual: Visual? { selectedVisualID.flatMap(visual) }

    func visual(_ id: UUID) -> Visual? {
        for p in pages { if let v = p.visuals.first(where: { $0.id == id }) { return v } }
        return nil
    }

    func column(for f: FieldRef) -> DataColumn? {
        guard let t = Engine.table(named: f.table, in: tables), let i = t.columnIndex(f.column) else { return nil }
        return t.columns[i]
    }

    var model: DataModel { DataModel(tables: tables, relationships: relationships, measures: measures) }

    func measure(for f: FieldRef) -> Measure? { measures.first { $0.table == f.table && $0.name == f.column } }

    var windowTitle: String {
        let name = fileURL?.deletingPathExtension().lastPathComponent ?? L("Sans titre")
        return isDirty ? L("%@ — modifié", name) : name
    }

    // MARK: Mutation helpers

    func mutatePage(_ body: (inout ReportPage) -> Void) {
        body(&pages[pageIndex])
        didChange()
    }

    func mutateVisual(_ id: UUID, _ body: (inout Visual) -> Void) {
        for p in pages.indices {
            if let i = pages[p].visuals.firstIndex(where: { $0.id == id }) {
                body(&pages[p].visuals[i])
                didChange()
                return
            }
        }
    }

    // MARK: Filters

    var activeFilterCount: Int {
        let page = currentPage
        return page.filters.filter { !$0.selected.isEmpty }.count
            + page.visuals.filter { $0.type == .slicer && !$0.slicerSelection.isEmpty }.count
            + (crossFilter?.pageID == page.id ? 1 : 0)
    }

    func filters(for v: Visual) -> [FilterSpec] {
        let page = currentPage
        var specs = page.filters.filter { !$0.selected.isEmpty }.map { FilterSpec(field: $0.field, allowed: $0.selected) }
        for s in page.visuals where s.type == .slicer && s.id != v.id && !s.slicerSelection.isEmpty {
            if let f = s.axis.first { specs.append(FilterSpec(field: f, allowed: s.slicerSelection)) }
        }
        if let cf = crossFilter, cf.pageID == page.id, cf.visualID != v.id {
            specs.append(FilterSpec(field: cf.field, allowed: [cf.label]))
        }
        return specs
    }

    func highlighted(in v: Visual) -> String? {
        guard let cf = crossFilter, cf.visualID == v.id else { return nil }
        return cf.label
    }

    func toggleCrossFilter(from v: Visual, label: String?) {
        selectedVisualID = v.id
        guard let label, let f = v.axis.first else { crossFilter = nil; return }
        if crossFilter?.visualID == v.id && crossFilter?.label == label {
            crossFilter = nil
        } else {
            crossFilter = CrossFilter(pageID: currentPageID, visualID: v.id, field: f, label: label)
        }
    }

    func clearSelection() {
        selectedVisualID = nil
        crossFilter = nil
    }

    // MARK: Visuals

    @discardableResult
    func addVisual(_ type: VisualType) -> UUID {
        let size = type.defaultSize
        let n = currentPage.visuals.count
        var origin = CGPoint(x: 40 + CGFloat(n % 8) * 30, y: 40 + CGFloat(n % 8) * 30)
        origin.x = min(origin.x, PageSize.width - size.width)
        origin.y = min(origin.y, PageSize.height - size.height)
        let v = Visual(type: type, frame: CGRect(origin: origin, size: size))
        mutatePage { $0.visuals.append(v) }
        selectedVisualID = v.id
        return v.id
    }

    func visualTypeTapped(_ type: VisualType) {
        if let id = selectedVisualID, visual(id) != nil {
            mutateVisual(id) { v in
                v.type = type
                if type == .slicer, let f = v.axis.first, column(for: f)?.type == .date, f.dateLevel == nil {
                    v.axis[0].dateLevel = .year
                }
            }
        } else {
            addVisual(type)
        }
    }

    func mutateFormat(_ id: UUID, _ body: (inout VisualFormat) -> Void) {
        mutateVisual(id) { v in
            var f = v.fmt
            body(&f)
            v.format = f
        }
    }

    func deleteVisual(_ id: UUID? = nil) {
        guard let id = id ?? selectedVisualID else { return }
        for p in pages.indices { pages[p].visuals.removeAll { $0.id == id } }
        if selectedVisualID == id { selectedVisualID = nil }
        if crossFilter?.visualID == id { crossFilter = nil }
        didChange()
    }

    func duplicateVisual(_ id: UUID? = nil) {
        guard let id = id ?? selectedVisualID, var v = visual(id) else { return }
        v.id = UUID()
        v.frame = v.frame.offsetBy(dx: 24, dy: 24)
        v.frame.origin.x = min(v.frame.origin.x, PageSize.width - v.frame.width)
        v.frame.origin.y = min(v.frame.origin.y, PageSize.height - v.frame.height)
        mutatePage { $0.visuals.append(v) }
        selectedVisualID = v.id
    }

    func bringToFront(_ id: UUID) {
        mutatePage { p in
            guard let i = p.visuals.firstIndex(where: { $0.id == id }) else { return }
            p.visuals.append(p.visuals.remove(at: i))
        }
    }

    func moveVisual(_ id: UUID, to frame: CGRect) {
        var f = frame
        f.size.width = min(max(f.width, 120), PageSize.width)
        f.size.height = min(max(f.height, 70), PageSize.height)
        f.origin.x = min(max(0, (f.minX / 4).rounded() * 4), PageSize.width - f.width)
        f.origin.y = min(max(0, (f.minY / 4).rounded() * 4), PageSize.height - f.height)
        f.size.width = (f.width / 4).rounded() * 4
        f.size.height = (f.height / 4).rounded() * 4
        mutateVisual(id) { $0.frame = f }
    }

    // MARK: Fields

    func defaultAggregation(for f: FieldRef) -> Aggregation {
        column(for: f)?.type == .number ? .sum : .count
    }

    func addField(_ field: FieldRef, to well: Well, visualID: UUID) {
        guard let v = visual(visualID) else { return }
        let isMeasure = measure(for: field) != nil
        let col = column(for: field)
        guard isMeasure || col != nil else { return }
        if isMeasure, well == .axis || well == .legend { return }
        var f = field
        f.dateLevel = nil
        func valueField() -> ValueField {
            isMeasure ? ValueField(field: field, aggregation: .sum, isMeasure: true)
                      : ValueField(field: f, aggregation: defaultAggregation(for: f))
        }
        mutateVisual(visualID) { vis in
            switch well {
            case .axis:
                if col?.type == .date {
                    switch vis.type {
                    case .slicer, .matrix: f.dateLevel = .year
                    case .table, .scatter, .map: f.dateLevel = nil
                    default: f.dateLevel = .month
                    }
                }
                if vis.type == .table || vis.type == .matrix {
                    if !vis.axis.contains(f) { vis.axis.append(f) }
                } else {
                    vis.axis = [f]
                    if vis.type == .slicer { vis.slicerSelection = [] }
                }
            case .legend:
                if col?.type == .date { f.dateLevel = .year }
                vis.legend = f
            case .values:
                if v.type.allowsManyValues { vis.values.append(valueField()) } else { vis.values = [valueField()] }
            case .slot(let i):
                if i < vis.values.count { vis.values[i] = valueField() } else { vis.values.append(valueField()) }
            }
        }
        if crossFilter?.visualID == visualID { crossFilter = nil }
    }

    /// Click on a field in the Data pane (like ticking its checkbox).
    func quickAdd(_ field: FieldRef) {
        if measure(for: field) != nil {
            if let v = selectedVisual {
                if v.values.contains(where: { $0.measure && $0.field == field }) {
                    mutateVisual(v.id) { $0.values.removeAll { $0.measure && $0.field == field } }
                } else if v.type.usesValueSlots {
                    addField(field, to: .slot(v.values.count), visualID: v.id)
                } else if v.type != .slicer {
                    addField(field, to: .values, visualID: v.id)
                }
            } else {
                addField(field, to: .values, visualID: addVisual(.card))
            }
            return
        }
        guard let col = column(for: field) else { return }
        if let v = selectedVisual {
            if v.allFields.contains(where: { $0.columnKey == field.columnKey }) {
                removeField(field, from: v.id)
                return
            }
            if v.type == .slicer { addField(field, to: .axis, visualID: v.id); return }
            if v.type == .card { addField(field, to: .values, visualID: v.id); return }
            if v.type.usesValueSlots && col.type == .number {
                addField(field, to: .slot(v.values.count), visualID: v.id); return
            }
            if col.type == .number { addField(field, to: .values, visualID: v.id); return }
            if v.type == .table || v.axis.isEmpty { addField(field, to: .axis, visualID: v.id); return }
            if v.type.isCartesian && v.legend == nil { addField(field, to: .legend, visualID: v.id); return }
            addField(field, to: .axis, visualID: v.id)
        } else {
            let id = addVisual(col.type == .number ? .column : .table)
            addField(field, to: col.type == .number ? .values : .axis, visualID: id)
        }
    }

    func removeField(_ field: FieldRef, from id: UUID) {
        mutateVisual(id) { v in
            v.axis.removeAll { $0.columnKey == field.columnKey }
            if v.legend?.columnKey == field.columnKey { v.legend = nil }
            v.values.removeAll { $0.field.columnKey == field.columnKey }
        }
        if crossFilter?.visualID == id { crossFilter = nil }
    }

    // MARK: Slicers

    func toggleSlicer(_ id: UUID, _ label: String) {
        mutateVisual(id) { v in
            if v.slicerSelection.contains(label) { v.slicerSelection.remove(label) } else { v.slicerSelection.insert(label) }
        }
    }

    func clearSlicer(_ id: UUID) { mutateVisual(id) { $0.slicerSelection = [] } }

    // MARK: Page filters

    func addPageFilter(_ field: FieldRef) {
        guard let col = column(for: field) else { return }
        var f = field
        f.dateLevel = col.type == .date ? .year : nil
        mutatePage { p in
            if !p.filters.contains(where: { $0.field == f }) { p.filters.append(PageFilter(field: f)) }
        }
    }

    func mutateFilter(_ id: UUID, _ body: (inout PageFilter) -> Void) {
        mutatePage { p in
            if let i = p.filters.firstIndex(where: { $0.id == id }) { body(&p.filters[i]) }
        }
    }

    func removePageFilter(_ id: UUID) { mutatePage { $0.filters.removeAll { $0.id == id } } }

    // MARK: Pages

    func selectPage(_ id: UUID) {
        currentPageID = id
        selectedVisualID = nil
        crossFilter = nil
    }

    func addPage() {
        let p = ReportPage(name: L("Page %@", pages.count + 1))
        pages.append(p)
        didChange()
        selectPage(p.id)
    }

    func duplicatePage(_ id: UUID) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        var p = pages[i]
        p.id = UUID()
        p.name += L(" (copie)")
        p.visuals = p.visuals.map { var v = $0; v.id = UUID(); return v }
        p.filters = p.filters.map { var f = $0; f.id = UUID(); return f }
        pages.insert(p, at: i + 1)
        didChange()
        selectPage(p.id)
    }

    func deletePage(_ id: UUID) {
        guard pages.count > 1, let i = pages.firstIndex(where: { $0.id == id }) else { return }
        pages.remove(at: i)
        didChange()
        if currentPageID == id { selectPage(pages[max(0, i - 1)].id) }
    }

    func renamePage(_ id: UUID, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[i].name = n
        didChange()
    }

    // MARK: Tables

    func uniqueTableName(_ base: String) -> String {
        var name = base, k = 2
        while tables.contains(where: { $0.name == name }) { name = "\(base) (\(k))"; k += 1 }
        return name
    }

    func importWithPanel() {
        let panel = NSOpenPanel()
        panel.title = L("Obtenir des données")
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Importer.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    func importFiles(_ urls: [URL]) {
        let files = urls.filter { Importer.supportedExtensions.contains($0.pathExtension.lowercased()) || $0.pathExtension.lowercased() == "xls" }
        guard !files.isEmpty else { return }
        isImporting = true
        Task { @MainActor in
            var loaded: [DataTable] = []
            var errors: [String] = []
            for url in files {
                do {
                    loaded += try await Task.detached(priority: .userInitiated) { try Importer.load(url) }.value
                } catch {
                    errors.append(error.localizedDescription)
                }
            }
            do {
                var added: [String] = []
                for var t in loaded {
                    t.name = uniqueTableName(t.name)
                    tables.append(t)
                    added.append(t.name)
                    if dataTableName == nil { dataTableName = t.name }
                }
                if !added.isEmpty { detectRelationships(for: added) }
                if !loaded.isEmpty { didChange() }
                isImporting = false
                if !errors.isEmpty { alertMessage = errors.joined(separator: "\n\n") }
            }
        }
    }

    func refreshAll() {
        let sources = tables.compactMap { t in t.source.map { (t.name, $0) } }
        guard !sources.isEmpty else {
            alertMessage = L("Aucune table n'est liée à un fichier source.")
            return
        }
        isImporting = true
        Task { @MainActor in
            var updates: [String: DataTable] = [:]
            var errors: [String] = []
            for (name, src) in sources {
                let url = URL(fileURLWithPath: src.path)
                do {
                    let loaded = try await Task.detached(priority: .userInitiated) { try Importer.load(url) }.value
                    if let t = loaded.first(where: { src.sheet == nil || $0.source?.sheet == src.sheet }) {
                        updates[name] = t
                    } else {
                        errors.append(L("« %@ » : feuille introuvable dans %@.", name, url.lastPathComponent))
                    }
                } catch {
                    errors.append("« \(name) » : \(error.localizedDescription)")
                }
            }
            do {
                for i in tables.indices {
                    if let u = updates[tables[i].name], !tables[i].steps.isEmpty {
                        // New source data becomes the base of the recipe, which is replayed.
                        var base = u
                        base.name = tables[i].name
                        tables[i].base = [base]
                        reapplySteps(i)
                    } else if let u = updates[tables[i].name] {
                        // Keep calculated columns: re-append their definitions, then recompute them.
                        let calculated = tables[i].columns.filter { $0.expression != nil }
                        tables[i].columns = u.columns + calculated
                        tables[i].rows = u.rows.map { $0 + Array(repeating: CellValue.empty, count: calculated.count) }
                    }
                }
                recomputeCalculatedColumns()
                if !updates.isEmpty { didChange() }
                isImporting = false
                if !errors.isEmpty { alertMessage = errors.joined(separator: "\n") }
            }
        }
    }

    func renameTable(_ old: String, to newName: String) {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != old, !tables.contains(where: { $0.name == n }),
              let i = tables.firstIndex(where: { $0.name == old }) else { return }
        tables[i].name = n
        func fix(_ f: inout FieldRef) { if f.table == old { f.table = n } }
        for p in pages.indices {
            for v in pages[p].visuals.indices {
                for a in pages[p].visuals[v].axis.indices { fix(&pages[p].visuals[v].axis[a]) }
                if pages[p].visuals[v].legend != nil { fix(&pages[p].visuals[v].legend!) }
                for a in pages[p].visuals[v].values.indices { fix(&pages[p].visuals[v].values[a].field) }
            }
            for f in pages[p].filters.indices { fix(&pages[p].filters[f].field) }
        }
        for i in measures.indices {
            if measures[i].table == old { measures[i].table = n }
            measures[i].expression = Self.renameTableReferences(in: measures[i].expression, from: old, to: n)
        }
        for r in relationships.indices {
            if relationships[r].fromTable == old { relationships[r].fromTable = n }
            if relationships[r].toTable == old { relationships[r].toTable = n }
        }
        if let p = modelLayout.removeValue(forKey: old) { modelLayout[n] = p }
        if dataTableName == old { dataTableName = n }
        crossFilter = nil
        didChange()
    }

    func deleteTable(_ name: String) {
        tables.removeAll { $0.name == name }
        relationships.removeAll { $0.involves(name) }
        measures.removeAll { $0.table == name }
        modelLayout[name] = nil
        for p in pages.indices {
            for v in pages[p].visuals.indices {
                pages[p].visuals[v].axis.removeAll { $0.table == name }
                if pages[p].visuals[v].legend?.table == name { pages[p].visuals[v].legend = nil }
                pages[p].visuals[v].values.removeAll { $0.field.table == name }
            }
            pages[p].filters.removeAll { $0.field.table == name }
        }
        if dataTableName == name { dataTableName = tables.first?.name }
        crossFilter = nil
        didChange()
    }

    func convertColumn(table: String, column: String, to type: ColumnType) {
        guard let ti = tables.firstIndex(where: { $0.name == table }), let ci = tables[ti].columnIndex(column),
              tables[ti].columns[ci].type != type else { return }
        if tables[ti].columns[ci].expression == nil {
            addStep(TransformStep(kind: .changeType, column: column, type: type), to: table)
        } else {
            let raw = Importer.cellsToRaw(tables[ti].rows.map { $0[ci] })
            let converted = Importer.coerce(raw, to: type)
            for r in tables[ti].rows.indices { tables[ti].rows[r][ci] = converted[r] }
            tables[ti].columns[ci].type = type
        }
        // Fields whose aggregation no longer makes sense fall back to a count.
        for p in pages.indices {
            for v in pages[p].visuals.indices {
                for a in pages[p].visuals[v].values.indices where pages[p].visuals[v].values[a].field.table == table
                    && pages[p].visuals[v].values[a].field.column == column {
                    if type != .number && pages[p].visuals[v].values[a].aggregation.isNumericOnly {
                        pages[p].visuals[v].values[a].aggregation = .count
                    }
                }
                for a in pages[p].visuals[v].axis.indices where pages[p].visuals[v].axis[a].table == table
                    && pages[p].visuals[v].axis[a].column == column {
                    pages[p].visuals[v].axis[a].dateLevel = type == .date ? .month : nil
                }
            }
        }
        didChange()
    }

    func loadSample() {
        let sample = SampleData.make(names: (uniqueTableName(L("Ventes")), uniqueTableName(L("Produits")), uniqueTableName(L("Régions"))))
        tables += sample.tables
        dataTableName = sample.tables[0].name
        detectRelationships(for: sample.tables.map(\.name))
        measures += sample.measures
        if pages.count == 1 && pages[0].visuals.isEmpty && pages[0].filters.isEmpty {
            pages = sample.pages
        } else {
            pages += sample.pages
        }
        didChange()
        selectPage(sample.pages[0].id)
        mode = .report
    }

    // MARK: Relationships

    /// Creates a relationship between two columns. The side with unique values becomes the "one" side.
    /// Returns an error message, or nil on success.
    @discardableResult
    func addRelationship(_ a: FieldRef, _ b: FieldRef) -> String? {
        guard a.table != b.table else { return L("Les deux colonnes doivent appartenir à des tables différentes.") }
        guard column(for: a) != nil, column(for: b) != nil else { return L("Colonne introuvable.") }
        let m = model
        let aUnique = m.isUnique(table: a.table, column: a.column)
        let bUnique = m.isUnique(table: b.table, column: b.column)
        guard aUnique || bUnique else {
            return L("Aucune des deux colonnes (« %@ », « %@ ») ne contient de valeurs uniques : les relations plusieurs-à-plusieurs ne sont pas prises en charge.", a.column, b.column)
        }
        let (many, one) = bUnique ? (a, b) : (b, a)
        if relationships.contains(where: { $0.fromTable == many.table && $0.fromColumn == many.column
            && $0.toTable == one.table && $0.toColumn == one.column }) {
            return L("Cette relation existe déjà.")
        }
        // A second path between the same tables would be ambiguous: keep it inactive.
        let active = !m.connected(many.table, one.table)
        relationships.append(Relationship(fromTable: many.table, fromColumn: many.column,
                                          toTable: one.table, toColumn: one.column, isActive: active))
        didChange()
        crossFilter = nil
        return active ? nil : L("Relation créée mais inactive : ces tables sont déjà reliées par un autre chemin.")
    }

    func deleteRelationship(_ id: UUID) {
        relationships.removeAll { $0.id == id }
        crossFilter = nil
        didChange()
    }

    func setRelationshipActive(_ id: UUID, _ active: Bool) {
        guard let i = relationships.firstIndex(where: { $0.id == id }) else { return }
        if active {
            var others = model
            others.relationships.remove(at: i)
            if others.connected(relationships[i].fromTable, relationships[i].toTable) {
                alertMessage = L("Impossible d'activer cette relation : les tables sont déjà reliées par un autre chemin actif. Désactivez-le d'abord.")
                return
            }
        }
        relationships[i].isActive = active
        crossFilter = nil
        didChange()
    }

    /// Links columns that share a name and a type when one side has unique values (like Power BI's autodetect).
    @discardableResult
    func detectRelationships(for newTables: [String]? = nil) -> Int {
        var created = 0
        let names = tables.map(\.name)
        for a in newTables ?? names {
            for b in names where b != a {
                guard let ta = Engine.table(named: a, in: tables), let tb = Engine.table(named: b, in: tables) else { continue }
                if model.connected(a, b) { continue }
                for ca in ta.columns {
                    guard let cb = tb.columns.first(where: {
                        $0.name.compare(ca.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                    }), cb.type == ca.type else { continue }
                    let m = model
                    guard m.isUnique(table: a, column: ca.name) || m.isUnique(table: b, column: cb.name) else { continue }
                    if addRelationship(FieldRef(table: a, column: ca.name), FieldRef(table: b, column: cb.name)) == nil {
                        created += 1
                    }
                    break
                }
            }
        }
        return created
    }

    // MARK: Measures

    func newMeasure(in table: String? = nil) {
        guard let home = table ?? dataTableName ?? tables.first?.name else { return }
        var n = L("Mesure"), k = 2
        while !isMeasureNameFree(n, excluding: nil, table: home) { n = L("Mesure %@", k); k += 1 }
        measureDraft = MeasureDraft(id: nil, name: n, table: home, expression: "", format: .auto)
    }

    func editMeasure(_ m: Measure) {
        measureDraft = MeasureDraft(id: m.id, name: m.name, table: m.table, expression: m.expression, format: m.format)
    }

    /// Measure names are unique in the model and must differ from the columns of their table.
    func isMeasureNameFree(_ name: String, excluding id: UUID?, table: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        if measures.contains(where: { $0.id != id && $0.name.caseInsensitiveEquals(n) }) { return false }
        if let t = Engine.table(named: table, in: tables), t.columns.contains(where: { $0.name.caseInsensitiveEquals(n) }) { return false }
        return true
    }

    // MARK: Calculated columns

    func newColumn(in table: String? = nil) {
        guard let home = table ?? dataTableName ?? tables.first?.name else { return }
        var n = L("Colonne"), k = 2
        while !isMeasureNameFree(n, excluding: nil, table: home) { n = L("Colonne %@", k); k += 1 }
        measureDraft = MeasureDraft(id: nil, name: n, table: home, expression: "", format: .auto, isColumn: true)
    }

    func editColumn(table: String, column: DataColumn) {
        measureDraft = MeasureDraft(id: nil, name: column.name, table: table, expression: column.expression ?? "",
                                    format: .auto, isColumn: true, originalName: column.name)
    }

    /// Evaluates a column expression for every row of the table.
    func computeColumn(table: String, expression: String, model m: DataModel? = nil) throws -> (ColumnType, [CellValue]) {
        let m = m ?? model
        guard let t = m.table(table) else { throw MeasureError(message: L("Table introuvable : %@", table)) }
        let e: Expr
        switch MeasureCompiler.parse(expression) {
        case .success(let x): e = x
        case .failure(let err): throw err
        }
        let ev = MeasureEvaluator(ctx: QueryContext(base: t, model: m), model: m)
        let values = try t.rows.indices.map { try ev.evaluateRow(e, row: $0) }
        let present = values.filter { !$0.isBlank }
        if !present.isEmpty && present.allSatisfy({ if case .date = $0 { return true }; return false }) {
            return (.date, values.map(\.cell))
        }
        if present.allSatisfy({ if case .number = $0 { return true }; return false }) {
            return (.number, values.map(\.cell))
        }
        return (.text, values.map { v in v.isBlank ? .empty : .text(v.string) })
    }

    /// Recomputes calculated columns (all tables, in column order). Errors leave blank values.
    func recomputeCalculatedColumns() {
        for ti in tables.indices {
            for ci in tables[ti].columns.indices {
                guard let expr = tables[ti].columns[ci].expression else { continue }
                let result = try? computeColumn(table: tables[ti].name, expression: expr)
                for r in tables[ti].rows.indices { tables[ti].rows[r][ci] = result?.1[r] ?? .empty }
                if let type = result?.0 { tables[ti].columns[ci].type = type }
            }
        }
    }

    func saveColumn(_ d: MeasureDraft) -> String? {
        let name = d.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return L("Donnez un nom à la colonne.") }
        guard !name.contains("[") && !name.contains("]") else { return L("Le nom ne peut pas contenir de crochets.") }
        guard let ti = tables.firstIndex(where: { $0.name == d.table }) else { return L("Table introuvable : %@", d.table) }
        let clash = tables[ti].columns.contains { $0.name.caseInsensitiveEquals(name) && $0.name != d.originalName }
            || measures.contains { $0.name.caseInsensitiveEquals(name) }
        guard !clash else { return L("Le nom « %@ » est déjà utilisé par une autre mesure ou une colonne.", name) }
        if let err = MeasureCompiler.validate(d.expression, home: d.table, name: "", model) { return err }
        let result: (ColumnType, [CellValue])
        do { result = try computeColumn(table: d.table, expression: d.expression) }
        catch { return error.localizedDescription }

        if let old = d.originalName, let ci = tables[ti].columnIndex(old) {
            tables[ti].columns[ci] = DataColumn(name: name, type: result.0, expression: d.expression)
            for r in tables[ti].rows.indices { tables[ti].rows[r][ci] = result.1[r] }
            if old != name { renameColumnReferences(table: d.table, from: old, to: name) }
        } else {
            tables[ti].columns.append(DataColumn(name: name, type: result.0, expression: d.expression))
            for r in tables[ti].rows.indices { tables[ti].rows[r].append(result.1[r]) }
        }
        recomputeCalculatedColumns()
        didChange()
        return nil
    }

    func deleteColumn(table: String, column: String) {
        guard let ti = tables.firstIndex(where: { $0.name == table }), let ci = tables[ti].columnIndex(column) else { return }
        tables[ti].columns.remove(at: ci)
        for r in tables[ti].rows.indices { tables[ti].rows[r].remove(at: ci) }
        recomputeCalculatedColumns()
        crossFilter = nil
        didChange()
    }

    /// Updates visuals, filters, relationships and expressions after a column rename.
    func renameColumnReferences(table: String, from old: String, to new: String) {
        func fix(_ f: inout FieldRef) { if f.table == table && f.column == old { f.column = new } }
        for p in pages.indices {
            for v in pages[p].visuals.indices {
                for a in pages[p].visuals[v].axis.indices { fix(&pages[p].visuals[v].axis[a]) }
                if pages[p].visuals[v].legend != nil { fix(&pages[p].visuals[v].legend!) }
                for a in pages[p].visuals[v].values.indices where !pages[p].visuals[v].values[a].measure {
                    fix(&pages[p].visuals[v].values[a].field)
                }
            }
            for f in pages[p].filters.indices { fix(&pages[p].filters[f].field) }
        }
        for r in relationships.indices {
            if relationships[r].fromTable == table && relationships[r].fromColumn == old { relationships[r].fromColumn = new }
            if relationships[r].toTable == table && relationships[r].toColumn == old { relationships[r].toColumn = new }
        }
        for i in measures.indices {
            measures[i].expression = Self.renameMeasureReferences(in: measures[i].expression, from: old, to: new)
        }
        for ti in tables.indices {
            for ci in tables[ti].columns.indices {
                if let e = tables[ti].columns[ci].expression {
                    tables[ti].columns[ci].expression = Self.renameMeasureReferences(in: e, from: old, to: new)
                }
            }
        }
    }

    /// Validates and stores a draft. Returns an error message, or nil on success.
    func saveMeasure(_ d: MeasureDraft) -> String? {
        if d.isColumn { return saveColumn(d) }
        let name = d.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return L("Donnez un nom à la mesure.") }
        guard !name.contains("[") && !name.contains("]") else { return L("Le nom ne peut pas contenir de crochets.") }
        guard isMeasureNameFree(name, excluding: d.id, table: d.table) else {
            return L("Le nom « %@ » est déjà utilisé par une autre mesure ou une colonne.", name)
        }
        var probe = model
        probe.measures.removeAll { $0.id == d.id }
        if let err = MeasureCompiler.validate(d.expression, home: d.table, name: name, probe) { return err }

        if let id = d.id, let i = measures.firstIndex(where: { $0.id == id }) {
            let old = measures[i]
            measures[i].name = name
            measures[i].table = d.table
            measures[i].expression = d.expression
            measures[i].format = d.format
            if old.name != name || old.table != d.table {
                for j in measures.indices where j != i {
                    measures[j].expression = Self.renameMeasureReferences(in: measures[j].expression, from: old.name, to: name)
                }
                for p in pages.indices {
                    for v in pages[p].visuals.indices {
                        for a in pages[p].visuals[v].values.indices where pages[p].visuals[v].values[a].measure
                            && pages[p].visuals[v].values[a].field == old.field {
                            pages[p].visuals[v].values[a].field = FieldRef(table: d.table, column: name)
                        }
                    }
                }
            }
        } else {
            measures.append(Measure(name: name, table: d.table, expression: d.expression, format: d.format))
        }
        didChange()
        return nil
    }

    func deleteMeasure(_ m: Measure) {
        measures.removeAll { $0.id == m.id }
        for p in pages.indices {
            for v in pages[p].visuals.indices {
                pages[p].visuals[v].values.removeAll { $0.measure && $0.field == m.field }
            }
        }
        didChange()
    }

    /// Preview of a draft over all rows (no filters).
    func previewMeasure(_ d: MeasureDraft) -> String {
        if d.isColumn {
            guard !d.expression.isEmpty else { return "" }
            if let err = MeasureCompiler.validate(d.expression, home: d.table, name: "", model) { return "⚠︎ " + err }
            do {
                let (_, values) = try computeColumn(table: d.table, expression: d.expression)
                return values.prefix(4).map { Fmt.cell($0).isEmpty ? L("(Vide)") : Fmt.cell($0) }.joined(separator: " · ")
            } catch {
                return "⚠︎ " + error.localizedDescription
            }
        }
        var probe = model
        probe.measures.removeAll { $0.id == d.id }
        let me = Measure(name: d.name.isEmpty ? "_" : d.name, table: d.table, expression: d.expression, format: d.format)
        probe.measures.append(me)
        if let err = MeasureCompiler.validate(d.expression, home: d.table, name: me.name, probe) { return "⚠︎ " + err }
        let deps = MeasureCompiler.dependencies(me, probe)
        guard let ctx = Engine.context(for: deps.isEmpty ? [FieldRef(table: d.table, column: "")] : deps, probe) else { return "" }
        do {
            let value = try MeasureEvaluator(ctx: ctx, model: probe).evaluateValue(me, rows: ctx.rowIndices([]), filters: [])
            switch value {
            case .blank: return L("(Vide)")
            case .text(let s): return s
            default: return value.number.map { Fmt.measure($0, d.format, compact: false) } ?? value.string
            }
        } catch {
            return "⚠︎ " + error.localizedDescription
        }
    }

    static func renameMeasureReferences(in expr: String, from old: String, to new: String) -> String {
        let pattern = "\\[\\s*" + NSRegularExpression.escapedPattern(for: old) + "\\s*\\]"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return expr }
        return re.stringByReplacingMatches(in: expr, range: NSRange(expr.startIndex..., in: expr),
                                           withTemplate: NSRegularExpression.escapedTemplate(for: "[\(new)]"))
    }

    static func renameTableReferences(in expr: String, from old: String, to new: String) -> String {
        let pattern = "(?<![\\p{L}\\p{N}_\\[])" + NSRegularExpression.escapedPattern(for: old) + "(?![\\p{L}\\p{N}_\\]])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return expr }
        let safe = new.contains(" ") ? "'\(new)'" : new
        return re.stringByReplacingMatches(in: expr, range: NSRange(expr.startIndex..., in: expr),
                                           withTemplate: NSRegularExpression.escapedTemplate(for: safe))
    }

    // MARK: Documents

    /// Asks to save unsaved changes. Returns false if the user cancelled.
    func confirmDiscard() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = L("Voulez-vous enregistrer les modifications apportées à « %@ » ?", fileURL?.deletingPathExtension().lastPathComponent ?? "Sans titre")
        alert.informativeText = L("Vos modifications seront perdues si vous ne les enregistrez pas.")
        alert.addButton(withTitle: L("Enregistrer"))
        alert.addButton(withTitle: L("Annuler"))
        alert.addButton(withTitle: L("Ne pas enregistrer"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func newDocument() {
        guard confirmDiscard() else { return }
        let p = ReportPage(name: L("Page 1"))
        tables = []
        relationships = []
        measures = []
        theme = Theme.defaultName
        modelLayout = [:]
        pages = [p]
        currentPageID = p.id
        selectedVisualID = nil
        crossFilter = nil
        dataTableName = nil
        fileURL = nil
        isDirty = false
        mode = .report
        resetHistory()
    }

    func openDocument() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.reportType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let doc = try JSONDecoder().decode(ReportDocument.self, from: data)
            tables = doc.tables
            relationships = doc.relationships
            measures = doc.measures
            modelLayout = doc.modelLayout
            theme = doc.theme ?? Theme.defaultName
            pages = doc.pages.isEmpty ? [ReportPage(name: L("Page 1"))] : doc.pages
            currentPageID = pages[0].id
            selectedVisualID = nil
            crossFilter = nil
            dataTableName = tables.first?.name
            fileURL = url
            isDirty = false
            mode = .report
            resetHistory()
        } catch {
            alertMessage = L("Impossible d'ouvrir « %@ » : %@", url.lastPathComponent, error.localizedDescription)
        }
    }

    @discardableResult
    func save() -> Bool {
        guard let url = fileURL else { return saveAs() }
        return write(to: url)
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.reportType]
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? L("Rapport")) + ".prisme"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    private func write(to url: URL) -> Bool {
        do {
            let data = try JSONEncoder().encode(ReportDocument(tables: tables, pages: pages, relationships: relationships, measures: measures, modelLayout: modelLayout, theme: theme))
            try data.write(to: url, options: .atomic)
            fileURL = url
            isDirty = false
            return true
        } catch {
            alertMessage = L("Échec de l'enregistrement : %@", error.localizedDescription)
            return false
        }
    }
}
