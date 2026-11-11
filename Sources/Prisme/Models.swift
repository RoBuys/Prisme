import Foundation
import CoreGraphics

// MARK: - Data

enum ColumnType: String, Codable, CaseIterable {
    case number, text, date

    var label: String {
        switch self {
        case .number: L("Nombre")
        case .text: L("Texte")
        case .date: L("Date")
        }
    }

    var symbol: String {
        switch self {
        case .number: "sum"
        case .text: "textformat"
        case .date: "calendar"
        }
    }
}

/// A single cell. Within a column, every non-empty cell matches the column's type.
enum CellValue: Hashable {
    case number(Double)
    case text(String)
    case date(Date)
    case empty

    var number: Double? { if case .number(let d) = self { return d }; return nil }
    var text: String? { if case .text(let s) = self { return s }; return nil }
    var date: Date? { if case .date(let d) = self { return d }; return nil }
    var isEmpty: Bool { if case .empty = self { return true }; return false }
}

struct DataColumn: Hashable, Codable, Identifiable {
    var name: String
    var type: ColumnType
    /// Calculated column: DAX-like expression evaluated for each row.
    var expression: String? = nil
    var id: String { name }
}

struct DataSource: Hashable, Codable {
    var path: String
    var sheet: String?
}

struct DataTable: Identifiable {
    var id = UUID()
    var name: String
    var columns: [DataColumn]
    var rows: [[CellValue]]
    var source: DataSource?

    func columnIndex(_ name: String) -> Int? {
        columns.firstIndex { $0.name == name }
    }
}

extension DataTable: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, columns, source, rowCount, data }

    /// Column-oriented payload: keeps saved reports compact.
    private struct ColumnPayload: Codable {
        var n: [Double?]?
        var t: [String?]?
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(columns, forKey: .columns)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encode(rows.count, forKey: .rowCount)
        var payloads: [ColumnPayload] = []
        for (i, col) in columns.enumerated() {
            switch col.type {
            case .text: payloads.append(ColumnPayload(n: nil, t: rows.map { $0[i].text }))
            case .number: payloads.append(ColumnPayload(n: rows.map { $0[i].number }, t: nil))
            case .date: payloads.append(ColumnPayload(n: rows.map { $0[i].date?.timeIntervalSince1970 }, t: nil))
            }
        }
        try c.encode(payloads, forKey: .data)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        columns = try c.decode([DataColumn].self, forKey: .columns)
        source = try c.decodeIfPresent(DataSource.self, forKey: .source)
        let count = try c.decode(Int.self, forKey: .rowCount)
        let payloads = try c.decode([ColumnPayload].self, forKey: .data)
        var rows = Array(repeating: Array(repeating: CellValue.empty, count: columns.count), count: count)
        for (i, col) in columns.enumerated() where i < payloads.count {
            let p = payloads[i]
            for r in 0..<count {
                switch col.type {
                case .text: if let s = p.t?[r] { rows[r][i] = .text(s) }
                case .number: if let d = p.n?[r] { rows[r][i] = .number(d) }
                case .date: if let d = p.n?[r] { rows[r][i] = .date(Date(timeIntervalSince1970: d)) }
                }
            }
        }
        self.rows = rows
    }
}

// MARK: - Fields

enum DateLevel: String, Codable, CaseIterable {
    case year, quarter, month, day

    var label: String {
        switch self {
        case .year: L("Année")
        case .quarter: L("Trimestre")
        case .month: L("Mois")
        case .day: L("Jour")
        }
    }
}

struct FieldRef: Hashable, Codable {
    var table: String
    var column: String
    var dateLevel: DateLevel? = nil

    var displayName: String {
        if let l = dateLevel { return "\(column) (\(l.label))" }
        return column
    }

    /// Identity of the underlying column, ignoring the date level.
    var columnKey: String { table + "\u{1F}" + column }

    static let payloadPrefix = "prisme-field:"
    var payload: String { Self.payloadPrefix + columnKey }

    init(table: String, column: String, dateLevel: DateLevel? = nil) {
        self.table = table
        self.column = column
        self.dateLevel = dateLevel
    }

    init?(payload: String) {
        guard payload.hasPrefix(Self.payloadPrefix) else { return nil }
        let parts = payload.dropFirst(Self.payloadPrefix.count).split(separator: "\u{1F}", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        self.init(table: String(parts[0]), column: String(parts[1]))
    }
}

enum Aggregation: String, Codable, CaseIterable {
    case sum, average, min, max, count, distinctCount

    var label: String {
        switch self {
        case .sum: L("Somme")
        case .average: L("Moyenne")
        case .min: L("Minimum")
        case .max: L("Maximum")
        case .count: L("Nombre")
        case .distinctCount: L("Nombre (distinct)")
        }
    }

