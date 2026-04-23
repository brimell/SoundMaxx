import AppKit
import SwiftUI

final class TrayController: NSObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var advancedWindow: NSWindow?
    private let deviceManager = AudioDeviceManager()

    private let audioEngine: AudioEngine
    private let eqModel: EQModel
    private let updateChecker: UpdateChecker

    init(audioEngine: AudioEngine, eqModel: EQModel, updateChecker: UpdateChecker) {
        self.audioEngine = audioEngine
        self.eqModel = eqModel
        self.updateChecker = updateChecker
        super.init()
        setupStatusItem()
        setupPopover()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "SoundMaxx EQ")
        button.action = #selector(buttonClicked)
        button.target = self
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
    }

    private func setupPopover() {
        let rootView = ContentView(layout: .compact, onOpenAdvancedWindow: { [weak self] in
            self?.openAdvancedWindow()
        })
        .environmentObject(audioEngine)
        .environmentObject(eqModel)
        .environmentObject(updateChecker)
        // Force active appearance so controls never dim when another app is in focus
        .environment(\.controlActiveState, .active)

        let controller = NSHostingController(rootView: rootView)
        popover = NSPopover()
        popover.contentViewController = controller
        // applicationDefined: we control open/close exclusively — no macOS auto-dismiss
        // that would race with our button action and cause the re-open loop
        popover.behavior = .applicationDefined
        popover.animates = false
    }

    @objc private func buttonClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseDown {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // Set menu temporarily so NSStatusItem shows it, then clear so left-click uses the action again.
    private func showContextMenu() {
        let menu = buildContextMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let statusTitle = audioEngine.isRunning ? "● Running" : "○ Stopped"
        let statusMenuItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())

        addItem(to: menu,
                title: eqModel.isEnabled ? "Disable Audio Processing" : "Enable Audio Processing",
                action: #selector(toggleEQ))

        let filtersItem = addItem(to: menu,
                                  title: eqModel.isEQFiltersEnabled ? "Disable EQ Filters" : "Enable EQ Filters",
                                  action: #selector(toggleEQFilters))
        filtersItem.isEnabled = eqModel.isEnabled

        addItem(to: menu, title: "Reset EQ to Flat", action: #selector(resetEQ))

        menu.addItem(.separator())

        addItem(to: menu,
                title: audioEngine.isRunning ? "Stop Audio Engine" : "Start Audio Engine",
                action: #selector(toggleAudio))

        addItem(to: menu, title: "Switch Output Device", action: #selector(cycleOutput))

        menu.addItem(.separator())

        addItem(to: menu, title: "Advanced Options…", action: #selector(openAdvancedWindowAction), keyEquivalent: ",")

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SoundMaxx", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func toggleEQ() {
        eqModel.setAudioEnabled(!eqModel.isEnabled)
    }

    @objc private func toggleEQFilters() {
        eqModel.setFiltersEnabled(!eqModel.isEQFiltersEnabled)
    }

    @objc private func resetEQ() {
        eqModel.reset()
    }

    @objc private func toggleAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
        } else {
            audioEngine.start()
        }
    }

    @objc private func cycleOutput() {
        let preferredUIDs = AppSettingsStore.shared.load()?.shortcutOutputDeviceUIDs
        guard let nextDevice = deviceManager.nextOutputDevice(
            after: audioEngine.selectedOutputDeviceID,
            preferredUIDs: preferredUIDs
        ) else { return }
        audioEngine.setOutputDevice(nextDevice.id)
        AppSettingsStore.shared.update { $0.selectedOutputDeviceID = Int32(nextDevice.id) }
    }

    @objc private func openAdvancedWindowAction() {
        openAdvancedWindow()
    }

    func openAdvancedWindow() {
        if advancedWindow == nil {
            let rootView = ContentView(layout: .full)
                .environmentObject(audioEngine)
                .environmentObject(eqModel)
                .environmentObject(updateChecker)

            let controller = NSHostingController(rootView: rootView)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 920),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "SoundMaxx Advanced"
            window.contentViewController = controller
            window.center()
            advancedWindow = window
        }

        advancedWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
