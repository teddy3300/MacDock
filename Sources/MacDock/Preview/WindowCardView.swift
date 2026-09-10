import AppKit
import AVFoundation

/// Backing view holding an AVSampleBufferDisplayLayer for GPU hardware-accelerated video rendering.
final class LiveStreamView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func makeBackingLayer() -> CALayer {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.clear.cgColor
        layer.cornerRadius = 8
        layer.masksToBounds = true
        return layer
    }

    var displayLayer: AVSampleBufferDisplayLayer? {
        layer as? AVSampleBufferDisplayLayer
    }
}

enum PreviewCardAction {
    case activate(CGWindowID)
    case close(CGWindowID)
    case quit(CGWindowID)
    case minimize(CGWindowID)
    case fullscreen(CGWindowID, zoomOnly: Bool)
    case refresh(CGWindowID)
}

/// One window thumbnail card used by both preview panels.
final class WindowCardView: NSView {
    private(set) var windowID: CGWindowID
    var onClick: ((CGWindowID) -> Void)?
    var onClose: ((CGWindowID) -> Void)?
    var onQuit: ((CGWindowID) -> Void)?
    var onMinimize: ((CGWindowID) -> Void)?
    var onFullscreen: ((CGWindowID, Bool) -> Void)? // bool is zoomOnly (Option key)
    var onRefresh: ((CGWindowID) -> Void)?
    var onEntered: ((CGWindowID) -> Void)?           // Thumbnail entered (triggers full preview)
    var onExited: ((CGWindowID) -> Void)?            // Thumbnail exited
    var onHeaderEntered: ((CGWindowID) -> Void)?     // Header/buttons entered (prevents full preview)

    private let imageView = NSImageView()
    private let liveStreamView = LiveStreamView()
    private let minimizedBadge = NSTextField(labelWithString: "已最小化")
    private let headerView = NSView()
    private let buttonsPill = NSView()
    private let titlePill = NSView()
    private let quitButton = NSButton()
    private let closeButton = NSButton()
    private let minimizeButton = NSButton()
    private let fullscreenButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()

    private var thumbHeight: CGFloat
    private var footerHeight: CGFloat
    private var currentCardSize: NSSize = .zero
    private let titleFontSize: CGFloat
    private let titleInHeader: Bool
    private let allowsRefresh: Bool
    private var fallbackImage: NSImage?
    private var thumbTrackingArea: NSTrackingArea?
    private var headerTrackingArea: NSTrackingArea?

    func update(
        window: WindowInfo,
        cardSize: NSSize,
        thumbHeight: CGFloat,
        footerHeight: CGFloat? = nil,
        displayTitle: String? = nil,
        image: CGImage?,
        fallbackImage: NSImage? = nil
    ) {
        self.windowID = window.id
        self.thumbHeight = thumbHeight
        if let footerHeight { self.footerHeight = footerHeight }
        self.currentCardSize = cardSize
        if let fallbackImage { self.fallbackImage = fallbackImage }
        frame = NSRect(origin: frame.origin, size: cardSize)
        let title = displayTitle ?? window.title
        titleLabel.stringValue = title.isEmpty ? "窗口" : title
        titleLabel.toolTip = title
        minimizedBadge.isHidden = window.isOnScreen
        hideLiveStream()
        setImage(image)
        layoutCard(cardSize: cardSize, closeSize: 16)
        invalidateIntrinsicContentSize()
    }

