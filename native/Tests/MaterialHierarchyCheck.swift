import AppKit
import SwiftUI

@main
struct MaterialHierarchyCheck {
    @MainActor
    static func main() {
        guard #available(macOS 26.0, *) else {
            print("SKIP: Liquid Glass requires macOS 26")
            return
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                              styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        let suite = "tez.material-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TezPreviewPreferences(defaults: defaults)
        let host = NSHostingView(rootView: WorkspaceView(selection: .constant(.routes))
            .environment(preferences))
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        guard window.isOpaque && window.backgroundColor.alphaComponent == 1 else {
            print("FAIL: The window must retain an opaque fallback behind empty and loading content")
            exit(1)
        }
        guard window.isMovable && window.isMovableByWindowBackground else {
            print("FAIL: Native window background dragging is not enabled")
            exit(1)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()

        var glassCount = 0
        var nestedGlassCount = 0
        var contentMaterials = 0
        @MainActor func visit(_ view: NSView, insideGlass: Bool) {
            let isGlass = view is NSGlassEffectView
            if isGlass {
                glassCount += 1
                if insideGlass { nestedGlassCount += 1 }
            }
            if let material = view as? NSVisualEffectView,
               material.identifier?.rawValue == "tez.semantic-material",
               material.material == .headerView || material.material == .contentBackground {
                contentMaterials += 1
            }
            for child in view.subviews { visit(child, insideGlass: insideGlass || isGlass) }
        }
        visit(host, insideGlass: false)
        guard glassCount > 0 else {
            print("FAIL: The test did not render the real system sidebar")
            exit(1)
        }
        guard nestedGlassCount == 0 else {
            print("FAIL: Found \(nestedGlassCount) glass backgrounds nested inside system glass")
            exit(1)
        }
        print("PASS: System glass exists with no nested glass backgrounds")
        guard contentMaterials == 2 else {
            print("FAIL: Expected semantic header and detail materials, got \(contentMaterials)")
            exit(1)
        }
        print("PASS: Route information uses two semantic standard materials")

        for highContrast in [false, true] {
            preferences.reduceTransparency = !highContrast
            preferences.increaseContrast = highContrast
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            contentMaterials = 0
            visit(host, insideGlass: false)
            guard contentMaterials == 0 else {
                print("FAIL: Opaque accessibility fallback retained translucent content materials")
                exit(1)
            }
            print("PASS: \(highContrast ? "Increased contrast" : "Reduced transparency") uses opaque content surfaces")
        }

        let liveWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let liveHost = NSHostingView(rootView: LiveWorkspaceView(store: NativeBackendStore()).environment(preferences))
        liveWindow.contentView = liveHost
        liveHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard liveWindow.isOpaque && liveWindow.backgroundColor.alphaComponent == 1 else {
            print("FAIL: Disconnected live workspace lost its opaque window fallback")
            exit(1)
        }
        print("PASS: Disconnected live workspace retains an opaque fallback without starting a backend")
    }
}
