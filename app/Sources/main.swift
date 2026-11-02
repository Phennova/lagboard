import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Always-on-top, non-activating panel that is excluded from screen capture.
final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .screenSaver // above full-screen apps
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        sharingType = .none // hide from screen sharing / screenshots
        becomesKeyOnlyIfNeeded = true
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FirstClickHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let board = Board()
    var panel: FloatingPanel!
    var statusItem: NSStatusItem!
    var setupWindow: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        ExtensionFiles.prepare()

        panel = FloatingPanel()
        let host = FirstClickHostingView(rootView: BoardView(board: board, onHide: { [weak self] in self?.togglePanel() }))
        host.frame.size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - panel.frame.width - 24, y: f.maxY - panel.frame.height - 24))
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "wifi.exclamationmark", accessibilityDescription: "LagBoard")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let keys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5]
        for (i, k) in keys.enumerated() where i < scenarios.count {
            let s = scenarios[i]
            HotKeys.register(k) { [weak self] in self?.board.run(s) }
        }
        HotKeys.register(kVK_ANSI_C) { [weak self] in self?.board.chaos.toggle() }
        HotKeys.register(kVK_ANSI_F) { [weak self] in self?.board.toggle("freeze") }
        HotKeys.register(kVK_ANSI_M) { [weak self] in self?.board.toggle("mute") }
        HotKeys.register(kVK_ANSI_0) { [weak self] in self?.board.allClear() }
        HotKeys.register(kVK_ANSI_L) { [weak self] in self?.togglePanel() }

        if board.mode == nil { showSetup() } else { panel.orderFrontRegardless() }
    }

    // Rebuilt every time the menu opens so it reflects the current mode.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let add = { (title: String, sel: Selector?) -> NSMenuItem in
            let item = menu.addItem(withTitle: title, action: sel, keyEquivalent: "")
            item.target = self
            return item
        }
        _ = add("Show / Hide Panel   ⌃⌥L", #selector(togglePanel))
        _ = add("All Clear   ⌃⌥0", #selector(allClear))
        menu.addItem(.separator())
        let modeName = board.mode == .virtualCamera ? "Virtual Camera" : board.mode == .extensionMode ? "Chrome Extension" : "not set up"
        add("Mode: \(modeName)", nil).isEnabled = false
        if board.mode == .virtualCamera {
            _ = add(board.cam.live ? "Turn Camera Off" : "Turn Camera On", #selector(toggleCamera))
            let camItem = add("Camera", nil)
            let sub = NSMenu()
            for d in CameraCapture.devices() {
                let it = sub.addItem(withTitle: d.localizedName, action: #selector(pickCamera(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = d.uniqueID
                it.state = d.uniqueID == board.cam.cameraID ? .on : .off
            }
            camItem.submenu = sub
        }
        _ = add("Setup…", #selector(showSetup))
        menu.addItem(.separator())
        _ = add("Quit LagBoard", #selector(quit))
    }

    @objc func showSetup() {
        if let w = setupWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "LagBoard Setup"
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.sharingType = .none
        w.contentView = NSHostingView(rootView: SetupView(board: board, cam: board.cam) { [weak self] in
            self?.setupWindow?.close()
        })
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.board.cam.setPreviewing(false)
            self?.setupWindow = nil
            self?.panel.orderFrontRegardless()
        }
        setupWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleCamera() {
        if board.cam.live { board.cam.goOffline(manual: true) } else { board.cam.goLive() }
    }

    @objc func pickCamera(_ sender: NSMenuItem) {
        board.cam.cameraID = sender.representedObject as? String
    }

    @objc func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    @objc func allClear() { board.allClear() }

    @objc func quit() {
        board.allClear()
        board.cam.goOffline()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }
}

// `LagBoard --snapshot out.png [panel|panel-virtual|choose|ext|virtual]` renders a view to
// an image (for previews) and exits.
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let which = i + 2 < CommandLine.arguments.count ? CommandLine.arguments[i + 2] : "panel"
    let savedMode = UserDefaults.standard.string(forKey: "mode") // restored below
    UserDefaults.standard.removeObject(forKey: "mode")
    let board = Board()
    let view: AnyView
    switch which {
    case "panel-virtual":
        board.mode = .virtualCamera
        board.toggle("lowres")
        view = AnyView(BoardView(board: board, onHide: {}))
    case "choose": view = AnyView(SetupView(board: board, cam: board.cam, onFinish: {}))
    case "ext": view = AnyView(SetupView(board: board, cam: board.cam, onFinish: {}, step: .ext))
    case "virtual": view = AnyView(SetupView(board: board, cam: board.cam, onFinish: {}, step: .virtual))
    default:
        board.toggle("lowres"); board.toggle("robot")
        view = AnyView(BoardView(board: board, onHide: {}))
    }
    let host = NSHostingView(rootView: view)
    host.frame.size = host.fittingSize
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    UserDefaults.standard.set(savedMode, forKey: "mode")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
