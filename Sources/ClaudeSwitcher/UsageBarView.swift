import AppKit
import ClaudeSwitcherCore

/// Compact usage rows: period, battery gauge, percentage used, and reset time.
///
/// A plain frame-based view drawn in one `draw(_:)`: `NSMenu` sizes a view item from its
/// frame and stretches it to the menu's width through the autoresizing mask. Colours are
/// semantic and resolved at draw time, so light and dark menus both come out right.
final class UsageBarView: NSView {

    struct Row: Sendable {
        let label: String
        /// `nil` renders as an em dash: the period has ended and the number is stale.
        let percent: Int?
        let level: UsageLevel
        let trailing: String?
        var isCached: Bool = false
    }

    /// Where item titles start in a menu with a state column, so the rows line up with the
    /// profile label above them.
    private static let titleInset: CGFloat = 21
    private static let rightInset: CGFloat = 14
    private static let rowHeight: CGFloat = 16
    private static let labelWidth: CGFloat = 36
    private static let barWidth: CGFloat = 22
    private static let barHeight: CGFloat = 9
    private static let percentWidth: CGFloat = 36

    private(set) var rows: [Row]

    init(rows: [Row], width: CGFloat = 300) {
        self.rows = rows
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(rows.count) * Self.rowHeight + 6))
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
        let note: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 10.5), .foregroundColor: NSColor.secondaryLabelColor]

        // Rows are laid out top-down; AppKit's origin is bottom-left.
        for (index, row) in rows.enumerated() {
            let tint = row.percent == nil || row.isCached ? NSColor.secondaryLabelColor : Self.color(for: row.level)
            let number: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]
            let top = bounds.height - 3 - CGFloat(index + 1) * Self.rowHeight
            let baseline = top + (Self.rowHeight - font.capHeight) / 2 - 1
            var x = Self.titleInset

            (row.label as NSString).draw(at: NSPoint(x: x, y: baseline), withAttributes: label)
            x += Self.labelWidth

            let track = NSRect(x: x, y: top + (Self.rowHeight - Self.barHeight) / 2, width: Self.barWidth, height: Self.barHeight)
            // A tiny battery gauge, with the percentage beside it. Fill means usage consumed.
            tint.withAlphaComponent(0.7).setStroke()
            let outline = NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2)
            outline.lineWidth = 0.8
            outline.stroke()
            tint.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: NSRect(x: track.maxX + 1, y: track.midY - 1.5, width: 1.5, height: 3),
                         xRadius: 0.6, yRadius: 0.6).fill()
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
                let available = bounds.width - Self.rightInset - x
                if available > 40 {
                    (trailing as NSString).draw(in: NSRect(x: x, y: baseline - 2, width: available, height: Self.rowHeight),
                                                withAttributes: note)
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
