import SwiftUI
import AppKit
import PreemAppUI

@main
struct PreemApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Preem") {
            PreemRootView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        Settings {
            PreemSettingsView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Preem") {
                    NotificationCenter.default.post(name: .preemShowAbout, object: nil)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    NotificationCenter.default.post(name: .preemNewProject, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("New Sequence…") {
                    NotificationCenter.default.post(name: .preemNewSequence, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("Open Project…") {
                    NotificationCenter.default.post(name: .preemOpenProject, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Sequence") {
                Button("Add Video Track") {
                    NotificationCenter.default.post(name: .preemAddVideoTrack, object: nil)
                }
                Button("Add Audio Track") {
                    NotificationCenter.default.post(name: .preemAddAudioTrack, object: nil)
                }
                Divider()
                Button("Render In to Out") {
                    NotificationCenter.default.post(name: .preemRenderInToOut, object: nil)
                }
                .keyboardShortcut(.return, modifiers: .shift)
            }
            CommandMenu("Clip") {
                Button("Effect Controls…") {
                    NotificationCenter.default.post(name: .preemShowEffectControls, object: nil)
                }
                .keyboardShortcut("5", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    NotificationCenter.default.post(name: .preemSave, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Save As…") {
                    NotificationCenter.default.post(name: .preemSaveAs, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("Export Sequence…") {
                    NotificationCenter.default.post(name: .preemExportSequence, object: nil)
                }
                .keyboardShortcut("e", modifiers: .command)

                Button("Export FCPXML…") {
                    NotificationCenter.default.post(name: .preemExportFCPXML, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SPM-built executables must escalate to a regular foreground app
        // or they sit in the background with no Dock icon and no key window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Dock icon (SPM executable has no .app bundle/Info.plist icon, so
        // set it at runtime). Preem's mark: timeline-track bars — the
        // Polymerge waveform turned on its side.
        if let url = Bundle.module.url(forResource: "PreemIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = img
        }

        // The main window exists by now (SwiftUI builds it before
        // applicationDidFinishLaunching fires). Hook it up:
        // - Frame autosave so position/size survive relaunches.
        // - Window delegate so the red close button HIDES the window
        //   instead of destroying it (Final Cut style).
        if let win = NSApp.windows.first(where: { $0.title == "Preem" || $0.contentView != nil }) {
            win.setFrameAutosaveName("preem.main.window")
            win.delegate = self
        }
    }

    /// Keep the app alive when the user closes the window. Combined
    /// with `applicationShouldHandleReopen`, this gives FCP-style
    /// behavior: close button parks the window; Dock-icon click brings
    /// it back; ⌘Q is the only real quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Re-open the main window when the user clicks the Dock icon
    /// (or chooses the app from `⌘Tab`) after having hidden it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows, let win = NSApp.windows.first {
            win.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// Intercept the close button: hide the window instead of closing
    /// it, so SwiftUI doesn't tear down the scene. The window is
    /// brought back by the Dock-icon reopen path.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    /// Warn before quitting with unsaved changes — save, discard,
    /// or cancel. The alert blocks the quit; the user's choice
    /// drives whether we tell AppKit to proceed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace = WorkspaceModel.current, workspace.isDirty else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Save changes before quitting?"
        alert.informativeText = "Unsaved edits to “\(workspace.project.name)” will be lost if you quit without saving."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:   // Save
            // Save may be async (NSSavePanel for untitled projects).
            // Quit only once the save actually settles; if it failed or
            // the user cancelled the panel, abort the quit.
            workspace.save { saved in
                NSApp.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        case .alertSecondButtonReturn:  // Cancel
            return .terminateCancel
        default:                        // Discard
            return .terminateNow
        }
    }
}
