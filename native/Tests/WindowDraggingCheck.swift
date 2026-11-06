import AppKit
import SwiftUI

@MainActor
private final class RecordingWindow: NSWindow {
    var dragCount = 0
    override func performDrag(with event: NSEvent) { dragCount += 1 }
}

@MainActor @Observable
private final class ControlState {
    var clicks = 0
    var text = "Editable text"
    var enabled = false
}

private struct ControlFixture: View {
    @Bindable var state: ControlState
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button("Plain action") { state.clicks += 1 }.buttonStyle(.plain)
                .frame(width: 180, height: 40)
            TextField("Value", text: $state.text).frame(width: 180, height: 40)
            Toggle("Enabled", isOn: $state.enabled).frame(width: 180, height: 40)
            Text("Selectable text").textSelection(.enabled).frame(width: 180, height: 40)
            Spacer()
        }
        .padding(20).frame(width: 500, height: 400, alignment: .topLeading)
        .tezWindowDragBackground("tez.window.drag.controls")
        .background(TezWindowSurface())
    }
}

@main
struct WindowDraggingCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            Task { @MainActor in
                await runChecks()
                exit(0)
            }
        }
        NSApp.run()
    }

    @MainActor private static func runChecks() async {
        let defaults = UserDefaults(suiteName: "tez.window-drag-check")!
        defer { defaults.removePersistentDomain(forName: "tez.window-drag-check") }
        let preferences = TezPreviewPreferences(defaults: defaults)
        let workspace = makeWindow(LiveWorkspaceView(store: NativeBackendStore()).environment(preferences), width: 1040, height: 700)
        checkRegion("tez.window.drag.empty", in: workspace)
        require(workspace.dragCount == 1, "Workspace blank space must explicitly start a window drag")
        print("PASS: Workspace blank space starts a native window drag")

        let table = descendants(workspace.contentView!).compactMap { $0 as? NSTableView }.first!
        let blank = table.convert(NSPoint(x: 50, y: table.bounds.maxY - 20), to: nil)
        require(table.row(at: table.convert(blank, from: nil)) == -1, "Sidebar fixture must contain empty space")
        click(blank, in: workspace)
        require(workspace.dragCount == 1, "List empty-space selection behavior must not be intercepted")
        let row = table.convert(NSPoint(x: 50, y: table.rect(ofRow: 1).midY), to: nil)
        click(row, in: workspace)
        require(workspace.dragCount == 1, "Sidebar rows must retain selection instead of dragging")
        let brand = descendants(workspace.contentView!).first { $0.identifier?.rawValue == "tez.window.drag.brand" }!
        click(brand.convert(NSPoint(x: 30, y: brand.bounds.midY), to: nil), in: workspace)
        require(workspace.dragCount == 2, "The noninteractive brand area must start a window drag")
        print("PASS: Brand area drags; list rows and empty-space selection keep their events")

        let state = ControlState()
        let controls = makeWindow(ControlFixture(state: state), width: 500, height: 400)
        click(NSPoint(x: 110, y: 360), in: controls)
        require(controls.dragCount == 0 && state.clicks == 1, "SwiftUI buttons must still execute without starting a window drag (drags=\(controls.dragCount), clicks=\(state.clicks))")
        for point in [NSPoint(x: 110, y: 300), NSPoint(x: 110, y: 240), NSPoint(x: 110, y: 180)] {
            click(point, in: controls)
            require(controls.dragCount == 0, "Inputs, switches and selectable text must not start window drags")
        }
        click(NSPoint(x: 350, y: 180), in: controls)
        require(controls.dragCount == 1, "Blank control-page space must still drag")
        print("PASS: SwiftUI buttons, native inputs, switches and selectable text keep their events")

        let settings = makeWindow(TezSettingsView(allowsBackendExamples: false).environment(preferences)
            .background(TezWindowSurface()), width: 740, height: 660)
        click(NSPoint(x: 400, y: 100), in: settings)
        require(settings.dragCount == 1, "Settings scroll-container blank space must start a drag")
        print("PASS: Settings blank space starts a native window drag")

        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/TezLayoutFixture")
        let store = NativeBackendStore(helperURL: helper, arguments: ["--fixture", "--route-controls"], mode: .attach)
        store.connect()
        for _ in 0..<200 {
            if store.state == .connected { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        require(store.state == .connected && store.snapshot != nil, "Real-page fixture must supply populated snapshots")
        defer { store.disconnect() }
        workspace.orderOut(nil)
        controls.orderOut(nil)
        settings.orderOut(nil)
        for width: CGFloat in [1040, 800] {
            for section in WorkspaceSection.allCases {
                let window = makeWindow(LiveWorkspaceView(store: store, selection: .constant(section)).environment(preferences),
                                        width: width, height: 700)
                try? await Task.sleep(for: .milliseconds(400))
                let identifiers: [String] = switch section {
                case .connection: ["page"]
                case .routes: ["header", "filter", "footer"]
                case .profiles: ["header", "page"]
                case .activity: ["header", "filter", "footer"]
                }
                for identifier in identifiers { checkRegion("tez.window.drag.\(identifier)", in: window) }
                print("PASS: \(section.rawValue) reachable drag regions at \(Int(width)) points")
                window.orderOut(nil)
            }
        }
        let logs = makeWindow(NativeLogsView(store: store).environment(preferences), width: 860, height: 560)
        try? await Task.sleep(for: .milliseconds(400))
        checkRegion("tez.window.drag.filter", in: logs)
        checkRegion("tez.window.drag.footer", in: logs)
        logs.orderOut(nil)
        print("PASS: Log controls and footer have reachable blank drag regions")
        print("Window dragging checks passed")
    }

    @MainActor private static func checkRegion(_ identifier: String, in window: RecordingWindow) {
        let content = window.contentView!
        for region in descendants(content) where region.identifier?.rawValue == identifier {
            for x in [0.5, 0.25, 0.75, 0.02, 0.98] {
                for y in [0.5, 0.25, 0.75] {
                    let point = region.convert(NSPoint(x: region.bounds.width * x, y: region.bounds.height * y), to: nil)
                    guard content.hitTest(content.superview?.convert(point, from: nil) ?? point) === region else { continue }
                    let before = window.dragCount
                    click(point, in: window)
                    require(window.dragCount == before + 1, "\(identifier) must call native dragging at \(point)")
                    return
                }
            }
        }
        require(false, "\(identifier) has no reachable blank drag region")
    }

    @MainActor private static func makeWindow(_ content: some View, width: CGFloat, height: CGFloat) -> RecordingWindow {
        let window = RecordingWindow(contentRect: NSRect(x: 300, y: 200, width: width, height: height),
                                     styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: content)
        window.contentView = host
        _ = window.windowNumber
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor private static func click(_ point: NSPoint, in window: NSWindow) {
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 1.1,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
        while let event = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func require(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
