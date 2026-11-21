import Foundation
import Testing
@testable import Prisme

extension PrismeTests {
    /// Power Query steps translated into Prisme steps, SQL Server sources.
    @Suite struct PowerQueryTests {
        static let query = #"""
        let
            // Source with a comment, a string holding a comma and a nested let
            Source = Csv.Document(File.Contents("PATH"), [Delimiter=";", Encoding=65001]),
            #"Promoted Headers" = Table.PromoteHeaders(Source, [PromoteAllScalars=true]),
            #"Changed Type" = Table.TransformColumnTypes(#"Promoted Headers",{{"Montant", Int64.Type}, {"Région", type text}}),
            #"Filtered Rows" = Table.SelectRows(#"Changed Type", each [Montant] > 60 and [Canal] <> "Inconnu, vraiment"),
            #"Added Custom" = Table.AddColumn(#"Filtered Rows", "Libellé", each if [Montant] >= 250 then Text.Upper([Région]) else [Région] & " (petit)"),
            #"Renamed Columns" = Table.RenameColumns(#"Added Custom",{{"Canal", "Channel"}}),
            #"Sorted Rows" = Table.Sort(#"Renamed Columns",{{"Montant", Order.Descending}}),
            #"Removed Columns" = Table.RemoveColumns(#"Sorted Rows",{"Date"})
        in
            #"Removed Columns"
        """#

        @Test func splitsLetSteps() throws {
            let steps = try #require(PowerQuery.letSteps(Self.query))
            #expect(steps.map(\.name) == ["Source", "Promoted Headers", "Changed Type", "Filtered Rows", "Added Custom",
                                          "Renamed Columns", "Sorted Rows", "Removed Columns"])
            #expect(steps[3].expr.contains("\"Inconnu, vraiment\""))
            let nested = try #require(PowerQuery.letSteps("let A = let x = 1, y = 2 in x + y, B = A in B"))
            #expect(nested.map(\.name) == ["A", "B"])
        }

        @Test func translatesSteps() {
            let t = PowerQuery.translate(Self.query)
            #expect(t.unsupported.isEmpty)
            #expect(t.steps.map(\.kind) == [.changeType, .changeType, .filterFormula, .customColumn, .renameColumn, .sortRows, .removeColumn])
            #expect(t.steps[2].text2 == #"([Montant] > 60 && [Canal] <> "Inconnu, vraiment")"#)
            #expect(t.steps[3].text2 == #"IF([Montant] >= 250, UPPER([Région]), ([Région] & " (petit)"))"#)
            #expect(t.steps[5].columns == ["Montant"] && t.steps[5].text == "1")
        }

        @Test(arguments: [
            ("[A] = null", "ISBLANK([A])"),
            ("not ([A] <> null)", "NOT((NOT(ISBLANK([A]))))"),
            ("Text.Middle([Code], 2, 3)", "MID([Code], 2 + 1, 3)"),
            ("Date.Year([D]) * 100 + Date.Month([D])", "((YEAR([D]) * 100) + MONTH([D]))"),
            ("List.Contains({\"a\", \"b\"}, [X])", #"([X] IN {"a", "b"})"#),
            ("Number.Round([V], 2)", "ROUND([V], 2)"),
        ])
        func translatesExpressions(_ m: String, _ dax: String) {
            #expect(PowerQuery.dax(m) == dax)
        }

        @Test func rejectsUnknownFunctions() {
            #expect(PowerQuery.dax("Text.Combine({[A], [B]}, \" \")") == nil)
            let t = PowerQuery.translate("let S = Csv.Document(\"x\"), P = Table.Pivot(S, {\"a\"}, \"k\", \"v\") in P")
            #expect(t.unsupported == ["Table.Pivot"])
        }

        @Test func moreTableFunctions() {
            let m = #"""
            let
                S = Sql.Database("srv", "db"),
                T = S{[Schema="dbo",Item="Sales"]}[Data],
                G = Table.Group(T, {"Region"}, {{"Total", each List.Sum([Amount]), type number}, {"Rows", each Table.RowCount(_), Int64.Type}}),
                U = Table.UnpivotOtherColumns(G, {"Region"}, "Attribute", "Value"),
                C = Table.TransformColumns(U, {{"Attribute", Text.Trim, type text}, {"Region", each Text.Upper(_)}}),
                J = Table.NestedJoin(C, {"Region"}, Regions, {"Name"}, "R", JoinKind.LeftOuter),
                E = Table.ExpandTableColumn(J, "R", {"Zone"}, {"Region zone"}),
                A = Table.Combine({E, Other}),
                I = Table.AddIndexColumn(A, "Index", 0, 1)
            in
                I
            """#
            let t = PowerQuery.translate(m)
            #expect(t.unsupported.isEmpty)
            #expect(t.steps.map(\.kind) == [.groupBy, .unpivotColumns, .trim, .changeType, .customColumn, .mergeTable, .renameColumn,
                                            .appendTable, .addIndex, .customColumn])
            #expect(t.steps[0].aggregations.map(\.aggregation) == [.sum, .count])
            #expect(t.steps[1].text3 == "others")
            #expect(t.steps[4].text2 == "UPPER([Region])")
            #expect(t.steps[5].text == "Regions" && t.steps[5].text2 == "Name" && t.steps[5].columns == ["Zone"])
            #expect(t.steps[6].column == "Regions.Zone" && t.steps[6].text == "Region zone")
            #expect(t.steps[9].text2 == "[Index] + -1")
        }

        @Test func importsAQueryWithItsSteps() throws {
            let csv = Fixture.url("ventes.csv").path
            let m = Self.query.replacingOccurrences(of: "PATH", with: csv)
            let schema: [String: Any] = ["model": ["tables": [
                ["name": "Ventes", "columns": [
                    ["name": "Région", "dataType": "string", "sourceColumn": "Région"],
                    ["name": "Canal", "dataType": "string", "sourceColumn": "Channel"],
                    ["name": "Montant", "dataType": "int64", "sourceColumn": "Montant"],
                    ["name": "Libellé", "dataType": "string", "sourceColumn": "Libellé"],
                ], "partitions": [["name": "p", "source": ["type": "m", "expression": m]]]],
            ]]]
            var z = ZipWriter()
            z.add("DataModelSchema", PBITExporter.utf16(String(decoding: try JSONSerialization.data(withJSONObject: schema), as: UTF8.self)))
            z.add("Report/Layout", PBITExporter.utf16(#"{"sections":[]}"#))
            let url = Fixture.temp("PQ.pbit")
            try z.finish().write(to: url)
            Loc.language = .fr
            let st = AppState()
            st.importPowerBI(url, askForFiles: false)
            let t = st.table("Ventes")
            #expect(t.columns.map(\.name) == ["Région", "Canal", "Montant", "Libellé"])
            // 50 is filtered out; sorted by amount, descending; label computed; Canal renamed in the query (Channel) then by the model.
            #expect(t.rows.map { $0[2] } == [.number(400), .number(250), .number(100)])
            #expect(t.rows.map { $0[3] } == [.text("NICE"), .text("LYON"), .text("Paris (petit)")])
            #expect(t.rows.map { $0[1] } == [.text("Magasin"), .text("En ligne"), .text("Magasin")])
            #expect(t.steps.contains { $0.kind == .filterFormula } && t.steps.last?.kind == .keepColumns)
            #expect(st.stepErrors["Ventes"]?.isEmpty ?? true)
            #expect(!(st.alertMessage ?? "").contains("non reprises"))
        }

        @Test func sqlServerSources() throws {
            let m = #"let Source = Sql.Database("srv.database.windows.net", "Sales", [Query="SELECT *#(lf)FROM T"]) in Source"#
            let (s, _) = try #require(MSource.source(m))
            #expect(s.sourceKind == .sqlserver && s.host == "srv.database.windows.net" && s.database == "Sales")
            #expect(s.query == "SELECT *\nFROM T")
            let nav = #"let S = Sql.Database(Server, Database), T = S{[Schema="hr",Item="People"]}[Data] in T"#
            let (n, _) = try #require(MSource.source(nav))
            #expect(n.query == "SELECT * FROM [hr].[People]" && n.host == "" && n.database == "")
            var src = DataSource(kind: .sqlserver, query: "SELECT 1", host: "srv", port: 1444, database: "db", user: "u")
            #expect(SQLServerCLI.server(src) == "srv,1444")
            #expect(SQLServerCLI.arguments(src).contains("-U"))
            src.user = ""
            #expect(SQLServerCLI.arguments(src).contains("ActiveDirectoryDefault"))
        }

        @Test func parsesSqlcmdOutput() {
            let sep = String(SQLServerCLI.separator)
            let out = "Id\(sep)Name\(sep)Amount\n--\(sep)----\(sep)------\n1\(sep)Alice\(sep)12.5\n2\(sep)NULL\(sep)7\n\n"
            let grid = SQLServerCLI.parse(out)
            #expect(grid.count == 3)
            #expect(grid[0].map { if case .text(let s) = $0 { return s }; return "" } == ["Id", "Name", "Amount"])
            #expect({ if case .empty = grid[2][1] { return true }; return false }())
            let t = Importer.makeTable(name: "T", grid: grid, source: nil)
            #expect(t?.columns.map(\.type) == [.number, .text, .number])
        }
    }
}
