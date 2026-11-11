import Foundation
import Testing
@testable import Prisme

extension PrismeTests {
    @Suite struct ImporterTests {
        @Test(arguments: [
            ("1 234,5", 1234.5), ("1.234,56", 1234.56), ("1,234.56", 1234.56), ("12%", 0.12), ("-7", -7.0),
            ("3,14", 3.14), ("1\u{00A0}000", 1000.0), ("10 €", 10.0),
        ])
        func parsesNumbers(_ text: String, _ expected: Double) {
            #expect(Importer.parseNumber(text).map { close($0, expected, 1e-9) } == true)
        }

        @Test func rejectsNonNumbers() {
            #expect(Importer.parseNumber("abc") == nil)
            #expect(Importer.parseNumber("") == nil)
        }

        @Test func readsCSVWithQuotesAndFrenchNumbers() throws {
            let url = Fixture.temp("t.csv")
            try "\u{FEFF}Date;Ville;Montant;Commentaire\n05/01/2024;Paris;\"1 234,50\";\"avec ; point-virgule\"\n12/02/2024;Lyon;99,9;\"ligne\nmultiple\"\n;Nice;;\n"
                .write(to: url, atomically: true, encoding: .utf8)
            let t = try #require(try Importer.load(url).first)
            #expect(t.columns.map(\.name) == ["Date", "Ville", "Montant", "Commentaire"])
            #expect(t.columns.map(\.type) == [.date, .text, .number, .text])
            #expect(t.rows.count == 3)
            #expect(t.rows[0][2] == .number(1234.5))
            #expect(t.rows[0][3] == .text("avec ; point-virgule"))
            #expect(t.rows[1][3] == .text("ligne\nmultiple"))
            #expect(t.rows[2][0] == .empty)
        }

        @Test func detectsDelimiters() {
            #expect(Importer.detectDelimiter("a,b,c\n1,2,3") == ",")
            #expect(Importer.detectDelimiter("a;b;c") == ";")
            #expect(Importer.detectDelimiter("a\tb") == "\t")
            #expect(Importer.detectDelimiter("\"x;y\",b,c") == ",")
        }

        @Test func readsXLSX() throws {
            let dir = Fixture.temp("x")
            let fm = FileManager.default
            for d in ["xl/_rels", "xl/worksheets"] { try fm.createDirectory(at: dir.appendingPathComponent(d), withIntermediateDirectories: true) }
            func w(_ path: String, _ s: String) throws { try s.write(to: dir.appendingPathComponent(path), atomically: true, encoding: .utf8) }
            try w("[Content_Types].xml", "<Types/>")
            try w("xl/workbook.xml", #"<workbook xmlns:r="r"><sheets><sheet name="Ventes" sheetId="1" r:id="rId1"/></sheets></workbook>"#)
            try w("xl/_rels/workbook.xml.rels", #"<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>"#)
            try w("xl/sharedStrings.xml", "<sst><si><t>Date</t></si><si><t>Produit</t></si><si><t>Prix</t></si><si><r><t>Ordi</t></r><r><t>nateur</t></r></si></sst>")
            try w("xl/styles.xml", #"<styleSheet><numFmts><numFmt numFmtId="164" formatCode="dd/mm/yyyy"/></numFmts><cellXfs><xf numFmtId="0"/><xf numFmtId="164"/></cellXfs></styleSheet>"#)
            try w("xl/worksheets/sheet1.xml", #"<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c></row><row r="2"><c r="A2" s="1"><v>45306</v></c><c r="B2" t="s"><v>3</v></c><c r="C2"><v>899.5</v></c></row><row r="4"><c r="A4" s="1"><v>45366</v></c><c r="B4" t="inlineStr"><is><t>Souris</t></is></c><c r="C4"><v>25</v></c></row></sheetData></worksheet>"#)
            let xlsx = Fixture.temp("t.xlsx")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = dir
            p.arguments = ["-qr", xlsx.path, "."]
            try p.run()
            p.waitUntilExit()
            let t = try #require(try Importer.load(xlsx).first)
            #expect(t.columns.map(\.type) == [.date, .text, .number])
            #expect(t.rows.count == 2)   // the blank row 3 is dropped
            #expect(t.rows[0][1] == .text("Ordinateur"))
            #expect(Fmt.day(t.rows[0][0].date!) == "15/01/2024")
        }

        @Test func flattensJSON() throws {
            let json = #"{"meta":{"n":2},"data":[{"id":1,"client":{"nom":"Alice"},"total":10.5,"actif":true},{"id":2,"client":{"nom":"Bob"},"total":null}]}"#
            let grid = try JSONReader.grid(Data(json.utf8), path: nil)
            let t = try #require(Importer.makeTable(name: "j", grid: grid, source: nil))
            #expect(t.columns.map(\.name) == ["actif", "client.nom", "id", "total"])
            #expect(t.rows.count == 2)
            #expect(t.rows[1][3] == .empty)
            let meta = try JSONReader.grid(Data(json.utf8), path: "meta")
            #expect(meta.count == 2)
        }

        @Test func readsSQLite() throws {
            let db = Fixture.temp("t.db")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            p.arguments = [db.path, "CREATE TABLE v(id INTEGER, ville TEXT, m REAL); INSERT INTO v VALUES (1,'Paris',12.5),(2,'Lyon',NULL);"]
            try p.run()
            p.waitUntilExit()
            let t = try #require(try Importer.load(source: DataSource(path: db.path, kind: .sqlite, query: "SELECT * FROM v"), name: "v").first)
            #expect(t.columns.map(\.type) == [.number, .text, .number])
            #expect(t.rows[1][2] == .empty)
            #expect(throws: (any Error).self) { try Importer.load(source: DataSource(path: db.path, kind: .sqlite, query: "SELECT * FROM nope"), name: "x") }
        }

        @Test func scramMatchesRFC7677() {
            let r = PostgresClient.scramFinal(password: "pencil", clientFirstBare: "n=user,r=rOprNGfwEbeRWgbNEkqO",
                serverFirst: "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
                serverNonce: "rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0",
                salt: Data(base64Encoded: "W22ZaJ0SNY7soEsUEjb6gQ==")!, iterations: 4096)
            #expect(r.message.hasSuffix("p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="))
            #expect(r.serverSignature.base64EncodedString() == "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")
        }
    }
}
