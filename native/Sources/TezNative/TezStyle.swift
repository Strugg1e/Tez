import AppKit
import Observation
import SwiftUI

@Observable
@MainActor
final class TezPreviewPreferences {
    private let defaults: UserDefaults
    var appearance: TezAppearance { didSet { defaults.set(appearance.rawValue, forKey: "tez.appearance") } }
    var reduceMotion: Bool { didSet { defaults.set(reduceMotion, forKey: "tez.reduceMotion") } }
    var reduceTransparency: Bool { didSet { defaults.set(reduceTransparency, forKey: "tez.reduceTransparency") } }
    var increaseContrast: Bool { didSet { defaults.set(increaseContrast, forKey: "tez.increaseContrast") } }
    var showProtocol: Bool { didSet { defaults.set(showProtocol, forKey: "tez.showProtocol") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: "tez.appearance").flatMap(TezAppearance.init(rawValue:)) ?? .system
        reduceMotion = defaults.bool(forKey: "tez.reduceMotion")
        reduceTransparency = defaults.bool(forKey: "tez.reduceTransparency")
        increaseContrast = defaults.bool(forKey: "tez.increaseContrast")
        showProtocol = defaults.object(forKey: "tez.showProtocol") as? Bool ?? true
    }
}

enum TezAppearance: String, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"
    var id: Self { self }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum TezStyle {
    static let success = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.35, green: 0.80, blue: 0.62, alpha: 1)
            : NSColor(srgbRed: 0.153, green: 0.42, blue: 0.32, alpha: 1)
    })
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.43, green: 0.64, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0.141, green: 0.353, blue: 0.769, alpha: 1)
    })
}

struct TezContentMaterial: View {
    var material: NSVisualEffectView.Material
    @Environment(TezPreviewPreferences.self) private var preferences
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if preferences.reduceTransparency || systemReduceTransparency || preferences.increaseContrast || contrast == .increased {
                Color(nsColor: .windowBackgroundColor)
            } else {
                TezVisualEffect(material: material)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

}

struct TezPrimaryActionStyle: ViewModifier {
    @Environment(TezPreviewPreferences.self) private var preferences
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !preferences.reduceTransparency,
           !systemReduceTransparency, !preferences.increaseContrast, contrast != .increased {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

struct TezWindowSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SurfaceView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class SurfaceView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
            DispatchQueue.main.async { [weak self] in self?.configureWindow() }
        }
        private func configureWindow() {
            guard let window else { return }
            window.isMovable = true
            window.isMovableByWindowBackground = true
            // Materials belong to individual surfaces, not to the window's fallback.
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.titlebarAppearsTransparent = false
            window.hasShadow = true
        }
    }
}

struct TezWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = DragRegionView()
        view.identifier = NSUserInterfaceItemIdentifier("tez.window.drag")
        view.toolTip = "拖动窗口"
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("窗口拖动区域")
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragRegionView: NSView {
        private var dragOrigin: NSPoint?
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: nil)
            if Bundle.main.object(forInfoDictionaryKey: "TezInterfaceOnly") as? Bool == true, let window {
                NotificationCenter.default.addObserver(self, selector: #selector(recordMovement), name: NSWindow.didMoveNotification, object: window)
            }
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            dragOrigin = window.frame.origin
            window.performDrag(with: event)
            if Bundle.main.object(forInfoDictionaryKey: "TezInterfaceOnly") as? Bool == true {
                recordMovement()
            }
        }

        @objc private func recordMovement() {
            guard let window, let before = dragOrigin else { return }
            let after = window.frame.origin
            setAccessibilityValue("drag delta: \(Int(after.x - before.x)), \(Int(after.y - before.y)); movable: \(window.isMovable)")
        }
    }
}

private struct TezVisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.identifier = NSUserInterfaceItemIdentifier("tez.semantic-material")
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.material = material
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

struct TezBrandMark: View {
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / 40
            Path { path in
                path.addArc(center: CGPoint(x: 20, y: 20), radius: 14.5,
                            startAngle: .degrees(-48), endAngle: .degrees(22), clockwise: true)
                path.move(to: CGPoint(x: 19.5, y: 13.5))
                path.addLine(to: CGPoint(x: 33.5, y: 13.5))
                path.move(to: CGPoint(x: 25.5, y: 13.5))
                path.addLine(to: CGPoint(x: 25.5, y: 26.5))
            }
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .stroke(TezStyle.accent, style: StrokeStyle(lineWidth: 5.4 * scale, lineCap: .round))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Tez")
    }
}
