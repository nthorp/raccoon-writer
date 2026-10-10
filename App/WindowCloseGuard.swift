import AppKit
import SwiftUI

/// Makes the hosting window unclosable while `isBlocked`: the close button greys out and
/// ⌘W beeps. Closing the window mid-write would hide the only Cancel button while the
/// drive is being erased.
struct WindowCloseGuard: NSViewRepresentable {
    let isBlocked: Bool

    func makeNSView(context: Context) -> GuardView {
        GuardView()
    }

    func updateNSView(_ view: GuardView, context: Context) {
        view.isBlocked = isBlocked
    }

    final class GuardView: NSView {
        var isBlocked = false {
            didSet { apply() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window else { return }
            // Without .closable the window has no working close button, and
            // performClose (⌘W) refuses with a beep.
            if isBlocked {
                window.styleMask.remove(.closable)
            } else {
                window.styleMask.insert(.closable)
            }
        }
    }
}
