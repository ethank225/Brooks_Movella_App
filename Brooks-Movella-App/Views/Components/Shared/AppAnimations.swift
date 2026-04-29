import SwiftUI

enum AppAnimation {
    // MARK: - Curves

    /// Fast UI toggle, expand/collapse, selection changes (0.2s)
    static let standard     = Animation.easeInOut(duration: 0.2)

    /// Content appearance, card phase transitions (0.25s)
    static let content      = Animation.easeInOut(duration: 0.25)

    /// State phase changes, status updates (0.3s)
    static let phase        = Animation.easeInOut(duration: 0.3)

    /// Expand/collapse sections (0.2s)
    static let expand       = Animation.easeInOut(duration: 0.2)

    /// Device state transitions — corrupted/erasing row swaps (0.4s)
    static let deviceState  = Animation.easeInOut(duration: 0.4)

    /// Drop target highlight feedback (0.15s)
    static let dropFeedback = Animation.easeInOut(duration: 0.15)

    /// Interactive spring for drag-drop, add/remove items
    static let interactive  = Animation.spring(response: 0.35, dampingFraction: 0.8)

    // MARK: - Transitions

    /// Banner slide in from top with fade
    static let bannerTransition: AnyTransition = .move(edge: .top).combined(with: .opacity)

    /// Dot chip add/remove — scale + fade
    static let chipTransition: AnyTransition = .asymmetric(
        insertion: .scale.combined(with: .opacity),
        removal: .scale.combined(with: .opacity)
    )

    /// Runner card add/remove in researcher list
    static let cardTransition: AnyTransition = .asymmetric(
        insertion: .move(edge: .top).combined(with: .opacity),
        removal: .move(edge: .top).combined(with: .opacity)
    )

    /// Async content load — smooth ease-out (0.35s)
    static let contentLoad = Animation.easeOut(duration: 0.35)
}

/// Fades + slides content in when it first appears after an async load.
/// Self-contained — no parent `.animation()` needed.
struct ContentLoadModifier: ViewModifier {
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 10)
            .onAppear {
                withAnimation(AppAnimation.contentLoad) {
                    visible = true
                }
            }
    }
}

extension View {
    func contentLoadAnimation() -> some View {
        modifier(ContentLoadModifier())
    }
}
