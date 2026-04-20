import Foundation

enum AccountListReorderLogic {
    static func previewOrder(
        currentOrder: [UUID],
        draggedAccountID: UUID,
        draggedMidY: CGFloat,
        rowFrames: [UUID: CGRect]
    ) -> [UUID] {
        guard currentOrder.contains(draggedAccountID) else {
            return currentOrder
        }

        var preview = currentOrder.filter { $0 != draggedAccountID }
        let insertionIndex = preview.firstIndex { accountID in
            guard let frame = rowFrames[accountID] else { return false }
            return draggedMidY < frame.midY
        } ?? preview.endIndex
        preview.insert(draggedAccountID, at: insertionIndex)
        return preview
    }
}

enum AccountListAutoScrollLogic {
    static let edgeActivationDistance: CGFloat = 32
    static let maximumPointsPerSecond: CGFloat = 480

    static func velocity(pointerY: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight > 0 else { return 0 }

        if pointerY < edgeActivationDistance {
            let progress = (edgeActivationDistance - max(pointerY, 0)) / edgeActivationDistance
            return -maximumPointsPerSecond * min(progress, 1)
        }

        if pointerY > viewportHeight - edgeActivationDistance {
            let distanceIntoEdge = min(pointerY, viewportHeight) - (viewportHeight - edgeActivationDistance)
            let progress = distanceIntoEdge / edgeActivationDistance
            return maximumPointsPerSecond * min(progress, 1)
        }

        return 0
    }
}
