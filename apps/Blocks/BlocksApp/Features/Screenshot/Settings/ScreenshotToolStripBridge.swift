import AppKit
import BlocksScreenshotCore
import SwiftUI

internal enum ScreenshotToolStripMetrics {
    static let leadingDropWidth: CGFloat = 8
    static let interItemDropWidth: CGFloat = 6
    static let trailingDropWidth: CGFloat = 36
    static let emptyTargetWidth: CGFloat = 240

    static func intrinsicContentWidth(toolCount: Int) -> CGFloat {
        guard toolCount > 0 else { return leadingDropWidth + emptyTargetWidth }
        return leadingDropWidth
            + CGFloat(toolCount) * BlocksVisualTokens.Control.minimumHitTarget
            + CGFloat(toolCount - 1) * interItemDropWidth
            + trailingDropWidth
    }

    static func overflows(toolCount: Int, viewportWidth: CGFloat) -> Bool {
        intrinsicContentWidth(toolCount: toolCount) > max(0, viewportWidth) + 1
    }

    static func visibleToolCount(viewportWidth: CGFloat) -> Int {
        let itemPitch = BlocksVisualTokens.Control.minimumHitTarget + interItemDropWidth
        let availableWidth = max(itemPitch, viewportWidth - trailingDropWidth)
        return max(1, Int((availableWidth / itemPitch).rounded(.down)))
    }

    static func maximumFirstVisibleIndex(toolCount: Int, viewportWidth: CGFloat) -> Int {
        max(0, toolCount - visibleToolCount(viewportWidth: viewportWidth))
    }
}

internal enum ScreenshotToolDragPlacement {
    struct Payload: Equatable {
        let tool: ScreenshotToolbarItemID
        let sourceZone: ScreenshotToolZone
        let sourceIndex: Int

        init(tool: ScreenshotToolbarItemID, sourceZone: ScreenshotToolZone, sourceIndex: Int) {
            self.tool = tool
            self.sourceZone = sourceZone
            self.sourceIndex = sourceIndex
        }
    }

    static func insertionIndex(atX locationX: CGFloat, toolCount: Int) -> Int {
        guard toolCount > 0 else { return 0 }
        let itemPitch = BlocksVisualTokens.Control.minimumHitTarget
            + ScreenshotToolStripMetrics.interItemDropWidth
        for index in 0..<toolCount {
            let midpoint = ScreenshotToolStripMetrics.leadingDropWidth
                + CGFloat(index) * itemPitch
                + BlocksVisualTokens.Control.minimumHitTarget / 2
            if locationX < midpoint { return index }
        }
        return toolCount
    }

    static func target(
        for dragged: ScreenshotToolbarItemID,
        in destinationTools: [ScreenshotToolbarItemID],
        insertionIndex: Int
    ) -> ScreenshotToolbarItemID? {
        let boundedIndex = min(max(0, insertionIndex), destinationTools.count)
        let sourceIndex = destinationTools.firstIndex(of: dragged)
        let destinationIndex = sourceIndex.map { boundedIndex > $0 ? boundedIndex - 1 : boundedIndex }
            ?? boundedIndex
        let remainingTools = destinationTools.filter { $0 != dragged }
        return destinationIndex < remainingTools.count ? remainingTools[destinationIndex] : nil
    }

    static func reorderedTools(
        moving dragged: ScreenshotToolbarItemID,
        in destinationTools: [ScreenshotToolbarItemID],
        insertionIndex: Int
    ) -> [ScreenshotToolbarItemID] {
        let target = target(for: dragged, in: destinationTools, insertionIndex: insertionIndex)
        var reordered = destinationTools.filter { $0 != dragged }
        let targetIndex = target.flatMap(reordered.firstIndex(of:)) ?? reordered.endIndex
        reordered.insert(dragged, at: targetIndex)
        return reordered
    }

    static func isNoOp(
        moving dragged: ScreenshotToolbarItemID,
        from sourceZone: ScreenshotToolZone?,
        to destinationZone: ScreenshotToolZone,
        destinationTools: [ScreenshotToolbarItemID],
        insertionIndex: Int
    ) -> Bool {
        guard sourceZone == destinationZone else { return false }
        return reorderedTools(
            moving: dragged,
            in: destinationTools,
            insertionIndex: insertionIndex
        ) == destinationTools
    }

