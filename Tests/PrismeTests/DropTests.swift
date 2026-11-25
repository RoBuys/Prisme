import Foundation
import Testing
@testable import Prisme

extension PrismeTests {
    /// Fields dragged from the Data pane onto the report page.
    @Suite struct DropTests {
        @Test func dropsOntoVisualsAndEmptySpace() throws {
            let st = Fixture.sample()
            st.addPage()
            #expect(st.currentPage.visuals.isEmpty)
            // Empty space: a table for text, a card for numbers, centered on the point.
            st.dropField(FieldRef(table: "Ventes", column: "Région"), at: CGPoint(x: 300, y: 200))
            st.dropField(FieldRef(table: "Ventes", column: "Montant"), at: CGPoint(x: 1000, y: 600))
            #expect(st.currentPage.visuals.map(\.type) == [.table, .card])
            #expect(st.currentPage.visuals[0].axis.map(\.column) == ["Région"])
            #expect(st.currentPage.visuals[1].values.first?.field.column == "Montant")
            #expect(st.currentPage.visuals[1].frame.maxX <= PageSize.width)
            // Onto a column chart: text → axis, then legend; numbers and measures → values.
            let id = st.addVisual(.column)
            let center = CGPoint(x: st.visual(id)!.frame.midX, y: st.visual(id)!.frame.midY)
            st.dropField(FieldRef(table: "Ventes", column: "Canal"), at: center)
            st.dropField(FieldRef(table: "Ventes", column: "Région"), at: center)
            st.dropField(FieldRef(table: "Ventes", column: "Chiffre d'affaires"), at: center)
            let v = try #require(st.visual(id))
            #expect(v.axis.map(\.column) == ["Canal"])
            #expect(v.legend?.column == "Région")
            #expect(v.values.first?.measure == true)
            #expect(st.selectedVisualID == id)
        }
    }
}
