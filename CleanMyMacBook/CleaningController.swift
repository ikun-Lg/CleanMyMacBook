import Cocoa
import Combine
import ApplicationServices
import CoreGraphics

private let kEscKeyCode = 53
private let kExitHoldSeconds: TimeInterval = 2.0
private let kFadeDuration: TimeInterval = 0.3

/// NX_SYSDEFINED (14): 顶部功能行按键（亮度、音量、Mission Control 等）
private let kCGEventTypeSystemDefined: UInt32 = 14

final class CleaningController: ObservableObject {

    // MARK: - 用户开关

    @Published var disableKeyboard = true
    @Published var disableTrackpad = true
    @Published var blackScreen = true

    // MARK: - 运行状态

    @Published private(set) var isActive = false
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published var needsAccessibilityPrompt = false

    var canStart: Bool { disableKeyboard || disableTrackpad || blackScreen }

    // MARK: - 内部资源

    private var keyboardTap: CFMachPort?
    private var mouseTap: CFMachPort?
    private var keyboardSource: CFRunLoopSource?
    private var mouseSource: CFRunLoopSource?

    private var overlayWindows: [NSWindow] = []
    private var hudWindow: NSWindow?
    private var hudLabel: NSTextField?

    private var exitHoldWork: DispatchWorkItem?
    private var hintFadeWork: DispatchWorkItem?
    private var isHoldingExitKey = false

    private let normalHint = "清洁模式已开启 · 按住 Esc 键 2 秒退出"
    private let exitingHint = "正在退出…请继续按住 Esc"

    // MARK: - 权限

    func refreshPermission() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 启停

    func start() {
        guard !isActive, canStart else { return }

        let needsTaps = disableKeyboard || disableTrackpad
        if needsTaps && !AXIsProcessTrusted() {
            requestAccessibility()
            needsAccessibilityPrompt = true
            return
        }
        needsAccessibilityPrompt = false

        isActive = true

        if blackScreen {
            showBlackOverlays()
            NSCursor.hide()
        }
        showHUD()

        if AXIsProcessTrusted() {
            installTaps()
        }

        flashHint()
    }

    func stop() {
        guard isActive else { return }
        isActive = false

        cancelExitHold()
        removeTaps()
        removeOverlays()
        removeHUD()
        NSCursor.unhide()
    }

    func toggle() {
        isActive ? stop() : start()
    }

    // MARK: - 事件拦截安装

    private func installTaps() {
        // 包含 kCGEventTypeSystemDefined(14)：拦截顶部功能行按键（亮度/音量等）
        let keyMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << kCGEventTypeSystemDefined)

        let (kTap, kSrc) = makeTap(mask: keyMask)
        keyboardTap = kTap
        keyboardSource = kSrc

