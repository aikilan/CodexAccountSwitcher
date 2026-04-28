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

    // 输入：当前顺序和预览顺序；输出：传给数据库 moveAccount 的目标账号。
    static func destinationAccountID(
        currentOrder: [UUID],
        previewOrder: [UUID],
        draggedAccountID: UUID
    ) -> UUID? {
        guard
            let sourceIndex = currentOrder.firstIndex(of: draggedAccountID),
            let targetIndex = previewOrder.firstIndex(of: draggedAccountID),
            sourceIndex != targetIndex
        else {
            return nil
        }

        if targetIndex < sourceIndex {
            let destinationIndex = targetIndex + 1
            return previewOrder.indices.contains(destinationIndex) ? previewOrder[destinationIndex] : nil
        }
        let destinationIndex = targetIndex - 1
        return previewOrder.indices.contains(destinationIndex) ? previewOrder[destinationIndex] : nil
    }

    // 输入：拖拽开始时的顺序和行 frame；输出：当前账号在拖拽预览中的视觉纵向偏移。
    static func visualOffsetY(
        accountID: UUID,
        draggedAccountID: UUID,
        dragTranslationHeight: CGFloat,
        initialOrder: [UUID],
        previewOrder: [UUID],
        initialRowFrames: [UUID: CGRect]
    ) -> CGFloat {
        if accountID == draggedAccountID {
            return dragTranslationHeight
        }

        guard
            let sourceIndex = initialOrder.firstIndex(of: accountID),
            let targetIndex = previewOrder.firstIndex(of: accountID),
            sourceIndex != targetIndex,
            initialOrder.indices.contains(targetIndex),
            let sourceFrame = initialRowFrames[accountID]
        else {
            return 0
        }

        let targetSlotAccountID = initialOrder[targetIndex]
        guard let targetFrame = initialRowFrames[targetSlotAccountID] else {
            return 0
        }

        return targetFrame.minY - sourceFrame.minY
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
