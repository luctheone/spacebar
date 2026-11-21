import AppKit
import Combine
import SwiftUI

@MainActor
final class SpaceBarDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    let controller = MonitorController()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var window: NSWindow?
    private var observation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "SpaceBar")
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 372, height: 590)
        popover.contentViewController = NSHostingController(rootView: SpaceBarView(controller: controller))
        observation = controller.$snapshot.sink { [weak self] value in
            guard let self else { return }
            let free = value.map { Display.bytes($0.disk.freeBytes) } ?? "…"
            self.item.button?.title = " " + free
            self.item.button?.toolTip = "SpaceBar · \(free) available"
            self.item.button?.setAccessibilityLabel("SpaceBar, \(free) available")
        }
        showWindow()
    }

    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = item.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        controller.setVisible(true)
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverDidClose(_ notification: Notification) { updateVisibility() }

    private func updateVisibility() {
        controller.setVisible(popover.isShown || (window?.isVisible == true && window?.isMiniaturized == false))
    }

    func windowDidMiniaturize(_ notification: Notification) { updateVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { updateVisibility() }

    func showWindow() {
        if let window { window.makeKeyAndOrderFront(nil); controller.setVisible(true); NSApp.activate(ignoringOtherApps: true); return }
        let host = NSHostingController(rootView: SpaceBarView(controller: controller))
        let panel = NSWindow(contentViewController: host)
        panel.title = "SpaceBar"
        panel.styleMask = [.titled, .closable, .miniaturizable]
        panel.setContentSize(NSSize(width: 372, height: 590))
        panel.center()
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.makeKeyAndOrderFront(nil)
        window = panel
        controller.setVisible(true)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { controller.setVisible(popover.isShown) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { controller.cancelScan() }
}

@main
struct SpaceBarApp: App {
    @NSApplicationDelegateAdaptor(SpaceBarDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}
