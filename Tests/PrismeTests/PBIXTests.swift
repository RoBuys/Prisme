import Foundation
import Compression
import Testing
@testable import Prisme

extension PrismeTests {
    @Suite struct PBIXTests {
        @Test func decompressesTheDataModel() throws {
            let dir = try PowerBIImporter.unzip(Fixture.url("AISample.pbix"))
            defer { try? FileManager.default.removeItem(at: dir) }
            let raw = try Data(contentsOf: dir.appendingPathComponent("DataModel"))
            let backup = try PBIXDataModel.decompress(raw)
            #expect(backup.count > raw.count)
            let db = try #require(PBIXDataModel.metadataDatabase(in: backup))
            #expect(db.prefix(15) == Data("SQLite format 3".utf8))
        }

        @Test func readsTheRealSampleModel() throws {
            Loc.language = .fr
            let st = AppState()
            st.importPowerBI(Fixture.url("AISample.pbix"), askForFiles: false)
            #expect(st.tables.count == 12)
            #expect(st.tables.contains { $0.name == "Opportunities" && $0.columns.contains { $0.name == "Status" } })
            #expect(st.measures.count == 22)
            let invalid = st.measures.filter { MeasureCompiler.validate($0.expression, home: $0.table, name: $0.name, st.model) != nil }
            #expect(invalid.isEmpty, "\(invalid.map(\.name))")
            #expect(st.relationships.count == 12)
            #expect(st.relationships.contains { $0.label == "Opportunities[AccountSeq] → Accounts[AccountSeq]" })
            #expect(st.pages.map(\.name) == ["Key Influencers", "Decomposition Tree", "Anomaly Detection"])
            // What-if parameter table: GENERATESERIES(-80, 20, 10).
            #expect(st.table("Opportunity Forecast Adjustment").rows.count == 11)
        }

        @Test func daxCommentsInAndCountax() throws {
            let st = Fixture.sample()
            #expect(close(try st.number("SUM(Ventes[Montant]) -- commentaire\n + 0 /* bloc */ // fin"), 1_415_422))
            #expect(close(try st.number(#"CALCULATE([Chiffre d'affaires], Ventes[Canal] IN {"Magasin", "En ligne"})"#), 1_415_422))
            #expect(close(try st.number(#"CALCULATE([Chiffre d'affaires], Ventes[Canal] IN {"Magasin"})"#), 603_375))
            #expect(close(try st.number("COUNTAX(Ventes, Ventes[Montant])"), 2822))
            #expect(close(try st.number(#"COUNTAX(FILTER(KEEPFILTERS(Ventes), Ventes[Canal] = "Magasin"), Ventes[Montant])"#), try st.number(#"CALCULATE(COUNTROWS(Ventes), Ventes[Canal] = "Magasin")"#)))
            #expect(close(try st.number("MROUND(17, 5) + ROUNDUP(1.21, 1) + ROUNDDOWN(1.29, 1)"), 15 + 1.3 + 1.2))
            #expect(try st.value(#"IF("b" IN {"a", "b"}, 1, 0)"#).number == 1)
        }

        @Test func decodesEnterDataTables() throws {
            let json = Data(#"[["7","January"],["8","February"]]"#.utf8)
            var out = [UInt8](repeating: 0, count: 1024)
            let n = json.withUnsafeBytes { src in
                compression_encode_buffer(&out, out.count, src.bindMemory(to: UInt8.self).baseAddress!, json.count, nil, COMPRESSION_ZLIB)
            }
            let b64 = Data(out.prefix(n)).base64EncodedString()
            let m = #"let Source = Table.FromRows(Json.Document(Binary.Decompress(Binary.FromText(""# + b64
                + #"", BinaryEncoding.Base64), Compression.Deflate)), let _t = ((type text) meta [Serialized.Text = true]) in type table [ID = _t, #"Month name" = _t]) in Source"#
            let grid = try #require(MSource.embeddedTable(m))
            #expect(grid.count == 3)
            let t = try #require(Importer.makeTable(name: "M", grid: grid, source: nil))
            #expect(t.columns.map(\.name) == ["ID", "Month name"])
            #expect(t.rows[1] == [.number(8), .text("February")])
        }
    }
}
