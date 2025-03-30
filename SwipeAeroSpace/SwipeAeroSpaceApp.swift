//
//  SwipeAeroSpaceApp.swift
//  SwipeAeroSpace
//
//  Created by Tricster on 1/25/25.
//

import SwiftUI

@available(macOS 14.0, *)
struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings
    
    var body: some View {
        Button("Settings") {
            openSettings()
        }
    }
}

func checkAccessibilityPermissions() {
    let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
    if !AXIsProcessTrustedWithOptions(options as CFDictionary) {
        _ = try? Process.run(URL(filePath: "/usr/bin/tccutil"), arguments: ["reset", "Accessibility", "club.mediosz.SwipeAeroSpace"])
        NSApplication.shared.terminate(nil)
    }
}

@main
struct SwipeAeroSpaceApp: App {
    @AppStorage("menuBarExtraIsInserted") var menuBarExtraIsInserted = true
    @Environment(\.openWindow) private var openWindow
    @State var swipeManager = SwipeManager()
    
    init() {
        checkAccessibilityPermissions()
        swipeManager.start()
    }
    
    var body: some Scene {
        MenuBarExtra(
            "Screenshots",
            image: "MenubarIcon",
            isInserted: $menuBarExtraIsInserted
        ) {
            Button("Next Workspace") {
                swipeManager.nextWorkspace()
            }
            Button("Prev Workspace") {
                swipeManager.prevWorkspace()
            }
            
            if #available(macOS 14.0, *) {
                SettingsButton()
            }
            else {
                Button(action: {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }, label: {
                    Text("Settings")
                })
            }
            
            Button("About") {
                openWindow(id: "about")
            }
            Divider()
            
            Button("Quit") {
                swipeManager.stop()
                NSApplication.shared.terminate(nil)
            }.keyboardShortcut("q")
        }
        
        Settings {
            SettingsView(swipeManager: swipeManager, socketInfo: swipeManager.socketInfo)
        }.windowResizability(.contentSize)
        
        WindowGroup(id: "about") {
            AboutView()
        }.windowResizability(.contentSize)
    }
}
