import AppKit
import ClaudeSwitcherCore

/// One line of the palette: something to perform, or a note such as "Asking Jev…".
enum PaletteRow: Equatable {
    case suggestion(PaletteSuggestion)
    case note(String, symbol: String, busy: Bool = false)

    var suggestion: PaletteSuggestion? {
        if case .suggestion(let suggestion) = self { return suggestion }
        return nil
    }
}

// MARK: - Controller

/// A Spotlight-style palette: one field in the middle of the screen with the right action
/// already highlighted, so a few letters and ↩ are enough. `PaletteEngine` ranks the rows on
/// every keystroke; requests it cannot place can go to Jev. Performing a row closes the
/// palette at once, and the app shows progress in the menu bar.
@MainActor
final class CommandPaletteController: NSObject, NSTextFieldDelegate {
    static let rowLimit = 8
    /// Jev's top interpretation at or above this runs without asking, unless it removes
    /// something or quits the app.
    static let automaticProbability = 0.85
    static let noMatchHint = "No match \u{00B7} try an email, \u{2018}add\u{2019}, \u{2018}codex\u{2019}, \u{2018}best\u{2019}, or \u{2018}diagnostics\u{2019}"
    static let jevFailure = "Jev could not help \u{00B7} try different words"

    /// Replace when a TypeSafe key is added or removed while the app runs.
    var router: JevRouter?

    private let contextProvider: @MainActor () -> PaletteContext
    private let performAction: @MainActor (PaletteAction) -> Void
    private var panel: PalettePanel?
    private var content: PaletteContentView?
    private var context = PaletteContext()
    private var rows: [PaletteRow] = []
    private var selection: Int?
    private var jevTask: Task<Void, Never>?
    private var isAsking = false
    /// The rows are Jev's answer rather than a ranking of the typed text.
    private var isShowingInterpretation = false
    private var isClosing = false
    /// The app in front when the palette opened, given the keyboard back if the palette had
    /// to activate this app to get it.
    private var previousApp: NSRunningApplication?
    private var activatedForKeyboard = false

    init(context: @escaping @MainActor () -> PaletteContext,
         perform: @escaping @MainActor (PaletteAction) -> Void,
         router: JevRouter? = nil) {
        contextProvider = context
        performAction = perform
        self.router = router
        super.init()
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if isVisible { close() } else { show() }
    }

