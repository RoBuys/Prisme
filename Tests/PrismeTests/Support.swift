import Foundation
import Testing
@testable import Prisme

/// All suites run one after another: the app keeps a few global caches and the interface language is global.
@Suite(.serialized) struct PrismeTests {}

enum Fixture {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent(name)
    }

    /// A fresh state with the French sample dataset (Ventes, Produits, Régions).
    static func sample() -> AppState {
        Loc.language = .fr
        let st = AppState()
        st.loadSample()
        return st
    }

    static func temp(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prisme-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
}

extension AppState {
    /// Evaluates an expression as a measure of `table`, over all rows passing `filters`.
    func value(_ expr: String, table: String = "Ventes", filters: [FilterSpec] = []) throws -> MValue {
        let me = Measure(name: "Test", table: table, expression: expr)
        var m = model
        m.measures.append(me)
        if let err = MeasureCompiler.validate(expr, home: table, name: me.name, m) { throw MeasureError(message: err) }
        let deps = MeasureCompiler.dependencies(me, m)
        let ctx = try #require(Engine.context(for: deps.isEmpty ? [FieldRef(table: table, column: "")] : deps, m))
        return try MeasureEvaluator(ctx: ctx, model: m).evaluateValue(me, rows: ctx.rowIndices(filters), filters: filters)
    }

    func number(_ expr: String, table: String = "Ventes", filters: [FilterSpec] = []) throws -> Double {
        try #require(try value(expr, table: table, filters: filters).number)
    }

    func table(_ name: String) -> DataTable { Engine.table(named: name, in: tables)! }

    func measureField(_ name: String) -> ValueField {
        ValueField(field: FieldRef(table: "Ventes", column: name), aggregation: .sum, isMeasure: true)
    }
}

func field(_ column: String, _ table: String = "Ventes", _ level: DateLevel? = nil) -> FieldRef {
    FieldRef(table: table, column: column, dateLevel: level)
}

func close(_ a: Double, _ b: Double, _ tolerance: Double = 0.01) -> Bool { abs(a - b) <= tolerance }
