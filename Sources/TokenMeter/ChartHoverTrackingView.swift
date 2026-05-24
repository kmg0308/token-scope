import AppKit
import SwiftUI

struct ChartHoverTrackingView: NSViewRepresentable {
    var onHover: (CGPoint?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onHover = onHover
        context.coordinator.onHover = onHover
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onHover = onHover
        view.coordinator = context.coordinator
        context.coordinator.onHover = onHover
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TrackingView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class Coordinator {
        var onHover: ((CGPoint?) -> Void)?
        private var eventMonitor: Any?

        deinit {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
        }

        @MainActor
        func updateEventMonitor(for view: TrackingView) {
            removeEventMonitor()
            guard let window = view.window else { return }
            onHover = view.onHover

            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .scrollWheel]) { [weak self, weak view, weak window] event in
                MainActor.assumeIsolated {
                    guard let self, let view, event.window === window else { return }
                    if event.type == .scrollWheel {
                        self.onHover?(nil)
                        return
                    }

                    let point = view.convert(event.locationInWindow, from: nil)
                    self.onHover?(view.bounds.contains(point) ? point : nil)
                }
                return event
            }
        }

        @MainActor
        func removeEventMonitor() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    final class TrackingView: NSView {
        var onHover: ((CGPoint?) -> Void)?
        var coordinator: Coordinator?

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
            if window == nil {
                coordinator?.removeEventMonitor()
            } else {
                coordinator?.updateEventMonitor(for: self)
            }
        }
    }
}
