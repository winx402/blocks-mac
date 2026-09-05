import BlocksScreenshotCore
import Foundation

enum ScreenshotEditorAction: Equatable {
    case close
    case selectToolbarItem(ScreenshotToolbarItemID)
    case selectElement(UUID)
    case undo
    case redo
    case pin
    case save
    case retake
    case complete
}

enum ScreenshotEditorSelectionModel {
    static func visibleElements(in snapshot: ScreenshotSceneSnapshot) -> [ScreenshotElement] {
        snapshot.elements.filter {
            intersects(ScreenshotGeometry.bounds(of: $0), snapshot.cropRect)
        }
    }

    static func nextElementID(
        afterDeleting id: UUID,
        from elements: [ScreenshotElement]
    ) -> UUID? {
        guard let deletedIndex = elements.firstIndex(where: { $0.id == id }) else { return nil }
        let remaining = elements.filter { $0.id != id }
        return remaining.indices.contains(deletedIndex)
            ? remaining[deletedIndex].id
            : remaining.last?.id
    }

    private static func intersects(_ lhs: ScreenshotPixelRect, _ rhs: ScreenshotPixelRect) -> Bool {
        lhs.x < rhs.x + rhs.width
            && lhs.x + lhs.width > rhs.x
            && lhs.y < rhs.y + rhs.height
            && lhs.y + lhs.height > rhs.y
    }
}

struct ScreenshotEditorChromeState: Equatable {
    let activeToolbarItemID: ScreenshotToolbarItemID
    let quickToolbarItems: [ScreenshotToolbarItemID]
    let extendedToolbarItems: [ScreenshotToolbarItemID]
    let isRoundedOutput: Bool
}

struct ScreenshotEditorInspectorState: Equatable {
    let selectedElementID: UUID?
    let selectedStepComponent: ScreenshotStepComponent?
    let selectedCalloutComponent: ScreenshotCalloutComponent?
    let activeStyle: ScreenshotElementAppearance
}

struct ScreenshotEditorToolbarState: Equatable {
    let activeToolbarItemID: ScreenshotToolbarItemID
    let canUndo: Bool
    let canRedo: Bool
    let isOutputPending: Bool
    let currentOutputCommand: ScreenshotEditorOutputCommand?
}

struct ScreenshotEditorOutputState: Equatable {
    let isPending: Bool
    let isCloseConfirmationPresented: Bool
    let renderState: ScreenshotEditorRenderState
}

extension ScreenshotEditorStore {
    var chromeState: ScreenshotEditorChromeState {
        ScreenshotEditorChromeState(
            activeToolbarItemID: activeToolbarItemID,
            quickToolbarItems: visibleQuickToolbarItems,
            extendedToolbarItems: visibleExtendedToolbarItems,
            isRoundedOutput: isRoundedOutput
        )
    }

    var inspectorState: ScreenshotEditorInspectorState {
        ScreenshotEditorInspectorState(
            selectedElementID: selectedElementID,
            selectedStepComponent: selectedStepComponent,
            selectedCalloutComponent: selectedCalloutComponent,
            activeStyle: activeStyle
        )
    }

    var toolbarState: ScreenshotEditorToolbarState {
        ScreenshotEditorToolbarState(
            activeToolbarItemID: activeToolbarItemID,
            canUndo: canUndo,
            canRedo: canRedo,
            isOutputPending: isOutputPending,
            currentOutputCommand: currentOutputCommand
        )
    }

    var outputState: ScreenshotEditorOutputState {
        ScreenshotEditorOutputState(
            isPending: isOutputPending,
            isCloseConfirmationPresented: isCloseConfirmationPresented,
            renderState: renderState
        )
    }
}
