import AppKit
import SwiftUI

class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let caffeinateManager: CaffeinateManager
    private var eventMonitor: Any?

    init(caffeinateManager: CaffeinateManager) {
        self.caffeinateManager = caffeinateManager
        super.init()
        setupStatusItem()
        setupPopover()
        setupEventMonitor()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "applewatch", accessibilityDescription: "WatchApprove")
            button.action = #selector(togglePopover)
            button.target = self
        }
        updateBadge()
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 480)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: ApprovalPopoverView(caffeinateManager: caffeinateManager)
        )
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            if let button = statusItem.button {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func updateBadge() {
        Task { @MainActor in
            let pending = await DatabaseManager.shared.pendingCount()
            if let button = statusItem.button {
                button.title = pending > 0 ? "\(pending)" : ""
            }
        }
    }

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.popover.isShown == true {
                self?.popover.performClose(nil)
            }
        }
    }
}