import Foundation
import CoreGraphics

/// The layout of one tab: a tree whose leaves are panes and whose inner
/// nodes are splits laid out in a row (side by side) or a column (stacked).
///
/// The port of the `{ type: 'pane', paneId }` / `{ type: 'split', dir,
/// children }` objects in state.js, with the tree helpers that went with
/// them (`splitTree`, `swapPanes`, `movePaneToEdge`, `removeFromTree`).
/// Values, not objects: every change builds a new tree, exactly as the
/// JavaScript did, so a layout can be compared and saved without aliasing.
indirect enum PaneNode: Equatable {
    case pane(String)
    case split(PaneSplit)

    var paneId: String? { if case .pane(let id) = self { return id }; return nil }

    /// Every pane id, in reading order (`panesOf`).
    var paneIds: [String] {
        switch self {
        case .pane(let id): return [id]
        case .split(let s): return s.children.flatMap { $0.paneIds }
        }
    }

    /// The first pane in reading order (`firstPaneOf`).
    var firstPane: String? {
        switch self {
        case .pane(let id): return id
        case .split(let s):
            for c in s.children { if let f = c.firstPane { return f } }
            return nil
        }
    }

    func contains(_ paneId: String) -> Bool { paneIds.contains(paneId) }
}

/// A split: its direction, its children and (once a divider has been
/// dragged) the share of the space each child has.
struct PaneSplit: Equatable {
    enum Dir: String { case row, col }
    var id: String = uid("split")
    var dir: Dir
    var children: [PaneNode]
    /// Fractions of the split's length, one per child. nil = equal shares.
    /// Sizes belong to a split that exists; any change to the children
    /// resets them, as the original cleared `flex` when a split changed.
    var weights: [CGFloat]? = nil

    static func == (a: PaneSplit, b: PaneSplit) -> Bool {
        a.dir == b.dir && a.children == b.children && a.weights == b.weights
    }
}

enum PaneTree {
    static func node(_ paneId: String) -> PaneNode { .pane(paneId) }

    /// `removeFromTree`: take a pane out, collapsing splits left with one child.
    static func removing(_ paneId: String, from node: PaneNode?) -> PaneNode? {
        guard let node else { return nil }
        switch node {
        case .pane(let id): return id == paneId ? nil : node
        case .split(var s):
            let kids = s.children.compactMap { removing(paneId, from: $0) }
            if kids.isEmpty { return nil }
            if kids.count == 1 { return kids[0] }
            if kids.count != s.children.count { s.weights = nil }
            s.children = kids
            return .split(s)
        }
    }

    /// `splitTree`: replace `paneId` with a split holding it and a new pane.
    static func splitting(_ node: PaneNode?, at paneId: String, adding newId: String, dir: PaneSplit.Dir) -> PaneNode? {
        guard let node else { return nil }
        switch node {
        case .pane(let id):
            guard id == paneId else { return node }
            return .split(PaneSplit(dir: dir, children: [.pane(paneId), .pane(newId)]))
        case .split(var s):
            s.children = s.children.map { splitting($0, at: paneId, adding: newId, dir: dir) ?? $0 }
            return .split(s)
        }
    }

    /// `swapPanes`: exchange two panes' places, leaving the shape alone.
    /// Sizes belong to the slot, so the weights stay where they are.
    static func swapping(_ node: PaneNode?, _ a: String, _ b: String) -> PaneNode? {
        guard let node else { return nil }
        switch node {
        case .pane(let id):
            if id == a { return .pane(b) }
            if id == b { return .pane(a) }
            return node
        case .split(var s):
            s.children = s.children.map { swapping($0, a, b) ?? $0 }
            return .split(s)
        }
    }

    /// `movePaneToEdge`: pull a pane out and lay it along a whole edge.
    static func movingToEdge(_ root: PaneNode?, _ paneId: String, _ dir: String) -> PaneNode? {
        guard let root, let rest = removing(paneId, from: root) else { return root }
        let axis: PaneSplit.Dir = (dir == "left" || dir == "right") ? .row : .col
        let first = dir == "left" || dir == "up"
        return .split(PaneSplit(dir: axis, children: first ? [.pane(paneId), rest] : [rest, .pane(paneId)]))
    }

    /// Replace the weights of the split with this id.
    static func settingWeights(_ node: PaneNode?, splitId: String, _ weights: [CGFloat]) -> PaneNode? {
        guard let node else { return nil }
        guard case .split(var s) = node else { return node }
        if s.id == splitId { s.weights = weights; return .split(s) }
        s.children = s.children.map { settingWeights($0, splitId: splitId, weights) ?? $0 }
        return .split(s)
    }

    /// Forget every split's sizes (a structural change elsewhere).
    static func clearingWeights(_ node: PaneNode?) -> PaneNode? {
        guard let node else { return nil }
        guard case .split(var s) = node else { return node }
        s.weights = nil
        s.children = s.children.map { clearingWeights($0) ?? $0 }
        return .split(s)
    }

    /// `splitNeighbours`: the panes sharing a split with this one, asked
    /// before it is taken out (removing it collapses the split).
    static func neighbours(of paneId: String, in root: PaneNode?) -> [String] {
        func walk(_ n: PaneNode?) -> [PaneNode]? {
            guard let n, case .split(let s) = n else { return nil }
            if s.children.contains(where: { $0.paneId == paneId }) {
                return s.children.filter { $0.paneId != paneId }
            }
            for c in s.children { if let f = walk(c) { return f } }
            return nil
        }
        return (walk(root) ?? []).flatMap { $0.paneIds }
    }

    /// The split directly containing this pane, if any.
    static func parentSplitId(of paneId: String, in root: PaneNode?) -> String? {
        guard let root, case .split(let s) = root else { return nil }
        if s.children.contains(where: { $0.paneId == paneId }) { return s.id }
        for c in s.children { if let f = parentSplitId(of: paneId, in: c) { return f } }
        return nil
    }

    /// Clear the weights of the splits that directly hold these panes.
    static func clearingWeights(around paneIds: [String], in root: PaneNode?) -> PaneNode? {
        var r = root
        for id in paneIds {
            if let sid = parentSplitId(of: id, in: r) { r = clearingWeightsOf(splitId: sid, r) }
        }
        return r
    }

    private static func clearingWeightsOf(splitId: String, _ node: PaneNode?) -> PaneNode? {
        guard let node, case .split(var s) = node else { return node }
        if s.id == splitId { s.weights = nil; return .split(s) }
        s.children = s.children.map { clearingWeightsOf(splitId: splitId, $0) ?? $0 }
        return .split(s)
    }
}