    static func adaptiveFullPreviewSize(
        for window: WindowInfo,
        screenSize: NSSize,
        scale: Double = AppSettings.shared.fullPreviewScale
    ) -> (card: NSSize, image: NSSize) {
        let w = window.bounds.width
        let h = window.bounds.height
        let aspect: CGFloat
        if w <= 2 || h <= 2 {
            aspect = 16.0 / 9.0
        } else {
            aspect = max(w / max(h, 1), 0.2)
        }

        let clampedScale = max(0.3, min(scale, 0.95))
        // Screen boundaries: strictly bounded to user scale proportion of screen
        let maxAllowedWidth = max(360, screenSize.width * clampedScale)
        let maxAllowedHeight = max(240, (screenSize.height - 100) * clampedScale)

        var targetWidth: CGFloat
        var targetHeight: CGFloat

        // For small utility windows / dialogs (e.g. <= 480x360), preview at 1:1 scale
        if w > 10 && h > 10 && w <= 480 && h <= 360 {
            targetWidth = w
            targetHeight = h
        } else if w > 10 && h > 10 {
            // Standard/larger windows: scale down according to selected scale
            targetWidth = w * clampedScale
            targetHeight = h * clampedScale
        } else {
            targetWidth = min(800, maxAllowedWidth)
            targetHeight = targetWidth / aspect
        }

        // Clamp to maximum allowed boundaries while preserving exact aspect ratio
        if targetWidth > maxAllowedWidth {
            targetWidth = maxAllowedWidth
            targetHeight = targetWidth / aspect
        }
        if targetHeight > maxAllowedHeight {
            targetHeight = maxAllowedHeight
            targetWidth = targetHeight * aspect
        }

        // Ensure minimum comfortable preview size
        let minWidth: CGFloat = 360
        let minHeight: CGFloat = 220
        if targetWidth < minWidth {
            targetWidth = minWidth
            targetHeight = targetWidth / aspect
            if targetHeight > maxAllowedHeight {
                targetHeight = maxAllowedHeight
                targetWidth = targetHeight * aspect
            }
        }
        if targetHeight < minHeight {
            targetHeight = minHeight
            targetWidth = targetHeight * aspect
            if targetWidth > maxAllowedWidth {
                targetWidth = maxAllowedWidth
                targetHeight = targetWidth / aspect
            }
        }

        let finalWidth = floor(targetWidth)
        let finalHeight = floor(targetHeight)
        let size = NSSize(width: finalWidth, height: finalHeight)
        return (size, size)
    }

    static func fittedSize(for window: WindowInfo, maxSize: NSSize, footerHeight: CGFloat = 34) -> (card: NSSize, image: NSSize) {
        let aspect: CGFloat
        if window.bounds.width <= 2 || window.bounds.height <= 2 {
            aspect = 16.0 / 9.0
        } else {
            aspect = max(window.bounds.width / max(window.bounds.height, 1), 0.5)
        }
        var image = NSSize(width: maxSize.width, height: maxSize.width / aspect)
        if image.height > maxSize.height {
            image.height = maxSize.height
            image.width = image.height * aspect
        }
        let minWidth: CGFloat = footerHeight > 0 ? 260 : 120
        let finalWidth = max(image.width, minWidth)
        return (NSSize(width: finalWidth, height: image.height + footerHeight), NSSize(width: finalWidth, height: image.height))
    }

    init(window: WindowInfo, cardSize: NSSize, thumbHeight: CGFloat, closeSize: CGFloat = 16,
         footerHeight: CGFloat = 34, titleFontSize: CGFloat = 11,
         titleInHeader: Bool = false,
         displayTitle: String? = nil,
         showsCloseButton: Bool = true,
         showsTitle: Bool = true,
         allowsRefresh: Bool = false,
         fallbackImage: NSImage? = nil) {
        self.windowID = window.id
        self.thumbHeight = thumbHeight
        self.footerHeight = footerHeight
        self.titleFontSize = titleFontSize
        self.titleInHeader = titleInHeader
        self.allowsRefresh = allowsRefresh
        self.fallbackImage = fallbackImage
        self.currentCardSize = cardSize
        super.init(frame: NSRect(origin: .zero, size: cardSize))

        wantsLayer = true
        if footerHeight == 0 {
            setContentHuggingPriority(.defaultLow, for: .horizontal)
            setContentHuggingPriority(.defaultLow, for: .vertical)
        } else {
            setContentHuggingPriority(.required, for: .horizontal)
            setContentHuggingPriority(.required, for: .vertical)
        }
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)

        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.backgroundColor = NSColor(white: 0.25, alpha: 0.35).cgColor
        layer?.masksToBounds = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(imageView)

