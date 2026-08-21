import SwiftUI

struct HomeContent<Action: Hashable>: View {
    let terminalText: String
    let terminalAccessibleLinks: [TerminalPresenter.AccessibleLink]
    let terminalHeight: CGFloat
    let rendersTerminalBackgroundActively: Bool
    let showsMenu: Bool
    let menuItems: [OptionListItem<Action>]
    let preferredMenuAction: Action?
    let secondaryMenuActions: Set<Action>
    let shareItems: [Action: URL]
    let loadingMenuActions: Set<Action>
    let isVolumeButtonInputEnabled: Bool
    let allowsOpeningTerminalLinks: Bool
    let onTerminalColumnCountChange: (Int) -> Void
    let onSelectMenuItem: (Action) -> Void
    var onTerminalLongPress: (() -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let expandableHeight = max(
                0,
                (geometry.size.height - HomeContentLayout.minimumMenuLayoutHeight) / 2
            )

            VStack(alignment: .leading, spacing: 0) {
                if showsMenu {
                    SwiftUI.Color.clear
                        .frame(height: HomeContentLayout.minimumTopSpacing + expandableHeight)
                } else {
                    Spacer(minLength: HomeContentLayout.minimumTopSpacing)
                }

                TerminalPresenter(
                    content: terminalText,
                    accessibleLinks: terminalAccessibleLinks,
                    allowsOpeningLinks: allowsOpeningTerminalLinks,
                    onColumnCountChange: onTerminalColumnCountChange,
                    onLongPress: onTerminalLongPress
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: terminalHeight,
                    maxHeight: showsMenu ? terminalHeight : .infinity,
                    alignment: .topLeading
                )
                .contentShape(Rectangle())

                if showsMenu {
                    ScrollViewReader { proxy in
                        ScrollView {
                            menu { action in
                                proxy.scrollTo(action, anchor: .center)
                            }
                        }
                        .frame(
                            height: HomeContentLayout.minimumMenuViewportHeight + expandableHeight,
                            alignment: .top
                        )
                        .scrollBounceBehavior(.basedOnSize)
                        .scrollIndicators(.hidden)
                        .padding(.leading, -OptionListLayout.markerGutter)
                        .id(menuItems.map(\.id))
                    }

                    SwiftUI.Color.clear
                        .frame(height: HomeContentLayout.minimumBottomSpacing)
                } else {
                    Spacer(minLength: HomeContentLayout.minimumBottomSpacing)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(Theme.pagePadding)
        .background {
            ZStack {
                Theme.background

                CustomBackgroundLayer()

                TerminalCharacterBackground(
                    rendersActively: rendersTerminalBackgroundActively
                )
                .opacity(0.05)
            }
            .ignoresSafeArea()
        }
    }

    private func menu(
        onSelectionChange: @escaping (Action) -> Void
    ) -> some View {
        OptionList(
            entries: menuItems,
            preferredSelection: preferredMenuAction,
            secondaryActions: secondaryMenuActions,
            shareItems: shareItems,
            loadingActions: loadingMenuActions,
            isVolumeButtonInputEnabled: isVolumeButtonInputEnabled,
            onSelectionChange: onSelectionChange,
            onSelect: onSelectMenuItem
        )
        .padding(.top, 36)
    }
}