    var isNumericOnly: Bool { [.sum, .average, .min, .max].contains(self) }
}

struct ValueField: Hashable, Codable, Identifiable {
    var id = UUID()
    var field: FieldRef
    var aggregation: Aggregation
    /// When true, `field.column` is the name of a measure of `field.table` (aggregation is ignored).
    var isMeasure: Bool? = nil

    var measure: Bool { isMeasure == true }

    var displayName: String {
        if measure { return field.column }
        switch aggregation {
        case .distinctCount: return L("Nombre distinct de %@", field.column)
        default: return L("%@ de %@", aggregation.label, field.column)
        }
    }
}

// MARK: - Report

enum VisualType: String, Codable, CaseIterable, Identifiable {
    case column, bar, line, area, pie, donut, card, table, slicer, matrix, scatter, combo, gauge, kpi, map
    var id: String { rawValue }

    var label: String {
        switch self {
        case .column: L("Histogramme")
        case .bar: L("Graphique à barres")
        case .line: L("Courbe")
        case .area: L("Aires")
        case .pie: L("Secteurs")
        case .donut: L("Anneau")
        case .card: L("Carte")
        case .table: L("Tableau")
        case .slicer: L("Segment")
        case .matrix: L("Matrice")
        case .scatter: L("Nuage de points")
        case .combo: L("Histogramme et courbe")
        case .gauge: L("Jauge")
        case .kpi: L("Indicateur clé (KPI)")
        case .map: L("Carte géographique")
        }
    }

    var symbol: String {
        switch self {
        case .column: "chart.bar.fill"
        case .bar: "chart.bar.doc.horizontal"
        case .line: "chart.xyaxis.line"
        case .area: "chart.line.uptrend.xyaxis"
        case .pie: "chart.pie.fill"
        case .donut: "circle.circle"
        case .card: "123.rectangle"
        case .table: "tablecells"
        case .slicer: "line.3.horizontal.decrease.circle"
        case .matrix: "square.grid.3x3"
        case .scatter: "chart.dots.scatter"
        case .combo: "chart.bar.xaxis"
        case .gauge: "gauge.with.dots.needle.67percent"
        case .kpi: "arrow.up.right.circle"
        case .map: "map"
        }
    }

    var isCartesian: Bool { [.column, .bar, .line, .area].contains(self) }
    /// Charts drawn on category / value axes (formatting options apply).
    var isAxisChart: Bool { isCartesian || self == .combo || self == .scatter }
    /// Value wells are fixed slots (X, Y, size…) rather than a list.
    var usesValueSlots: Bool { [.scatter, .combo, .gauge, .kpi, .map].contains(self) }
    /// The value list can hold several fields.
    var allowsManyValues: Bool { [.table, .matrix].contains(self) || isCartesian }
    var isPie: Bool { self == .pie || self == .donut }

    var defaultSize: CGSize {
        switch self {
        case .card: CGSize(width: 260, height: 130)
        case .slicer: CGSize(width: 240, height: 260)
        case .table: CGSize(width: 480, height: 300)
        case .pie, .donut: CGSize(width: 380, height: 280)
        case .matrix: CGSize(width: 520, height: 300)
        case .gauge: CGSize(width: 300, height: 210)
        case .kpi: CGSize(width: 300, height: 180)
        case .map: CGSize(width: 480, height: 340)
        default: CGSize(width: 460, height: 290)
        }
    }
}

enum SortMode: String, Codable, CaseIterable {
    case auto, valueDesc, valueAsc, categoryAsc, categoryDesc

    var label: String {
        switch self {
        case .auto: L("Automatique")
        case .valueDesc: L("Valeur décroissante")
        case .valueAsc: L("Valeur croissante")
        case .categoryAsc: L("Catégorie (A → Z)")
        case .categoryDesc: L("Catégorie (Z → A)")
        }
    }
}

/// Per-visual formatting options (all optional in saved files).
struct VisualFormat: Hashable, Codable {
    var dataLabels = false
    var showLegend = true
    var gridlines = true
    var axisTitles = false
    /// Hex color (RRGGBB) of the first series, overriding the theme.
    var color: String?
    var valueFormat: MeasureFormat = .auto
    var sort: SortMode = .auto
    /// Keep only the first N categories after sorting (0 = all).
    var topN = 0
    /// Table visual: column used for sorting, and its direction.
    var tableSortColumn: Int?
    var tableSortDescending = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case dataLabels, showLegend, gridlines, axisTitles, color, valueFormat, sort, topN, tableSortColumn, tableSortDescending
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dataLabels = try c.decodeIfPresent(Bool.self, forKey: .dataLabels) ?? false
        showLegend = try c.decodeIfPresent(Bool.self, forKey: .showLegend) ?? true
        gridlines = try c.decodeIfPresent(Bool.self, forKey: .gridlines) ?? true
        axisTitles = try c.decodeIfPresent(Bool.self, forKey: .axisTitles) ?? false
        color = try c.decodeIfPresent(String.self, forKey: .color)
        valueFormat = try c.decodeIfPresent(MeasureFormat.self, forKey: .valueFormat) ?? .auto
        sort = try c.decodeIfPresent(SortMode.self, forKey: .sort) ?? .auto
        topN = try c.decodeIfPresent(Int.self, forKey: .topN) ?? 0
        tableSortColumn = try c.decodeIfPresent(Int.self, forKey: .tableSortColumn)
        tableSortDescending = try c.decodeIfPresent(Bool.self, forKey: .tableSortDescending) ?? false
    }
}

