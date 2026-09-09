import AppKit

enum PreviewCardAction {
    case activate(CGWindowID)
    case close(CGWindowID)
    case refresh(CGWindowID)
}

/// One window thumbnail card used by both preview panels.
final class WindowCardView: NSView {
    let windowID: CGWindowID
    var onClick: ((CGWindowID) -> Void)?
    var onClose: ((CGWindowID) -> Void)?
    var onRefresh: ((CGWindowID) -> Void)?
    var onEntered: ((CGWindowID) -> Void)?
    var onExited: ((CGWindowID) -> Void)?

    private let imageView = NSImageView()
    private let closeButton = NSButton()
    private let refreshButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let thumbHeight: CGFloat
    private let footerHeight: CGFloat
    private let titleFontSize: CGFloat
    private let titleInHeader: Bool
    private let allowsRefresh: Bool
    private let fallbackImage: NSImage?
    private var trackingArea: NSTrackingArea?

    static func fittedSize(for window: WindowInfo, maxSize: NSSize, footerHeight: CGFloat = 30) -> (card: NSSize, image: NSSize) {
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
        return (NSSize(width: image.width, height: image.height + footerHeight), image)
    }

    init(window: WindowInfo, cardSize: NSSize, thumbHeight: CGFloat, closeSize: CGFloat = 18,
         footerHeight: CGFloat = 30, titleFontSize: CGFloat = 10,
         titleInHeader: Bool = false,
         displayTitle: String? = nil,
         showsCloseButton: Bool = true,
         allowsRefresh: Bool = false,
         fallbackImage: NSImage? = nil) {
        self.windowID = window.id
        self.thumbHeight = thumbHeight
        self.footerHeight = footerHeight
        self.titleFontSize = titleFontSize
        self.titleInHeader = titleInHeader
        self.allowsRefresh = allowsRefresh
        self.fallbackImage = fallbackImage
        super.init(frame: NSRect(origin: .zero, size: cardSize))
        wantsLayer = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(imageView)

        titleLabel.stringValue = displayTitle ?? (window.title.isEmpty ? "窗口" : window.title)
        titleLabel.font = .systemFont(ofSize: titleFontSize, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = titleInHeader ? .left : .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        addSubview(titleLabel)

        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.stringValue = "预览不可用"
        statusLabel.isHidden = true
        addSubview(statusLabel)

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

        layoutCard(cardSize: cardSize, closeSize: closeSize)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { bounds.size }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onEntered?(windowID) }
    override func mouseExited(with event: NSEvent) { onExited?(windowID) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        // Image/title/status subviews are display-only. Route their clicks to
        // the card so clicking anywhere in the preview activates this exact
        // window; keep the macOS-style close button independently clickable.
        if !closeButton.isHidden, closeButton.frame.contains(point) { return closeButton }
        if !refreshButton.isHidden, refreshButton.frame.contains(point) { return refreshButton }
        return self
    }

    private func layoutCard(cardSize: NSSize, closeSize: CGFloat) {
        if titleInHeader {
            // First-layer cards use a compact title bar above the thumbnail:
            // the close affordance and title share one stable horizontal row.
            imageView.frame = NSRect(x: 0, y: 0, width: cardSize.width, height: thumbHeight)
            titleLabel.frame = NSRect(x: closeSize + 12,
                                      y: thumbHeight,
                                      width: max(0, cardSize.width - closeSize - 16),
                                      height: max(12, footerHeight))
            closeButton.frame = NSRect(x: 5,
                                       y: thumbHeight + (footerHeight - closeSize) / 2,
                                       width: closeSize, height: closeSize)
            refreshButton.frame = NSRect(x: cardSize.width - 26, y: 6, width: 20, height: 20)
            statusLabel.frame = NSRect(x: 8, y: thumbHeight / 2 - 12,
                                       width: cardSize.width - 16, height: 24)
        } else {
            // Full preview cards keep their existing footer title treatment.
            imageView.frame = NSRect(x: 0, y: footerHeight, width: cardSize.width, height: thumbHeight)
            titleLabel.frame = NSRect(x: 0, y: 0, width: cardSize.width,
                                      height: max(12, footerHeight))
            statusLabel.frame = NSRect(x: 8, y: footerHeight + thumbHeight / 2 - 12,
                                       width: cardSize.width - 16, height: 24)
            closeButton.frame = NSRect(x: 8,
                                       y: cardSize.height - closeSize - 8,
                                       width: closeSize, height: closeSize)
            refreshButton.frame = NSRect(x: cardSize.width - 30,
                                         y: footerHeight + 8,
                                         width: 22, height: 22)
        }
    }

    @objc private func closePressed() { onClose?(windowID) }
    @objc private func refreshPressed() { onRefresh?(windowID) }

    override func mouseDown(with event: NSEvent) {
        onClick?(windowID)
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            onClose?(windowID)
        } else {
            super.otherMouseDown(with: event)
        }
    }

    func action(atWindowPoint point: NSPoint) -> PreviewCardAction? {
        let localPoint = convert(point, from: nil)
        guard bounds.contains(localPoint) else { return nil }
        if !closeButton.isHidden, closeButton.frame.contains(localPoint) { return .close(windowID) }
        if !refreshButton.isHidden, refreshButton.frame.contains(localPoint) {
            return .refresh(windowID)
        }
        return .activate(windowID)
    }

    func setImage(_ image: CGImage?) {
        if let image {
            imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            titleLabel.textColor = titleInHeader ? .labelColor : adaptiveTextColor(for: image)
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