        if disableTrackpad {
            let mouseMask: CGEventMask =
                (1 << CGEventType.leftMouseDown.rawValue) |
                (1 << CGEventType.leftMouseUp.rawValue) |
                (1 << CGEventType.rightMouseDown.rawValue) |
                (1 << CGEventType.rightMouseUp.rawValue) |
                (1 << CGEventType.mouseMoved.rawValue) |
                (1 << CGEventType.leftMouseDragged.rawValue) |
                (1 << CGEventType.rightMouseDragged.rawValue) |
                (1 << CGEventType.scrollWheel.rawValue) |
                (1 << CGEventType.otherMouseDown.rawValue) |
                (1 << CGEventType.otherMouseUp.rawValue) |
                (1 << CGEventType.otherMouseDragged.rawValue)

            let (mTap, mSrc) = makeTap(mask: mouseMask)
            mouseTap = mTap
            mouseSource = mSrc
        }
    }

    private func makeTap(mask: CGEventMask) -> (CFMachPort?, CFRunLoopSource?) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: cleaningEventTapCallback,
            userInfo: refcon
        ) else {
            return (nil, nil)
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return (tap, source)
    }

    func reEnableTaps() {
        if let keyboardTap { CGEvent.tapEnable(tap: keyboardTap, enable: true) }
        if let mouseTap { CGEvent.tapEnable(tap: mouseTap, enable: true) }
    }

    private func removeTaps() {
        if let keyboardTap { CGEvent.tapEnable(tap: keyboardTap, enable: false) }
        if let mouseTap { CGEvent.tapEnable(tap: mouseTap, enable: false) }
        if let keyboardSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), keyboardSource, .commonModes) }
        if let mouseSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), mouseSource, .commonModes) }
        keyboardTap = nil
        mouseTap = nil
        keyboardSource = nil
        mouseSource = nil
    }

    // MARK: - 事件处理

    /// 返回 true 表示吞掉该事件
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .keyDown, .keyUp:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            return handleKey(keyCode: keyCode, isDown: type == .keyDown)
        case .flagsChanged:
            flashHint()
            return disableKeyboard
        default:
            flashHint()
            // NX_SYSDEFINED(14): 顶部功能键属于键盘输入，按键盘开关处理
            if type.rawValue == kCGEventTypeSystemDefined { return disableKeyboard }
            return disableTrackpad
        }
    }

    private func handleKey(keyCode: Int, isDown: Bool) -> Bool {
        flashHint()
        if keyCode == kEscKeyCode {
            if isDown { beginExitHold() } else { cancelExitHold() }
            return true
        }
        return disableKeyboard
    }

    func handleWindowKey(keyCode: Int, isDown: Bool) -> Bool {
        flashHint()
        if keyCode == kEscKeyCode {
            if isDown { beginExitHold() } else { cancelExitHold() }
        }
        return true
    }

    // MARK: - 长按退出

    private func beginExitHold() {
        guard !isHoldingExitKey else { return }
        isHoldingExitKey = true
        setHint(exitingHint)

        let work = DispatchWorkItem { [weak self] in self?.stop() }
        exitHoldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + kExitHoldSeconds, execute: work)
    }

    private func cancelExitHold() {
        isHoldingExitKey = false
        exitHoldWork?.cancel()
        exitHoldWork = nil
        if isActive { setHint(normalHint) }
    }

    // MARK: - 黑屏遮罩

    private func showBlackOverlays() {
        for screen in NSScreen.screens {
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.ignoresMouseEvents = false

            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.controller = self
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.black.cgColor
            window.contentView = view

            window.setFrame(screen.frame, display: true)
            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            overlayWindows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = kFadeDuration
            for window in overlayWindows { window.animator().alphaValue = 1 }
        }
    }

    private func removeOverlays() {
        let windows = overlayWindows
        overlayWindows.removeAll()
        guard !windows.isEmpty else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = kFadeDuration
            for window in windows { window.animator().alphaValue = 0 }
        }, completionHandler: {
            for window in windows { window.orderOut(nil) }
        })
    }

    // MARK: - 提示 HUD

    private func showHUD() {
        guard hudWindow == nil, let screen = NSScreen.main else { return }

        let size = NSSize(width: 420, height: 60)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - 160,
            width: size.width,
            height: size.height
        )
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        container.layer?.cornerRadius = 16

        let label = NSTextField(labelWithString: normalHint)
        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.alignment = .center
        label.frame = NSRect(x: 12, y: (size.height - 22) / 2, width: size.width - 24, height: 22)
        label.autoresizingMask = [.width]
        container.addSubview(label)

        window.contentView = container
        window.orderFrontRegardless()

        hudWindow = window
        hudLabel = label
    }

    private func removeHUD() {
        hudWindow?.orderOut(nil)
        hudWindow = nil
        hudLabel = nil
        hintFadeWork?.cancel()
        hintFadeWork = nil
    }

    private func setHint(_ text: String) {
        hudLabel?.stringValue = text
    }

    private func flashHint() {
        guard isActive, let container = hudWindow?.contentView else { return }
        hintFadeWork?.cancel()
        container.alphaValue = 1.0

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 1.5
                container.animator().alphaValue = 0.0
            }
        }
        hintFadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}

// MARK: - 黑屏窗口 / 视图

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView {
    weak var controller: CleaningController?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        _ = controller?.handleWindowKey(keyCode: Int(event.keyCode), isDown: true)
    }

    override func keyUp(with event: NSEvent) {
        _ = controller?.handleWindowKey(keyCode: Int(event.keyCode), isDown: false)
    }
}

// MARK: - CGEventTap C 回调

private nonisolated func cleaningEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<CleaningController>.fromOpaque(refcon).takeUnretainedValue()

    return MainActor.assumeIsolated {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            controller.reEnableTaps()
            return Unmanaged.passUnretained(event)
        }
        let consume = controller.handle(type: type, event: event)
        return consume ? nil : Unmanaged.passUnretained(event)
    }
}
