import AppKit
import ClaudeSwitcherCore

/// One compact line: period, rounded gauge, percentage used, and reset time.
///
/// A plain frame-based view drawn in one `draw(_:)`: `NSMenu` sizes a view item from its
/// frame and stretches it to the menu's width through the autoresizing mask. Colours are
/// semantic and resolved at draw time, so light and dark menus both come out right.
final class UsageBarView: NSView {

    struct Row: Sendable {
        let label: String
        /// `nil` renders as an em dash: no reading for this window, or it has reset since.
        let percent: Int?
        let level: UsageLevel
        let trailing: String?
        /// The value may have moved since it was read: shown as "~84%", in the same colours.
        var isStale: Bool = false
    }

    /// Where item titles start in a menu with a state column, so the rows line up with the
    /// profile label above them.
    static let titleInset: CGFloat = 30
    static let preferredWidth: CGFloat = 407
    /// Labels, separators and reset times. `secondaryLabelColor` washes out on the
    /// translucent menu.
    static let mutedTextColor = neutralColor(alpha: 0.75)

    // A column is its label, then fixed gauge, number and reset widths; whatever is left
    // separates the two columns. At the preferred width "~100%" and the widest reset,
    // "↻ Wed 04:44", fit in both columns.
    private static let rightInset: CGFloat = 12
    private static let rowHeight: CGFloat = 22
    private static let minimumColumnGap: CGFloat = 14
    private static let labelGap: CGFloat = 5
    private static let barWidth: CGFloat = 26
    private static let barHeight: CGFloat = 10
    private static let barGap: CGFloat = 6
    private static let percentWidth: CGFloat = 44
    private static let trailingWidth: CGFloat = 69
    /// Text in every column shares one baseline, placed so the digits centre on the gauge.
    private static let baseline: CGFloat = 7
    /// Every gauge uses the same alphas, whatever its level or the reading's age.
    private static let trackAlpha: CGFloat = 0.2
    private static let outlineAlpha: CGFloat = 0.55
    private static let unknownTrackColor = neutralColor(alpha: 0.12)

    private(set) var rows: [Row]

