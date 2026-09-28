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
        /// `nil` renders as an em dash when the provider has no reading for this window.
        let percent: Int?
        let level: UsageLevel
        let trailing: String?
        var isCached: Bool = false
    }

    /// Where item titles start in a menu with a state column, so the rows line up with the
    /// profile label above them.
    static let titleInset: CGFloat = 30
    static let preferredWidth: CGFloat = 407
    private static let rightInset: CGFloat = 14
    private static let rowHeight: CGFloat = 22
    private static let labelWidth: CGFloat = 36
    private static let barWidth: CGFloat = 22
    private static let barHeight: CGFloat = 9
    private static let percentWidth: CGFloat = 36

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
        let font = NSFont.menuFont(ofSize: 11)
        let label: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let note: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 10.5), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]

        let visible = Array(rows.prefix(2))
        let availableWidth = bounds.width - Self.titleInset - Self.rightInset
        let columnWidth = (availableWidth - 22) / 2
        for (index, row) in visible.enumerated() {
            let tint = row.percent == nil || row.isCached ? NSColor.secondaryLabelColor : Self.color(for: row.level)
            let number: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: tint]
            let top: CGFloat = 0
            let baseline = (Self.rowHeight - font.capHeight) / 2 - 1
            let start = Self.titleInset + CGFloat(index) * (columnWidth + 22)
            var x = start
            if index == 1 {
                ("|" as NSString).draw(at: NSPoint(x: start - 14, y: baseline), withAttributes: label)
            }
            (row.label as NSString).draw(at: NSPoint(x: x, y: baseline), withAttributes: label)
            x += Self.labelWidth

            let track = NSRect(x: x, y: top + (Self.rowHeight - Self.barHeight) / 2, width: Self.barWidth, height: Self.barHeight)
            // A small rounded gauge. Fill and percentage both mean usage consumed.
            tint.withAlphaComponent(0.7).setStroke()
            let outline = NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2)
            outline.lineWidth = 0.8
            outline.stroke()
            if let percent = row.percent, percent > 0 {
                let inner = track.insetBy(dx: 1.5, dy: 1.5)
                let fill = NSRect(x: inner.minX, y: inner.minY,
                                  width: max(1, inner.width * CGFloat(min(percent, 100)) / 100),
                                  height: inner.height)
                tint.setFill()
                NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()
            }
            x += Self.barWidth + 10

            let text = row.percent.map { "\($0)%" } ?? "\u{2014}"
            (text as NSString).draw(at: NSPoint(x: x, y: baseline), withAttributes: number)
            x += Self.percentWidth

            if let trailing = row.trailing {
                let available = start + columnWidth - x
                if available > 20 {
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(rect: NSRect(x: x, y: 0, width: available, height: bounds.height)).addClip()
                    (trailing as NSString).draw(at: NSPoint(x: x, y: baseline), withAttributes: note)
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
        }
    }

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
}
