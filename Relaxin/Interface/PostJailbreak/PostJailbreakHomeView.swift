import LocalAuthentication
import PhotosUI
import SwiftUI

struct PostJailbreakHomeView: View {
    private static let ownGoalStudioPicksURL = URL(string: "https://owngoal.dev")!

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @ObservedObject var session: PostJailbreakSession

    let environment: PostJailbreakEnvironment

    @State private var screen = Screen.home
    @State private var alert: Alert?
    @State private var visibleCreditCharacterCount = 0
    @State private var terminalColumnCount = 32

    /// Custom background picker presentation state.
    @State private var showsBackgroundPicker = false
    @State private var backgroundPickerKind: CustomBackgroundKind = .image
    @State private var backgroundPickerItem: PhotosPickerItem?
    @State private var backgroundRevision = 0

    private var bootLogoUsesDarkAppearance: Bool {
        colorScheme == .dark
    }

    private var terminalOutput: [TerminalOutputLine] {
        guard session.isPerformingAction,
              screen == .confirmation(.removeJailbreak)
        else {
            return session.output
        }
        return session.output + [
            TerminalOutputLine(
                label: String(
                    localized: "Removing the jailbreak. Keep Relaxin in the foreground.",
                    bundle: environment.resourceBundle
                ),
                status: .running
            ),
        ]
    }

    private var terminalText: String {
        guard session.isAvailable else {
            return RelaxinTerminalContent.unavailable(
                resourceBundle: environment.resourceBundle
            )
        }
        switch screen.terminalSurface {
        case .home:
            return RelaxinTerminalContent.home(
                isJailbroken: true,
                resourceBundle: environment.resourceBundle
            )
        case let .command(command):
            return RelaxinTerminalContent.command(
                command: command,
                output: terminalOutput,
                isJailbroken: true,
                terminalWidth: terminalColumnCount,
                resourceBundle: environment.resourceBundle
            )
        case .credits:
            return RelaxinTerminalContent.credits(
                visibleCharacterCount: visibleCreditCharacterCount,
                linksEnabled: environment.interfaceMode.allowsExternalNavigation
            )
        }
    }

    private var terminalAccessibleLinks: [TerminalPresenter.AccessibleLink] {
        guard screen == .credits else { return [] }
        return RelaxinCredits.accessibleLinks(
            linksEnabled: environment.interfaceMode.allowsExternalNavigation
        )
    }

    private var menuItems: [OptionListItem<MenuAction>] {
        guard session.isAvailable else { return [] }
        return screen.menuEntries(
            runtimeOptions: session.runtimeOptions,
            canReinstallSileo: session.canReinstallSileo,
            allowsExternalNavigation: environment.interfaceMode.allowsExternalNavigation,
            resourceBundle: environment.resourceBundle
        ).map { entry in
            OptionListItem(id: entry.action, title: entry.title)
        }
    }

    private var menuShareItems: [MenuAction: URL] {
        guard environment.interfaceMode.allowsExternalNavigation,
              screen == .credits,
              let url = environment.resourceBundle.url(
                  forResource: "Licenses",
                  withExtension: "txt"
              )
        else {
            return [:]
        }
        return [.showSoftwareLicense: url]
    }

    private var enabledToggleOptions: Set<ToggleOption> {
        Set(
            ToggleOption.allCases.filter {
                $0.isEnabled(in: session.runtimeOptions)
            }
        )
    }

