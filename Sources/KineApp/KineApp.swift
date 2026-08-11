import SwiftUI
import AppKit
import KineAppUI

@main
struct KineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Kinestasis") {
            KineRootView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        Settings {
            KineSettingsView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Kinestasis") {
                    NotificationCenter.default.post(name: .kineShowAbout, object: nil)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    NotificationCenter.default.post(name: .kineNewProject, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("New Sequence…") {
                    NotificationCenter.default.post(name: .kineNewSequence, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("Open Project…") {
                    NotificationCenter.default.post(name: .kineOpenProject, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Sequence") {
                Button("Add Video Track") {
                    NotificationCenter.default.post(name: .kineAddVideoTrack, object: nil)
                }
                Button("Add Audio Track") {
                    NotificationCenter.default.post(name: .kineAddAudioTrack, object: nil)
                }
                Divider()
                Button("Render In to Out") {
                    NotificationCenter.default.post(name: .kineRenderInToOut, object: nil)
                }
                .keyboardShortcut(.return, modifiers: .shift)
            }
            CommandMenu("Clip") {
                Button("Effect Controls…") {
                    NotificationCenter.default.post(name: .kineShowEffectControls, object: nil)
                }
                .keyboardShortcut("5", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    NotificationCenter.default.post(name: .kineSave, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Save As…") {
                    NotificationCenter.default.post(name: .kineSaveAs, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("Export Sequence…") {
                    NotificationCenter.default.post(name: .kineExportSequence, object: nil)
                }
                .keyboardShortcut("e", modifiers: .command)

                Button("Export FCPXML…") {
                    NotificationCenter.default.post(name: .kineExportFCPXML, object: nil)
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

        // The whole app is dark chrome (pro-NLE convention). Forcing the
        // appearance at the NSApp level covers every window AppKit makes
        // for us: Settings, menus, context menus, popovers, open/save
        // panels. Without this, system light mode rendered black text on
        // our dark panels in windows outside the root view's
        // preferredColorScheme.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // Dock icon (SPM executable has no .app bundle/Info.plist icon, so
        // set it at runtime). The mark: a burst card with amber motion
        // echoes, drawn on the standard 824/1024 icon grid so it sits at
        // the same size as every other Dock icon.
        if let url = Bundle.module.url(forResource: "KineIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = img
        }

        // The main window exists by now (SwiftUI builds it before
        // applicationDidFinishLaunching fires). Hook it up:
        // - Frame autosave so position/size survive relaunches.
        // - Window delegate so the red close button HIDES the window
        //   instead of destroying it (Final Cut style).
        if let win = NSApp.windows.first(where: { $0.title == "Kinestasis" || $0.contentView != nil }) {
            win.setFrameAutosaveName("kine.main.window")
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