    /// Opens on the screen with the pointer, with an empty field and fresh state.
    func show() {
        let (panel, content) = makePanelIfNeeded()
        context = contextProvider()
        cancelJev()
        content.field.stringValue = ""
        refresh(keepingSelection: false)
        position(panel)
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == NSRunningApplication.current ? nil : front
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(content.field)
        if !panel.isKeyWindow {
            // Without user intent macOS may keep the keyboard elsewhere; activating asks for it.
            activatedForKeyboard = true
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        cancelJev()
        guard !isClosing, let panel, panel.isVisible else { return }
        isClosing = true
        panel.orderOut(nil)
        isClosing = false
        if activatedForKeyboard { returnKeyboardSoon() }
        activatedForKeyboard = false
    }

    /// After the action has run: if it opened nothing of ours, the app that was in front gets
    /// the keyboard back.
    private func returnKeyboardSoon() {
        guard let previous = previousApp else { return }
        previousApp = nil
        DispatchQueue.main.async {
            guard NSApp.isActive, NSApp.keyWindow == nil, NSApp.modalWindow == nil, !previous.isTerminated else { return }
            NSApp.yieldActivation(to: previous)
            previous.activate(options: [])
        }
    }

    /// Re-ranks with fresh state while open, keeping the selected row when it is still there.
    /// Jev's answer, or the wait for it, stays as it is.
    func reload() {
        guard isVisible else { return }
        context = contextProvider()
        guard !isAsking, !isShowingInterpretation else { return }
        refresh(keepingSelection: true)
    }

    // MARK: Rows

    private var query: String { content?.field.stringValue ?? "" }

    private func refresh(keepingSelection: Bool) {
        let keep = keepingSelection ? selection.flatMap { rows[$0].suggestion?.id } : nil
        let suggestions = PaletteEngine.suggestions(for: query, context: context, limit: Self.rowLimit)
        isShowingInterpretation = false
        if suggestions.isEmpty {
            setRows([.note(Self.noMatchHint, symbol: "questionmark.circle")], selecting: nil)
        } else {
            setRows(suggestions.map(PaletteRow.suggestion), selecting: keep)
        }
    }

    private func setRows(_ rows: [PaletteRow], selecting id: String?) {
        self.rows = rows
        selection = id.flatMap { id in rows.firstIndex { $0.suggestion?.id == id } }
            ?? rows.firstIndex { $0.suggestion != nil }
        guard let panel, let content else { return }
        // Rows that appear under a still pointer must not take the selection from the best match.
        PaletteRowView.ignorePointerUntilItMoves()
        let height = content.show(rows: rows, selection: selection, asking: isAsking)
        resize(panel, height: height)
        announceSelection()
    }

    private func select(_ index: Int) {
        guard rows.indices.contains(index), rows[index].suggestion != nil, selection != index else { return }
        selection = index
        content?.select(index)
        announceSelection()
    }

    private func moveSelection(by step: Int) {
        let actionable = rows.indices.filter { rows[$0].suggestion != nil }
        guard !actionable.isEmpty else { return }
        guard let current = selection, let position = actionable.firstIndex(of: current) else {
            select(actionable[0])
            return
        }
        select(actionable[min(max(position + step, 0), actionable.count - 1)])
    }

    private func perform(at index: Int) {
        guard !isAsking, rows.indices.contains(index), let suggestion = rows[index].suggestion else { return }
        if case .askJev(let text) = suggestion.action {
            ask(text)
            return
        }
        close()
        performAction(suggestion.action)
    }

    /// ⌘1–⌘9.
    private func performShortcut(_ number: Int) -> Bool {
        guard rows.indices.contains(number - 1), rows[number - 1].suggestion != nil else { return false }
        perform(at: number - 1)
        return true
    }

    /// ⎋ clears the field first, then closes.
    private func escape() {
        guard let field = content?.field, !field.stringValue.isEmpty else {
            close()
            return
        }
        field.stringValue = ""
        cancelJev()
        refresh(keepingSelection: false)
    }

    private func announceSelection() {
        guard NSWorkspace.shared.isVoiceOverEnabled, let panel, let selection,
              let suggestion = rows[selection].suggestion else { return }
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: [suggestion.title, suggestion.subtitle].compactMap { $0 }.joined(separator: ", "),
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    // MARK: Jev

    private func ask(_ text: String) {
        guard let router else {
            setRows([.note(Self.jevFailure, symbol: "sparkles")], selecting: nil)
            return
        }
        cancelJev()
        isAsking = true
        setRows([.note("Asking Jev\u{2026}", symbol: "sparkles", busy: true)], selecting: nil)
        let context = self.context
        let candidates = PaletteEngine.allCandidates(context: context, query: text)
        jevTask = Task { [weak self] in
            let result: Result<[PaletteSuggestion], any Error>
            do {
                result = .success(try await router.interpret(text, candidates: candidates, context: context))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.jevAnswered(result)
        }
    }

    private func jevAnswered(_ result: Result<[PaletteSuggestion], any Error>) {
        jevTask = nil
        isAsking = false
        guard isVisible else { return }
        guard case .success(let interpretations) = result, let top = interpretations.first else {
            setRows([.note(Self.jevFailure, symbol: "sparkles")], selecting: nil)
            return
        }
        if top.score >= Self.automaticProbability, Self.mayRunWithoutAsking(top) {
            close()
            performAction(top.action)
            return
        }
        isShowingInterpretation = true
        setRows(interpretations.map { .suggestion(Self.labelled($0)) }, selecting: nil)
    }

    /// A confident guess may run straight away, but never one that removes an account or quits.
    static func mayRunWithoutAsking(_ suggestion: PaletteSuggestion) -> Bool {
        !suggestion.isDestructive && suggestion.action != .command(.quit)
    }

    private static func labelled(_ suggestion: PaletteSuggestion) -> PaletteSuggestion {
        let likelihood = "Jev \(Int((suggestion.score * 100).rounded()))%"
        return PaletteSuggestion(id: suggestion.id, action: suggestion.action, title: suggestion.title,
                                 subtitle: [suggestion.subtitle, likelihood].compactMap { $0 }.joined(separator: " \u{00B7} "),
                                 symbol: suggestion.symbol, isDestructive: suggestion.isDestructive, score: suggestion.score)
    }

    private func cancelJev() {
        jevTask?.cancel()
        jevTask = nil
        isAsking = false
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        cancelJev()
        refresh(keepingSelection: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.scrollToBeginningOfDocument(_:)):
            moveSelection(by: -rows.count)
        case #selector(NSResponder.moveToEndOfDocument(_:)), #selector(NSResponder.scrollToEndOfDocument(_:)):
            moveSelection(by: rows.count)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            if let selection { perform(at: selection) }
        case #selector(NSResponder.cancelOperation(_:)):
            escape()
        default:
            return false
        }
        return true
    }

    // MARK: Window

    private func makePanelIfNeeded() -> (PalettePanel, PaletteContentView) {
        if let panel, let content { return (panel, content) }
        let content = PaletteContentView(preview: false)
        let panel = PalettePanel(contentRect: NSRect(origin: .zero, size: content.frame.size))
        panel.contentView = content
        content.field.delegate = self
        content.onHover = { [weak self] index in self?.select(index) }
        content.onClick = { [weak self] index in self?.perform(at: index) }
        panel.onResignKey = { [weak self] in self?.close() }
        panel.onCloseRequest = { [weak self] in self?.close() }
        panel.onCommandNumber = { [weak self] number in self?.performShortcut(number) ?? false }
        self.panel = panel
        self.content = content
        return (panel, content)
    }

    /// Centred on the screen with the pointer, its top a third of the way down.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        var top = screen.frame.maxY - screen.frame.height / 3
        top = max(top, visible.minY + size.height + 12)
        top = min(top, visible.maxY - 12)
        panel.setFrameOrigin(NSPoint(x: (visible.midX - size.width / 2).rounded(), y: (top - size.height).rounded()))
    }

    /// Grows and shrinks downwards: the field stays where the eye already is.
    private func resize(_ panel: NSPanel, height: CGFloat) {
        var frame = panel.frame
        guard frame.height != height else { return }
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - height
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    // MARK: Preview

    enum PreviewError: Error { case unknownAppearance, renderingFailed }

    /// Draws the palette with `query` typed into a 2x PNG, for README screenshots. Uses a solid
    /// stand-in for the translucent material, which only renders on screen.
    static func renderPreview(context: PaletteContext, query: String, appearance: NSAppearance.Name, to url: URL) throws {
        guard let look = NSAppearance(named: appearance) else { throw PreviewError.unknownAppearance }
        let view = PaletteContentView(preview: true)
        view.field.stringValue = query
        let suggestions = PaletteEngine.suggestions(for: query, context: context, limit: rowLimit)
        let rows: [PaletteRow] = suggestions.isEmpty
            ? [.note(noMatchHint, symbol: "questionmark.circle")]
            : suggestions.map(PaletteRow.suggestion)
        _ = view.show(rows: rows, selection: rows.firstIndex { $0.suggestion != nil }, asking: false)
        // Controls take their appearance from a window, so the view gets one that is never shown.
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = look
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }

        let scale: CGFloat = 2
        let margin: CGFloat = 40
        let size = view.bounds.size
        guard let palette = bitmap(size: size, scale: scale) else { throw PreviewError.renderingFailed }
        look.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: palette) }

