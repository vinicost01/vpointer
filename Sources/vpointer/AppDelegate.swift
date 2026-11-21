import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let showMenuBarNotification = Notification.Name("com.vinicost.vpointer.showMenuBarIcon")

    private enum PrefKey {
        static let scrollAutomationEnabled = "scrollAutomationEnabled"
        static let middleClickEnabled = "middleClickEnabled"
        static let middleClickPressEnabled = "middleClickPressEnabled"
        static let middleClickTapEnabled = "middleClickTapEnabled"
        static let hideMenuBarIcon = "hideMenuBarIcon"
    }

    private var statusItem: NSStatusItem?
    private var scrollManager: ScrollManager!
    private var mouseMonitor: MouseMonitor!
    private var middleClickManager: MiddleClickManager!

    private var isAutomationEnabled: Bool = true
    private var isMiddleClickEnabled: Bool = false
    private var isMiddleClickPressEnabled: Bool = true
    private var isMiddleClickTapEnabled: Bool = true
    private var isMenuBarIconHidden: Bool = false
    private var connectedMice: [String] = []

    private var mouseStatusItem: NSMenuItem?
    private var scrollStatusItem: NSMenuItem?
    private var automationToggleItem: NSMenuItem?
    private var middleClickToggleItem: NSMenuItem?
    private var middleClickPressItem: NSMenuItem?
    private var middleClickTapItem: NSMenuItem?
    private var accessibilityPermissionItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadPreferences()

        scrollManager = ScrollManager()
        middleClickManager = MiddleClickManager()
        middleClickManager.isClickEnabled = isMiddleClickPressEnabled
        middleClickManager.isTapEnabled = isMiddleClickTapEnabled
        middleClickManager.onAccessibilityStatusChanged = { [weak self] _ in
            self?.updateUI()
        }
        middleClickManager.isEnabled = isMiddleClickEnabled

        if !isMenuBarIconHidden {
            setupStatusBar()
        }

        mouseMonitor = MouseMonitor { [weak self] mice in
            self?.handleMouseListChanged(mice)
        }
        mouseMonitor.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleShowMenuBarNotification),
            name: Self.showMenuBarNotification,
            object: nil
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMenuBarIcon()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        mouseMonitor?.stop()
        middleClickManager?.isEnabled = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - Preferences

    private func loadPreferences() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            PrefKey.scrollAutomationEnabled: true,
            PrefKey.middleClickEnabled: false,
            PrefKey.middleClickPressEnabled: true,
            PrefKey.middleClickTapEnabled: true,
            PrefKey.hideMenuBarIcon: false
        ])

        isAutomationEnabled = defaults.bool(forKey: PrefKey.scrollAutomationEnabled)
        isMiddleClickEnabled = defaults.bool(forKey: PrefKey.middleClickEnabled)
        isMiddleClickPressEnabled = defaults.bool(forKey: PrefKey.middleClickPressEnabled)
        isMiddleClickTapEnabled = defaults.bool(forKey: PrefKey.middleClickTapEnabled)
        isMenuBarIconHidden = defaults.bool(forKey: PrefKey.hideMenuBarIcon)
    }

    private func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(isAutomationEnabled, forKey: PrefKey.scrollAutomationEnabled)
        defaults.set(isMiddleClickEnabled, forKey: PrefKey.middleClickEnabled)
        defaults.set(isMiddleClickPressEnabled, forKey: PrefKey.middleClickPressEnabled)
        defaults.set(isMiddleClickTapEnabled, forKey: PrefKey.middleClickTapEnabled)
        defaults.set(isMenuBarIconHidden, forKey: PrefKey.hideMenuBarIcon)
    }

    // MARK: - Status Bar UI

    private func setupStatusBar() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        let menu = NSMenu()

        let mouseItem = NSMenuItem(title: "Verificando dispositivos...", action: nil, keyEquivalent: "")
        mouseItem.isEnabled = false
        menu.addItem(mouseItem)
        mouseStatusItem = mouseItem

        let scrollItem = NSMenuItem(title: "Natural Scrolling: —", action: nil, keyEquivalent: "")
        scrollItem.isEnabled = false
        menu.addItem(scrollItem)
        scrollStatusItem = scrollItem

        menu.addItem(.separator())

        let autoItem = NSMenuItem(
            title: "Troca automática de Natural Scrolling",
            action: #selector(toggleAutomation),
            keyEquivalent: ""
        )
        autoItem.target = self
        menu.addItem(autoItem)
        automationToggleItem = autoItem

        menu.addItem(.separator())

        let mcToggle = NSMenuItem(
            title: "MiddleClick (3 dedos)",
            action: #selector(toggleMiddleClick),
            keyEquivalent: ""
        )
        mcToggle.target = self
        menu.addItem(mcToggle)
        middleClickToggleItem = mcToggle

        let mcPress = NSMenuItem(
            title: "Clique físico com 3 dedos",
            action: #selector(toggleMiddleClickPress),
            keyEquivalent: ""
        )
        mcPress.target = self
        mcPress.indentationLevel = 1
        menu.addItem(mcPress)
        middleClickPressItem = mcPress

        let mcTap = NSMenuItem(
            title: "Toque leve com 3 dedos (Tap)",
            action: #selector(toggleMiddleClickTap),
            keyEquivalent: ""
        )
        mcTap.target = self
        mcTap.indentationLevel = 1
        menu.addItem(mcTap)
        middleClickTapItem = mcTap

        let permItem = NSMenuItem(
            title: "⚠ Conceder permissão de Acessibilidade...",
            action: #selector(requestAccessibilityPermission),
            keyEquivalent: ""
        )
        permItem.target = self
        permItem.indentationLevel = 1
        menu.addItem(permItem)
        accessibilityPermissionItem = permItem

        menu.addItem(.separator())

        let loginItem = NSMenuItem(
            title: "Iniciar com o macOS",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.target = self
        menu.addItem(loginItem)
        launchAtLoginItem = loginItem

        let hideIconItem = NSMenuItem(
            title: "Ocultar ícone da barra de menus",
            action: #selector(hideMenuBarIcon),
            keyEquivalent: ""
        )
        hideIconItem.target = self
        menu.addItem(hideIconItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Sair do vpointer",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        updateLaunchAtLoginState()
        updateUI()
    }

    private func showMenuBarIcon() {
        isMenuBarIconHidden = false
        savePreferences()
        setupStatusBar()
        updateUI()
    }

    private func handleMouseListChanged(_ mice: [String]) {
        connectedMice = mice
        applyScrollRuleIfEnabled()
        updateUI()
    }

    private func applyScrollRuleIfEnabled() {
        guard isAutomationEnabled else { return }
        let shouldEnableNaturalScrolling = connectedMice.isEmpty
        if scrollManager.isNaturalScrollingEnabled != shouldEnableNaturalScrolling {
            scrollManager.setNaturalScrolling(enabled: shouldEnableNaturalScrolling)
        }
    }

    private func updateUI() {
        guard let statusItem else { return }
        let hasMouse = !connectedMice.isEmpty
        let naturalEnabled = scrollManager.isNaturalScrollingEnabled

        if let button = statusItem.button {
            let symbolName: String
            if !isAutomationEnabled {
                symbolName = "computermouse"
            } else {
                symbolName = hasMouse ? "computermouse.fill" : "hand.draw"
            }

            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "vpointer") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = hasMouse ? "M" : "T"
            }

            button.appearsDisabled = !isAutomationEnabled && !isMiddleClickEnabled
            button.toolTip = hasMouse
                ? "vpointer: Mouse conectado (Natural Scrolling desativado)"
                : "vpointer: Nenhum mouse conectado (Natural Scrolling ativado)"
        }

        if hasMouse {
            let uniqueNames = Array(NSOrderedSet(array: connectedMice)) as? [String] ?? connectedMice
            mouseStatusItem?.title = "Mouse conectado: \(uniqueNames.joined(separator: ", "))"
        } else {
            mouseStatusItem?.title = "Nenhum mouse conectado"
        }

        scrollStatusItem?.title = "Natural Scrolling: \(naturalEnabled ? "Ativado" : "Desativado")"
        automationToggleItem?.state = isAutomationEnabled ? .on : .off

        middleClickToggleItem?.state = isMiddleClickEnabled ? .on : .off
        middleClickPressItem?.state = isMiddleClickPressEnabled ? .on : .off
        middleClickTapItem?.state = isMiddleClickTapEnabled ? .on : .off
        middleClickPressItem?.isHidden = !isMiddleClickEnabled
        middleClickTapItem?.isHidden = !isMiddleClickEnabled

        let needsPermission = isMiddleClickEnabled && !middleClickManager.hasAccessibilityPermission
        accessibilityPermissionItem?.isHidden = !needsPermission
    }

    private func updateLaunchAtLoginState() {
        guard let launchAtLoginItem else { return }
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            launchAtLoginItem.state = (status == .enabled) ? .on : .off
            launchAtLoginItem.isEnabled = true
        } else {
            launchAtLoginItem.isEnabled = false
        }
    }

    // MARK: - Actions

    @objc private func handleWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.mouseMonitor.refreshConnectedDevices()
            self?.middleClickManager.restartDevicesIfRunning()
        }
    }

    @objc private func handleShowMenuBarNotification() {
        DispatchQueue.main.async { [weak self] in
            self?.showMenuBarIcon()
        }
    }

    @objc private func toggleAutomation() {
        isAutomationEnabled.toggle()
        savePreferences()
        if isAutomationEnabled {
            applyScrollRuleIfEnabled()
        }
        updateUI()
    }

    @objc private func toggleMiddleClick() {
        isMiddleClickEnabled.toggle()
        savePreferences()
        middleClickManager.isEnabled = isMiddleClickEnabled
        if isMiddleClickEnabled && !middleClickManager.hasAccessibilityPermission {
            middleClickManager.requestAccessibilityPermission()
        }
        updateUI()
    }

    @objc private func toggleMiddleClickPress() {
        isMiddleClickPressEnabled.toggle()
        savePreferences()
        middleClickManager.isClickEnabled = isMiddleClickPressEnabled
        updateUI()
    }

    @objc private func toggleMiddleClickTap() {
        isMiddleClickTapEnabled.toggle()
        savePreferences()
        middleClickManager.isTapEnabled = isMiddleClickTapEnabled
        updateUI()
    }

    @objc private func requestAccessibilityPermission() {
        middleClickManager.requestAccessibilityPermission()
        updateUI()
    }

    @objc private func hideMenuBarIcon() {
        let alert = NSAlert()
        alert.messageText = "Ocultar ícone da barra de menus?"
        alert.informativeText = "O vpointer continuará funcionando em segundo plano.\n\nPara exibir o ícone novamente, basta abrir o aplicativo vpointer pelo Spotlight ou pela pasta Aplicativos."
        alert.addButton(withTitle: "Ocultar")
        alert.addButton(withTitle: "Cancelar")
        alert.alertStyle = .informational

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isMenuBarIconHidden = true
        savePreferences()

        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Não foi possível alterar o início automático"
            alert.informativeText = "Mova o vpointer.app para a pasta /Applications e tente novamente.\n\nDetalhe: \(error.localizedDescription)"
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        updateLaunchAtLoginState()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
