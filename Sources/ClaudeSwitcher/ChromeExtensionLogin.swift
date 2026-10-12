import AppKit
import ApplicationServices
import ClaudeSwitcherCore

/// Presses "Log in" on the official Claude extension's options page in each window the
/// companion opened, then waits until every one shows the signed-in view. The companion
/// approves Claude.ai's consent page itself; this only reaches the extension's own page,
/// which no other extension can script.
enum ChromeExtensionLoginRunner {
    static let chromeBundleID = "com.google.Chrome"
    static let nodeLimit = 6000
    static let depthLimit = 60

    /// Prints one JSON object and returns the process exit status.
    static func run(arguments: ArraySlice<String>) -> Int32 {
        let timeout = value(after: "--timeout", in: arguments).flatMap(TimeInterval.init) ?? 45
        let expected = value(after: "--windows", in: arguments).flatMap(Int.init) ?? 1
        let output = attempt(timeout: max(1, timeout), expectedWindows: max(1, expected))
        emit(output)
        return output["ok"] as? Bool == true ? 0 : 1
    }

    private static func value(after flag: String, in arguments: ArraySlice<String>) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.index(after: index) < arguments.endIndex else { return nil }
        return arguments[arguments.index(after: index)]
    }

    private static func emit(_ output: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data("{\"ok\":false}".utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private struct Tracked {
        let window: AXUIElement
        var pressed = false
        var signedIn = false
    }

    private static func attempt(timeout: TimeInterval, expectedWindows: Int) -> [String: Any] {
        // Never prompt from a helper: the menu app asks once, under its own name.
        guard AXIsProcessTrusted() else { return ["ok": false, "error": "accessibility_needed"] }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleID)
        guard !apps.isEmpty else { return ["ok": false, "error": "chrome_not_running"] }
        let elements = apps.map { AXUIElementCreateApplication($0.processIdentifier) }
        // Chromium builds its web accessibility tree only for an assistive client.
        for element in elements {
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        Thread.sleep(forTimeInterval: 0.5)

        var tracked: [Tracked] = []
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            for element in elements {
                for window in windows(of: element)
                where ChromeExtensionLogin.isCandidate(windowTitle: string(window, kAXTitleAttribute) ?? "")
                    && !tracked.contains(where: { CFEqual($0.window, window) }) {
                    tracked.append(Tracked(window: window))
                }
            }
            for index in tracked.indices where !tracked[index].signedIn {
                // A closed window has no role; it counts as not signed in.
                switch findControl(in: tracked[index].window) {
                case .logOut?:
                    tracked[index].signedIn = true
                case .logIn(let button)?:
                    if !tracked[index].pressed, AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
                        tracked[index].pressed = true
                    }
                case nil:
                    break
                }
            }
            let progress = ChromeExtensionLogin.Progress(windows: tracked.count,
                                                         pressed: tracked.filter(\.pressed).count,
                                                         signedIn: tracked.filter(\.signedIn).count)
            if progress.isDone(expectedWindows: expectedWindows) || Date() >= deadline {
                return progress.result(expectedWindows: expectedWindows, timedOut: true)
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    private enum Found { case logIn(AXUIElement), logOut }

    /// Breadth-first, so the page's own buttons are reached before deep content.
    private static func findControl(in window: AXUIElement) -> Found? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var head = 0
        while head < queue.count, head < nodeLimit {
            let (element, depth) = queue[head]
            head += 1
            if string(element, kAXRoleAttribute) == kAXButtonRole as String {
                switch label(of: element).flatMap(ChromeExtensionLogin.control(forLabel:)) {
                case .logIn?: return .logIn(element)
                case .logOut?: return .logOut
                case nil: break
                }
            }
            if depth < depthLimit {
                queue.append(contentsOf: children(of: element).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    private static func label(of button: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let text = string(button, attribute), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        // Web buttons often carry their text only on a static-text child.
        for child in children(of: button) where string(child, kAXRoleAttribute) == kAXStaticTextRole as String {
            return string(child, kAXValueAttribute) ?? string(child, kAXTitleAttribute)
        }
        return nil
    }

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