        let canvas = NSSize(width: size.width + margin * 2, height: size.height + margin * 2)
        guard let output = bitmap(size: canvas, scale: scale),
              let graphics = NSGraphicsContext(bitmapImageRep: output) else { throw PreviewError.renderingFailed }
        let dark = PaletteStyle.isDark(look)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        let outline = NSBezierPath(roundedRect: frame, xRadius: PaletteContentView.cornerRadius,
                                   yRadius: PaletteContentView.cornerRadius)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.25)
        shadow.shadowBlurRadius = 28
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        (dark ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
        outline.fill()
        NSShadow().set()
        outline.addClip()
        palette.draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = output.representation(using: .png, properties: [:]) else { throw PreviewError.renderingFailed }
        try data.write(to: url, options: .atomic)
    }

    private static func bitmap(size: NSSize, scale: CGFloat) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                   pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }
}

// MARK: - Style

enum PaletteStyle {
    /// Label text at `alpha`, resolved by whichever appearance draws it. A dimmed
    /// `NSColor.labelColor` would keep the appearance current when it was made. Increase
    /// Contrast makes it stronger.
    static func label(_ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                    .accessibilityHighContrastDarkAqua])
            let dark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let contrast = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
            return NSColor(white: dark ? 1 : 0, alpha: min(1, alpha + (contrast ? 0.2 : 0)))
        }
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                .accessibilityHighContrastDarkAqua])
        return match == .darkAqua || match == .accessibilityHighContrastDarkAqua
    }
}

