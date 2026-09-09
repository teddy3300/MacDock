import AppKit

/// Small preview shown above the dock: an app header bar + a row of window cards with 4 action buttons.
final class SmallPreviewPanel: NSPanel {
    static let maxCards = 20
    static let maxPanelWidth: CGFloat = 2400
    static let standardCardWidth: CGFloat = 280
    static let padding: CGFloat = 10
    static let spacing: CGFloat = 10
    static let headerHeight: CGFloat = 28

    var onEntered: (() -> Void)?
    var onExited: (() -> Void)?
    var onCardEntered: ((CGWindowID) -> Void)?
    var onCardExited: ((CGWindowID) -> Void)?
    var onCardHeaderEntered: ((CGWindowID) -> Void)?
    var onCardClick: ((CGWindowID) -> Void)?
    var onCardClose: ((CGWindowID) -> Void)?
    var onCardQuit: ((CGWindowID) -> Void)?
    var onCardMinimize: ((CGWindowID) -> Void)?
    var onCardFullscreen: ((CGWindowID, Bool) -> Void)?
    var onCardRefresh: ((CGWindowID) -> Void)?

    private let root = HoverTrackingView(frame: .zero)
    private let headerView = NSView()
    private let appIconView = NSImageView()
    private let appNameLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
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
        let availableWidth = max(160, screenWidth - 24)
        let desiredWidth = padding * 2
            + CGFloat(count) * standardCardWidth
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
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(effect)

        // Top App Header
        headerView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerView)

        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(appIconView)

        appNameLabel.font = .systemFont(ofSize: 13, weight: .bold)
        appNameLabel.textColor = .labelColor
        appNameLabel.lineBreakMode = .byTruncatingTail
        appNameLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(appNameLabel)

        // Scrollable cards row
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        cardsStack.orientation = .horizontal
        cardsStack.spacing = Self.spacing
        cardsStack.alignment = .top
        cardsStack.distribution = .fill
        cardsStack.translatesAutoresizingMaskIntoConstraints = false

        let clip = NSClipView()
        clip.drawsBackground = false
        clip.documentView = cardsStack
        scrollView.contentView = clip

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: root.topAnchor),
            effect.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            // Top Header constraints
            headerView.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            headerView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.padding + 2),
            headerView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.padding),
            headerView.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            appIconView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            appIconView.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            appIconView.widthAnchor.constraint(equalToConstant: 20),
            appIconView.heightAnchor.constraint(equalToConstant: 20),

            appNameLabel.leadingAnchor.constraint(equalTo: appIconView.trailingAnchor, constant: 8),
            appNameLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            appNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor),

            // Scroll View constraints
            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.padding),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.padding),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.padding),
        ])
        contentView = root
    }

    func setWindows(_ windows: [WindowInfo], images: [CGWindowID: CGImage], appName: String,
                    appIcon: NSImage? = nil,
                    titleForWindow: ((WindowInfo) -> String)? = nil) {
        // Update App Header
        appIconView.image = appIcon
        appNameLabel.stringValue = appName

        for v in cardsStack.arrangedSubviews {
            cardsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        cards.removeAll()

        let visible = Array(windows.prefix(Self.maxCards))
        let screenWidth = NSScreen.main?.frame.width ?? 1440
        let panelWidth = Self.layoutWidth(windowCount: visible.count, screenWidth: screenWidth)

        var maxHeight: CGFloat = 0
        let showTitle = AppSettings.shared.showWindowTitle
        let showClose = AppSettings.shared.showCloseButton
        let thumbHeight = AppSettings.shared.cardHeight
        let footerHeight: CGFloat = showTitle ? 34 : 0

        for w in visible {
            let fitted = WindowCardView.fittedSize(for: w,
                                                   maxSize: NSSize(width: Self.standardCardWidth, height: thumbHeight),
                                                   footerHeight: footerHeight)
            let title = titleForWindow?(w) ?? (w.title.isEmpty ? appName : w.title)
            let card = WindowCardView(window: w, cardSize: fitted.card, thumbHeight: fitted.image.height,
                                      closeSize: 16, footerHeight: footerHeight, titleFontSize: 11,
                                      titleInHeader: true,
                                      displayTitle: title,
                                      showsCloseButton: showClose,
                                      showsTitle: showTitle,
                                      allowsRefresh: !w.isOnScreen,
                                      fallbackImage: appIcon)
            card.onEntered = { [weak self] id in self?.onCardEntered?(id) }
            card.onExited = { [weak self] id in self?.onCardExited?(id) }
            card.onHeaderEntered = { [weak self] id in self?.onCardHeaderEntered?(id) }
            card.onClick = { [weak self] id in self?.onCardClick?(id) }
            card.onClose = { [weak self] id in self?.onCardClose?(id) }
            card.onQuit = { [weak self] id in self?.onCardQuit?(id) }
            card.onMinimize = { [weak self] id in self?.onCardMinimize?(id) }
            card.onFullscreen = { [weak self] id, zoom in self?.onCardFullscreen?(id, zoom) }
            card.onRefresh = { [weak self] id in self?.onCardRefresh?(id) }
            card.setImage(images[w.id])
            cards[w.id] = card
            cardsStack.addArrangedSubview(card)
            maxHeight = max(maxHeight, fitted.card.height)
        }

        let totalHeight = Self.padding * 2 + Self.headerHeight + 4 + (visible.isEmpty ? 220 : maxHeight)
        layoutSize = NSSize(width: max(panelWidth, 220), height: totalHeight)
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
