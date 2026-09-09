import AppKit

/// Small preview shown above the dock: a row of window cards with per-window ✕.
final class SmallPreviewPanel: NSPanel {
    static let maxCards = 20
    static let compactPanelWidth: CGFloat = 360
    static let maxPanelWidth: CGFloat = 2400
    static let expandedCardWidth: CGFloat = 90
    static let maxImageHeight: CGFloat = 110
    static let padding: CGFloat = 8
    static let spacing: CGFloat = 6

    var onEntered: (() -> Void)?
    var onExited: (() -> Void)?
    var onCardEntered: ((CGWindowID) -> Void)?
    var onCardExited: ((CGWindowID) -> Void)?
    var onCardClick: ((CGWindowID) -> Void)?
    var onCardClose: ((CGWindowID) -> Void)?
    var onCardRefresh: ((CGWindowID) -> Void)?

    private let root = HoverTrackingView(frame: .zero)
    private let cardsStack = NSStackView()
    private var cards: [CGWindowID: WindowCardView] = [:]
    private var effect: NSVisualEffectView!
    private var layoutSize = NSSize(width: 420, height: 340)

    init(onEntered: (() -> Void)?, onExited: (() -> Void)?) {
        self.onEntered = onEntered
        self.onExited = onExited
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        ignoresMouseEvents = false
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        0.1
    }

    static func layoutWidth(windowCount: Int, screenWidth: CGFloat) -> CGFloat {
        let count = max(1, min(windowCount, maxCards))
        let availableWidth = max(120, screenWidth - 16)
        guard count > 5 else { return min(compactPanelWidth, availableWidth) }
        let desiredWidth = padding * 2
            + CGFloat(count) * expandedCardWidth
            + CGFloat(count - 1) * spacing
        return min(maxPanelWidth, min(desiredWidth, availableWidth))
    }

    private func buildContent() {
        root.onEntered = { [weak self] in self?.onEntered?() }
        root.onExited = { [weak self] in self?.onExited?() }

        effect = NSVisualEffectView(frame: .zero)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(effect)

        cardsStack.orientation = .horizontal
        cardsStack.spacing = Self.spacing
        cardsStack.alignment = .top
        cardsStack.distribution = .fill
        cardsStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(cardsStack)

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: root.topAnchor),
            effect.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            cardsStack.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.padding),
            cardsStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.padding),
            cardsStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.padding),
            cardsStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.padding),
        ])
        contentView = root
    }

    func setWindows(_ windows: [WindowInfo], images: [CGWindowID: CGImage], appName: String,
                    appIcon: NSImage? = nil,
                    titleForWindow: ((WindowInfo) -> String)? = nil) {
        for v in cardsStack.arrangedSubviews {
            cardsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        cards.removeAll()
        let visible = Array(windows.prefix(Self.maxCards))
        let count = max(visible.count, 1)
        let screenWidth = NSScreen.main?.frame.width ?? 1440
        let panelWidth = Self.layoutWidth(windowCount: visible.count, screenWidth: screenWidth)
        let cardWidth = min(
            170,
            (panelWidth - Self.padding * 2 - CGFloat(count - 1) * Self.spacing) / CGFloat(count)
        )
        var totalWidth = Self.padding * 2 + CGFloat(max(visible.count - 1, 0)) * Self.spacing
        var maxHeight: CGFloat = 0
        let showTitle = AppSettings.shared.showWindowTitle
        let showClose = AppSettings.shared.showCloseButton
        let thumbHeight = AppSettings.shared.cardHeight
        let footerHeight: CGFloat = showTitle ? 22 : 0
        for w in visible {
            let fitted = WindowCardView.fittedSize(for: w,
                                                   maxSize: NSSize(width: cardWidth, height: thumbHeight),
                                                   footerHeight: footerHeight)
            let title = titleForWindow?(w) ?? (w.title.isEmpty ? appName : w.title)
            let card = WindowCardView(window: w, cardSize: fitted.card, thumbHeight: fitted.image.height,
                                      closeSize: 16, footerHeight: footerHeight, titleFontSize: 9,
                                      titleInHeader: true,
                                      displayTitle: title,
                                      showsCloseButton: showClose,
                                      showsTitle: showTitle,
                                      allowsRefresh: !w.isOnScreen,
                                      fallbackImage: appIcon)
            card.onEntered = { [weak self] id in self?.onCardEntered?(id) }
            card.onExited = { [weak self] id in self?.onCardExited?(id) }
            card.onClick = { [weak self] id in self?.onCardClick?(id) }
            card.onClose = { [weak self] id in self?.onCardClose?(id) }
            card.onRefresh = { [weak self] id in self?.onCardRefresh?(id) }
            card.setImage(images[w.id])
            cards[w.id] = card
            cardsStack.addArrangedSubview(card)
            totalWidth += fitted.card.width
            maxHeight = max(maxHeight, fitted.card.height)
        }
        layoutSize = NSSize(width: visible.isEmpty ? 320 : totalWidth,
                            height: visible.isEmpty ? 250 : Self.padding * 2 + maxHeight)
    }

    func updateImage(_ image: CGImage?, for windowID: CGWindowID) {
        cards[windowID]?.setImage(image)
    }

    func setRefreshing(_ refreshing: Bool, for windowID: CGWindowID) {
        cards[windowID]?.setRefreshing(refreshing)
    }

    func action(atScreenPoint point: NSPoint) -> PreviewCardAction? {
        guard isVisible else { return nil }
        let windowPoint = convertPoint(fromScreen: point)
        for card in cards.values {
            if let action = card.action(atWindowPoint: windowPoint) {
                return action
            }
        }
        return nil
    }

    func desiredSize() -> NSSize {
        layoutSize
    }
}
