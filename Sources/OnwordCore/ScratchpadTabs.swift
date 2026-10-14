import CoreGraphics
import Foundation

/// The floating Scratchpad window's tabs: up to five open notes, one of them active.
public struct ScratchpadTabs: Equatable {
    public static let limit = 5

    public private(set) var ids: [UUID] = []
    public private(set) var activeID: UUID?

    public init(ids: [UUID] = [], activeID: UUID? = nil) {
        self.ids = Array(ids.prefix(Self.limit))
        self.activeID = activeID.flatMap { self.ids.contains($0) ? $0 : nil } ?? self.ids.first
    }

    public var isFull: Bool { ids.count >= Self.limit }
    public var isEmpty: Bool { ids.isEmpty }

    /// Adds a tab after the active one and activates it. Returns false (and changes nothing) when full.
    @discardableResult
    public mutating func add(_ id: UUID) -> Bool {
        if ids.contains(id) { activeID = id; return true }
        guard !isFull else { return false }
        let index = activeID.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? ids.count
        ids.insert(id, at: index)
        activeID = id
        return true
    }

    /// Shows a note: activates its tab if it's already open, otherwise adds one. When all five tabs are
    /// taken, the note replaces the active tab; the replaced note's id is returned.
    @discardableResult
    public mutating func open(_ id: UUID) -> UUID? {
        if add(id) { return nil }
        guard let active = activeID, let index = ids.firstIndex(of: active) else { return nil }
        ids[index] = id
        activeID = id
        return active
    }

    public mutating func activate(_ id: UUID) {
        if ids.contains(id) { activeID = id }
    }

    /// Closes a tab. If it was active, the tab to its right (or else its left) becomes active.
    public mutating func close(_ id: UUID) {
        guard let index = ids.firstIndex(of: id) else { return }
        ids.remove(at: index)
        if activeID == id { activeID = ids.isEmpty ? nil : ids[min(index, ids.count - 1)] }
    }

    public mutating func removeAll() {
        ids.removeAll()
        activeID = nil
    }
}

/// Sizes and placement of the Scratchpad window (points, AppKit coordinates with y up).
public enum ScratchpadGeometry {
    public static let defaultSize = CGSize(width: 500, height: 420)
    public static let minSize = CGSize(width: 300, height: 200)
    public static let expandedSize = CGSize(width: 920, height: 660)
    /// Widths above this count as "expanded" for the expand/compact toggle: round((500 + 920) / 2).
    public static let compactMaxWidth: CGFloat = 710

    public static func isExpanded(width: CGFloat) -> Bool { width > compactMaxWidth }

    /// A frame of `size` whose top-left corner is at `topLeft`, moved (and if need be shrunk) so it
    /// fits entirely inside `visible`.
    public static func frame(topLeft: CGPoint, size: CGSize, in visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        let x = max(visible.minX, min(topLeft.x, visible.maxX - width))
        let top = min(visible.maxY, max(topLeft.y, visible.minY + height))
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
}