struct Visual: Identifiable, Hashable, Codable {
    var id = UUID()
    var type: VisualType
    var frame: CGRect
    var title: String = ""
    var showTitle = true
    var axis: [FieldRef] = []
    var legend: FieldRef?
    var values: [ValueField] = []
    var slicerSelection: Set<String> = []
    var format: VisualFormat?

    var fmt: VisualFormat { format ?? VisualFormat() }

    var autoTitle: String {
        switch type {
        case .card, .gauge, .kpi: return values.first?.displayName ?? type.label
        case .slicer: return axis.first?.displayName ?? type.label
        case .table, .matrix:
            let names = axis.map(\.displayName) + [legend].compactMap { $0?.displayName } + values.map(\.displayName)
            return names.isEmpty ? type.label : names.joined(separator: ", ")
        default:
            let v = (type.isPie ? Array(values.prefix(1)) : values).map(\.displayName).joined(separator: ", ")
            guard !v.isEmpty else { return type.label }
            var t = v
            if let a = axis.first { t += L(" par %@", a.displayName) }
            if type.isCartesian, let l = legend { t += L(" et %@", l.displayName) }
            return t
        }
    }

    var displayTitle: String { title.isEmpty ? autoTitle : title }

    var allFields: [FieldRef] { axis + [legend].compactMap { $0 } + values.map(\.field) }
}

struct PageFilter: Identifiable, Hashable, Codable {
    var id = UUID()
    var field: FieldRef
    var selected: Set<String> = []
}

struct ReportPage: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var visuals: [Visual] = []
    var filters: [PageFilter] = []
}

enum PageSize {
    static let width: CGFloat = 1280
    static let height: CGFloat = 720
}

enum MeasureFormat: String, Codable, CaseIterable {
    case auto, integer, decimal, percent, currency

    var label: String {
        switch self {
        case .auto: L("Automatique")
        case .integer: L("Nombre entier")
        case .decimal: L("Décimal (2)")
        case .percent: L("Pourcentage")
        case .currency: L("Monétaire (€)")
        }
    }
}

/// A calculated measure (DAX-like expression), shown in its home table.
struct Measure: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var table: String
    var expression: String
    var format: MeasureFormat = .auto

    var field: FieldRef { FieldRef(table: table, column: name) }
}

/// Many-to-one link: each row of `fromTable` matches at most one row of `toTable`.
/// Filters flow from the "one" side (`toTable`) to the "many" side (`fromTable`).
struct Relationship: Identifiable, Hashable, Codable {
    var id = UUID()
    var fromTable: String
    var fromColumn: String
    var toTable: String
    var toColumn: String
    var isActive = true

    var label: String { "\(fromTable)[\(fromColumn)] → \(toTable)[\(toColumn)]" }

    func involves(_ table: String) -> Bool { fromTable == table || toTable == table }
}

struct ReportDocument: Codable {
    var version = 2
    var tables: [DataTable]
    var pages: [ReportPage]
    var relationships: [Relationship] = []
    var measures: [Measure] = []
    var modelLayout: [String: CGPoint] = [:]
    var theme: String?

    init(tables: [DataTable], pages: [ReportPage], relationships: [Relationship], measures: [Measure],
         modelLayout: [String: CGPoint], theme: String?) {
        self.theme = theme
        self.version = 3
        self.tables = tables
        self.pages = pages
        self.relationships = relationships
        self.measures = measures
        self.modelLayout = modelLayout
    }

    private enum CodingKeys: String, CodingKey { case version, tables, pages, relationships, measures, modelLayout, theme }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        tables = try c.decode([DataTable].self, forKey: .tables)
        pages = try c.decode([ReportPage].self, forKey: .pages)
        relationships = try c.decodeIfPresent([Relationship].self, forKey: .relationships) ?? []
        measures = try c.decodeIfPresent([Measure].self, forKey: .measures) ?? []
        modelLayout = try c.decodeIfPresent([String: CGPoint].self, forKey: .modelLayout) ?? [:]
        theme = try c.decodeIfPresent(String.self, forKey: .theme)
    }
}