// MARK: - Panel

/// Borderless and non-activating: it takes the keyboard without bringing the app forward, so
/// the app underneath keeps its place and gets focus back on close.
final class PalettePanel: NSPanel {
    var onResignKey: (() -> Void)?
    var onCommandNumber: ((Int) -> Bool)?
    var onCloseRequest: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .modalPanel
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        acceptsMouseMovedEvents = true
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// A menu bar app has no Edit menu, so editing shortcuts are routed here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command, let number = Int(key), (1...9).contains(number), onCommandNumber?(number) == true {
            return true
        }
        let editing: [String: Selector] = [
            "x": #selector(NSText.cut(_:)), "c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)),
            "a": #selector(NSText.selectAll(_:)), "z": Selector(("undo:")),
        ]
        let action = flags == .command ? editing[key] : (flags == [.command, .shift] && key == "z" ? Selector(("redo:")) : nil)
        if let action, let responder = firstResponder, responder.tryToPerform(action, with: self) {
            return true
        }
        if flags == .command, key == "w" {
            onCloseRequest?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Content

/// The field, a hairline, and the rows, over a translucent material with a lighter, steadier
/// tint than a system menu so text stays easy to read.
final class PaletteContentView: NSView {
    static let width: CGFloat = 640
    static let headerHeight: CGFloat = 56
    static let rowHeight: CGFloat = 44
    static let listInset: CGFloat = 6
    static let cornerRadius: CGFloat = 14

    static func height(rows: Int) -> CGFloat {
        headerHeight + 1 + (rows > 0 ? CGFloat(rows) * rowHeight + listInset * 2 : 0)
    }

    let field = PaletteSearchField()
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    private let backdrop: NSView
    private let tint = PaletteTintView()
    private let separator = PaletteSeparatorView()
    private let icon = PaletteIconView()
    private var rowViews: [PaletteRowView] = []

    override var isFlipped: Bool { true }

    init(preview: Bool) {
        if preview {
            backdrop = PalettePreviewBackdrop()
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.maskImage = Self.roundedMask(radius: Self.cornerRadius)
            backdrop = material
        }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height(rows: 1)))
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        for view in [backdrop, tint] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        addSubview(icon)
        addSubview(field)
        addSubview(separator)
        setAsking(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Lays out `rows` and returns the height the window should have.
    func show(rows: [PaletteRow], selection: Int?, asking: Bool) -> CGFloat {
        setAsking(asking)
        while rowViews.count < rows.count {
            let view = PaletteRowView()
            view.onHover = { [weak self] index in self?.onHover?(index) }
            view.onClick = { [weak self] index in self?.onClick?(index) }
            rowViews.append(view)
            addSubview(view)
        }
        let height = Self.height(rows: rows.count)
        setFrameSize(NSSize(width: Self.width, height: height))
        let top = Self.headerHeight + 1 + Self.listInset
        for (index, view) in rowViews.enumerated() {
            guard index < rows.count else {
                view.isHidden = true
                view.configure(nil, index: index, selected: false)
                continue
            }
            view.isHidden = false
            view.frame = NSRect(x: 0, y: top + CGFloat(index) * Self.rowHeight, width: Self.width, height: Self.rowHeight)
            view.configure(rows[index], index: index, selected: index == selection)
        }
        layoutHeader()
        return height
    }

    func select(_ index: Int) {
        for (position, view) in rowViews.enumerated() where !view.isHidden {
            view.isSelected = position == index
        }
    }

    override func layout() {
        super.layout()
        layoutHeader()
    }

    private func layoutHeader() {
        icon.frame = NSRect(x: 20, y: (Self.headerHeight - 22) / 2, width: 22, height: 22)
        field.frame = NSRect(x: 52, y: (Self.headerHeight - 26) / 2, width: Self.width - 52 - 20, height: 26)
        separator.frame = NSRect(x: 0, y: Self.headerHeight, width: Self.width, height: 1)
    }

    private func setAsking(_ asking: Bool) {
        icon.symbol = asking ? "sparkles" : "magnifyingglass"
        icon.color = asking ? .controlAccentColor : PaletteStyle.label(0.6)
    }

    /// A stretchable rounded mask, so the window shadow follows the corners.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

final class PaletteSearchField: NSTextField {
    static let placeholder = "Switch, add or manage accounts\u{2026}"

    init() {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        lineBreakMode = .byClipping
        cell?.isScrollable = true
        cell?.wraps = false
        font = .systemFont(ofSize: 20)
        textColor = .labelColor
        placeholderAttributedString = NSAttributedString(string: Self.placeholder, attributes: [
            .font: NSFont.systemFont(ofSize: 20),
            .foregroundColor: PaletteStyle.label(0.45),
        ])
        setAccessibilityLabel("Command palette")
        setAccessibilityHelp("Type an account, a command or a request. Up and down choose, Return performs.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The lighter, more opaque layer over the material. Drawn, so it follows light and dark mode.
final class PaletteTintView: NSView {
    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let dark = PaletteStyle.isDark(effectiveAppearance)
        let fill = dark ? NSColor.windowBackgroundColor.withAlphaComponent(0.62) : NSColor(white: 0.99, alpha: 0.6)
        fill.setFill()
        let radius = PaletteContentView.cornerRadius
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.1)).setStroke()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        edge.lineWidth = 1
        edge.stroke()
    }
}

/// Stands in for the material in offscreen previews.
final class PalettePreviewBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let dark = PaletteStyle.isDark(effectiveAppearance)
        (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.955, alpha: 1)).setFill()
        let radius = PaletteContentView.cornerRadius
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

/// The magnifier, or sparkles while Jev thinks. Drawn rather than an image view, so its colour
/// is resolved for the current appearance, offscreen too.
final class PaletteIconView: NSView {
    var symbol = "magnifyingglass" { didSet { needsDisplay = true } }
    var color = NSColor.labelColor { didSet { needsDisplay = true } }

    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        PaletteRowView.drawSymbol(symbol, color: color, pointSize: 18, weight: .medium, in: bounds)
    }
}