    var body: some View {
        HomeContent(
            terminalText: terminalText,
            terminalAccessibleLinks: terminalAccessibleLinks,
            terminalHeight: screen.terminalHeight,
            rendersTerminalBackgroundActively: false,
            showsMenu: session.isAvailable,
            menuItems: menuItems,
            preferredMenuAction: nil,
            secondaryMenuActions: [.back],
            shareItems: menuShareItems,
            loadingMenuActions: [],
            isVolumeButtonInputEnabled: alert == nil
                && !session.isPerformingAction,
            allowsOpeningTerminalLinks: environment.interfaceMode.allowsExternalNavigation,
            onTerminalColumnCountChange: { terminalColumnCount = $0 },
            onSelectMenuItem: performMenuAction,
            onTerminalLongPress: promptSloganEdit
        )
        .disabled(session.isPerformingAction)
        .allowsHitTesting(!session.isPerformingAction)
        .id(backgroundRevision)
        .onReceive(
            NotificationCenter.default.publisher(
                for: RelaxinSlogan.changedNotification
            )
        ) { _ in
            backgroundRevision += 1
        }
        .task(id: screen == .credits) {
            await animateCreditsIfNeeded()
        }
        .modifier(
            LightImpactFeedbackModifier(trigger: screen) { oldScreen, newScreen in
                oldScreen != newScreen
            }
        )
        .modifier(LightImpactFeedbackModifier(trigger: enabledToggleOptions))
        .sheet(isPresented: $showsBackgroundPicker) {
            backgroundPicker
        }
        .alert(item: $alert) { alert in
            switch alert.kind {
            case .notice:
                SwiftUI.Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(
                        Text(
                            String(
                                localized: "OK",
                                bundle: environment.resourceBundle
                            )
                        )
                    )
                )
            case .userspaceRebootRequired:
                SwiftUI.Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(
                        Text(
                            String(
                                localized: "Reboot Now",
                                bundle: environment.resourceBundle
                            )
                        )
                    ) {
                        restartUserspace()
                    },
                    secondaryButton: .cancel(
                        Text(
                            String(
                                localized: "Reboot Later",
                                bundle: environment.resourceBundle
                            )
                        )
                    )
                )
            }
        }
    }

    private func performMenuAction(_ action: MenuAction) {
        switch action {
        case .advancedOptions:
            session.refreshRuntimeOptions()
            screen = .advancedOptions
        case .resetAndRemoval:
            screen = .resetAndRemoval
        case .credits:
            screen = .credits
        case .openOwnGoalStudioPicks:
            guard environment.interfaceMode.allowsExternalNavigation else { return }
            openURL(Self.ownGoalStudioPicksURL)
        case .showSoftwareLicense:
            guard environment.interfaceMode.allowsExternalNavigation else { return }
            showSoftwareLicenseUnavailable()
        case let .toggleOption(option):
            toggle(option)
        case let .confirm(action):
            screen = .confirmation(action)
        case .restartSpringBoard:
            session.perform(.restartSpringBoard)
        case .restartUserspace:
            restartUserspace()
        case .refreshJailbreakApps:
            session.perform(.refreshJailbreakApps)
        case .customizeBackground:
            screen = .customBackground
        case let .setBackground(kind):
            showBackgroundPicker(kind: kind)
        case .clearBackground:
            CustomBackgroundStore.clear()
            backgroundRevision += 1
            screen = .advancedOptions
        case .resetMobilePassword:
            authenticateForPasswordReset()
        case .reinstallSileo:
            guard session.canReinstallSileo else { return }
            session.reinstallSileo()
        case .removeJailbreak:
            session.perform(.removeJailbreak)
        case .back:
            if let destination = screen.backDestination {
                screen = destination
            }
        }
    }

    private func toggle(_ option: ToggleOption) {
        let enabled = !option.isEnabled(in: session.runtimeOptions)
        switch option {
        case .tweakInjection:
            session.setTweakInjectionEnabled(enabled)
            alert = .userspaceRebootRequired(in: environment.resourceBundle)
        case .appJIT:
            session.setAppJITEnabled(enabled)
        }
    }

    private func restartUserspace() {
        session.perform(
            .restartUserspace(darkAppearance: bootLogoUsesDarkAppearance)
        )
    }

    private func authenticateForPasswordReset() {
        let context = LAContext()
        var authenticationError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &authenticationError
        ) else {
            session.perform(.resetMobilePassword)
            return
        }

        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: String(
                localized: "Authentication is required to change your mobile password.",
                bundle: environment.resourceBundle
            )
        ) { success, _ in
            guard success else { return }
            Task { @MainActor in
                session.perform(.resetMobilePassword)
            }
        }
    }

    private func showSoftwareLicenseUnavailable() {
        guard environment.interfaceMode.allowsExternalNavigation else { return }
        let message = String(
            localized: "The software license file is missing.",
            bundle: environment.resourceBundle
        )
        AppLog.error(Self.self, message)
        alert = Alert(
            title: String(
                localized: "Software License Unavailable",
                bundle: environment.resourceBundle
            ),
            message: message
        )
    }

    private func animateCreditsIfNeeded() async {
        visibleCreditCharacterCount = 0
        guard screen == .credits else { return }

        var characterCount = 0
        while characterCount < RelaxinCredits.characterCount {
            do {
                try await Task.sleep(
                    for: .milliseconds(.random(in: 15 ... 35))
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            characterCount = min(
                characterCount + .random(in: 1 ... 4),
                RelaxinCredits.characterCount
            )
            visibleCreditCharacterCount = characterCount
        }
    }

    // MARK: - Custom Background

    private func showBackgroundPicker(kind: CustomBackgroundKind) {
        backgroundPickerKind = kind
        backgroundPickerItem = nil
        showsBackgroundPicker = true
    }

    @ViewBuilder
    private var backgroundPicker: some View {
        NavigationStack {
            PhotosPicker(
                selection: $backgroundPickerItem,
                matching: backgroundPickerKind == .image ? .images : .videos,
                preferredItemEncoding: .current
            ) {
                Text(
                    backgroundPickerKind == .image
                        ? "选择背景图片"
                        : "选择背景视频"
                )
                .font(Theme.font)
                .padding()
            }
            .navigationTitle("自定义背景")
            .onChange(of: backgroundPickerItem) { newItem in
                guard let newItem else { return }
                loadBackgroundItem(newItem)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func loadBackgroundItem(_ item: PhotosPickerItem) {
        Task { @MainActor in
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      !data.isEmpty
                else {
                    return
                }

                let fileExtension = backgroundPickerKind == .image ? "jpg" : "mov"
                let temporaryURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "relaxin-background-\(UUID().uuidString).\(fileExtension)"
                    )
                try data.write(to: temporaryURL)

                guard CustomBackgroundStore.install(
                    kind: backgroundPickerKind,
                    sourceURL: temporaryURL
                ) else {
                    return
                }
                try? FileManager.default.removeItem(at: temporaryURL)

                backgroundRevision += 1
                showsBackgroundPicker = false
                screen = .customBackground
            } catch {
                AppLog.error(Self.self, "background pick failed: \(error)")
            }
        }
    }

    /// Long-press on the terminal banner: edit the slogan text.
    private func promptSloganEdit() {
        guard !session.isPerformingAction else { return }

        let alert = UIAlertController(
            title: "自定义标语",
            message: "修改首页显示的文字，保存后立即生效。",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.text = RelaxinSlogan.current
            textField.clearButtonMode = .whileEditing
            textField.autocapitalizationType = .sentences
        }
        alert.addAction(
            UIAlertAction(
                title: "保存",
                style: .default
            ) { [weak alert] _ in
                let text = alert?.textFields?.first?.text ?? ""
                RelaxinSlogan.set(text)
            }
        )
        alert.addAction(
            UIAlertAction(
                title: "重置",
                style: .destructive
            ) { _ in
                RelaxinSlogan.reset()
            }
        )
        alert.addAction(
            UIAlertAction(
                title: "取消",
                style: .cancel
            )
        )

        guard let host = viewControllerHost() else { return }
        host.present(alert, animated: true)
    }

    /// Finds the nearest presented UIViewController to host UIKit alerts.
    private func viewControllerHost() -> UIViewController? {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else {
            return nil
        }
        var top = windowScene.windows
            .first(where: { $0.isKeyWindow })?
            .rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
