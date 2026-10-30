import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = MixerModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var iconObserver: AnyCancellable?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.contentViewController = NSHostingController(rootView: MixerView(model: model))
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        iconObserver = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateIcon() }
        updateIcon()

        if CommandLine.arguments.contains("--show") { showPopover() }
    }

    /// Opening Mixo again from Finder or Spotlight shows the mixer.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    private func updateIcon() {
        let volume = model.masterVolume
        let symbol = model.masterMuted || volume == 0 ? "speaker.slash.fill"
            : volume < 0.34 ? "speaker.wave.1.fill"
            : volume < 0.67 ? "speaker.wave.2.fill"
            : "speaker.wave.3.fill"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mixo")
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        model.refresh()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Mixo has no Dock icon, so macOS may not treat it as active and the transient popover
        // would ignore clicks in other apps. Watch for them ourselves.
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            // Clicks on the popover itself can arrive here when Mixo isn't the active app.
            guard let self, let window = popover.contentViewController?.view.window,
                  !window.frame.contains(NSEvent.mouseLocation),
                  !(statusItem.button?.window?.frame.contains(NSEvent.mouseLocation) ?? false) else { return }
            popover.performClose(nil)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }
}