final class PaletteSeparatorView: NSView {
    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        PaletteStyle.label(0.1).setFill()
        bounds.fill()
    }
}

// MARK: - Row

final class PaletteRowView: NSView {
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
        }
    }

    private var row: PaletteRow?
    private var index = 0
    private let spinner = NSProgressIndicator()
    /// Hovering selects only when the pointer really moves, not when rows change under a still pointer.
    private static var lastPointer: NSPoint?

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    init() {
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityElement(false)
        addSubview(spinner)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ row: PaletteRow?, index: Int, selected: Bool) {
        self.row = row
        self.index = index
        isSelected = selected
        if case .note(_, _, let busy) = row, busy {
            spinner.frame = NSRect(x: 24, y: (PaletteContentView.rowHeight - 16) / 2, width: 16, height: 16)
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let dark = PaletteStyle.isDark(effectiveAppearance)
        let suggestion = row.suggestion
        if isSelected, suggestion != nil {
            NSColor.controlAccentColor.withAlphaComponent(dark ? 0.32 : 0.2).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
        let title: String
        let subtitle: String?
        let symbol: String
        var titleColor = NSColor.labelColor
        var symbolColor = PaletteStyle.label(0.75)
        var busy = false
        switch row {
        case .suggestion(let value):
            title = value.title
            subtitle = value.subtitle
            symbol = value.symbol
            if value.isDestructive {
                titleColor = .systemRed
                symbolColor = .systemRed
            }
        case .note(let text, let name, let isBusy):
            title = text
            subtitle = nil
            symbol = name
            titleColor = PaletteStyle.label(0.75)
            busy = isBusy
        }
        if !busy {
            Self.drawSymbol(symbol, color: symbolColor, pointSize: 16, weight: .regular,
                            in: NSRect(x: 22, y: (bounds.height - 20) / 2, width: 20, height: 20))
        }

        let hintWidth: CGFloat = suggestion == nil ? 0 : 56
        let textX: CGFloat = 54
        let textWidth = bounds.width - textX - hintWidth - 14
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let titleFont = NSFont.systemFont(ofSize: 14, weight: isSelected && suggestion != nil ? .medium : .regular)
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: titleColor, .paragraphStyle: paragraph]
        if let subtitle {
            (title as NSString).draw(with: NSRect(x: textX, y: 5, width: textWidth, height: 19),
                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttributes)
            let subtitleAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5),
                .foregroundColor: PaletteStyle.label(0.7),
                .paragraphStyle: paragraph,
            ]
            (subtitle as NSString).draw(with: NSRect(x: textX, y: 24, width: textWidth, height: 16),
                                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: subtitleAttributes)
        } else {
            (title as NSString).draw(with: NSRect(x: textX, y: (bounds.height - 18) / 2, width: textWidth, height: 19),
                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttributes)
        }

        guard suggestion != nil else { return }
        let hint = isSelected ? "\u{21A9}" : (index < 9 ? "\u{2318}\(index + 1)" : "")
        guard !hint.isEmpty else { return }
        let hintAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: isSelected ? 14 : 11.5, weight: .medium),
            .foregroundColor: PaletteStyle.label(isSelected ? 0.6 : 0.35),
        ]
        let size = (hint as NSString).size(withAttributes: hintAttributes)
        (hint as NSString).draw(at: NSPoint(x: bounds.width - 24 - size.width, y: (bounds.height - size.height) / 2),
                                withAttributes: hintAttributes)
    }

    /// An SF Symbol fitted into `box`, in `color` as the current appearance resolves it.
    static func drawSymbol(_ name: String, color: NSColor, pointSize: CGFloat, weight: NSFont.Weight, in box: NSRect) {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
                .applying(NSImage.SymbolConfiguration(paletteColors: [resolved]))) else { return }
        let size = image.size
        let fit = min(box.width / max(size.width, 1), box.height / max(size.height, 1), 1)
        let drawn = NSSize(width: size.width * fit, height: size.height * fit)
        image.draw(in: NSRect(x: box.midX - drawn.width / 2, y: box.midY - drawn.height / 2,
                              width: drawn.width, height: drawn.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: Mouse

    static func ignorePointerUntilItMoves() {
        lastPointer = NSEvent.mouseLocation
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseMoved(with event: NSEvent) {
        let pointer = NSEvent.mouseLocation
        guard pointer != Self.lastPointer else { return }
        Self.lastPointer = pointer
        if row?.suggestion != nil { onHover?(index) }
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard row?.suggestion != nil, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?(index)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { row != nil && !isHidden }

    override func accessibilityRole() -> NSAccessibility.Role? {
        row?.suggestion == nil ? .staticText : .button
    }

    override func accessibilityLabel() -> String? {
        switch row {
        case .suggestion(let value): return [value.title, value.subtitle].compactMap { $0 }.joined(separator: ", ")
        case .note(let text, _, _): return text
        case nil: return nil
        }
    }

    override func accessibilityHelp() -> String? {
        guard row?.suggestion != nil else { return nil }
        return index < 9 ? "Return or Command-\(index + 1) performs it" : "Return performs it"
    }

    override func isAccessibilitySelected() -> Bool { isSelected }

    override func accessibilityPerformPress() -> Bool {
        guard row?.suggestion != nil else { return false }
        onClick?(index)
        return true
    }
}
