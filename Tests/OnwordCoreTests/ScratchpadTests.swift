import XCTest
@testable import OnwordCore

final class ScratchpadTabsTests: XCTestCase {
    func testAddActivatesAndStopsAtFive() {
        var tabs = ScratchpadTabs()
        let ids = (0..<6).map { _ in UUID() }
        for id in ids.prefix(5) { XCTAssertTrue(tabs.add(id)) }
        XCTAssertEqual(tabs.activeID, ids[4])
        XCTAssertFalse(tabs.add(ids[5]))
        XCTAssertEqual(tabs.ids, Array(ids.prefix(5)))
    }

    func testOpenReusesTabOrReplacesActiveWhenFull() {
        let ids = (0..<6).map { _ in UUID() }
        var tabs = ScratchpadTabs(ids: Array(ids.prefix(5)), activeID: ids[1])
        XCTAssertNil(tabs.open(ids[3]))
        XCTAssertEqual(tabs.activeID, ids[3])
        XCTAssertEqual(tabs.ids.count, 5)
        XCTAssertEqual(tabs.open(ids[5]), ids[3])
        XCTAssertEqual(tabs.ids[3], ids[5])
        XCTAssertEqual(tabs.activeID, ids[5])
    }

    func testCloseActivatesNeighbour() {
        let ids = (0..<3).map { _ in UUID() }
        var tabs = ScratchpadTabs(ids: ids, activeID: ids[1])
        tabs.close(ids[1])
        XCTAssertEqual(tabs.activeID, ids[2])
        tabs.close(ids[2])
        XCTAssertEqual(tabs.activeID, ids[0])
        tabs.close(ids[0])
        XCTAssertNil(tabs.activeID)
        XCTAssertTrue(tabs.isEmpty)
    }

    func testFrameIsClampedToVisibleArea() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)   // menu bar above, Dock below
        let size = ScratchpadGeometry.defaultSize
        // Plenty of room: top-left exactly at the cursor.
        XCTAssertEqual(ScratchpadGeometry.frame(topLeft: CGPoint(x: 100, y: 800), size: size, in: visible),
                       CGRect(x: 100, y: 380, width: 500, height: 420))
        // Near the bottom-right corner: pushed back inside.
        XCTAssertEqual(ScratchpadGeometry.frame(topLeft: CGPoint(x: 1400, y: 60), size: size, in: visible),
                       CGRect(x: 940, y: 25, width: 500, height: 420))
        // Larger than the screen: shrunk to fit.
        let huge = ScratchpadGeometry.frame(topLeft: .zero, size: CGSize(width: 2000, height: 2000), in: visible)
        XCTAssertEqual(huge, visible)
        XCTAssertFalse(ScratchpadGeometry.isExpanded(width: 500))
        XCTAssertTrue(ScratchpadGeometry.isExpanded(width: 920))
    }

    func testCustomTitleAndOlderFiles() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","body":"","created":"2026-01-01T00:00:00Z","updated":"2026-01-01T00:00:00Z","pinned":false}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var note = try decoder.decode(Note.self, from: Data(old.utf8))
        XCTAssertNil(note.customTitle)
        XCTAssertTrue(note.isBlank)
        note.customTitle = "Groceries"
        XCTAssertEqual(note.title, "Groceries")
        XCTAssertFalse(note.isBlank)
        XCTAssertTrue(note.matches("grocer"))
    }
}
