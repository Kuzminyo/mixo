import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = MixerModel()
    private var statusItem: NSStatusItem!
    private var panel: MixerPanel!
    private var iconObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        panel = MixerPanel(model: model)
        panel.ignoredFrame = { [weak self] in self?.statusItem.button?.window?.frame ?? .zero }

        iconObserver = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateIcon() }
        updateIcon()

        if CommandLine.arguments.contains("--show") {
            // Wait for the menu bar icon to get its place, the panel opens under it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showPanel() }
        }
    }

    /// Opening Mixo again from Finder or Spotlight shows the mixer.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
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

    @objc private func togglePanel() {
        panel.isVisible ? panel.close() : showPanel()
    }

    private func showPanel() {
        model.refresh()
        let anchor: NSRect
        if let button = statusItem.button, let window = button.window {
            anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        } else {
            // No icon on screen (e.g. hidden by the notch): open near the top center.
            let screen = NSScreen.main?.frame ?? .zero
            anchor = NSRect(x: screen.midX, y: screen.maxY - 30, width: 0, height: 0)
        }
        panel.show(below: anchor)
    }
}
