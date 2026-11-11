import Foundation
import Testing
@testable import Prisme

extension PrismeTests {
    /// DAX found in real Power BI templates (Sentinel reports).
    @Suite struct DAXCompatTests {
        let st = Fixture.sample()

        @Test(arguments: [
            ("IF(NOT ISBLANK([Chiffre d'affaires]) && 1 = 1, 1, 0)", 1.0),
            ("IF(NOT 1 = 2, 1, 0)", 1),
            ("SUM(ventes[montant])", 1_415_422),                                        // case-insensitive names
            ("IF(CONTAINSSTRING(\"Premium Per User\", \"per\"), 1, 0)", 1),
            ("LEN(UNICHAR(9650))", 1),
            ("IFERROR(RELATED(Produits[Catégorie]), 7) + IFERROR(5, 7)", 12),   // RELATED fails outside a row context
            ("IF(ISEMPTY(FILTER(Ventes, Ventes[Montant] < 0)), 1, 0)", 1),
            ("WEEKDAY(DATE(2024, 1, 1))", 2),                                           // a Monday
            ("WEEKDAY(DATE(2024, 1, 1), 2)", 1),
            ("DISTINCTCOUNTNOBLANK(Ventes[Produit])", 10),
            ("CALCULATE([Chiffre d'affaires], OR(Ventes[Canal] = \"Magasin\", Ventes[Canal] = \"Inexistant\"))", 603_375),
            ("CALCULATE([Chiffre d'affaires], Ventes[Canal] = \"Magasin\" || Ventes[Canal] = \"Inexistant\")", 603_375),
            ("CALCULATE(COUNTROWS(Ventes), NOT ISBLANK(Ventes[Canal]))", 2822),
            ("COUNTROWS(CALENDAR(DATE(2024, 1, 1), DATE(2024, 12, 31)))", 366),
            ("COUNTROWS(FILTER(CALENDAR(DATE(2024, 1, 1), DATE(2024, 12, 31)), MONTH([Date]) = 2))", 29),
            ("SUMX(GENERATESERIES(1, 4), [Value])", 10),
        ])
        func expressions(_ expr: String, _ expected: Double) throws {
            #expect(close(try st.number(expr), expected), "\(expr)")
        }

        @Test func calendarTables() throws {
            #expect(st.saveCalculatedTable(name: "Dates", expression: """
                VAR FirstYear = 2024
                RETURN ADDCOLUMNS(FILTER(CALENDARAUTO(), YEAR([Date]) >= FirstYear),
                                  "Year", YEAR([Date]), "Weekday", WEEKDAY([Date], 2))
                """) == nil)
            let t = st.table("Dates")
            #expect(t.columns.map(\.name) == ["Date", "Year", "Weekday"])
            #expect(t.rows.first?[1] == .number(2024))
            #expect(t.rows.count == 366 + 365)   // the sample covers 2024–2025
        }

        @Test func whatIfParameterKeepsItsColumnName() {
            var t = DataTable(name: "Cost of P1", columns: [DataColumn(name: "Cost of P1", type: .number)], rows: [])
            t.expression = "GENERATESERIES(0, 10000, 5)"
            st.tables.append(t)
            st.measures.append(Measure(name: "Cost of P1 Value", table: "Cost of P1", expression: "SELECTEDVALUE('Cost of P1'[Cost of P1], 4995)"))
            st.recomputeCalculatedColumns()
            #expect(st.table("Cost of P1").columns.map(\.name) == ["Cost of P1"])
            #expect(st.table("Cost of P1").rows.count == 2001)
            #expect(MeasureCompiler.validate("[Cost of P1 Value]", home: "Ventes", name: "x", st.model) == nil)
        }

        @Test func mQueryHelpers() {
            let m = #"let BaseUrl = "https://example.com/data.json", Source = Json.Document(Web.Contents(BaseUrl)) in Source"#
            #expect(MSource.argument(m, after: "Web.Contents") == "https://example.com/data.json")
            let api = #"let Source = Json.Document(Web.Contents("https://api.example.com/", [RelativePath = "v1/items"])) in Source"#
            #expect(MSource.source(api) == nil)
            #expect(MSource.connector(api) == "Web API (Web.Contents)")
            #expect(MSource.constantValue("let\n    Source = true\nin\n    Source") == "TRUE")
            #expect(MSource.constantValue(#"let Source = "abc" in Source"#) == "abc")
            #expect(MSource.constantValue("let Source = Sql.Database(\"a\", \"b\") in Source") == nil)
        }
    }
}
