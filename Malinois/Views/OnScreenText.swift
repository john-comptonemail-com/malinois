//
//  OnScreenText.swift
//  Malinois
//
//  What a laid-out screen shows, for the tests that host a real screen (item 120). SwiftUI gives a
//  unit test no accessibility elements, so the text of a notice or badge cannot be read off a
//  rendered screen; instead each one built with `reportedOnScreen(_:)` tells a recorder in the
//  environment when it appears and disappears. Likewise a button built with `reportedAction(_:_:)`
//  hands the recorder its action, for a test to press, and the share sheet tells it what it was
//  handed (item 90, phase 4); a PIN pad's keys and a dialog iOS draws do the same (item 232). Debug
//  only: in Release the modifiers are the view itself and nothing here is compiled.
//

import SwiftUI

extension View {
    /// Tells a test that lays out this screen that `text` is on it (item 120). Nothing in Release.
    func reportedOnScreen(_ text: String) -> some View {
        #if DEBUG
        modifier(OnScreenReport(text: text))
        #else
        self
        #endif
    }

    /// Lets a test that lays out this screen press the button `label` names, with `action`, the button's own (item
    /// 90, phase 4): a unit test has no accessibility elements to activate. Nothing in Release.
    func reportedAction(_ label: String, _ action: @escaping @MainActor () -> Void) -> some View {
        #if DEBUG
        modifier(OnScreenAction(label: label, action: action))
        #else
        self
        #endif
    }

    /// As `reportedAction(_:_:)`, for a button whose action changes while it stays on screen (item 232: a PIN pad's
    /// keys submit by themselves or wait for ✓ as the pad's state has it). A test presses the action as the screen last
    /// drew it, as a finger would, where `reportedAction` keeps the one the button first appeared with. Nothing in
    /// Release.
    func reportedActionAsDrawn(_ label: String, _ action: @escaping @MainActor () -> Void) -> some View {
        #if DEBUG
        modifier(OnScreenActionAsDrawn(label: label, action: action))
        #else
        self
        #endif
    }

    /// Tells a test that lays out this screen that a dialog iOS draws is up, under `title`, and lets it press the
    /// dialog's button `label` names, or its Cancel ("Cancel: " and the title) (item 232): a confirmation is not a
    /// view, so it neither appears nor can be pressed in a unit test. Either press closes the dialog first, as iOS
    /// does; the button then runs `action`. Nothing in Release.
    func reportedDialog(_ title: String, isPresented: Binding<Bool>, button label: String,
                        _ action: @escaping @MainActor () -> Void) -> some View {
        #if DEBUG
        modifier(OnScreenDialog(title: title, isPresented: isPresented, label: label, action: action))
        #else
        self
        #endif
    }
}

#if DEBUG
/// The text of every reporting notice and badge on screen, in the order they appeared, and where each
/// was last laid out (in the window's coordinates), since appearing is not the same as being visible
/// (Codex's W1: a badge pushed above the top of the screen still appears). Also the buttons a test may
/// press, and what each share sheet the screen opened was handed (item 90, phase 4).
@MainActor
final class OnScreenRecorder {
    private(set) var shown: [String] = []
    private(set) var frames: [String: CGRect] = [:]
    private(set) var actions: [String: @MainActor () -> Void] = [:]
    private(set) var shared: [[Any]] = []

    func appeared(_ text: String) { shown.append(text) }

    func disappeared(_ text: String) {
        if let index = shown.firstIndex(of: text) { shown.remove(at: index) }
    }

    func placed(_ text: String, at frame: CGRect) { frames[text] = frame }

    func offered(_ label: String, _ action: @escaping @MainActor () -> Void) { actions[label] = action }

    func withdrew(_ label: String) { actions[label] = nil }

    func handed(_ items: [Any]) { shared.append(items) }
}

extension EnvironmentValues {
    /// Set only by a test that lays out a screen; nil in the app.
    @Entry var onScreenRecorder: OnScreenRecorder?
}

private struct OnScreenReport: ViewModifier {
    let text: String
    @Environment(\.onScreenRecorder) private var recorder

    func body(content: Content) -> some View {
        content
            .onAppear { recorder?.appeared(text) }
            .onDisappear { recorder?.disappeared(text) }
            .onChange(of: text) { old, new in
                recorder?.disappeared(old)
                recorder?.appeared(new)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                recorder?.placed(text, at: frame)
            }
    }
}

/// The action a button was last drawn with.
@MainActor
private final class DrawnAction {
    var action: (@MainActor () -> Void)?
}

private struct OnScreenActionAsDrawn: ViewModifier {
    let label: String
    let action: @MainActor () -> Void
    @Environment(\.onScreenRecorder) private var recorder
    @State private var drawn = DrawnAction()

    func body(content: Content) -> some View {
        drawn.action = action   // a reference's property, not the view's state: drawing again is not asked for
        return content
            .onAppear { [drawn] in recorder?.offered(label) { drawn.action?() } }
            .onDisappear { recorder?.withdrew(label) }
    }
}

private struct OnScreenDialog: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    let label: String
    let action: @MainActor () -> Void
    @Environment(\.onScreenRecorder) private var recorder

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented, initial: true) { _, up in
                if up {
                    recorder?.appeared(title)
                    recorder?.offered(label) {
                        isPresented = false
                        action()
                    }
                    recorder?.offered("Cancel: " + title) { isPresented = false }
                } else {
                    gone()
                }
            }
            .onDisappear(perform: gone)
    }

    private func gone() {
        recorder?.disappeared(title)
        recorder?.withdrew(label)
        recorder?.withdrew("Cancel: " + title)
    }
}

private struct OnScreenAction: ViewModifier {
    let label: String
    let action: @MainActor () -> Void
    @Environment(\.onScreenRecorder) private var recorder

    func body(content: Content) -> some View {
        content
            .onAppear { recorder?.offered(label, action) }
            .onDisappear { recorder?.withdrew(label) }
    }
}
#endif
