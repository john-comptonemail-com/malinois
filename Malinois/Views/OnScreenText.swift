//
//  OnScreenText.swift
//  Malinois
//
//  What a laid-out screen shows, for the tests that host a real screen (item 120). SwiftUI gives a
//  unit test no accessibility elements, so the text of a notice or badge cannot be read off a
//  rendered screen; instead each one built with `reportedOnScreen(_:)` tells a recorder in the
//  environment when it appears and disappears. Debug only: in Release the modifier is the view
//  itself and nothing here is compiled.
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
}

#if DEBUG
/// The text of every reporting notice and badge on screen, in the order they appeared, and where each
/// was last laid out (in the window's coordinates), since appearing is not the same as being visible
/// (Codex's W1: a badge pushed above the top of the screen still appears).
@MainActor
final class OnScreenRecorder {
    private(set) var shown: [String] = []
    private(set) var frames: [String: CGRect] = [:]

    func appeared(_ text: String) { shown.append(text) }

    func disappeared(_ text: String) {
        if let index = shown.firstIndex(of: text) { shown.remove(at: index) }
    }

    func placed(_ text: String, at frame: CGRect) { frames[text] = frame }
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
#endif