    init(rows: [Row], width: CGFloat = UsageBarView.preferredWidth) {
        self.rows = rows
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.rowHeight))
        autoresizingMask = [.width]
    }

    func update(rows: [Row]) {
        self.rows = rows
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Keep the gauges and text distinct from the menu material.
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let labelFont = NSFont.menuFont(ofSize: 11)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let noteFont = NSFont.menuFont(ofSize: 10.5)
        let label: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: Self.mutedTextColor]
        let note: [NSAttributedString.Key: Any] = [.font: noteFont, .foregroundColor: Self.mutedTextColor]

        let visible = Array(rows.prefix(2))
        let labelWidths = visible.map { ceil(($0.label as NSString).size(withAttributes: label).width) + Self.labelGap }
        let fixedWidth = Self.barWidth + Self.barGap + Self.percentWidth + Self.trailingWidth
        let used = labelWidths.reduce(0, +) + CGFloat(visible.count) * fixedWidth
        let gap = max(Self.minimumColumnGap, bounds.width - Self.titleInset - Self.rightInset - used)
        var start = Self.titleInset
        for (index, row) in visible.enumerated() {
            if index == 1 {
                let bar = "|" as NSString
                let x = start - (gap + bar.size(withAttributes: label).width) / 2
                bar.draw(at: NSPoint(x: x, y: Self.baseline + labelFont.descender), withAttributes: label)
            }
            var x = start
            (row.label as NSString).draw(at: NSPoint(x: x, y: Self.baseline + labelFont.descender), withAttributes: label)
            x += labelWidths[index]

            let color = Self.color(for: row.level)
            let track = NSRect(x: x, y: (Self.rowHeight - Self.barHeight) / 2, width: Self.barWidth, height: Self.barHeight)
            Self.drawGauge(in: track, percent: row.percent, color: color)
            x += Self.barWidth + Self.barGap

            let text = row.percent.map { (row.isStale ? "~" : "") + "\($0)%" } ?? "\u{2014}"
            let number: [NSAttributedString.Key: Any] = [
                .font: numberFont,
                .foregroundColor: row.percent == nil ? Self.mutedTextColor : color,
            ]
            (text as NSString).draw(at: NSPoint(x: x, y: Self.baseline + numberFont.descender), withAttributes: number)
            x += Self.percentWidth

            if let trailing = row.trailing {
                // The last column may use the slack; a narrower view clips instead of overlapping.
                let end = index == visible.count - 1 ? bounds.width - Self.rightInset : x + Self.trailingWidth
                let available = end - x
                if available > 20 {
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(rect: NSRect(x: x, y: 0, width: available, height: bounds.height)).addClip()
                    (trailing as NSString).draw(at: NSPoint(x: x, y: Self.baseline + noteFont.descender), withAttributes: note)
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            start += labelWidths[index] + fixedWidth + gap
        }
    }

    /// One anatomy for every known value: a track tinted with the level colour, a thin
    /// outline, and the used portion at full strength. An unknown value keeps only a
    /// neutral track. Fill and percentage both mean usage consumed.
    private static func drawGauge(in track: NSRect, percent: Int?, color: NSColor) {
        let shape = NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3)
        guard let percent else {
            unknownTrackColor.setFill()
            shape.fill()
            return
        }
        color.withAlphaComponent(trackAlpha).setFill()
        shape.fill()
        let outline = NSBezierPath(roundedRect: track.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
        outline.lineWidth = 1
        color.withAlphaComponent(outlineAlpha).setStroke()
        outline.stroke()
        guard percent > 0 else { return }
        let inner = track.insetBy(dx: 2, dy: 2)
        let used = NSRect(x: inner.minX, y: inner.minY,
                          width: max(1, inner.width * CGFloat(min(percent, 100)) / 100), height: inner.height)
        color.setFill()
        NSBezierPath(roundedRect: used, xRadius: 1.5, yRadius: 1.5).fill()
    }

    // MARK: - Preview

    /// Draws account titles with their gauge rows on a menu-like rounded card and writes a
    /// PNG at twice the point size, for README screenshots and visual checks. Every row comes
    /// from the caller; nothing here invents data.
    static func renderPreview(rowsPerAccount accounts: [(title: String, rows: [Row])],
                              appearance name: NSAppearance.Name, to url: URL) throws {
        let padding: CGFloat = 6
        let scale: CGFloat = 2
        let size = NSSize(width: preferredWidth, height: padding * 2 + CGFloat(accounts.count) * rowHeight * 2)
        guard let appearance = NSAppearance(named: name),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                            pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            let transform = NSAffineTransform()
            transform.scale(by: scale)
            transform.concat()
            let card = NSRect(origin: .zero, size: size)
            previewBackground.setFill()
            NSBezierPath(roundedRect: card, xRadius: 10, yRadius: 10).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 9.5, yRadius: 9.5).stroke()

            let title: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor]
            var y = size.height - padding
            for account in accounts {
                y -= rowHeight
                let text = account.title as NSString
                text.draw(at: NSPoint(x: titleInset, y: y + (rowHeight - text.size(withAttributes: title).height) / 2),
                          withAttributes: title)
                y -= rowHeight
                let gauges = UsageBarView(rows: account.rows)
                NSGraphicsContext.saveGraphicsState()
                let offset = NSAffineTransform()
                offset.translateX(by: 0, yBy: y)
                offset.concat()
                gauges.draw(gauges.bounds)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        // Point size in the metadata, so the PNG opens at its menu size on a Retina display.
        bitmap.size = size
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
    }

    /// Close to the opaque menu material in each appearance.
    private static let previewBackground = adaptiveColor(light: (0.95, 0.95, 0.96), dark: (0.16, 0.16, 0.17))

    private static func color(for level: UsageLevel) -> NSColor {
        switch level {
        case .normal: return healthyColor
        case .warning: return warningColor
        case .critical, .limit: return criticalColor
        }
    }

    // Darker text colors in light mode keep these tiny numbers readable.
    private static let healthyColor = adaptiveColor(light: (0.12, 0.46, 0.27), dark: (0.38, 0.82, 0.51))
    private static let warningColor = adaptiveColor(light: (0.60, 0.36, 0.02), dark: (1.0, 0.72, 0.29))
    private static let criticalColor = adaptiveColor(light: (0.76, 0.16, 0.14), dark: (1.0, 0.39, 0.35))

    private static func adaptiveColor(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
    }

    /// Black or white at a fixed alpha, like `labelColor`. `withAlphaComponent` on a system
    /// colour resolves it once, for whichever appearance is current at that moment.
    private static func neutralColor(alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 1 : 0, alpha: alpha)
        }
    }
}
