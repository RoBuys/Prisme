import Foundation

/// A cell as read from a file, before the column type is decided.
enum RawCell {
    case empty
    case text(String)
    case number(Double)
    case date(Date)
}

struct ImportError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum Importer {
    static let supportedExtensions = ["csv", "tsv", "txt", "xlsx", "xlsm"]

    /// Loads every table contained in a file (one per Excel sheet).
    static func load(_ url: URL) throws -> [DataTable] {
        let ext = url.pathExtension.lowercased()
        let base = url.deletingPathExtension().lastPathComponent
        switch ext {
        case "csv", "tsv", "txt":
            let grid = try readCSV(url)
            guard let t = makeTable(name: base, grid: grid, source: DataSource(path: url.path)) else {
                throw ImportError(message: "Le fichier « \(url.lastPathComponent) » ne contient aucune donnée.")
            }
            return [t]
        case "xlsx", "xlsm":
            let sheets = try XLSXReader.read(url)
            let tables = sheets.compactMap { sheet in
                makeTable(name: sheets.count == 1 ? base : sheet.name, grid: sheet.rows,
                          source: DataSource(path: url.path, sheet: sheet.name))
            }
            guard !tables.isEmpty else {
                throw ImportError(message: "Le classeur « \(url.lastPathComponent) » ne contient aucune feuille avec des données.")
            }
            return tables
        case "xls":
            throw ImportError(message: "Le format .xls (Excel 97-2003) n'est pas pris en charge. Enregistrez le fichier au format .xlsx.")
        default:
            throw ImportError(message: "Format de fichier non pris en charge : .\(ext)")
        }
    }

    // MARK: Table building

    static func makeTable(name: String, grid: [[RawCell]], source: DataSource?) -> DataTable? {
        func isEmpty(_ c: RawCell) -> Bool { if case .empty = c { return true }; return false }
        func isBlank(_ row: [RawCell]) -> Bool { row.allSatisfy(isEmpty) }
        var rows = grid
        while let first = rows.first, isBlank(first) { rows.removeFirst() }
        while let last = rows.last, isBlank(last) { rows.removeLast() }
        guard let header = rows.first else { return nil }
        let body = rows.dropFirst().filter { !isBlank($0) }

        var width = header.count
        for r in body { width = max(width, r.count) }
        // Drop trailing columns that have neither a header nor data.
        while width > 0 {
            let i = width - 1
            let headerEmpty = i >= header.count || isEmpty(header[i])
            let dataEmpty = body.allSatisfy { row in i >= row.count || isEmpty(row[i]) }
            if headerEmpty && dataEmpty { width -= 1 } else { break }
        }
        guard width > 0 else { return nil }

        var names: [String] = []
        for i in 0..<width {
            var n = i < header.count ? rawText(header[i]) : ""
            if n.isEmpty { n = "Colonne \(i + 1)" }
            var candidate = n, k = 2
            while names.contains(candidate) { candidate = "\(n) (\(k))"; k += 1 }
            names.append(candidate)
        }

        var columns: [DataColumn] = []
        var columnValues: [[CellValue]] = []
        for i in 0..<width {
            let cells = body.map { i < $0.count ? $0[i] : .empty }
            let (type, values) = inferColumn(cells)
            columns.append(DataColumn(name: names[i], type: type))
            columnValues.append(values)
        }
        let tableRows = (0..<body.count).map { r in columnValues.map { $0[r] } }
        return DataTable(name: name, columns: columns, rows: tableRows, source: source)
    }

    static func rawText(_ c: RawCell) -> String {
        switch c {
        case .empty: ""
        case .text(let s): s.trimmingCharacters(in: .whitespacesAndNewlines)
        case .number(let d): Fmt.plain(d)
        case .date(let d): Fmt.day(d)
        }
    }

    static func inferColumn(_ cells: [RawCell]) -> (ColumnType, [CellValue]) {
        var allNumber = true, allDate = true, any = false
        var texts: [String] = []
        for c in cells {
            switch c {
            case .empty: continue
            case .number: any = true; allDate = false
            case .date: any = true; allNumber = false
            case .text(let s):
                any = true
                texts.append(s)
                if allNumber && parseNumber(s) == nil { allNumber = false }
            }
            if !allNumber && !allDate { break }
        }
        guard any else { return (.text, cells.map { _ in .empty }) }
        if allNumber { return (.number, coerce(cells, to: .number)) }
        if allDate && (texts.isEmpty || dateFormatter(for: texts) != nil) {
            return (.date, coerce(cells, to: .date))
        }
        return (.text, coerce(cells, to: .text))
    }

