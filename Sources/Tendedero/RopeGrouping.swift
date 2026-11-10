import Foundation

extension Pegged {
    var ropeGroupKind: RopeGroupKind? {
        if noteID != nil { return .notes }
        return isRecording ? nil : .images
    }
}

struct RopeGroup {
    let kind: RopeGroupKind
    let members: [Pegged]
    let expanded: Bool

    var id: UUID { kind.id }
    var cover: Pegged { members[0] }
}

/// A projection of the rope. Group controls occupy display slots only and
/// never enter the stored item order, drag operations, or clear/undo batches.
struct RopePresentation {
    let groups: [RopeGroup]
    let slotIDs: [UUID]
    private let indices: [UUID: Int]
    private let collapsedMembers: [UUID: UUID]

    init(items: [Pegged], rules: [RopeGroupKind: RopeFoldRule], expanded: RopeGroupKind?) {
        let members = Dictionary(grouping: items.filter { !$0.falling }, by: \.ropeGroupKind)
        groups = RopeGroupKind.allCases.compactMap { kind in
            guard let matching = members[kind], rules[kind]?.groups(matching.count) == true else { return nil }
            return RopeGroup(kind: kind, members: matching, expanded: expanded == kind)
        }
        let groupsByKind = Dictionary(uniqueKeysWithValues: groups.map { ($0.kind, $0) })
        var slots: [UUID] = []
        var collapsed: [UUID: UUID] = [:]
        for item in items where !item.falling {
            guard let kind = item.ropeGroupKind, let group = groupsByKind[kind] else {
                slots.append(item.id)
                continue
            }
            if item.id == group.cover.id {
                if group.expanded {
                    slots.append(contentsOf: group.members.map(\.id))
                } else {
                    slots.append(group.id)
                }
            }
            if !group.expanded { collapsed[item.id] = group.id }
        }
        slotIDs = slots
        var slotIndices = Dictionary(uniqueKeysWithValues: slots.enumerated().map { ($1, $0) })
        for group in groups where group.expanded {
            slotIndices[group.id] = slotIndices[group.cover.id]
        }
        indices = slotIndices
        collapsedMembers = collapsed
    }

    func slot(for id: UUID) -> UUID { collapsedMembers[id] ?? id }
    func index(for id: UUID) -> Int? { indices[slot(for: id)] }
    func hides(_ id: UUID) -> Bool { collapsedMembers[id] != nil }
    func scrollLimit(visible: Int) -> CGFloat { CGFloat(max(0, slotIDs.count - visible)) * Layout.spacing }
}
