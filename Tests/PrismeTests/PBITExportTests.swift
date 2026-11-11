import Foundation
import Testing
@testable import Prisme

extension PrismeTests {
    @Suite struct PBITExportTests {
        @Test func roundTripsThroughImport() throws {
            let st = Fixture.sample()
            #expect(st.saveCalculatedTable(name: "CA par région",
                                           expression: "SUMMARIZE(Ventes, Ventes[Région], \"CA\", [Chiffre d'affaires])") == nil)
            // A column name that needs quoting in M.
            st.renameColumnForTest(table: "Régions", from: "Zone", to: "Zone, \"nom\" [x]")
            let r = try st.pbitData()
            let url = Fixture.temp("Export.pbit")
            try r.data.write(to: url)

            // Container: UTF-16 parts, as Power BI writes them.
            let dir = try PowerBIImporter.unzip(url)
            defer { try? FileManager.default.removeItem(at: dir) }
            let version = try Data(contentsOf: dir.appendingPathComponent("Version"))
            #expect(version == Data([0x31, 0, 0x2E, 0, 0x32, 0, 0x38, 0]))
            let schema = try Data(contentsOf: dir.appendingPathComponent("DataModelSchema"))
            #expect(String(data: schema, encoding: .utf16LittleEndian)?.hasPrefix("{") == true)
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("[Content_Types].xml").path))

            let back = AppState()
            back.importPowerBI(url, askForFiles: false)
            #expect(Set(back.tables.map(\.name)) == Set(st.tables.map(\.name)))
            for t in st.tables {
                let u = back.table(t.name)
                #expect(u.rows.count == t.rows.count, "\(t.name)")
                #expect(u.columns.map(\.name) == t.columns.map(\.name), "\(t.name)")
                #expect(u.columns.map(\.type) == t.columns.map(\.type), "\(t.name)")
            }
            #expect(back.table("Régions").columns.contains { $0.name == "Zone, \"nom\" [x]" })
            #expect(back.table("Ventes").rows.prefix(50) == st.table("Ventes").rows.prefix(50))
            #expect(back.table("CA par région").expression == st.table("CA par région").expression)
            #expect(back.measures.map(\.name) == st.measures.map(\.name))
            #expect(back.measures.map(\.format) == st.measures.map(\.format))
            #expect(close(try back.number("[Chiffre d'affaires]"), 1_415_422))
            #expect(back.relationships.count == st.relationships.count)
            #expect(back.pages.map(\.name) == st.pages.map(\.name))
            for (p, q) in zip(st.pages, back.pages) {
                let exported = p.visuals.filter { PBITExporter.visualTypes[$0.type] != nil }
                #expect(q.visuals.map(\.type) == exported.map(\.type), "\(p.name)")
                #expect(q.visuals.map(\.values.count) == exported.map(\.values.count), "\(p.name)")
                // Date levels (year, month…) need Power BI's auto date tables: the date column itself is exported.
                func plain(_ v: [Visual]) -> [[FieldRef]] { v.map { $0.axis.map { FieldRef(table: $0.table, column: $0.column) } } }
                #expect(plain(q.visuals) == plain(exported), "\(p.name)")
            }
        }

        @Test func exportsTheRealSample() throws {
            Loc.language = .fr
            let st = AppState()
            st.importPowerBI(Fixture.url("AISample.pbix"), askForFiles: false)
            let url = Fixture.temp("AISample.pbit")
            try st.pbitData().data.write(to: url)
            let back = AppState()
            back.importPowerBI(url, askForFiles: false)
            #expect(back.tables.count == st.tables.count)
            #expect(back.table("Opportunities").rows.count == 20_000)
            #expect(back.measures.count == st.measures.count)
            #expect(back.relationships.count == st.relationships.count)
            #expect(try back.number("COUNTROWS(Opportunities)", table: "Opportunities") == 20_000)
        }

        @Test func zipIsReadable() throws {
            var z = ZipWriter()
            z.add("a.txt", Data("hello".utf8))
            z.add("dir/b.txt", Data())
            let url = Fixture.temp("t.zip")
            try z.finish().write(to: url)
            let dir = try PowerBIImporter.unzip(url)
            #expect(try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8) == "hello")
            #expect(ZipWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        }
    }
}

extension AppState {
    /// Renames a column and the references to it (test helper).
    func renameColumnForTest(table: String, from old: String, to new: String) {
        guard let ti = tables.firstIndex(where: { $0.name == table }), let ci = tables[ti].columnIndex(old) else { return }
        tables[ti].columns[ci].name = new
        renameColumnReferences(table: table, from: old, to: new)
    }
}
