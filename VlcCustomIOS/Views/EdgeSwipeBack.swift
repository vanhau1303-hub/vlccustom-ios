import SwiftUI
import UIKit

/// iOS-style "swipe in from the left edge to go back" for screens that navigate by swapping their own content
/// (the SMB folder browser) instead of pushing onto a NavigationStack, where the system gesture does not exist.
/// A thin invisible strip along the leading edge owns the gesture, so list scrolling and taps elsewhere are untouched.
private struct EdgeSwipeBack: ViewModifier {
    let enabled: Bool
    let action: () -> Void
    @State private var dragX: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: dragX * 0.35)
            .overlay(alignment: .leading) {
                if enabled {
                    Color.clear
                        .frame(width: 22)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 10, coordinateSpace: .global)
                                .onChanged { value in
                                    dragX = max(0, value.translation.width)
                                }
                                .onEnded { value in
                                    let passed = value.translation.width > 90 || value.predictedEndTranslation.width > 180
                                    withAnimation(.easeOut(duration: 0.2)) { dragX = 0 }
                                    if passed {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        action()
                                    }
                                }
                        )
                }
            }
            .overlay(alignment: .leading) {
                // A small chevron that follows the finger, so the gesture is discoverable and feels live.
                if dragX > 8 {
                    Image(systemName: "chevron.backward.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.accentColor)
                        .opacity(min(1, dragX / 90))
                        .offset(x: min(dragX, 90) * 0.5 - 20)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    /// Swipe from the left screen edge calls `action` (only while `enabled`).
    func edgeSwipeBack(enabled: Bool = true, action: @escaping () -> Void) -> some View {
        modifier(EdgeSwipeBack(enabled: enabled, action: action))
    }
}
