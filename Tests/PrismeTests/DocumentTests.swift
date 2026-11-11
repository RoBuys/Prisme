import Foundation
import Testing
@testable import Prisme

extension PrismeTests {
    @Suite struct DocumentTests {
        @Test func saveAndReopenKeepsEverything() throws {
            let st = Fixture.sample()
            st.theme = "ocean"
            st.addBookmark()
            st.addStep(TransformStep(kind: .filterRows, column: "Montant", text: "1000", op: .greater), to: "Ventes")
            _ = st.saveColumn(MeasureDraft(id: nil, name: "Double", table: "Ventes", expression: "Ventes[Montant] * 2", format: .auto, isColumn: true))
            let data = try JSONEncoder().encode(ReportDocument(tables: st.tables, pages: st.pages, relationships: st.relationships,
                                                               measures: st.measures, modelLayout: st.modelLayout, theme: st.theme,
                                                               bookmarks: st.bookmarks))
            let url = Fixture.temp("r.prisme")
            try data.write(to: url)
            let other = AppState()
            other.open(url)
            #expect(other.alertMessage == nil)
            #expect(other.tables.map(\.name) == st.tables.map(\.name))
            #expect(other.table("Ventes").rows == st.table("Ventes").rows)
            #expect(other.table("Ventes").steps.count == 1)
            #expect(other.table("Ventes").base.first?.rows.count == 2822)
            #expect(other.table("Ventes").columns.last?.expression == "Ventes[Montant] * 2")
            #expect(other.relationships == st.relationships)
            #expect(other.measures == st.measures)
            #expect(other.pages == st.pages)
            #expect(other.theme == "ocean")
            #expect(other.bookmarks.count == 1)
        }

        @Test func opensVersion1Documents() throws {
            // A document written before relationships, measures, themes and bookmarks existed.
            let json = #"{"version":1,"tables":[{"id":"6F2A1C3E-0000-4000-8000-000000000001","name":"T","columns":[{"name":"a","type":"number"}],"rowCount":2,"data":[{"n":[1,2]}]}],"pages":[{"id":"6F2A1C3E-0000-4000-8000-000000000002","name":"P","visuals":[],"filters":[]}]}"#
            let url = Fixture.temp("old.prisme")
            try json.write(to: url, atomically: true, encoding: .utf8)
            let st = AppState()
            st.open(url)
            #expect(st.alertMessage == nil)
            #expect(st.table("T").rows == [[.number(1)], [.number(2)]])
            #expect(st.relationships.isEmpty && st.measures.isEmpty && st.bookmarks.isEmpty)
        }

        @Test func undoRedo() {
            let st = Fixture.sample()
            st.resetHistory()
            let n = st.currentPage.visuals.count
            st.deleteVisual(st.currentPage.visuals[0].id)
            Thread.sleep(forTimeInterval: 0.7)
            st.deleteTable("Régions")
            #expect(st.tables.count == 2 && st.canUndo)
            st.undo()
            #expect(st.tables.count == 3 && st.currentPage.visuals.count == n - 1)
            st.undo()
            #expect(st.currentPage.visuals.count == n && !st.canUndo)
            st.redo()
            #expect(st.currentPage.visuals.count == n - 1 && st.canRedo)
        }

        @Test func renamingATableUpdatesReferences() {
            let st = Fixture.sample()
            st.renameTable("Ventes", to: "Sales")
            #expect(st.measures.first { $0.name == "Chiffre d'affaires" }?.expression == "SUM(Sales[Montant])")
            #expect(st.relationships.allSatisfy { $0.fromTable == "Sales" })
            #expect(st.pages.flatMap(\.visuals).flatMap(\.allFields).allSatisfy { $0.table != "Ventes" })
            #expect(close((try? st.number("[Chiffre d'affaires]", table: "Sales")) ?? 0, 1_415_422))
        }

        @Test func everyInterfaceStringHasAnEnglishTranslation() throws {
            let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Sources/Prisme")
            let files = try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
            let code = try files.map { try String(contentsOf: sources.appendingPathComponent($0), encoding: .utf8) }.joined()
            let re = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
            let keys = Set(re.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap {
                Range($0.range(at: 1), in: code).map { String(code[$0]).replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\n"#, with: "\n") }
            })
            let missing = keys.filter { Strings.en[$0] == nil }.sorted()
            #expect(missing.isEmpty, "Missing English strings: \(missing)")
        }
    }

