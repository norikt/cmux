import AppKit
import Bonsplit
import Foundation
import ObjectiveC

/// Hosts a standalone Ghostty surface in a floating `NSPanel`, created when a
/// `cmux.json` command declares `"window": { "mode": "floating" }`.
///
/// Lifecycle mirrors `BrowserPopupWindowController`:
/// - The controller self-retains via `objc_setAssociatedObject` on its panel.
/// - Released in `windowWillClose(_:)`, which also frees the Ghostty surface
///   via `TerminalSurface.teardownSurface()`.
/// - Re-invoking a command whose floating window already exists re-keys the
///   existing window instead of opening a second one.
@MainActor
final class FloatingTerminalWindowController: NSObject, NSWindowDelegate {

    // MARK: - Static registries

    private static var windowsByCommandId: [String: FloatingTerminalWindowController] = [:]
    private static var windowsBySurfaceId: [UUID: FloatingTerminalWindowController] = [:]
    private static var associatedObjectKey: UInt8 = 0

    // MARK: - Instance state

    let surface: TerminalSurface
    private let panel: FloatingTerminalPanel
    private let commandId: String
    private let commandDisplayName: String
    private var bypassCloseConfirmation = false

    // MARK: - Public entry point

    /// Open (or re-key) the floating window associated with `command`.
    ///
    /// `baseCwd` is the fallback working directory used when the command's
    /// `window.cwd` is absent; callers should pass the focused terminal's
    /// `requestedWorkingDirectory` (or workspace `currentDirectory`).
    static func open(command: CmuxCommandDefinition, shellCommand: String, baseCwd: String) {
        let trimmedShellCommand = shellCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedShellCommand.isEmpty else {
            return
        }

        if let existing = windowsByCommandId[command.id] {
            let restart = command.restart ?? .ignore
            switch restart {
            case .ignore:
                existing.bringToFront()
                return
            case .recreate:
                existing.close(skipConfirmation: true)
            case .confirm:
                let alert = NSAlert()
                alert.messageText = String(
                    localized: "dialog.cmuxConfig.confirmRestart.title",
                    defaultValue: "Workspace Already Exists"
                )
                alert.informativeText = String(
                    localized: "dialog.cmuxConfig.confirmRestart.message",
                    defaultValue: "A workspace with this name already exists. Close it and create a new one?"
                )
                alert.alertStyle = .warning
                alert.addButton(withTitle: String(
                    localized: "dialog.cmuxConfig.confirmRestart.recreate",
                    defaultValue: "Recreate"
                ))
                alert.addButton(withTitle: String(
                    localized: "dialog.cmuxConfig.confirmRestart.cancel",
                    defaultValue: "Cancel"
                ))
                guard alert.runModal() == .alertFirstButtonReturn else {
                    existing.bringToFront()
                    return
                }
                existing.close(skipConfirmation: true)
            }
        }

        let controller = FloatingTerminalWindowController(
            command: command,
            shellCommand: trimmedShellCommand,
            baseCwd: baseCwd
        )
        windowsByCommandId[command.id] = controller
        windowsBySurfaceId[controller.surface.id] = controller
    }

    /// Called by the Ghostty `close_surface_cb` path when a surface that isn't
    /// attached to a workspace is being torn down by the runtime (e.g. the
    /// user typed `exit` or `lazygit` quit). Returns true if a matching
    /// floating window was found and closed.
    @discardableResult
    static func handleRuntimeSurfaceClose(surfaceId: UUID) -> Bool {
        guard let controller = windowsBySurfaceId[surfaceId] else { return false }
        controller.close(skipConfirmation: true)
        return true
    }

    // MARK: - Init

    private init(
        command: CmuxCommandDefinition,
        shellCommand: String,
        baseCwd: String
    ) {
        self.commandId = command.id
        self.commandDisplayName = command.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let standaloneId = UUID()

        let resolvedCwd = Self.resolveCwd(command: command, baseCwd: baseCwd)

        let surface = TerminalSurface(
            tabId: standaloneId,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: resolvedCwd,
            initialCommand: shellCommand
        )
        self.surface = surface

        let contentRect = Self.initialContentRect(window: command.window)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .utilityWindow]
        let panel = FloatingTerminalPanel(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(
            "cmux.floating-terminal.\(command.id)"
        )
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .normal
        panel.minSize = NSSize(width: 240, height: 160)
        panel.title = command.name
        self.panel = panel

        super.init()

        let host = surface.hostedView
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: contentRect.size)
        panel.contentView = host