        liveStreamView.alphaValue = 0
        liveStreamView.isHidden = true
        addSubview(liveStreamView)

        minimizedBadge.font = .systemFont(ofSize: 10, weight: .semibold)
        minimizedBadge.textColor = .white
        minimizedBadge.alignment = .center
        minimizedBadge.wantsLayer = true
        minimizedBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        minimizedBadge.layer?.cornerRadius = 9
        minimizedBadge.layer?.masksToBounds = true
        minimizedBadge.isHidden = window.isOnScreen
        addSubview(minimizedBadge)

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.stringValue = "预览不可用"
        statusLabel.isHidden = true
        addSubview(statusLabel)

        refreshButton.isBordered = false
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新预览")
        refreshButton.imagePosition = .imageOnly
        refreshButton.contentTintColor = .white
        refreshButton.toolTip = "刷新窗口预览"
        refreshButton.wantsLayer = true
        refreshButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        refreshButton.layer?.cornerRadius = 10
        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed)
        refreshButton.isHidden = !allowsRefresh
        addSubview(refreshButton)

        if titleInHeader {
            buildRichHeader(displayTitle: displayTitle ?? window.title,
                            showsCloseButton: showsCloseButton,
                            showsTitle: showsTitle,
                            closeSize: closeSize)
        } else if footerHeight > 0 {
            buildSimpleFooter(displayTitle: displayTitle ?? window.title,
                              showsCloseButton: showsCloseButton,
                              closeSize: closeSize)
        }

        layoutCard(cardSize: cardSize, closeSize: closeSize)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildRichHeader(displayTitle: String, showsCloseButton: Bool, showsTitle: Bool, closeSize: CGFloat) {
        headerView.wantsLayer = true
        addSubview(headerView)

        // Buttons capsule
        buttonsPill.wantsLayer = true
        buttonsPill.layer?.cornerRadius = 13
        buttonsPill.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.45).cgColor
        buttonsPill.layer?.borderWidth = 0.5
        buttonsPill.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        headerView.addSubview(buttonsPill)

        // 1. Quit button (Pinkish red)
        setupCircleButton(quitButton,
                          sfSymbol: "power",
                          fallbackChar: "⏻",
                          color: NSColor(srgbRed: 0.95, green: 0.42, blue: 0.55, alpha: 0.9),
                          tooltip: "退出应用程序",
                          action: #selector(quitPressed))
        buttonsPill.addSubview(quitButton)

        // 2. Close button (Red)
        setupCircleButton(closeButton,
                          sfSymbol: "xmark",
                          fallbackChar: "✕",
                          color: NSColor(srgbRed: 1.0, green: 0.38, blue: 0.35, alpha: 0.9),
                          tooltip: "关闭此窗口",
                          action: #selector(closePressed))
        buttonsPill.addSubview(closeButton)

        // 3. Minimize button (Yellow)
        setupCircleButton(minimizeButton,
                          sfSymbol: "minus",
                          fallbackChar: "—",
                          color: NSColor(srgbRed: 1.0, green: 0.75, blue: 0.18, alpha: 0.9),
                          tooltip: "最小化窗口",
                          action: #selector(minimizePressed))
        buttonsPill.addSubview(minimizeButton)

        // 4. Fullscreen button (Green)
        setupCircleButton(fullscreenButton,
                          sfSymbol: "arrow.up.left.and.arrow.down.right",
                          fallbackChar: "⤢",
                          color: NSColor(srgbRed: 0.18, green: 0.80, blue: 0.35, alpha: 0.9),
                          tooltip: "全屏 (按住 Option 最大化)",
                          action: #selector(fullscreenPressed))
        buttonsPill.addSubview(fullscreenButton)

        // Title capsule
        titlePill.wantsLayer = true
        titlePill.layer?.cornerRadius = 13
        titlePill.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.45).cgColor
        titlePill.layer?.borderWidth = 0.5
        titlePill.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        headerView.addSubview(titlePill)

        titleLabel.stringValue = displayTitle.isEmpty ? "窗口" : displayTitle
        titleLabel.font = .systemFont(ofSize: titleFontSize, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        titleLabel.toolTip = displayTitle
        titleLabel.isHidden = !showsTitle
        titlePill.addSubview(titleLabel)

        buttonsPill.isHidden = !showsCloseButton
    }

    private func buildSimpleFooter(displayTitle: String, showsCloseButton: Bool, closeSize: CGFloat) {
        titleLabel.stringValue = displayTitle.isEmpty ? "窗口" : displayTitle
        titleLabel.font = .systemFont(ofSize: titleFontSize, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        addSubview(titleLabel)

        closeButton.isBordered = false
        closeButton.title = "×"
        closeButton.font = .systemFont(ofSize: 13, weight: .semibold)
        closeButton.contentTintColor = .white
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.systemRed.cgColor
        closeButton.layer?.cornerRadius = closeSize / 2
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.isHidden = !showsCloseButton
        addSubview(closeButton)
    }

    private func setupCircleButton(_ btn: NSButton, sfSymbol: String, fallbackChar: String, color: NSColor, tooltip: String, action: Selector) {
        btn.isBordered = false
        btn.toolTip = tooltip
        btn.target = self
        btn.action = action
        btn.wantsLayer = true
        btn.layer?.backgroundColor = color.cgColor
        btn.layer?.cornerRadius = 8
        btn.layer?.masksToBounds = true

        if let img = NSImage(systemSymbolName: sfSymbol, accessibilityDescription: tooltip) {
            let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            btn.image = img.withSymbolConfiguration(config) ?? img
            btn.imagePosition = .imageOnly
            btn.contentTintColor = .white
        } else {
            btn.title = fallbackChar
            btn.font = .systemFont(ofSize: 9, weight: .bold)
            btn.contentTintColor = .white
        }
    }

    override var intrinsicContentSize: NSSize {
        currentCardSize.width > 0 ? currentCardSize : bounds.size
    }

    override func layout() {
        super.layout()
        layoutCard(cardSize: bounds.size, closeSize: 16)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let thumbTrackingArea { removeTrackingArea(thumbTrackingArea) }
        if let headerTrackingArea { removeTrackingArea(headerTrackingArea) }

        if titleInHeader && footerHeight > 0 {
            let headerRect = NSRect(x: 0, y: thumbHeight, width: bounds.width, height: footerHeight)
            let hArea = NSTrackingArea(rect: headerRect,
                                       options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                       owner: self,
                                       userInfo: ["zone": "header"])
            addTrackingArea(hArea)
            headerTrackingArea = hArea

            let thumbRect = NSRect(x: 0, y: 0, width: bounds.width, height: thumbHeight)
            let tArea = NSTrackingArea(rect: thumbRect,
                                       options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                       owner: self,
                                       userInfo: ["zone": "thumbnail"])
            addTrackingArea(tArea)
            thumbTrackingArea = tArea
        } else {
            let area = NSTrackingArea(rect: bounds,
                                      options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                      owner: self,
                                      userInfo: ["zone": "full"])
            addTrackingArea(area)
            thumbTrackingArea = area
        }
    }

    override func mouseEntered(with event: NSEvent) {
        let zone = (event.trackingArea?.userInfo as? [String: String])?["zone"]
        if zone == "header" {
            onHeaderEntered?(windowID)
        } else {
            onEntered?(windowID)
        }
    }

    override func mouseExited(with event: NSEvent) {
        let zone = (event.trackingArea?.userInfo as? [String: String])?["zone"]
        if zone != "header" {
            onExited?(windowID)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let view = super.hitTest(point) else { return nil }
        if view == quitButton || view == closeButton || view == minimizeButton || view == fullscreenButton || view == refreshButton {
            return view
        }
        return self
    }

    private func layoutCard(cardSize: NSSize, closeSize: CGFloat) {
        if titleInHeader {
            headerView.frame = NSRect(x: 0, y: thumbHeight, width: cardSize.width, height: footerHeight)
            imageView.frame = NSRect(x: 4, y: 4, width: cardSize.width - 8, height: thumbHeight - 6)
            liveStreamView.frame = imageView.frame
            minimizedBadge.frame = NSRect(x: cardSize.width - 66, y: thumbHeight - 26, width: 58, height: 18)

            let pillY = (footerHeight - 26) / 2
            buttonsPill.frame = NSRect(x: 6, y: pillY, width: 94, height: 26)

            let bSize: CGFloat = 16
            let bY: CGFloat = 5
            quitButton.frame = NSRect(x: 6, y: bY, width: bSize, height: bSize)
            closeButton.frame = NSRect(x: 28, y: bY, width: bSize, height: bSize)
            minimizeButton.frame = NSRect(x: 50, y: bY, width: bSize, height: bSize)
            fullscreenButton.frame = NSRect(x: 72, y: bY, width: bSize, height: bSize)

            let titleX = buttonsPill.isHidden ? 6 : buttonsPill.frame.maxX + 8
            let titleWidth = max(40, cardSize.width - titleX - 6)
            titlePill.frame = NSRect(x: titleX, y: pillY, width: titleWidth, height: 26)
            titleLabel.frame = NSRect(x: 8, y: 3, width: max(10, titleWidth - 16), height: 20)

            refreshButton.frame = NSRect(x: cardSize.width - 28, y: 8, width: 20, height: 20)
            statusLabel.frame = NSRect(x: 8, y: thumbHeight / 2 - 12, width: cardSize.width - 16, height: 24)
        } else if footerHeight == 0 {
            // Immersive full preview mode: image fills the entire card
            imageView.frame = NSRect(origin: .zero, size: cardSize)
            liveStreamView.frame = imageView.frame
            minimizedBadge.frame = NSRect(x: cardSize.width - 66, y: cardSize.height - 26, width: 58, height: 18)
            titleLabel.frame = .zero
            titleLabel.isHidden = true
            closeButton.isHidden = true
            refreshButton.isHidden = true
            statusLabel.frame = NSRect(x: 8, y: cardSize.height / 2 - 12, width: cardSize.width - 16, height: 24)
        } else {
            imageView.frame = NSRect(x: 0, y: footerHeight, width: cardSize.width, height: thumbHeight)
            liveStreamView.frame = imageView.frame
            minimizedBadge.frame = NSRect(x: cardSize.width - 66, y: cardSize.height - 26, width: 58, height: 18)
            titleLabel.frame = NSRect(x: 0, y: 0, width: cardSize.width, height: max(12, footerHeight))
            statusLabel.frame = NSRect(x: 8, y: footerHeight + thumbHeight / 2 - 12, width: cardSize.width - 16, height: 24)
            closeButton.frame = NSRect(x: 8, y: cardSize.height - closeSize - 8, width: closeSize, height: closeSize)
            refreshButton.frame = NSRect(x: cardSize.width - 30, y: footerHeight + 8, width: 22, height: 22)
        }
    }

    func displayLayerForLiveStream() -> AVSampleBufferDisplayLayer? {
        liveStreamView.displayLayer
    }

    func showLiveStream() {
        liveStreamView.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            liveStreamView.animator().alphaValue = 1.0
        }
    }

    func hideLiveStream() {
        liveStreamView.alphaValue = 0
        liveStreamView.isHidden = true
        liveStreamView.displayLayer?.flushAndRemoveImage()
    }

    @objc private func quitPressed() { onQuit?(windowID) }
    @objc private func closePressed() { onClose?(windowID) }
    @objc private func minimizePressed() { onMinimize?(windowID) }
    @objc private func fullscreenPressed() {
        let zoom = NSEvent.modifierFlags.contains(.option)
        onFullscreen?(windowID, zoom)
    }
    @objc private func refreshPressed() { onRefresh?(windowID) }

    override func mouseDown(with event: NSEvent) {
        onClick?(windowID)
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            switch AppSettings.shared.middleClickAction {
            case .closeWindow:
                onClose?(windowID)
            case .activateWindow:
                onClick?(windowID)
            case .none:
                break
            }
        } else {
            super.otherMouseDown(with: event)
        }
    }

    func action(atWindowPoint point: NSPoint) -> PreviewCardAction? {
        let localPoint = convert(point, from: nil)
        guard bounds.contains(localPoint) else { return nil }

        if titleInHeader {
            if !buttonsPill.isHidden {
                let pInPill = buttonsPill.convert(localPoint, from: self)
                if buttonsPill.bounds.contains(pInPill) {
                    if quitButton.frame.contains(pInPill) { return .quit(windowID) }
                    if closeButton.frame.contains(pInPill) { return .close(windowID) }
                    if minimizeButton.frame.contains(pInPill) { return .minimize(windowID) }
                    if fullscreenButton.frame.contains(pInPill) {
                        return .fullscreen(windowID, zoomOnly: NSEvent.modifierFlags.contains(.option))
                    }
                }
            }
        } else {
            if !closeButton.isHidden {
                let pClose = closeButton.convert(localPoint, from: self)
                if closeButton.bounds.contains(pClose) {
                    return .close(windowID)
                }
            }
        }

        if !refreshButton.isHidden {
            let pRefresh = refreshButton.convert(localPoint, from: self)
            if refreshButton.bounds.contains(pRefresh) {
                return .refresh(windowID)
            }
        }
        return .activate(windowID)
    }

    func setImage(_ image: CGImage?) {
        if let image {
            imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            titleLabel.textColor = titleInHeader ? .labelColor : (footerHeight == 0 ? .labelColor : adaptiveTextColor(for: image))
            statusLabel.isHidden = true
            refreshButton.isHidden = true
        } else {
            imageView.image = fallbackImage
            titleLabel.textColor = .labelColor
            statusLabel.stringValue = fallbackImage == nil ? "已最小化" : ""
            statusLabel.isHidden = fallbackImage != nil
            refreshButton.isHidden = !allowsRefresh
        }
    }

    func setRefreshing(_ refreshing: Bool) {
        refreshButton.isEnabled = !refreshing
        refreshButton.alphaValue = refreshing ? 0.45 : 1
    }

    private func adaptiveTextColor(for image: CGImage) -> NSColor {
        guard let providerData = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(providerData) else { return .labelColor }
        let bytesPerPixel = max(image.bitsPerPixel / 8, 1)
        guard bytesPerPixel >= 3 else { return .labelColor }
        let rowBytes = image.bytesPerRow
        let sampleStepX = max(image.width / 4, 1)
        let sampleStepY = max(image.height / 4, 1)
        let littleEndian = image.bitmapInfo.contains(.byteOrder32Little)
        let redIndex = littleEndian ? 2 : 0
        let greenIndex = 1
        let blueIndex = littleEndian ? 0 : 2
        var luminance = 0.0
        var samples = 0
        for y in stride(from: sampleStepY / 2, to: image.height, by: sampleStepY) {
            for x in stride(from: sampleStepX / 2, to: image.width, by: sampleStepX) {
                let offset = y * rowBytes + x * bytesPerPixel
                let r = Double(bytes[offset + redIndex]) / 255.0
                let g = Double(bytes[offset + greenIndex]) / 255.0
                let b = Double(bytes[offset + blueIndex]) / 255.0
                luminance += 0.2126 * r + 0.7152 * g + 0.0722 * b
                samples += 1
            }
        }
        guard samples > 0 else { return .labelColor }
        return luminance / Double(samples) > 0.58 ? .black : .white
    }
}
