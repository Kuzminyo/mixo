import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The mixer window. Unlike a popover it is not attached to the menu bar, so it stays in place
/// when the menu bar hides in full-screen apps, and it grows to fit its content inside the screen.
final class MixerPanel: NSPanel {
    private static let gap: CGFloat = 6
    private static let margin: CGFloat = 8

    private var anchor: NSRect = .zero
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    /// Frames (in screen coordinates) whose clicks should not close the panel, like the menu bar icon.
    var ignoredFrame: () -> NSRect = { .zero }

    init(model: MixerModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow

        let root = MixerView(model: model)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: \.size) { [weak self] size in
                self?.fit(size)
            }
        contentView = NSHostingView(rootView: root)
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        DispatchQueue.main.async { self.close() }
    }

    /// Shows the panel under `anchor` (the menu bar icon's frame on screen).
    func show(below anchor: NSRect) {
        self.anchor = anchor
        fit(contentView?.fittingSize ?? frame.size)
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            // Mixo is rarely the active app, so clicks on the panel itself can arrive here too.
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            if !frame.contains(mouse) && !ignoredFrame().contains(mouse) { close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            self?.close()
            return nil
        }
    }

    override func close() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        outsideClickMonitor = nil
        keyMonitor = nil
        super.close()
    }

    /// Keeps the top edge under the icon and the whole panel inside the screen.
    private func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        // Use the full frame: in full-screen spaces the menu bar hides and visibleFrame jumps.
        let bounds = screen.frame.insetBy(dx: Self.margin, dy: Self.margin)
        let top = min(anchor.minY - Self.gap, bounds.maxY)
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: top - size.height)
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = max(origin.y, bounds.minY)
        setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
