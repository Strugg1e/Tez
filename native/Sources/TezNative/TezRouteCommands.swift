import SwiftUI

struct TezRouteNavigation {
    let enabled: Bool
    let move: (Int) -> Void
}

private struct TezRouteNavigationKey: FocusedValueKey {
    typealias Value = TezRouteNavigation
}

extension FocusedValues {
    var tezRouteNavigation: TezRouteNavigation? {
        get { self[TezRouteNavigationKey.self] }
        set { self[TezRouteNavigationKey.self] = newValue }
    }
}

struct TezRouteCommands: Commands {
    @FocusedValue(\.tezRouteNavigation) private var navigation

    var body: some Commands {
        CommandMenu("线路") {
            Button("选择上一条线路") { navigation?.move(-1) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(navigation?.enabled != true)
            Button("选择下一条线路") { navigation?.move(1) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(navigation?.enabled != true)
        }
    }
}
