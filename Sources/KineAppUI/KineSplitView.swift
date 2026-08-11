import SwiftUI
import AppKit

/// Per-pane configuration for `KineSplitView`.
///
/// `holdingPriority` controls which pane resists resizing when the
/// surrounding window grows or shrinks. Higher = more resistant. Set the
/// bin's pane to a higher holding priority than the viewer/timeline
/// column so the column absorbs the extra width.
public struct KinePaneSpec: Sendable {
    public var minThickness: CGFloat
    public var maxThickness: CGFloat?
    public var holdingPriority: Float
    public var canCollapse: Bool

    public init(
        minThickness: CGFloat,
        maxThickness: CGFloat? = nil,
        holdingPriority: Float = 250,    // NSLayoutConstraint.Priority.defaultLow.rawValue
        canCollapse: Bool = false
    ) {
        self.minThickness = minThickness
        self.maxThickness = maxThickness
        self.holdingPriority = holdingPriority
        self.canCollapse = canCollapse
    }
}

/// SwiftUI wrapper around `NSSplitViewController` for proper two-pane
/// dividers with holding priorities, min/max thicknesses, and autosaved
/// divider positions across launches.
///
/// Nest two of these to get four panes, three for the standard NLE
/// shape (bin | viewers above timeline).
public struct KineSplitView<First: View, Second: View>: NSViewControllerRepresentable {
    public let isVertical: Bool          // true → horizontal stack (vertical divider)
    public let autosaveName: String
    public let firstSpec: KinePaneSpec
    public let secondSpec: KinePaneSpec
    public let initialFirstThickness: CGFloat?
    public let first: () -> First
    public let second: () -> Second

    public init(
        isVertical: Bool,
        autosaveName: String,
        firstSpec: KinePaneSpec,
        secondSpec: KinePaneSpec,
        initialFirstThickness: CGFloat? = nil,
        @ViewBuilder first: @escaping () -> First,
        @ViewBuilder second: @escaping () -> Second
    ) {
        self.isVertical = isVertical
        self.autosaveName = autosaveName
        self.firstSpec = firstSpec
        self.secondSpec = secondSpec
        self.initialFirstThickness = initialFirstThickness
        self.first = first
        self.second = second
    }

    public func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller = NSSplitViewController()
        controller.splitView.isVertical = isVertical
        controller.splitView.dividerStyle = .thin
        controller.splitView.autosaveName = autosaveName

        let firstHost = NSHostingController(rootView: first())
        let firstItem = NSSplitViewItem(viewController: firstHost)
        firstItem.minimumThickness = firstSpec.minThickness
        if let max = firstSpec.maxThickness { firstItem.maximumThickness = max }
        firstItem.holdingPriority = NSLayoutConstraint.Priority(firstSpec.holdingPriority)
        firstItem.canCollapse = firstSpec.canCollapse
        controller.addSplitViewItem(firstItem)

        let secondHost = NSHostingController(rootView: second())
        let secondItem = NSSplitViewItem(viewController: secondHost)
        secondItem.minimumThickness = secondSpec.minThickness
        if let max = secondSpec.maxThickness { secondItem.maximumThickness = max }
        secondItem.holdingPriority = NSLayoutConstraint.Priority(secondSpec.holdingPriority)
        secondItem.canCollapse = secondSpec.canCollapse
        controller.addSplitViewItem(secondItem)

        // Apply initial divider position if no autosaved one exists yet.
        if let initial = initialFirstThickness {
            let key = "NSSplitView Subview Frames \(autosaveName)"
            let hasAutosave = UserDefaults.standard.object(forKey: key) != nil
            if !hasAutosave {
                DispatchQueue.main.async {
                    controller.splitView.setPosition(initial, ofDividerAt: 0)
                }
            }
        }

        return controller
    }

    public func updateNSViewController(_ controller: NSSplitViewController, context: Context) {
        guard controller.splitViewItems.count >= 2 else { return }
        if let host = controller.splitViewItems[0].viewController as? NSHostingController<First> {
            host.rootView = first()
        }
        if let host = controller.splitViewItems[1].viewController as? NSHostingController<Second> {
            host.rootView = second()
        }
    }
}