    static func coerce(_ cells: [RawCell], to type: ColumnType) -> [CellValue] {
        switch type {
        case .text:
            return cells.map { c in
                let s = rawText(c)
                return s.isEmpty ? .empty : .text(s)
            }
        case .number:
            return cells.map { c in
                switch c {
                case .number(let d): .number(d)
                case .text(let s): parseNumber(s).map { .number($0) } ?? .empty
                default: .empty
                }
            }
        case .date:
            let texts = cells.compactMap { c -> String? in if case .text(let s) = c { return s }; return nil }
            let fmt = texts.isEmpty ? nil : dateFormatter(for: texts, requireAll: false)
            return cells.map { c in
                switch c {
                case .date(let d): return .date(d)
                case .text(let s):
                    if let d = fmt?.date(from: s.trimmingCharacters(in: .whitespaces)) { return .date(d) }
                    return .empty
                case .number(let n) where n > 0 && n < 2_958_465:
                    return .date(excelDate(n))
                default: return .empty
                }
            }
        }
    }

    static func cellsToRaw(_ values: [CellValue]) -> [RawCell] {
        values.map { v in
            switch v {
            case .empty: .empty
            case .number(let d): .number(d)
            case .text(let s): .text(s)
            case .date(let d): .date(d)
            }
        }
    }

    static func excelDate(_ serial: Double) -> Date {
        Date(timeIntervalSince1970: (serial - 25569) * 86400)
    }

    // MARK: Parsing helpers

