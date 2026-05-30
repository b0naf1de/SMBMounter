import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        setupMenuBar()
        ShareManager.shared.startMonitoring()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        ShareManager.shared.stopMonitoring()
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Give the status item a stable identity so macOS persists its position
        // and third-party menu-bar managers (Bartender, Ice, etc.) can reliably
        // track it across launches. Without an autosaveName, the system assigns a
        // non-deterministic identity that is never persisted, so menu-bar managers
        // treat the item as brand-new on every launch and may hide it by default.
        statusItem?.autosaveName = "com.smbmounter.statusitem"
        statusItem?.isVisible = true

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "externaldrive.fill.badge.wifi", accessibilityDescription: "SMBMounter")
            button.action = #selector(togglePopover)
            button.target = self
        }
        
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 500)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(ShareManager.shared)
        )
        self.popover = popover
    }
    
    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        
        if let popover = popover {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    
    func updateStatusIcon(hasError: Bool) {
        DispatchQueue.main.async {
            let symbolName = hasError ? "externaldrive.badge.exclamationmark" : "externaldrive.fill.badge.wifi"
            self.statusItem?.button?.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: "SMBMounter"
            )
        }
    }
}
