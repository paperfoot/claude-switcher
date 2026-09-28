import AppKit

/// Labels keep a fixed frame, including when a background error message changes.
@MainActor
final class MenuDetailView: NSView {
    private let label: NSTextField
    init(text: String, section: Bool = false, height: CGFloat = 22) {
        label = NSTextField(labelWithString: text)
        super.init(frame: NSRect(x: 0, y: 0, width: UsageBarView.preferredWidth, height: height))
        autoresizingMask = [.width]
        label.font = section ? .systemFont(ofSize: 12, weight: .medium) : .menuFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        // NSTextField adds a 2-point text inset inside its borderless cell.
        label.frame = NSRect(x: UsageBarView.titleInset - 2, y: (height - 16) / 2,
                             width: frame.width - UsageBarView.titleInset - 12, height: 16)
        label.autoresizingMask = [.width]
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityElement(!text.isEmpty)
        setAccessibilityRole(.staticText)
        update(text: text)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(text: String) {
        label.stringValue = text
        toolTip = text.isEmpty ? nil : text
        setAccessibilityLabel(text)
    }
}