    static func parseNumber(_ input: String) -> Double? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var factor = 1.0
        if s.hasSuffix("%") { factor = 0.01; s.removeLast() }
        s = String(s.unicodeScalars.filter {
            !($0 == " " || $0 == "\u{00A0}" || $0 == "\u{202F}" || $0 == "€" || $0 == "$" || $0 == "£" || $0 == "'")
        })
        guard !s.isEmpty, s.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) else { return nil }
        let hasComma = s.contains(","), hasDot = s.contains(".")
        if hasComma && hasDot {
            // The last separator is the decimal one.
            if let c = s.lastIndex(of: ","), let d = s.lastIndex(of: "."), c > d {
                s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        } else if hasComma {
            if s.filter({ $0 == "," }).count > 1 {
                s = s.replacingOccurrences(of: ",", with: "")
            } else {
                s = s.replacingOccurrences(of: ",", with: ".")
            }
        }
        guard let d = Double(s), d.isFinite else { return nil }
        return d * factor
    }

    static let dateFormats = [
        "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
        "d/M/yyyy HH:mm:ss", "d/M/yyyy HH:mm", "d/M/yyyy", "d-M-yyyy", "d.M.yyyy", "yyyy/M/d", "M/d/yyyy",
    ]

    private static let formatters: [DateFormatter] = dateFormats.map { f in
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = f
        df.isLenient = false
        return df
    }

    /// Finds a date format that parses every sample (or most of them when `requireAll` is false).
    static func dateFormatter(for samples: [String], requireAll: Bool = true) -> DateFormatter? {
        let trimmed = samples.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = trimmed.first, first.count >= 6, first.first?.isNumber == true else { return nil }
        let probe = Array(trimmed.prefix(50))
        var best: (DateFormatter, Int)?
        for f in formatters {
            let ok = probe.filter { f.date(from: $0) != nil }.count
            if ok == probe.count {
                if !requireAll || trimmed.allSatisfy({ f.date(from: $0) != nil }) { return f }
            } else if !requireAll, ok > 0, ok > (best?.1 ?? 0) {
                best = (f, ok)
            }
        }
        return best?.0
    }

    // MARK: CSV

    static func readCSV(_ url: URL) throws -> [[RawCell]] {
        let data = try Data(contentsOf: url)
        guard var s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
            throw ImportError(message: "Impossible de lire l'encodage du fichier « \(url.lastPathComponent) ».")
        }
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        let delimiter: Unicode.Scalar = url.pathExtension.lowercased() == "tsv" ? "\t" : detectDelimiter(s)
        return parseCSV(s, delimiter: delimiter).map { row in
            row.map { f in
                let t = f.trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? .empty : .text(t)
            }
        }
    }

    static func detectDelimiter(_ s: String) -> Unicode.Scalar {
        let firstLine = s.prefix { $0 != "\n" && $0 != "\r" && $0 != "\r\n" }
        var counts: [Unicode.Scalar: Int] = [",": 0, ";": 0, "\t": 0, "|": 0]
        var inQuotes = false
        for u in firstLine.unicodeScalars {
            if u == "\"" { inQuotes.toggle() }
            if !inQuotes, counts[u] != nil { counts[u]! += 1 }
        }
        let best = counts.max { $0.value < $1.value }
        return (best?.value ?? 0) > 0 ? best!.key : ","
    }

    static func parseCSV(_ s: String, delimiter: Unicode.Scalar) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var it = s.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        func endField() { row.append(String(field)); field = String.UnicodeScalarView() }
        func endRow() { endField(); rows.append(row); row = [] }

        while let u = pending ?? it.next() {
            pending = nil
            if inQuotes {
                if u == "\"" {
                    if let n = it.next() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else {
                    field.append(u)
                }
            } else if u == "\"" && field.isEmpty {
                inQuotes = true
            } else if u == delimiter {
                endField()
            } else if u == "\n" {
                endRow()
            } else if u == "\r" {
                if let n = it.next(), n != "\n" { pending = n }
                endRow()
            } else {
                field.append(u)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}

// MARK: - XLSX

enum XLSXReader {
    struct Sheet {
        var name: String
        var rows: [[RawCell]]
    }

    static func read(_ url: URL) throws -> [Sheet] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("prisme-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-qq", "-o", url.path, "-d", tmp.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw ImportError(message: "Le fichier « \(url.lastPathComponent) » n'est pas un classeur Excel valide.")
        }

        func file(_ path: String) -> Data? { try? Data(contentsOf: tmp.appendingPathComponent(path)) }

        guard let wbData = file("xl/workbook.xml"), let wb = DOMBuilder.parse(wbData) else {
            throw ImportError(message: "Classeur Excel illisible (workbook.xml manquant).")
        }
        var targets: [String: String] = [:]
        if let relsData = file("xl/_rels/workbook.xml.rels"), let rels = DOMBuilder.parse(relsData) {
            for r in rels.descendants("Relationship") {
                if let id = r.attrs["Id"], let t = r.attrs["Target"] { targets[id] = t }
            }
        }
        let shared = file("xl/sharedStrings.xml").map(SharedStringsParser.parse) ?? []
        let dateStyles = file("xl/styles.xml").flatMap(DOMBuilder.parse).map(dateStyleIndexes) ?? []

        var sheets: [Sheet] = []
        for (i, s) in wb.descendants("sheet").enumerated() {
            let name = s.attrs["name"] ?? "Feuille \(i + 1)"
            var path = "xl/worksheets/sheet\(i + 1).xml"
            if let rid = s.attrs["r:id"], let t = targets[rid] {
                path = t.hasPrefix("/") ? String(t.dropFirst()) : "xl/" + t
            }
            guard let data = file(path) else { continue }
            let parser = SheetParser(shared: shared, dateStyles: dateStyles)
            sheets.append(Sheet(name: name, rows: parser.parse(data)))
        }
        return sheets
    }

    static let builtinDateFormats: Set<Int> = Set(14...22).union(27...36).union(45...47).union(50...58)

    static func dateStyleIndexes(_ styles: XNode) -> Set<Int> {
        var custom: [Int: String] = [:]
        for f in styles.descendants("numFmt") {
            if let id = f.attrs["numFmtId"].flatMap(Int.init), let code = f.attrs["formatCode"] { custom[id] = code }
        }
        func isDate(_ id: Int) -> Bool {
            if builtinDateFormats.contains(id) { return true }
            guard let code = custom[id] else { return false }
            var cleaned = ""
            var inQuote = false, inBracket = false
            for ch in code.lowercased() {
                if ch == "\"" { inQuote.toggle(); continue }
                if ch == "[" { inBracket = true; continue }
                if ch == "]" { inBracket = false; continue }
                if !inQuote && !inBracket { cleaned.append(ch) }
            }
            return cleaned.contains("y") || cleaned.contains("d") || cleaned.contains("m")
        }
        var result = Set<Int>()
        guard let xfs = styles.children.first(where: { $0.name == "cellXfs" }) else { return result }
        for (i, xf) in xfs.children.filter({ $0.name == "xf" }).enumerated() {
            if let id = xf.attrs["numFmtId"].flatMap(Int.init), isDate(id) { result.insert(i) }
        }
        return result
    }

    static func columnIndex(_ ref: String) -> Int? {
        var n = 0
        var seen = false
        for u in ref.unicodeScalars {
            guard u.value >= 65 && u.value <= 90 else { break }
            n = n * 26 + Int(u.value - 64)
            seen = true
        }
        return seen ? n - 1 : nil
    }
}

final class XNode {
    let name: String
    let attrs: [String: String]
    var children: [XNode] = []
    var text = ""

    init(name: String, attrs: [String: String]) {
        self.name = name
        self.attrs = attrs
    }

    func descendants(_ n: String) -> [XNode] {
        var out: [XNode] = []
        for c in children {
            if c.name == n { out.append(c) }
            out.append(contentsOf: c.descendants(n))
        }
        return out
    }
}

final class DOMBuilder: NSObject, XMLParserDelegate {
    private var stack: [XNode] = [XNode(name: "#root", attrs: [:])]

    static func parse(_ data: Data) -> XNode? {
        let b = DOMBuilder()
        let p = XMLParser(data: data)
        p.delegate = b
        guard p.parse() else { return nil }
        return b.stack.first?.children.first
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let n = XNode(name: elementName, attrs: attributeDict)
        stack.last?.children.append(n)
        stack.append(n)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if stack.count > 1 { stack.removeLast() }
    }
}

final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inSI = false, inT = false, inPhonetic = false

    static func parse(_ data: Data) -> [String] {
        let s = SharedStringsParser()
        let p = XMLParser(data: data)
        p.delegate = s
        p.parse()
        return s.strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "si": inSI = true; current = ""
        case "rPh": inPhonetic = true
        case "t": if inSI && !inPhonetic { inT = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inT { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "si": strings.append(current); inSI = false
        case "rPh": inPhonetic = false
        case "t": inT = false
        default: break
        }
    }
}

final class SheetParser: NSObject, XMLParserDelegate {
    private let shared: [String]
    private let dateStyles: Set<Int>
    private var cells: [Int: [Int: RawCell]] = [:]
    private var maxCol = -1
    private var row = -1, col = 0, nextCol = 0
    private var type: String?
    private var style = 0
    private var text = ""
    private var capturing = false
    private static let maxColumns = 1000

    init(shared: [String], dateStyles: Set<Int>) {
        self.shared = shared
        self.dateStyles = dateStyles
    }

    func parse(_ data: Data) -> [[RawCell]] {
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
        guard let lastRow = cells.keys.max(), maxCol >= 0 else { return [] }
        return (0...lastRow).map { r in
            let rowCells = cells[r] ?? [:]
            return (0...maxCol).map { rowCells[$0] ?? .empty }
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        switch elementName {
        case "row":
            row = a["r"].flatMap(Int.init).map { $0 - 1 } ?? (row + 1)
            nextCol = 0
        case "c":
            col = a["r"].flatMap(XLSXReader.columnIndex) ?? nextCol
            type = a["t"]
            style = a["s"].flatMap(Int.init) ?? 0
            text = ""
        case "v":
            capturing = true
        case "t":
            if type == "inlineStr" { capturing = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "v", "t":
            capturing = false
        case "c":
            nextCol = col + 1
            guard col < Self.maxColumns, row >= 0 else { return }
            let value = makeCell()
            if case .empty = value { return }
            cells[row, default: [:]][col] = value
            maxCol = max(maxCol, col)
        default: break
        }
    }

    private func makeCell() -> RawCell {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "s":
            guard let i = Int(t), i >= 0, i < shared.count else { return .empty }
            let s = shared[i].trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? .empty : .text(s)
        case "inlineStr", "str":
            return t.isEmpty ? .empty : .text(t)
        case "b":
            return .text(t == "1" ? "VRAI" : "FAUX")
        case "e":
            return .empty
        case "d":
            let f = ISO8601DateFormatter()
            return f.date(from: t).map { .date($0) } ?? (t.isEmpty ? .empty : .text(t))
        default:
            guard let d = Double(t) else { return t.isEmpty ? .empty : .text(t) }
            return dateStyles.contains(style) ? .date(Importer.excelDate(d)) : .number(d)
        }
    }
}
