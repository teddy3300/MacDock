import AppKit

/// Large preview shown when the mouse enters the small preview.
final class FullPreviewPanel: NSPanel {
    static let maxCards = 5
    static let maxPanelWidth: CGFloat = 3200
    static let maxImageHeight: CGFloat = 1200
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 12

    var onEntered: (() -> Void)?
    var onExited: (() -> Void)?
    var onCardClick: ((CGWindowID) -> Void)?

    private let root = HoverTrackingView(frame: .zero)
    private let headerLabel = NSTextField(labelWithString: "")
    private let containerView = NSView()
    private let cardsStack = NSStackView()
    private var cards: [CGWindowID: WindowCardView] = [:]
    private var singleCard: WindowCardView?
    private var effect: NSVisualEffectView!
    private var layoutSize = NSSize(width: 960, height: 590)

    static func usesExpandedLayout(windowBounds: CGRect, screenSize: NSSize) -> Bool {
        guard windowBounds.width > 0, windowBounds.height > 0,
              screenSize.width > 0, screenSize.height > 0 else { return false }
        let widthRatio = windowBounds.width / screenSize.width
        let areaRatio = (windowBounds.width * windowBounds.height)
            / (screenSize.width * screenSize.height)
        let isLandscape = windowBounds.width / windowBounds.height >= 1.1
        return isLandscape && (widthRatio >= 0.72 || areaRatio >= 0.55)
    }

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

        headerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        headerLabel.textColor = .labelColor
        headerLabel.alignment = .center
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.maximumNumberOfLines = 1
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerLabel)

        containerView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(containerView)

        cardsStack.orientation = .horizontal
        cardsStack.spacing = Self.spacing
        cardsStack.alignment = .centerY
        cardsStack.distribution = .fillEqually
        cardsStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: root.topAnchor),
            effect.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            headerLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            headerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.padding),
            headerLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.padding),
            headerLabel.heightAnchor.constraint(equalToConstant: 20),

            containerView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            containerView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.padding),
            containerView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.padding),
            containerView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.padding),
        ])
        contentView = root
    }

    func setWindows(_ windows: [WindowInfo], images: [CGWindowID: CGImage], appName: String,
                    appIcon: NSImage? = nil) {
        stopLiveStream()
        if windows.count == 1, let first = windows.first {
            let title = first.title.isEmpty ? appName : first.title
            let status = first.isOnScreen ? "" : " (已最小化)"
            headerLabel.stringValue = "\(appName) · \(title)\(status)"
            headerLabel.toolTip = headerLabel.stringValue
        } else {
            headerLabel.stringValue = appName + " · \(windows.count) 个窗口"
            headerLabel.toolTip = headerLabel.stringValue
        }
        let visible = Array(windows.prefix(Self.maxCards))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        let screenSize = screen?.visibleFrame.size ?? screen?.frame.size ?? NSSize(width: 1440, height: 900)

        var totalWidth: CGFloat = 0
        var maxHeight: CGFloat = 0

        if visible.count == 1, let w = visible.first {
            let fitted = WindowCardView.adaptiveFullPreviewSize(for: w, screenSize: screenSize)
            if let card = singleCard, containerView.subviews.contains(card) {
                card.update(
                    window: w,
                    cardSize: fitted.card,
                    thumbHeight: fitted.image.height,
                    footerHeight: 0,
                    displayTitle: nil,
                    image: images[w.id],
                    fallbackImage: appIcon
                )
                cards.removeAll()
                cards[w.id] = card
            } else {
                for v in containerView.subviews {
                    v.removeFromSuperview()
                }
                cards.removeAll()
                let card = WindowCardView(
                    window: w,
                    cardSize: fitted.card,
                    thumbHeight: fitted.image.height,
                    footerHeight: 0,
                    showsCloseButton: false,
                    showsTitle: false,
                    fallbackImage: appIcon
                )
                card.translatesAutoresizingMaskIntoConstraints = false
                card.onClick = { [weak self] id in self?.onCardClick?(id) }
                card.setImage(images[w.id])
                singleCard = card
                cards[w.id] = card
                containerView.addSubview(card)
                NSLayoutConstraint.activate([
                    card.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                    card.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                    card.topAnchor.constraint(equalTo: containerView.topAnchor),
                    card.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
                ])
            }
            totalWidth = fitted.card.width + Self.padding * 2
            maxHeight = fitted.card.height
        } else {
            singleCard = nil
            for v in containerView.subviews {
                v.removeFromSuperview()
            }
            for v in cardsStack.arrangedSubviews {
                cardsStack.removeArrangedSubview(v)
                v.removeFromSuperview()
            }
            cards.removeAll()
            let count = max(visible.count, 1)
            let availableWidth = min(Self.maxPanelWidth, screenSize.width - 40)
            let cardWidth = (availableWidth - Self.padding * 2 - CGFloat(count - 1) * Self.spacing) / CGFloat(count)
            let maxImageHeight = min(Self.maxImageHeight, screenSize.height - 120)
            var cardsWidth: CGFloat = 0
            for w in visible {
                let fitted = WindowCardView.fittedSize(for: w,
                                                       maxSize: NSSize(width: cardWidth, height: maxImageHeight),
                                                       footerHeight: 0)
                let card = WindowCardView(window: w, cardSize: fitted.card, thumbHeight: fitted.image.height,
                                          footerHeight: 0,
                                          showsCloseButton: false,
                                          showsTitle: false,
                                          fallbackImage: appIcon)
                card.onClick = { [weak self] id in self?.onCardClick?(id) }
                card.setImage(images[w.id])
                cards[w.id] = card
                cardsStack.addArrangedSubview(card)
                cardsWidth += fitted.card.width
                maxHeight = max(maxHeight, fitted.card.height)
            }
            containerView.addSubview(cardsStack)
            NSLayoutConstraint.activate([
                cardsStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                cardsStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                cardsStack.topAnchor.constraint(equalTo: containerView.topAnchor),
                cardsStack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            ])
            totalWidth = cardsWidth + Self.padding * 2 + CGFloat(max(visible.count - 1, 0)) * Self.spacing
        }

        layoutSize = NSSize(width: visible.isEmpty ? 600 : totalWidth,
                            height: visible.isEmpty ? 400 : 8 + 20 + 6 + maxHeight + Self.padding)
    }

    func startLiveStream(for window: WindowInfo, frameRate: Int) {
        guard window.isOnScreen else { return }
        guard let card = cards[window.id],
              let displayLayer = card.displayLayerForLiveStream() else { return }
        LiveStreamManager.shared.startStream(
            for: window.id,
            frameRate: frameRate,
            displayLayer: displayLayer,
            onFirstFrame: { [weak card] in
                card?.showLiveStream()
            }
        )
    }

    func stopLiveStream() {
        LiveStreamManager.shared.stopCurrentStream()
        singleCard?.hideLiveStream()
        for card in cards.values {
            card.hideLiveStream()
        }
    }

    override func orderOut(_ sender: Any?) {
        stopLiveStream()
        super.orderOut(sender)
    }

    func updateImage(_ image: CGImage?, for windowID: CGWindowID) {
        cards[windowID]?.setImage(image)
    }

    func desiredSize() -> NSSize {
        layoutSize
    }
}
