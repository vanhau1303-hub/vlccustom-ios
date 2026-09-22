import SwiftUI
import UIKit

extension View {
    /// Dismisses the keyboard when the user taps anywhere else on this view. SwiftUI has no built-in "tap outside
    /// to dismiss" for a plain (non-scrolling) form, so this fills the gap for the SMB connect forms.
    func dismissesKeyboardOnTap() -> some View {
        onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
}
