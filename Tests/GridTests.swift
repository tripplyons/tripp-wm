import CoreGraphics
import Testing
import TrippWMCore

struct GridTests {
    private let area = CGRect(x: 100, y: -320, width: 1920, height: 1080)

    private func letter(_ name: String, _ modifiers: KeyCombo.Modifiers = []) throws -> Grid.Key {
        Grid.Key(keyCode: try KeyCombo(parsing: "alt-\(name)").keyCode, modifiers: modifiers)
    }

    @Test
    func sizesCellsAndAssignsUniqueLabelsInRowOrder() {
        let grid = Grid(area: area)
        #expect(grid.columns == 80)
        #expect(grid.rows == 45)
        #expect(grid.label(row: 0, column: 0) == "aaa")
        #expect(grid.label(row: 0, column: 26) == "aba")
        #expect(grid.label(row: 1, column: 0) == "adc")
        var labels = Set<String>()
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                let cell = grid.cell(row: row, column: column)
                #expect(abs(cell.width - 24) < 1)
                #expect(abs(cell.height - 24) < 1)
                labels.insert(grid.label(row: row, column: column))
            }
        }
        #expect(labels.count == grid.rows * grid.columns)
        let last = grid.cell(row: grid.rows - 1, column: grid.columns - 1)
        #expect(abs(last.maxX - area.maxX) < 0.001)
        #expect(abs(last.maxY - area.maxY) < 0.001)
    }

    @Test
    func thirdLetterClicksWithFinalModifiers() throws {
        for (modifiers, button): (KeyCombo.Modifiers, Grid.Button) in [
            ([], .left), (.shift, .right), ([.command, .shift], .middle)
        ] {
            var grid = Grid(area: area)
            #expect(grid.handle(try letter("a", .command)) == .pending)
            #expect(grid.handle(try letter("d", .shift)) == .pending)
            #expect(grid.matches(row: 1, column: 0))
            #expect(!grid.matches(row: 0, column: 0))
            let cell = grid.cell(row: 1, column: 0)
            #expect(grid.handle(try letter("c", modifiers)) == .click(CGPoint(x: cell.midX, y: cell.midY), button))
        }
    }

    @Test
    func backspaceEditsPrefixAndInvalidInputIsIgnored() throws {
        var grid = Grid(area: area)
        _ = grid.handle(try letter("z"))
        #expect(grid.prefix.isEmpty)
        _ = grid.handle(try letter("a"))
        _ = grid.handle(try letter("b"))
        #expect(grid.handle(.backspace) == .pending)
        #expect(grid.prefix == "a")
        _ = grid.handle(.backspace)
        _ = grid.handle(.backspace)
        #expect(grid.prefix.isEmpty)
        #expect(grid.handle(try letter("1")) == .pending)
        #expect(grid.prefix.isEmpty)
        #expect(grid.handle(.escape) == .cancel)
    }

    @Test
    func smallAndLargeAreasStayWithinLabelCapacity() throws {
        var tiny = Grid(area: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(tiny.rows == 1 && tiny.columns == 1)
        _ = tiny.handle(try letter("a"))
        _ = tiny.handle(try letter("a"))
        #expect(tiny.handle(try letter("b")) == .pending)
        #expect(tiny.prefix == "aa")
        #expect(tiny.handle(try letter("a")) == .click(CGPoint(x: 5, y: 5), .left))
        let large = Grid(area: CGRect(x: 0, y: 0, width: 10000, height: 10000))
        #expect(large.rows * large.columns <= Grid.capacity)
        #expect(large.label(row: large.rows - 1, column: large.columns - 1).count == 3)
    }

    @Test
    func readsKeysByPosition() {
        #expect(Grid.Key(keyCode: 0x33, modifiers: []) == .backspace)
        #expect(Grid.Key(keyCode: 0x00, modifiers: [.shift]) == .letter("a", [.shift]))
        #expect(Grid.Key(keyCode: 0x31, modifiers: []) == .other)
    }
}