    static func intent(
        for payload: Payload,
        destinationZone: ScreenshotToolZone,
        destinationTools: [ScreenshotToolbarItemID],
        insertionIndex: Int
    ) -> ScreenshotToolDropIntent? {
        guard !isNoOp(
            moving: payload.tool,
            from: payload.sourceZone,
            to: destinationZone,
            destinationTools: destinationTools,
            insertionIndex: insertionIndex
        ) else { return nil }
        return ScreenshotToolDropIntent(
            tool: payload.tool,
            destinationZone: destinationZone,
            beforeTool: target(
                for: payload.tool,
                in: destinationTools,
                insertionIndex: insertionIndex
            )
        )
    }
}

internal struct ScreenshotToolDropIntent: Equatable {
    let tool: ScreenshotToolbarItemID
    let destinationZone: ScreenshotToolZone
    let beforeTool: ScreenshotToolbarItemID?
}

internal struct ScreenshotToolZonesSnapshot: Equatable {
    let quick: [ScreenshotToolbarItemID]
    let expanded: [ScreenshotToolbarItemID]
    let hidden: [ScreenshotToolbarItemID]

    func tools(in zone: ScreenshotToolZone) -> [ScreenshotToolbarItemID] {
        switch zone {
        case .quick: quick
        case .expanded: expanded
        case .hidden: hidden
        }
    }
}

internal enum ScreenshotToolZonesBoardMetrics {
    static let zoneHeight: CGFloat = 84
    static let zoneSpacing: CGFloat = 8
    static let requiredHeight = zoneHeight * 3 + zoneSpacing * 2
}

struct ScreenshotToolZonesBoardBridge: NSViewRepresentable {
    let snapshot: ScreenshotToolZonesSnapshot
    let onMoveTool: (ScreenshotToolbarItemID, ScreenshotToolZone, ScreenshotToolbarItemID?) -> Void
    let onMove: (ScreenshotToolbarItemID, Int) -> Void
    let focusedTool: Binding<ScreenshotToolbarItemID?>
    @Environment(\.blocksImmediateTooltipHost) private var tooltipHost

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ScreenshotToolZonesBoardView {
        let board = ScreenshotToolZonesBoardView()
        context.coordinator.board = board
        board.configureCollections(
            dataSource: context.coordinator,
            delegate: context.coordinator,
            eventDelegate: context.coordinator
        )
        return board
    }

    func updateNSView(_ board: ScreenshotToolZonesBoardView, context: Context) {
        context.coordinator.update(from: self, board: board, tooltipHost: tooltipHost)
    }

