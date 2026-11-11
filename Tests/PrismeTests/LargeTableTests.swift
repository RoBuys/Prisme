import Foundation
import Testing
@testable import Prisme

extension PrismeTests {
    /// Calculated columns on large tables (parallel evaluation) and the functions they commonly use.
    @Suite struct LargeTableTests {
        let st = Fixture.sample()

        @Test(arguments: [
            ("DATE(2024, 3, 1) - DATE(2024, 2, 1)", 29.0),                 // days between dates
            ("DAY(DATE(2024, 2, 28) + 2)", 1),                             // date + days
            ("MONTH(DATE(2024, 2, 28) + 2)", 3),
            ("LEN(MID(\"1 North East\", 3, 15))", 10),
            ("CEILING(31 / 30, 1) - 1", 1),
            ("FLOOR(7.8, 0.5)", 7.5),
            ("LEN(TRIM(\"  a   b  \"))", 3),
            ("LEN(SUBSTITUTE(\"a-b-c\", \"-\", \"\"))", 3),
            ("LEN(SUBSTITUTE(\"a-b-c\", \"-\", \"+\", 2))", 5),
            ("SEARCH(\"B\", \"abc\")", 2),
            ("FIND(\"z\", \"abc\", 1, 0)", 0),
            ("VALUE(\"1\" & 2 + 3)", 15),                                 // & binds after +
            ("YEAR(DATE(1899, 12, 30)) * 10000 + MONTH(DATE(2100, 12, 31)) * 100 + DAY(DATE(2000, 2, 29))", 18_991_229),
        ])
        func functions(_ expr: String, _ expected: Double) throws {
            #expect(close(try st.number(expr), expected), "\(expr)")
        }

        @Test func civilDatesMatchCalendar() {
            for t in stride(from: -3_000_000_000.0, to: 5_000_000_000, by: 7_777_777) {
                let c = Fmt.calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: t))
                let v = MeasureEvaluator.civil(t)
                #expect(v.year == c.year && v.month == c.month && v.day == c.day, "\(t)")
            }
        }

        @Test func parallelColumnsMatchSerialOnes() throws {
            // 60 000 rows (parallel path) related to a dimension through number, text and date keys.
            let n = 60_000
            let day = 86_400.0
            let facts = DataTable(name: "F", columns: [
                DataColumn(name: "K", type: .number), DataColumn(name: "Code", type: .text), DataColumn(name: "D", type: .date),
                DataColumn(name: "Hire", type: .date),
            ], rows: (0..<n).map { i in
                [.number(Double(i % 7)), .text(["a", "B ", "c"][i % 3]), .date(Date(timeIntervalSince1970: Double(i % 30) * day)),
                 .date(Date(timeIntervalSince1970: Double(i % 11) * day))]
            })
            let dimK = DataTable(name: "DK", columns: [DataColumn(name: "K", type: .number), DataColumn(name: "Label", type: .text)],
                                 rows: (0..<7).map { [.number(Double($0)), .text("k\($0)")] })
            let dimC = DataTable(name: "DC", columns: [DataColumn(name: "Code", type: .text), DataColumn(name: "W", type: .number)],
                                 rows: [[.text("A"), .number(1)], [.text("b"), .number(2)], [.text("c"), .number(3)]])
            let dimD = DataTable(name: "DD", columns: [DataColumn(name: "D", type: .date), DataColumn(name: "Wk", type: .number)],
                                 rows: (0..<30).map { [.date(Date(timeIntervalSince1970: Double($0) * day)), .number(Double($0 / 7))] })
            let s = AppState()
            s.tables = [facts, dimK, dimC, dimD]
            s.relationships = [Relationship(fromTable: "F", fromColumn: "K", toTable: "DK", toColumn: "K"),
                               Relationship(fromTable: "F", fromColumn: "Code", toTable: "DC", toColumn: "Code"),
                               Relationship(fromTable: "F", fromColumn: "D", toTable: "DD", toColumn: "D")]
            let expr = "RELATED(DK[Label]) & \"-\" & RELATED(DC[W]) * 10 + RELATED(DD[Wk]) & \"-\" & ([D] - [Hire])"
            let (_, values) = try s.computeColumn(table: "F", expression: expr)
            #expect(values.count == n)
            for i in [0, 1, 2, 12_345, n - 1] {
                let w = Double([1, 2, 3][i % 3]) * 10 + Double((i % 30) / 7)
                #expect(values[i] == .text("k\(i % 7)-\(Fmt.plain(w))-\(Fmt.plain(Double(i % 30 - i % 11)))"), "\(i)")
            }
        }
    }
}
