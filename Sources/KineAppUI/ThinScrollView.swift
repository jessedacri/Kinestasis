import SwiftUI
import AppKit

/// SwiftUI ScrollView wrapper backed by NSScrollView with a custom
/// `ThinScroller` so the indicator stays slim regardless of the
/// macOS "Show scroll bars" system preference. Single-axis only
/// (`.horizontal` or `.vertical`).
///
/// The hosted SwiftUI content is wrapped in an NSHostingView and
/// pinned to the scroll view's clip view on the non-scrolling axis,
/// so e.g. a horizontal ThinScrollView lets content grow wider than
/// the visible width while sharing the container's height.
struct ThinScrollView<Content: View>: NSViewRepresentable {
    let axis: Axis
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // Legacy style + autohidesScrollers=false gives us an always-
        // visible scroller in its own track row (Pro NLE style), and
        // ignores the macOS "Show scroll bars" system preference.
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        scroll.hasHorizontalScroller = (axis == .horizontal)
        scroll.hasVerticalScroller   = (axis == .vertical)
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity   = .none

        if axis == .horizontal {
            let bar = ThinScroller(frame: .zero)
            bar.controlSize = .small
            scroll.horizontalScroller = bar
        } else {
            let bar = ThinScroller(frame: .zero)
            bar.controlSize = .small
            scroll.verticalScroller = bar
        }

        let host = NSHostingView(rootView: AnyView(content()))
        host.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = host
        scroll.contentView.postsBoundsChangedNotifications = true

        // Pin the host's non-scrolling axis to the scroll view's
        // content view so SwiftUI lays it out at the correct extent
        // without scrolling on that axis.
        if let clip = scroll.documentView?.superview {
            switch axis {
            case .horizontal:
                NSLayoutConstraint.activate([
                    host.topAnchor.constraint(equalTo: clip.topAnchor),
                    host.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
                ])
            case .vertical:
                NSLayoutConstraint.activate([
                    host.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                    host.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
                ])
            }
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let host = nsView.documentView as? NSHostingView<AnyView> {
            host.rootView = AnyView(content())
        }
    }
}

/// NSScroller subclass drawing a slim track + knob. Width is fixed
/// (~10 px) and the knob is clearly visible — not a hairline. Always
/// renders the same way regardless of the macOS "Show scroll bars"
/// system preference.
final class ThinScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { false }

    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        return 10
    }

    override func drawKnob() {
        let bounds = rect(for: .knob)
        let isHorizontal = bounds.width > bounds.height
        let inset: CGFloat = 2
        // Vertical pill shape — narrow in the scroll direction's
        // cross-axis, full length along the scroll direction.
        let knobRect: NSRect
        if isHorizontal {
            knobRect = NSRect(x: bounds.minX, y: bounds.midY - 2.5, width: bounds.width, height: 5)
                .insetBy(dx: inset, dy: 0)
        } else {
            knobRect = NSRect(x: bounds.midX - 2.5, y: bounds.minY, width: 5, height: bounds.height)
                .insetBy(dx: 0, dy: inset)
        }
        let path = NSBezierPath(roundedRect: knobRect, xRadius: 2.5, yRadius: 2.5)
        NSColor(white: 1.0, alpha: 0.75).setFill()
        path.fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight: Bool) {
        // Thin track centered in the scroller channel.
        let isHorizontal = slotRect.width > slotRect.height
        let trackRect: NSRect
        if isHorizontal {
            trackRect = NSRect(x: slotRect.minX, y: slotRect.midY - 1.5, width: slotRect.width, height: 3)
                .insetBy(dx: 3, dy: 0)
        } else {
            trackRect = NSRect(x: slotRect.midX - 1.5, y: slotRect.minY, width: 3, height: slotRect.height)
                .insetBy(dx: 0, dy: 3)
        }
        let path = NSBezierPath(roundedRect: trackRect, xRadius: 1.5, yRadius: 1.5)
        NSColor(white: 0.0, alpha: 0.35).setFill()
        path.fill()
    }
}