    static func dismantleNSView(_ board: ScreenshotToolZonesBoardView, coordinator: Coordinator) {
        board.tearDown()
        coordinator.board = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate,
        ScreenshotToolCollectionViewEventDelegate
    {
        weak var board: ScreenshotToolZonesBoardView?
        private var onMoveTool: ((ScreenshotToolbarItemID, ScreenshotToolZone, ScreenshotToolbarItemID?) -> Void)?
        private var onMove: ((ScreenshotToolbarItemID, Int) -> Void)?
        private var focusedTool: Binding<ScreenshotToolbarItemID?>?
        private var lastHandledFocusRequest: ScreenshotToolbarItemID?

        func update(
            from source: ScreenshotToolZonesBoardBridge,
            board: ScreenshotToolZonesBoardView,
            tooltipHost: BlocksImmediateTooltipHostModel?
        ) {
            onMoveTool = source.onMoveTool
            onMove = source.onMove
            focusedTool = source.focusedTool
            self.board = board
            board.update(snapshot: source.snapshot, tooltipHost: tooltipHost)

            let requestedTool = source.focusedTool.wrappedValue
            guard let requestedTool else {
                lastHandledFocusRequest = nil
                board.synchronizeSelection(tool: nil, requestsFocus: false)
                return
            }
            guard board.contains(tool: requestedTool) else {
                lastHandledFocusRequest = nil
                board.synchronizeSelection(tool: nil, requestsFocus: false)
                return
            }
            let requestsFocus = requestedTool != lastHandledFocusRequest
            lastHandledFocusRequest = requestedTool
            board.synchronizeSelection(tool: requestedTool, requestsFocus: requestsFocus)
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

        func collectionView(
            _ collectionView: NSCollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            guard let collectionView = collectionView as? ScreenshotToolCollectionView else { return 0 }
            return board?.tools(in: collectionView.toolZone).count ?? 0
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            guard let item = collectionView.makeItem(
                withIdentifier: ScreenshotToolCollectionViewItem.reuseIdentifier,
                for: indexPath
            ) as? ScreenshotToolCollectionViewItem else {
                return NSCollectionViewItem()
            }
            guard let collectionView = collectionView as? ScreenshotToolCollectionView else { return item }
            let zone = collectionView.toolZone
            let tools = board?.tools(in: zone) ?? []
            guard tools.indices.contains(indexPath.item) else { return item }
            let tool = tools[indexPath.item]
            item.configure(
                tool: tool,
                zone: zone,
                onFocus: { [weak self] in
                    self?.focusedTool?.wrappedValue = tool
                    self?.board?.synchronizeSelection(tool: tool, requestsFocus: true)
                },
                onMoveToZone: { [weak self] destination in
                    self?.requestMove(tool: tool, to: destination, before: nil)
                },
                onPointerDrag: { [weak self] phase in
                    self?.handlePointerDrag(phase, tool: tool, sourceZone: zone)
                }
            )
            return item
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            guard let collectionView = collectionView as? ScreenshotToolCollectionView,
                  let index = indexPaths.first?.item else { return }
            let tools = board?.tools(in: collectionView.toolZone) ?? []
            guard tools.indices.contains(index) else { return }
            board?.deselectCollections(except: collectionView)
            focusedTool?.wrappedValue = tools[index]
        }

        fileprivate func toolCollectionView(_ collectionView: ScreenshotToolCollectionView, move tool: ScreenshotToolbarItemID, offset: Int) {
            onMove?(tool, offset)
        }

        fileprivate func toolCollectionView(
            _ collectionView: ScreenshotToolCollectionView,
            move tool: ScreenshotToolbarItemID,
            to destination: ScreenshotToolZone
        ) {
            requestMove(tool: tool, to: destination, before: nil)
        }

        fileprivate func toolCollectionView(_ collectionView: ScreenshotToolCollectionView, focused tool: ScreenshotToolbarItemID) {
            focusedTool?.wrappedValue = tool
        }

        private func requestMove(
            tool: ScreenshotToolbarItemID,
            to destination: ScreenshotToolZone,
            before target: ScreenshotToolbarItemID?
        ) {
            focusedTool?.wrappedValue = tool
            onMoveTool?(tool, destination, target)
        }

        private func handlePointerDrag(
            _ phase: ScreenshotToolPointerDragPhase,
            tool: ScreenshotToolbarItemID,
            sourceZone: ScreenshotToolZone
        ) {
            guard let board else { return }
            switch phase {
            case let .began(windowPoint):
                guard let sourceIndex = board.tools(in: sourceZone).firstIndex(of: tool) else { return }
                board.beginPointerDrag(ScreenshotToolDragPlacement.Payload(
                    tool: tool,
                    sourceZone: sourceZone,
                    sourceIndex: sourceIndex
                ))
                board.updatePointerDrag(atWindowPoint: windowPoint)
            case let .changed(windowPoint):
                board.updatePointerDrag(atWindowPoint: windowPoint)
            case let .ended(windowPoint):
                guard let intent = board.completePointerDrag(atWindowPoint: windowPoint) else { return }
                focusedTool?.wrappedValue = intent.tool
                onMoveTool?(intent.tool, intent.destinationZone, intent.beforeTool)
            case .cancelled:
                board.cancelPointerDrag()
            }
        }
    }
}

private enum ScreenshotToolPointerDragPhase {
    case began(CGPoint)
    case changed(CGPoint)
    case ended(CGPoint)
    case cancelled
}

@MainActor
private protocol ScreenshotToolCollectionViewEventDelegate: AnyObject {
    func toolCollectionView(
        _ collectionView: ScreenshotToolCollectionView,
        move tool: ScreenshotToolbarItemID,
        offset: Int
    )
    func toolCollectionView(
        _ collectionView: ScreenshotToolCollectionView,
        move tool: ScreenshotToolbarItemID,
        to destination: ScreenshotToolZone
    )
    func toolCollectionView(
        _ collectionView: ScreenshotToolCollectionView,
        focused tool: ScreenshotToolbarItemID
    )
}

@MainActor
final class ScreenshotToolZonesBoardView: NSView {
    private var snapshot = ScreenshotToolZonesSnapshot(quick: [], expanded: [], hidden: [])
    private var pendingSnapshot: ScreenshotToolZonesSnapshot?
    private(set) var dragIsActive = false
    private var proposedDropIntent: ScreenshotToolDropIntent?
    private var pointerDragPayload: ScreenshotToolDragPlacement.Payload?
    private let zoneCards: [ScreenshotToolZone: ScreenshotToolZoneCardView]

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        var cards: [ScreenshotToolZone: ScreenshotToolZoneCardView] = [:]
        for zone in ScreenshotToolZone.allCases {
            cards[zone] = ScreenshotToolZoneCardView(zone: zone)
        }
        zoneCards = cards
        super.init(frame: frameRect)
        for zone in ScreenshotToolZone.allCases {
            if let card = zoneCards[zone] { addSubview(card) }
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        for (index, zone) in ScreenshotToolZone.allCases.enumerated() {
            zoneCards[zone]?.frame = NSRect(
                x: 0,
                y: CGFloat(index) * (ScreenshotToolZonesBoardMetrics.zoneHeight + ScreenshotToolZonesBoardMetrics.zoneSpacing),
                width: bounds.width,
                height: ScreenshotToolZonesBoardMetrics.zoneHeight
            )
        }
    }

    fileprivate func configureCollections(
        dataSource: NSCollectionViewDataSource,
        delegate: NSCollectionViewDelegate,
        eventDelegate: ScreenshotToolCollectionViewEventDelegate
    ) {
        for zone in ScreenshotToolZone.allCases {
            guard let card = zoneCards[zone] else { continue }
            card.host.collectionView.dataSource = dataSource
            card.host.collectionView.delegate = delegate
            card.host.collectionView.eventDelegate = eventDelegate
        }
    }

    func update(
        snapshot nextSnapshot: ScreenshotToolZonesSnapshot,
        tooltipHost: BlocksImmediateTooltipHostModel?
    ) {
        for zone in ScreenshotToolZone.allCases {
            guard let card = zoneCards[zone] else { continue }
            card.host.collectionView.tooltipHost = tooltipHost
        }
        guard !dragIsActive else {
            pendingSnapshot = nextSnapshot
            return
        }
        apply(snapshot: nextSnapshot)
    }

    func tools(in zone: ScreenshotToolZone) -> [ScreenshotToolbarItemID] {
        snapshot.tools(in: zone)
    }

    func contains(tool: ScreenshotToolbarItemID) -> Bool {
        ScreenshotToolZone.allCases.contains { snapshot.tools(in: $0).contains(tool) }
    }

    var configuredCollectionZones: [ScreenshotToolZone] {
        ScreenshotToolZone.allCases.compactMap { zone in
            zoneCards[zone]?.host.collectionView.toolZone
        }
    }

    func synchronizeSelection(tool: ScreenshotToolbarItemID?, requestsFocus: Bool) {
        guard let tool else {
            deselectCollections(except: nil)
            return
        }
        for zone in ScreenshotToolZone.allCases {
            guard let card = zoneCards[zone],
                  let index = snapshot.tools(in: zone).firstIndex(of: tool) else { continue }
            deselectCollections(except: card.host.collectionView)
            card.host.synchronizeSelection(itemAt: index, requestsFocus: requestsFocus)
            return
        }
        deselectCollections(except: nil)
    }

    func deselectCollections(except retained: NSCollectionView?) {
        for zone in ScreenshotToolZone.allCases {
            guard let collectionView = zoneCards[zone]?.host.collectionView,
                  collectionView !== retained else { continue }
            collectionView.deselectAll(nil)
        }
    }

    private func beginPointerSession() {
        dragIsActive = true
        pendingSnapshot = nil
        proposedDropIntent = nil
        for zone in ScreenshotToolZone.allCases {
            zoneCards[zone]?.host.collectionView.hideTooltip()
        }
    }

    func beginPointerDrag(_ payload: ScreenshotToolDragPlacement.Payload) {
        beginPointerSession()
        pointerDragPayload = payload
    }

    func updatePointerDrag(atWindowPoint windowPoint: CGPoint) {
        updatePointerDrag(atBoardPoint: convert(windowPoint, from: nil))
    }

    func updatePointerDrag(atBoardPoint boardPoint: CGPoint) {
        guard let pointerDragPayload else { return }
        proposedDropIntent = resolvedDrop(
            payload: pointerDragPayload,
            boardPoint: boardPoint
        )
        if proposedDropIntent == nil { clearDropFeedback() }
    }

    func completePointerDrag(atWindowPoint windowPoint: CGPoint) -> ScreenshotToolDropIntent? {
        completePointerDrag(atBoardPoint: convert(windowPoint, from: nil))
    }

    func completePointerDrag(atBoardPoint boardPoint: CGPoint) -> ScreenshotToolDropIntent? {
        updatePointerDrag(atBoardPoint: boardPoint)
        let intent = proposedDropIntent
        pointerDragPayload = nil
        finishPointerDrag()
        return intent
    }

    func cancelPointerDrag() {
        pointerDragPayload = nil
        finishPointerDrag()
    }

    private func finishPointerDrag() {
        clearDropFeedback()
        dragIsActive = false
        proposedDropIntent = nil
        if let pendingSnapshot {
            self.pendingSnapshot = nil
            apply(snapshot: pendingSnapshot)
        }
    }

    func tearDown() {
        cancelPointerDrag()
        clearDropFeedback()
        for zone in ScreenshotToolZone.allCases {
            guard let card = zoneCards[zone] else { continue }
            card.host.collectionView.hideTooltip()
            card.host.collectionView.dataSource = nil
            card.host.collectionView.delegate = nil
            card.host.collectionView.eventDelegate = nil
        }
    }

    private func apply(snapshot nextSnapshot: ScreenshotToolZonesSnapshot) {
        guard snapshot != nextSnapshot else { return }
        snapshot = nextSnapshot
        for zone in ScreenshotToolZone.allCases {
            guard let host = zoneCards[zone]?.host else { continue }
            host.update(toolCount: nextSnapshot.tools(in: zone).count)
            host.collectionView.reloadData()
        }
    }

    private func resolvedDrop(
        payload: ScreenshotToolDragPlacement.Payload,
        boardPoint: CGPoint
    ) -> ScreenshotToolDropIntent? {
        guard snapshot.tools(in: payload.sourceZone).indices.contains(payload.sourceIndex),
              snapshot.tools(in: payload.sourceZone)[payload.sourceIndex] == payload.tool else {
            return nil
        }
        guard let destinationZone = ScreenshotToolZone.allCases.first(where: {
            zoneCards[$0]?.frame.contains(boardPoint) == true
        }), let host = zoneCards[destinationZone]?.host else { return nil }

        var hostPoint = host.convert(boardPoint, from: self)
        host.autoScrollIfNeeded(atViewportX: hostPoint.x)
        hostPoint = host.convert(boardPoint, from: self)
        let destinationTools = snapshot.tools(in: destinationZone)
        let insertionIndex = ScreenshotToolDragPlacement.insertionIndex(
            atX: host.contentLocationX(forViewportX: hostPoint.x),
            toolCount: destinationTools.count
        )
        guard let intent = ScreenshotToolDragPlacement.intent(
            for: payload,
            destinationZone: destinationZone,
            destinationTools: destinationTools,
            insertionIndex: insertionIndex
        ) else { return nil }

        for zone in ScreenshotToolZone.allCases {
            guard let card = zoneCards[zone] else { continue }
            if zone == destinationZone {
                card.host.showInsertionIndicator(at: insertionIndex)
            } else {
                card.host.hideInsertionIndicator()
            }
        }
        return intent
    }

    private func clearDropFeedback() {
        for zone in ScreenshotToolZone.allCases {
            zoneCards[zone]?.host.hideInsertionIndicator()
        }
    }

}

@MainActor
private final class ScreenshotToolZoneCardView: BlocksAppKitGlassSurfaceView {
    let zone: ScreenshotToolZone
    let host = ScreenshotToolStripHostView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    init(zone: ScreenshotToolZone) {
        self.zone = zone
        super.init(frame: .zero)
        blocksSurfaceConfiguration = BlocksAppKitSurfaceConfiguration(
            role: .section,
            cornerRadius: BlocksVisualTokens.CornerRadius.control,
            drawsShadow: false
        )

        iconView.image = NSImage(
            systemSymbolName: zone.systemImage,
            accessibilityDescription: zone.localizedAccessibilityTitle
        )
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .secondaryLabelColor
        titleLabel.stringValue = zone.localizedAccessibilityTitle
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor

        addBlocksContentSubview(iconView)
        addBlocksContentSubview(titleLabel)
        addBlocksContentSubview(host)
        host.collectionView.toolZone = zone
        host.collectionView.setAccessibilityLabel(zone.localizedAccessibilityTitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let contentBounds = blocksContentView.bounds
        iconView.frame = NSRect(x: 12, y: contentBounds.height - 24, width: 14, height: 14)
        titleLabel.frame = NSRect(
            x: 32,
            y: contentBounds.height - 26,
            width: max(0, contentBounds.width - 44),
            height: 18
        )
        host.frame = NSRect(x: 8, y: 8, width: max(0, contentBounds.width - 16), height: 48)
    }
}

@MainActor
final class ScreenshotToolStripHostView: NSView {
    let scrollView = NSScrollView()
    fileprivate let collectionView = ScreenshotToolCollectionView()
    private let emptyPlaceholder = ScreenshotToolEmptyPlaceholderView()
    private let insertionIndicator = ScreenshotToolInsertionIndicatorView()
    private var toolCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(
            width: BlocksVisualTokens.Control.minimumHitTarget,
            height: BlocksVisualTokens.Control.minimumHitTarget
        )
        layout.minimumLineSpacing = ScreenshotToolStripMetrics.interItemDropWidth
        layout.minimumInteritemSpacing = ScreenshotToolStripMetrics.interItemDropWidth
        layout.sectionInset = NSEdgeInsets(
            top: 4,
            left: ScreenshotToolStripMetrics.leadingDropWidth,
            bottom: 4,
            right: ScreenshotToolStripMetrics.trailingDropWidth
        )

        collectionView.collectionViewLayout = layout
        collectionView.register(
            ScreenshotToolCollectionViewItem.self,
            forItemWithIdentifier: ScreenshotToolCollectionViewItem.reuseIdentifier
        )
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = collectionView
        addSubview(scrollView)
        addSubview(emptyPlaceholder)
        addSubview(insertionIndicator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let contentWidth = max(
            bounds.width,
            ScreenshotToolStripMetrics.intrinsicContentWidth(toolCount: toolCount)
        )
        collectionView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: bounds.height)
        emptyPlaceholder.frame = NSRect(
            x: ScreenshotToolStripMetrics.leadingDropWidth,
            y: 4,
            width: min(ScreenshotToolStripMetrics.emptyTargetWidth, max(0, bounds.width - 16)),
            height: BlocksVisualTokens.Control.minimumHitTarget
        )
        insertionIndicator.frame.size.height = BlocksVisualTokens.Control.minimumHitTarget
    }

    func update(toolCount: Int) {
        self.toolCount = toolCount
        emptyPlaceholder.isHidden = toolCount > 0
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func synchronizeSelection(itemAt index: Int?, requestsFocus: Bool) {
        guard let index, index >= 0 else {
            collectionView.deselectAll(nil)
            return
        }
        let indexPath = IndexPath(item: index, section: 0)
        collectionView.selectItems(at: [indexPath], scrollPosition: [.nearestHorizontalEdge])
        guard requestsFocus else { return }
        collectionView.scrollToItems(at: [indexPath], scrollPosition: [.nearestHorizontalEdge])
        if window?.firstResponder !== collectionView {
            window?.makeFirstResponder(collectionView)
        }
    }

    func showInsertionIndicator(at insertionIndex: Int) {
        let boundedIndex = min(max(0, insertionIndex), toolCount)
        let pitch = BlocksVisualTokens.Control.minimumHitTarget + ScreenshotToolStripMetrics.interItemDropWidth
        let contentX: CGFloat
        if boundedIndex == 0 {
            contentX = ScreenshotToolStripMetrics.leadingDropWidth
        } else {
            contentX = ScreenshotToolStripMetrics.leadingDropWidth
                + CGFloat(boundedIndex) * pitch
                - ScreenshotToolStripMetrics.interItemDropWidth / 2
        }
        let viewportX = contentX - scrollView.contentView.bounds.origin.x
        insertionIndicator.frame = NSRect(
            x: viewportX - 1,
            y: 4,
            width: 2,
            height: BlocksVisualTokens.Control.minimumHitTarget
        )
        insertionIndicator.isHidden = viewportX < 0 || viewportX > bounds.width
    }

    func hideInsertionIndicator() {
        insertionIndicator.isHidden = true
    }

    func contentLocationX(forViewportX viewportX: CGFloat) -> CGFloat {
        max(0, viewportX) + scrollView.contentView.bounds.origin.x
    }

    func autoScrollIfNeeded(atViewportX viewportX: CGFloat) {
        guard ScreenshotToolStripMetrics.overflows(
            toolCount: toolCount,
            viewportWidth: bounds.width
        ) else { return }
        let edgeWidth: CGFloat = 28
        let step: CGFloat = 18
        var origin = scrollView.contentView.bounds.origin
        if viewportX < edgeWidth {
            origin.x -= step
        } else if viewportX > bounds.width - edgeWidth {
            origin.x += step
        } else {
            return
        }
        let maximumX = max(0, collectionView.bounds.width - scrollView.contentView.bounds.width)
        origin.x = min(max(0, origin.x), maximumX)
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

@MainActor
private final class ScreenshotToolCollectionView: NSCollectionView {
    weak var eventDelegate: ScreenshotToolCollectionViewEventDelegate?
    weak var tooltipHost: BlocksImmediateTooltipHostModel?
    var toolZone = ScreenshotToolZone.quick
    private var hoverTrackingArea: NSTrackingArea?
    private var hoveredIndexPath: IndexPath?
    private var contextTool: ScreenshotToolbarItemID?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredItem(with: event)
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredIndexPath(nil)
        hideTooltip()
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        hideTooltip()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        hideTooltip()
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let indexPath = selectionIndexPaths.first,
              let tool = tool(at: indexPath) else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 123, 126:
            eventDelegate?.toolCollectionView(self, move: tool, offset: -1)
        case 124, 125:
            eventDelegate?.toolCollectionView(self, move: tool, offset: 1)
        case 36, 49, 76:
            eventDelegate?.toolCollectionView(self, move: tool, to: toolZone.nextZone)
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: location),
              let tool = tool(at: indexPath) else { return nil }
        selectItems(at: [indexPath], scrollPosition: [])
        contextTool = tool
        eventDelegate?.toolCollectionView(self, focused: tool)

        let menu = NSMenu()
        for destination in ScreenshotToolZone.allCases where destination != toolZone {
            let item = NSMenuItem(
                title: destination.moveActionTitle,
                action: #selector(moveContextTool(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = destination.menuTag
            menu.addItem(item)
        }
        return menu
    }

    func hideTooltip() {
        tooltipHost?.hide()
        setHoveredIndexPath(nil)
    }

    @objc private func moveContextTool(_ sender: NSMenuItem) {
        guard let tool = contextTool,
              let destination = ScreenshotToolZone(menuTag: sender.tag) else { return }
        eventDelegate?.toolCollectionView(self, move: tool, to: destination)
    }

    private func updateHoveredItem(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let next = indexPathForItem(at: location)
        guard next != hoveredIndexPath else { return }
        setHoveredIndexPath(next)
        guard let next,
              let tool = tool(at: next),
              let item = item(at: next) else {
            hideTooltip()
            return
        }
        tooltipHost?.show(label: tool.localizedSettingsTitle, anchor: item.view)
    }

    private func setHoveredIndexPath(_ next: IndexPath?) {
        if let previous = hoveredIndexPath,
           let item = item(at: previous) as? ScreenshotToolCollectionViewItem {
            item.setHovered(false)
        }
        hoveredIndexPath = next
        if let next, let item = item(at: next) as? ScreenshotToolCollectionViewItem {
            item.setHovered(true)
        }
    }

    private func tool(at indexPath: IndexPath) -> ScreenshotToolbarItemID? {
        guard let dataSource,
              indexPath.item < dataSource.collectionView(self, numberOfItemsInSection: indexPath.section),
              let item = item(at: indexPath) as? ScreenshotToolCollectionViewItem else { return nil }
        return item.tool
    }
}

@MainActor
private final class ScreenshotToolCollectionViewItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ScreenshotToolCollectionViewItem")
    private var toolView: ScreenshotToolCollectionItemView { view as! ScreenshotToolCollectionItemView }
    private(set) var tool: ScreenshotToolbarItemID?

    override func loadView() {
        view = ScreenshotToolCollectionItemView(frame: NSRect(
            x: 0,
            y: 0,
            width: BlocksVisualTokens.Control.minimumHitTarget,
            height: BlocksVisualTokens.Control.minimumHitTarget
        ))
    }

    override var isSelected: Bool {
        didSet { toolView.setSelected(isSelected) }
    }

    func configure(
        tool: ScreenshotToolbarItemID,
        zone: ScreenshotToolZone,
        onFocus: @escaping () -> Void,
        onMoveToZone: @escaping (ScreenshotToolZone) -> Void,
        onPointerDrag: @escaping (ScreenshotToolPointerDragPhase) -> Void
    ) {
        self.tool = tool
        toolView.configure(
            tool: tool,
            zone: zone,
            onFocus: onFocus,
            onMoveToZone: onMoveToZone,
            onPointerDrag: onPointerDrag
        )
        toolView.setSelected(isSelected)
    }

    func setHovered(_ hovered: Bool) { toolView.setHovered(hovered) }

    override func prepareForReuse() {
        super.prepareForReuse()
        tool = nil
        toolView.prepareForReuse()
    }
}

@MainActor
private final class ScreenshotToolCollectionItemView: NSView {
    private let imageView = NSImageView()
    private var hovered = false
    private var selected = false
    private var onFocus: (() -> Void)?
    private var onMoveToZone: ((ScreenshotToolZone) -> Void)?
    private var onPointerDrag: ((ScreenshotToolPointerDragPhase) -> Void)?
    private var nextZone = ScreenshotToolZone.expanded

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:))))
        addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let iconSize = ScreenshotDesignTokens.iconVisualSize + 2
        imageView.frame = NSRect(
            x: (bounds.width - iconSize) / 2,
            y: (bounds.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
    }

    func configure(
        tool: ScreenshotToolbarItemID,
        zone: ScreenshotToolZone,
        onFocus: @escaping () -> Void,
        onMoveToZone: @escaping (ScreenshotToolZone) -> Void,
        onPointerDrag: @escaping (ScreenshotToolPointerDragPhase) -> Void
    ) {
        self.onFocus = onFocus
        self.onMoveToZone = onMoveToZone
        self.onPointerDrag = onPointerDrag
        nextZone = zone.nextZone
        imageView.image = NSImage(
            systemSymbolName: tool.systemImage,
            accessibilityDescription: tool.localizedSettingsTitle
        )
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: ScreenshotDesignTokens.iconVisualSize,
            weight: .medium
        )
        imageView.contentTintColor = .secondaryLabelColor
        setAccessibilityLabel(tool.localizedSettingsTitle)
        setAccessibilityValue(L10n.format(
            "settings.screenshot.tools.movableInZone",
            zone.localizedAccessibilityTitle
        ))
        setAccessibilityCustomActions(
            ScreenshotToolZone.allCases.filter { $0 != zone }.map { destination in
                NSAccessibilityCustomAction(name: destination.moveActionTitle) { [weak self] in
                    self?.onMoveToZone?(destination)
                    return true
                }
            }
        )
        updateAppearance()
    }

    override func accessibilityPerformPress() -> Bool {
        onMoveToZone?(nextZone)
        return true
    }

    func setHovered(_ hovered: Bool) {
        self.hovered = hovered
        updateAppearance()
    }

    func setSelected(_ selected: Bool) {
        self.selected = selected
        updateAppearance()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovered = false
        selected = false
        onFocus = nil
        onMoveToZone = nil
        onPointerDrag = nil
        setAccessibilityCustomActions([])
        updateAppearance()
    }

    private func updateAppearance() {
        BlocksAppKitInteractiveChrome.apply(
            to: self,
            selected: selected,
            hovered: hovered,
            pressed: false
        )
        imageView.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
    }

    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onFocus?()
    }

    @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        let location = recognizer.location(in: nil)
        switch recognizer.state {
        case .began:
            onPointerDrag?(.began(location))
        case .changed:
            onPointerDrag?(.changed(location))
        case .ended:
            onPointerDrag?(.ended(location))
        case .cancelled, .failed:
            onPointerDrag?(.cancelled)
        default:
            break
        }
    }
}

private final class ScreenshotToolEmptyPlaceholderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let border = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: BlocksVisualTokens.CornerRadius.small,
            yRadius: BlocksVisualTokens.CornerRadius.small
        )
        border.lineWidth = 1
        border.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.separatorColor.setStroke()
        border.stroke()

        let title = L10n.string("settings.screenshot.tools.detail") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(
            at: NSPoint(x: 10, y: max(0, (bounds.height - size.height) / 2)),
            withAttributes: attributes
        )
    }
}

private final class ScreenshotToolInsertionIndicatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.cornerRadius = BlocksVisualTokens.Stroke.insertionIndicatorWidth / 2
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        }
    }
}

private extension ScreenshotToolZone {
    static var allCases: [ScreenshotToolZone] { [.quick, .expanded, .hidden] }

    var nextZone: ScreenshotToolZone {
        switch self {
        case .quick: .expanded
        case .expanded: .hidden
        case .hidden: .quick
        }
    }

    var localizedAccessibilityTitle: String {
        switch self {
        case .quick: L10n.string("settings.screenshot.tools.quick")
        case .expanded: L10n.string("settings.screenshot.tools.expanded")
        case .hidden: L10n.string("settings.screenshot.tools.library")
        }
    }

    var systemImage: String {
        switch self {
        case .quick: "bolt.fill"
        case .expanded: "ellipsis.circle"
        case .hidden: "eye.slash"
        }
    }

    var moveActionTitle: String {
        switch self {
        case .quick: L10n.string("settings.screenshot.tools.moveToQuick")
        case .expanded: L10n.string("settings.screenshot.tools.moveToExpanded")
        case .hidden: L10n.string("settings.screenshot.tools.moveToHidden")
        }
    }

    var menuTag: Int {
        switch self {
        case .quick: 0
        case .expanded: 1
        case .hidden: 2
        }
    }

    init?(menuTag: Int) {
        switch menuTag {
        case 0: self = .quick
        case 1: self = .expanded
        case 2: self = .hidden
        default: return nil
        }
    }
}

extension ScreenshotToolbarItemID {
    var localizedSettingsTitle: String {
        L10n.string("screenshot.editor.tool.\(rawValue)")
    }
}