        objc_setAssociatedObject(
            panel,
            &Self.associatedObjectKey,
            self,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        panel.delegate = self

        AppDelegate.shared?.applyWindowDecorations(to: panel)

        #if DEBUG
        dlog(
            "floating.init command=\(commandId) surface=\(surface.id.uuidString.prefix(5)) " +
            "cwd=\(resolvedCwd) size=\(Int(contentRect.width))x\(Int(contentRect.height))"
        )
        #endif

        panel.makeKeyAndOrderFront(nil)

        // Drive the surface's focus state the same way TerminalPanel.focus()
        // does so lazygit and friends accept keystrokes immediately.
        surface.setFocus(true)
        host.setActive(true)
        host.ensureFocus(for: standaloneId, surfaceId: surface.id)
    }

    // MARK: - Helpers

    private func bringToFront() {
        if panel.isMiniaturized {
            panel.deminiaturize(nil)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func close(skipConfirmation: Bool = false) {
        if skipConfirmation {
            bypassCloseConfirmation = true
        }
        panel.close() // triggers windowShouldClose/windowWillClose
        if skipConfirmation, panel.isVisible {
            bypassCloseConfirmation = false
        }
    }

    private static func resolveCwd(command: CmuxCommandDefinition, baseCwd: String) -> String {
        if let explicit = command.window?.cwd,
           !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return CmuxConfigStore.resolveCwd(explicit, relativeTo: baseCwd)
        }
        if !baseCwd.isEmpty {
            return baseCwd
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private static func initialContentRect(window: CmuxCommandWindow?) -> NSRect {
        let defaultWidth: CGFloat = 1100
        let defaultHeight: CGFloat = 720
        let minWidth: CGFloat = 240
        let minHeight: CGFloat = 160

        let requestedWidth = window?.width.map { CGFloat($0) } ?? defaultWidth
        let requestedHeight = window?.height.map { CGFloat($0) } ?? defaultHeight

        let screen = NSApp.keyWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let clampedWidth = min(max(requestedWidth, minWidth), visibleFrame.width)
        let clampedHeight = min(max(requestedHeight, minHeight), visibleFrame.height)
        return NSRect(
            x: visibleFrame.midX - clampedWidth / 2,
            y: visibleFrame.midY - clampedHeight / 2,
            width: clampedWidth,
            height: clampedHeight
        )
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !bypassCloseConfirmation,
              surface.needsConfirmClose() else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "dialog.closeTab.title", defaultValue: "Close tab?")
        if commandDisplayName.isEmpty {
            alert.informativeText = String(
                localized: "dialog.closeTab.message",
                defaultValue: "This will close the current tab."
            )
        } else {
            let messageFormat = String(
                localized: "dialog.closeTab.messageNamed",
                defaultValue: "This will close \"%@\"."
            )
            alert.informativeText = String(format: messageFormat, commandDisplayName)
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "dialog.closeTab.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "dialog.closeTab.cancel", defaultValue: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        #if DEBUG
        dlog(
            "floating.close command=\(commandId) " +
            "surface=\(surface.id.uuidString.prefix(5))"
        )
        #endif

        Self.windowsByCommandId.removeValue(forKey: commandId)
        Self.windowsBySurfaceId.removeValue(forKey: surface.id)

        surface.beginPortalCloseLifecycle(reason: "floating.close")
        surface.setFocus(false)
        surface.hostedView.setActive(false)
        surface.hostedView.setVisibleInUI(false)
        TerminalWindowPortalRegistry.detach(hostedView: surface.hostedView)
        surface.teardownSurface()

        panel.delegate = nil
        objc_setAssociatedObject(
            panel,
            &Self.associatedObjectKey,
            nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}

/// NSPanel subclass that intercepts Cmd+W so the main menu's "Close Tab"
/// action (swizzled via `cmux_performKeyEquivalent`) can't target the
/// underlying workspace while this floating panel is key.
private class FloatingTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command,
           KeyboardLayout.normalizedCharacters(for: event) == "w" {
            #if DEBUG
            dlog("floating.panel.cmdW close")
            #endif
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