    @Suite struct PowerBIImportTests {
        private func imported(_ name: String) -> AppState {
            Loc.language = .fr
            let st = AppState()
            st.importPowerBI(Fixture.url(name), askForFiles: false)
            return st
        }

        @Test func pbitTemplate() throws {
            let st = imported("Test.pbit")
            #expect(st.tables.map(\.name) == ["Ventes", "Régions"])
            #expect(st.table("Ventes").rows.count == 4)
            #expect(st.table("Ventes").columns.last?.expression == "Ventes[Montant] * 2")
            #expect(st.measures.map(\.name) == ["CA", "Part", "Bizarre"])
            #expect(st.measures[0].format == .currency && st.measures[1].format == .percent)
            #expect(st.relationships.map(\.label) == ["Ventes[Région] → Régions[Région]"])
            #expect(st.pages.map(\.name) == ["Synthèse", "Vide"])
            let visuals = st.pages[0].visuals
            #expect(visuals.map(\.type) == [.column, .card, .line, .slicer, .table, .text])
            #expect(visuals[0].title == "Ventes par région")
            #expect(visuals[0].frame == CGRect(x: 0, y: 0, width: 640, height: 360))   // 1600×900 scaled to 1280×720
            #expect(visuals[2].axis.first?.dateLevel == .year)
            #expect(Engine.cardValue(visuals[1], st.model, [])?.value.filter(\.isNumber) == "80000")
            let table = Engine.tableData(visuals[4], st.model, [])
            #expect(table.raw.map { $0[2] } == ["0.375", "0.625"])
            #expect(st.alertMessage?.contains("textbox") == false)   // text boxes are imported
            #expect(st.alertMessage?.contains("Bizarre") == true)
        }

        @Test func pbipProjectWithTMDLAndPBIR() throws {
            let st = imported("Proj.pbip")
            #expect(Set(st.tables.map(\.name)) == ["Ventes", "Régions"])
            #expect(st.measures.map(\.name) == ["Chiffre d'affaires", "Marge"])
            #expect(st.measures[1].expression == "VAR x = [Chiffre d'affaires]\nRETURN x * 0.3")
            #expect(st.table("Ventes").columns.last?.name == "Grosse vente")
            #expect(st.relationships.count == 1)
            let v = st.pages[0].visuals
            #expect(v.map(\.type) == [.donut, .matrix])
            #expect(v[0].title == "CA par zone")
            let m = Engine.matrixData(v[1], st.model, [])
            #expect(m.headers == ["Canal", "Est", "Nord", "Sud", "Total"])
            #expect(close((try? st.number("[Marge]")) ?? 0, 240))
        }

        @Test func pbixLayoutOnly() {
            let st = imported("Test.pbix")
            #expect(Set(st.tables.map(\.name)) == ["Ventes", "Régions"])
            #expect(st.tables.allSatisfy { $0.rows.isEmpty })
            #expect(Set(st.measures.map(\.name)) == ["CA", "Part"])
            #expect(st.pages[0].visuals.count == 6)
        }

        @Test func tmdlNames() {
            #expect(PowerBIImporter.tmdlName("'Chiffre d''affaires'") == "Chiffre d'affaires")
            #expect(PowerBIImporter.tmdlQualified("'My Table'.'My Col'")! == ("My Table", "My Col"))
            #expect(PowerBIImporter.tmdlQualified("Ventes.Région")! == ("Ventes", "Région"))
        }

        @Test func mSources() {
            let csv = MSource.source(#"let Source = Csv.Document(File.Contents("C:\data\v.csv"),[Delimiter=";"]) in Source"#)
            #expect(csv?.1 == #"C:\data\v.csv"#)
            let xl = MSource.source(#"Excel.Workbook(File.Contents("x.xlsx"), null, true){[Item="Feuil1",Kind="Sheet"]}[Data]"#)
            #expect(xl?.0.sheet == "Feuil1")
            let pg = MSource.source(#"PostgreSQL.Database("db.local:6543", "shop"){[Schema="public",Item="orders"]}[Data]"#)
            #expect(pg?.0.kind == .postgres && pg?.0.port == 6543 && pg?.0.query == "SELECT * FROM public.orders")
            #expect(MSource.source(#"Sql.Database("srv", "db")"#) == nil)
        }
    }
}
