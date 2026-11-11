import Foundation
import Testing
@testable import Prisme

extension PrismeTests {
    @Suite struct TransformTests {
        let st = Fixture.sample()

        private func rows(_ t: String) -> [[String]] { st.table(t).rows.map { $0.map(Fmt.cell) } }

        @Test func basicStepsAndRemoval() throws {
            let url = Fixture.temp("s.csv")
            try "Date;Ville;Montant\n05/01/2024; Paris ;1200\n06/01/2024;Lyon;50\n07/01/2024;Nice;300\n07/01/2024;Nice;300\n"
                .write(to: url, atomically: true, encoding: .utf8)
            var t = try #require(try Importer.load(url).first)
            t.name = "S"
            st.tables.append(t)
            st.addStep(TransformStep(kind: .trim, column: "Ville"), to: "S")
            st.addStep(TransformStep(kind: .removeDuplicates), to: "S")
            st.addStep(TransformStep(kind: .renameColumn, column: "Ville", text: "City"), to: "S")
            st.addStep(TransformStep(kind: .filterRows, column: "Montant", text: "100", op: .greater), to: "S")
            st.addStep(TransformStep(kind: .addIndex, text: "Index"), to: "S")
            #expect(st.table("S").columns.map(\.name) == ["Date", "City", "Montant", "Index"])
            #expect(rows("S").map { $0[1] } == ["Paris", "Nice"])
            st.removeStep(st.table("S").steps[2].id, from: "S")
            #expect(st.table("S").columns[1].name == "Ville")
            // Refresh replays the recipe on new source data.
            try "Date;Ville;Montant\n01/02/2024;Lille;999\n02/02/2024;Brest;10\n".write(to: url, atomically: true, encoding: .utf8)
            var base = try #require(try Importer.load(url).first)
            base.name = "S"
            let i = st.tables.firstIndex { $0.name == "S" }!
            st.tables[i].base = [base]
            st.reapplySteps(i)
            #expect(rows("S").map { $0[1] } == ["Lille"])
        }

        @Test func mergeGroupPivotUnpivotConditional() {
            var m = TransformStep(kind: .mergeTable, column: "Produit", text: "Produits", text2: "Produit")
            m.columns = ["Catégorie"]
            st.addStep(m, to: "Ventes")
            #expect(st.table("Ventes").columns.last?.name == "Produits.Catégorie")
            var g = TransformStep(kind: .groupBy)
            g.columns = ["Produits.Catégorie", "Canal"]
            g.aggregations = [.init(name: "", aggregation: .count, column: ""), .init(name: "CA", aggregation: .sum, column: "Montant")]
            st.addStep(g, to: "Ventes")
            #expect(st.table("Ventes").rows.count == 8)
            let info = rows("Ventes").first { $0[0] == "Informatique" && $0[1] == "En ligne" }
            #expect(info?[3].filter(\.isNumber) == "394485")
            var p = TransformStep(kind: .pivotColumn, column: "Canal", text: "CA")
            p.aggregation = .sum
            st.addStep(p, to: "Ventes")
            #expect(st.table("Ventes").columns.map(\.name).suffix(2) == ["En ligne", "Magasin"])
            var u = TransformStep(kind: .unpivotColumns, text: "Canal", text2: "CA")
            u.columns = ["En ligne", "Magasin"]
            st.addStep(u, to: "Ventes")
            #expect(st.table("Ventes").rows.count == 8)   // blank cells are dropped
            var c = TransformStep(kind: .conditionalColumn, column: "CA", text: "Niveau", text2: "100000", op: .greater)
            c.text3 = "Fort"
            c.text4 = "[Canal]"
            st.addStep(c, to: "Ventes")
            let levels = Set(rows("Ventes").map { $0.last! })
            #expect(levels == ["Fort", "En ligne", "Magasin"])
            #expect(st.stepErrors["Ventes"]?.isEmpty ?? true)
        }

        @Test func failingStepIsReported() {
            st.addStep(TransformStep(kind: .removeColumn, column: "Inexistante"), to: "Ventes")
            #expect(st.stepErrors["Ventes"]?.count == 1)
            #expect(st.table("Ventes").rows.count == 2822)
        }
    }
}
