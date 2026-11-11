import Foundation
import Testing
@testable import Prisme

extension PrismeTests {
    /// Table functions, table variables and calculated tables.
    @Suite struct DAXTableTests {
        let st = Fixture.sample()

        @Test(arguments: [
            ("COUNTROWS(SUMMARIZE(Ventes, Ventes[Produit]))", 10.0),
            ("COUNTROWS(DISTINCT(Ventes[Produit]))", 10),
            ("SUMX(SUMMARIZE(Ventes, Ventes[Région], \"CA\", SUM(Ventes[Montant])), [CA])", 1_415_422),
            ("MAXX(SUMMARIZE(Ventes, Ventes[Région], \"CA\", [Chiffre d'affaires]), [CA])", 412_123),
            ("SUMX(SUMMARIZE(Ventes, Produits[Catégorie], \"CA\", [Chiffre d'affaires]), [CA])", 1_415_422),
            ("SUMX(ADDCOLUMNS(VALUES(Ventes[Produit]), \"CA\", [Chiffre d'affaires]), [CA])", 1_415_422),
            ("SUMX(SELECTCOLUMNS(Ventes, \"M\", Ventes[Montant]), [M])", 1_415_422),
            ("SUMX(SUMMARIZECOLUMNS(Ventes[Région], \"CA\", [Chiffre d'affaires]), [CA])", 1_415_422),
            ("VAR t = FILTER(Ventes, Ventes[Montant] > 1000) RETURN COUNTROWS(t)", 408),
            ("VAR t = SUMMARIZE(Ventes, Ventes[Produit], \"CA\", [Chiffre d'affaires]) RETURN SUMX(TOPN(3, t, [CA]), [CA])", 1_006_921),
            ("VAR t = FILTER(Produits, Produits[Catégorie] = \"Audio\") RETURN CALCULATE([Chiffre d'affaires], t)", 120_454),
            ("CALCULATE([Chiffre d'affaires], SUMMARIZE(FILTER(Ventes, Ventes[Canal] = \"Magasin\"), Ventes[Canal]))", 603_375),
            ("COUNTROWS(CALCULATETABLE(Ventes, Ventes[Canal] = \"Magasin\")) - CALCULATE(COUNTROWS(Ventes), Ventes[Canal] = \"Magasin\")", 0),
        ])
        func tableFunctions(_ expr: String, _ expected: Double) throws {
            #expect(close(try st.number(expr), expected), "\(expr)")
        }

        @Test func filterOnAddedColumn() throws {
            let v = try st.number("MAXX(FILTER(ADDCOLUMNS(VALUES(Ventes[Région]), \"CA\", [Chiffre d'affaires]), [CA] < 412123), [CA])")
            #expect(v < 412_123 && v > 0)
        }

        @Test func validation() {
            #expect(MeasureCompiler.validate("SUMMARIZE(Ventes, Ventes[Canal])", home: "Ventes", name: "x", st.model) != nil)
            #expect(MeasureCompiler.validate("SUMX(ADDCOLUMNS(Ventes, \"Y\", 1), [Z])", home: "Ventes", name: "x", st.model) != nil)
            #expect(MeasureCompiler.validateTable("SUMMARIZE(Ventes, Ventes[Région], \"CA\", [Chiffre d'affaires])", st.model) == nil)
            #expect(MeasureCompiler.validateTable("SUM(Ventes[Montant])", st.model) != nil)
        }

        @Test func calculatedTable() throws {
            #expect(st.saveCalculatedTable(name: "CA par région",
                                           expression: "SUMMARIZE(Ventes, Ventes[Région], \"CA\", [Chiffre d'affaires])") == nil)
            let t = st.table("CA par région")
            #expect(t.columns.map(\.name) == ["Région", "CA"])
            #expect(t.columns.map(\.type) == [.text, .number])
            #expect(t.rows.count == 6)
            #expect(close(t.rows.compactMap { $0[1].number }.reduce(0, +), 1_415_422))
            // Recomputed when the data changes, and saved with the report.
            let data = try JSONEncoder().encode(t)
            #expect(try JSONDecoder().decode(DataTable.self, from: data).expression == t.expression)
        }
    }
}
