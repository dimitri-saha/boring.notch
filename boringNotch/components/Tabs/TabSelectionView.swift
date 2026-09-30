//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
    TabModel(label: "Terminal", icon: "terminal.fill", view: .terminal)
]

enum NotchTabs {
    /// The tabs that should be offered right now. Home is always present; Shelf follows the
    /// existing "show tabs" rules; Terminal appears whenever the terminal feature is enabled.
    static func visible(shelfEnabled: Bool, shelfHasItems: Bool, alwaysShowTabs: Bool, terminalEnabled: Bool) -> [TabModel] {
        tabs.filter { tab in
            switch tab.view {
            case .home:
                return true
            case .shelf:
                return shelfEnabled && (shelfHasItems || alwaysShowTabs)
            case .terminal:
                return terminalEnabled
            }
        }
    }
}

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var tvm = ShelfStateViewModel.shared
    @Default(.boringShelf) var boringShelf
    @Default(.enableTerminal) var enableTerminal
    @Namespace var animation

    private var visibleTabs: [TabModel] {
        NotchTabs.visible(
            shelfEnabled: boringShelf,
            shelfHasItems: !tvm.isEmpty,
            alwaysShowTabs: coordinator.alwaysShowTabs,
            terminalEnabled: enableTerminal
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
