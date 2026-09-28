import AppKit

/// Feedback stays in the menu bar even after the account menu closes.
@MainActor
final class StatusItemFeedback {
    private weak var button: NSStatusBarButton?
    private let spinner = ClickThroughProgressIndicator()
    private var resetTask: Task<Void, Never>?

    init(button: NSStatusBarButton) {
        self.button = button
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.usesThreadedAnimation = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.setAccessibilityElement(false)
        button.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
        ])
        showIdle()
    }

    func begin(email: String) {
        resetTask?.cancel()
        resetTask = nil
        button?.image = nil
        button?.title = ""
        button?.contentTintColor = nil
        setDescription("Switching to \(email)…")
        spinner.startAnimation(nil)
    }

    func finish(ok: Bool, browserReady: Bool, email: String, message: String,
                onSuccessDismiss: @escaping @MainActor () -> Void) {
        resetTask?.cancel()
        spinner.stopAnimation(nil)
        let complete = ok && browserReady
        showSymbol(complete ? "checkmark" : "exclamationmark.triangle",
                   tint: complete ? Self.successColor : (ok ? Self.warningColor : Self.failureColor))
        setDescription(complete ? "Switched to \(email)" : message)
        guard complete else { return }
        resetTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            guard let self else { return }
            self.showIdle(email: email)
            onSuccessDismiss()
        }
    }

    private func showIdle(email: String? = nil) {
        showSymbol("person.2.circle", tint: nil)
        setDescription(email.map { $0 } ?? "Claude and Codex accounts")
    }

    private func showSymbol(_ name: String, tint: NSColor?) {
        var image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: tint == nil ? .regular : .semibold))
        if let tint {
            image = image?.withSymbolConfiguration(.init(paletteColors: [tint]))
        }
        image?.isTemplate = tint == nil
        button?.image = image
        button?.title = image == nil ? "Accounts" : ""
        button?.contentTintColor = nil
    }

    private func setDescription(_ text: String) {
        button?.toolTip = text
        button?.setAccessibilityLabel(text)
    }

    private static let successColor = adaptive(light: (0.12, 0.46, 0.27), dark: (0.38, 0.82, 0.51))
    private static let warningColor = adaptive(light: (0.60, 0.36, 0.02), dark: (1, 0.72, 0.29))
    private static let failureColor = adaptive(light: (0.76, 0.16, 0.14), dark: (1, 0.39, 0.35))

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
    }
}

private final class ClickThroughProgressIndicator: NSProgressIndicator {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
