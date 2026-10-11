import AppKit
import DesignSystem
import T3Protocol

/// Settings > Integrations (IntegrationsSettings.tsx, ProjectDefaultsSettings.tsx with `category="integrations"`):
/// agent browser access, the browser defaults this device keeps, and the device hub rows.
public final class IntegrationsSettingsView: ScopedSettingsPage {
    private var deviceInventoryTask: Task<Void, Never>?
    private var deviceHostEditor: DeviceHostEditor?
    public init(context: SettingsPageContext) {
        super.init(context: context)
        body = [browserAccessSection(), browserSection(), browserProfilesSection(), devicesSection()]
    }

    // MARK: Agent browser access (server, project-scoped)

    private func browserAccessSection() -> SettingsSectionView {
        let r = serverSwitch("agent-browser-access", "", key: "enableAgentBrowserAccess", reset: "default browser access", label: "Agent browser access")
        r.title = "Agent browser access"
        projectScopeDetails([(r, "Allow agents in this project to use the shared browser. Applies when the agent session next starts.",
                              "Allow agents to use the shared browser. Projects can override it.")])
        return section("browser-access", "Browser", [r])
    }

    // MARK: Browser defaults (this device)

    private func browserSection() -> SettingsSectionView {
        let viewport = SettingsBrowserViewportControl(frame: .zero)
        let viewportRow = row("browser-default-viewport", detail: "Tab size for you and agents. Fill fits the panel; other sizes show the device toolbar.", control: viewport)
        let viewportReset = ResetSlot(label: "default browser viewport")
        viewportRow.accessories = [viewportReset]
        viewportReset.action = { [weak self] in self?.context.writeClient?(["browserDefaultViewport": .object(["_tag": .string("fill")])]) }
        viewport.onChange = { [weak self] value in
            self?.context.writeClient?(["browserDefaultViewport": value])
            self?.onHeightChange?()
        }
        binder.add { [weak self, weak viewport] in
            guard let self else { return }
            viewport?.value = client["browserDefaultViewport"]
            viewportReset.isShown = client["browserDefaultViewport"]["_tag"]?.stringValue != "fill"
        }

        let zoomLevels: [Double] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0]
        let zoom = settingsSelect(zoomLevels.map { "\(Int(($0 * 100).rounded()))%" }, width: 160)
        zoom.setAccessibilityLabel("Default browser zoom")
        let zoomRow = row("browser-default-zoom", detail: "Page zoom applied to new browser tabs.", control: zoom)
        let zoomReset = ResetSlot(label: "default browser zoom")
        zoomRow.accessories = [zoomReset]
        zoomReset.action = { [weak self] in self?.context.writeClient?(["browserDefaultZoomFactor": .number(1)]) }
        zoom.onChange = { [weak self] i in self?.context.writeClient?(["browserDefaultZoomFactor": .number(zoomLevels[i])]) }
        binder.add { [weak self, weak zoom] in
            guard let self else { return }
            let value = self.client["browserDefaultZoomFactor"].doubleValue ?? 1
            zoom?.selectedIndex = zoomLevels.firstIndex(of: value)
            zoomReset.isShown = value != 1
        }

        let appearance = clientSelect("browser-default-appearance", "The color scheme pages are told to prefer. System follows your OS setting.",
                                      key: "browserDefaultAppearance", options: [("system", "System"), ("light", "Light"), ("dark", "Dark")],
                                      width: 160, reset: "default browser appearance")
        let rates: [Double] = [30, 60]
        let rate = settingsSelect(rates.map { "\(Int($0)) fps" }, width: 160)
        rate.setAccessibilityLabel("Browser recording frame rate")
        let rateRow = row("browser-recording-frame-rate", detail: "Maximum recording rate. 30 fps saves CPU and storage; 60 fps is smoother.", control: rate)
        let rateReset = ResetSlot(label: "browser recording frame rate")
        rateRow.accessories = [rateReset]
        rateReset.action = { [weak self] in self?.context.writeClient?(["browserRecordingFrameRate": .number(30)]) }
        rate.onChange = { [weak self] i in self?.context.writeClient?(["browserRecordingFrameRate": .number(rates[i])]) }
        binder.add { [weak self, weak rate] in
            guard let self else { return }
            let value = self.client["browserRecordingFrameRate"].doubleValue ?? 30
            rate?.selectedIndex = rates.firstIndex(of: value)
            rateReset.isShown = value != 30
        }
        let keys = clientSwitch("browser-recording-key-presses", "Show pressed keys and shortcuts in new recordings. Password fields are excluded.",
                                key: "browserRecordingShowKeyPresses", label: "Show key presses in recordings")
        let mouse = clientSwitch("browser-recording-mouse-presses", "Highlight mouse presses and held buttons in new recordings.",
                                 key: "browserRecordingShowMousePresses", label: "Show mouse presses in recordings")
        let links = clientSelect("browser-link-target",
                                 "Where links in the chat and terminal open. Hold ⌘ or Ctrl while clicking a link to open it in your default browser either way.",
                                 key: "browserLinkTarget", options: [("system", "Your default browser"), ("app", "T3 Code")], width: 160,
                                 reset: "link target", label: "Open links in")
        let floating = clientSwitch("browser-auto-show-floating-preview",
                                    "Show the floating preview when an agent opens a browser or device unless the agent says otherwise.",
                                    key: "browserAutoShowFloatingPreview", reset: "auto-show floating preview", label: "Auto-show floating preview")
        return section("browser", "Browser", [viewportRow, zoomRow, appearance, rateRow, keys, mouse, links, floating])
    }

    private func browserProfilesSection() -> SettingsSectionView {
        let add = ButtonView("New profile", icon: .plus, variant: .outline, size: .sm)
        add.action = { [weak self] in self?.editBrowserProfile(nil) }
        let addRow = row("browser-profiles", detail: "Separate cookies and logins for each browser profile.", control: add)
        addRow.title = "Browser profiles"
        let choose = settingsSelect(["Default"], width: 176)
        choose.onChange = { [weak self] i in
            guard let self else { return }
            let profiles = BrowserProfiles.resolved(client).filter { $0["id"]?.stringValue != "incognito" }
            guard profiles.indices.contains(i) else { return }
            context.writeClient?(["browserDefaultProfileId": profiles[i]["id"] ?? .string("default")])
        }
        let defaultRow = row("browser-default-profile", detail: "Used for new browser tabs.", control: choose); defaultRow.title = "Default profile"
        let manage = ButtonView("Manage profiles", variant: .outline, size: .sm)
        manage.action = { [weak self, weak manage] in
            guard let self, let manage else { return }
            let items = BrowserProfiles.resolved(client).filter { $0["id"]?.stringValue != "incognito" }.map { profile -> MenuItem in
                var clear = MenuItem("Clear browsing data")
                clear.action = { [weak self] in self?.clearBrowserProfile(profile, remove: false) }
                var children = [clear]
                if profile["id"]?.stringValue != "default" {
                    var rename = MenuItem("Rename"); rename.action = { [weak self] in self?.editBrowserProfile(profile) }
                    var remove = MenuItem("Remove"); remove.action = { [weak self] in self?.clearBrowserProfile(profile, remove: true) }
                    children += [rename, remove]
                }
                return .submenu(profile["name"]?.stringValue ?? "Profile", children)
            }
            MenuPopupView.show(items, from: manage, placement: .dropdown)
        }
        let manageRow = row("browser-manage-profiles", control: manage); manageRow.title = "Saved profiles"
        binder.add { [weak self, weak choose, weak add] in
            guard let self else { return }
            let profiles = BrowserProfiles.resolved(client).filter { $0["id"]?.stringValue != "incognito" }
            choose?.options = profiles.map { $0["name"]?.stringValue ?? "Profile" }
            choose?.selectedIndex = profiles.firstIndex { $0["id"]?.stringValue == BrowserProfiles.defaultId(client) }
            add?.isEnabled = profiles.count < 25
        }
        return section("browser-profiles", "Browser profiles", [addRow, defaultRow, manageRow])
    }
    private func editBrowserProfile(_ profile: JSONValue?) {
        let dialog = DialogView(title: profile == nil ? "New profile" : "Rename profile")
        let name = InputView(placeholder: "Profile name", text: profile?["name"]?.stringValue ?? "")
        let save = ButtonView("Save"), cancel = ButtonView("Cancel", variant: .ghost)
        dialog.panelContent = [name]; dialog.footerButtons = [cancel, save]
        let modal = context.presentDialog?(dialog)
        cancel.action = { [weak modal] in modal?.close() }
        save.action = { [weak self, weak modal, weak name] in
            guard let self else { return }
            let label = String((name?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
            guard !label.isEmpty else { return }
            var profiles = BrowserProfiles.resolved(client).dropFirst(2).map { $0 }
            let id = profile?["id"]?.stringValue ?? "profile-" + UUID().uuidString.lowercased()
            let next = BrowserProfiles.profile(id, label)
            if let index = profiles.firstIndex(where: { $0["id"]?.stringValue == id }) { profiles[index] = next }
            else { guard profiles.count < 24 else { return }; profiles.append(next) }
            context.writeClient?(["browserProfiles": .array(profiles)]); refresh(); modal?.close()
        }
    }
    private func clearBrowserProfile(_ profile: JSONValue, remove: Bool) {
        guard let id = profile["id"]?.stringValue, let request = context.request else { return }
        context.confirm?(remove ? "Remove this profile and its browsing data?" : "Clear this profile's browsing data?", true) { [weak self] in
            guard let self else { return }
            let targets = context.scope.targets
            Task { [weak self] in
                guard let self else { return }
                do {
                    for target in targets { _ = try await request(target.environmentId, "preview.clearProfile", .object(["profileId": .string(id)])) }
                    if remove {
                        let profiles = BrowserProfiles.resolved(client).dropFirst(2).filter { $0["id"]?.stringValue != id }
                        var patch: [String: JSONValue] = ["browserProfiles": .array(profiles)]
                        if BrowserProfiles.defaultId(client) == id { patch["browserDefaultProfileId"] = .string("default") }
                        context.writeClient?(patch); refresh()
                    }
                } catch { context.toast?("Unable to clear browser profile", String(describing: error), .error) }
            }
        }
    }

    // MARK: Devices

    /// The device hub and agent device access (`DeviceIntegrationControls`). Outside a project scope T3 turns
    /// them on through `device.configure`, which installs the device helpers on the server.
    private func devicesSection() -> SettingsSectionView {
        let hub = serverSwitch("device-hub", "Enable this environment to open simulators and emulators, whether they run here or on a remote device host.",
                               key: "enableDeviceSupport", reset: nil, label: "Device hub")
        hub.accessories.last.map { ($0 as? ResetSlot)?.isShown = false }
        (hub.control as? SwitchView)?.onChange = { [weak self] value in
            self?.configureDevice(value ? ["enabled": .bool(true)] : ["enabled": .bool(false), "agentAccessEnabled": .bool(false)])
        }
        let agent = serverSwitch("agent-device-access",
                                 "Allow new agent sessions in this environment to start and control local and remote devices, with required tools set up automatically.",
                                 key: "enableAgentDeviceAccess", reset: nil, label: "Agent device access")
        let projectAgentChange = (agent.control as? SwitchView)?.onChange
        (agent.control as? SwitchView)?.onChange = { [weak self] value in
            guard let self else { return }
            if self.context.scope.isProjectScope { projectAgentChange?(value) }
            else { self.configureDevice(["agentAccessEnabled": .bool(value)]) }
        }
        binder.add { [weak self, weak agent, weak hub] in
            guard let self else { return }
            // Outside a project, agent access writes through `device.configure` too.
            (agent?.control as? SwitchView)?.isEnabled = self.context.scope.canWrite
            (hub?.control as? SwitchView)?.isEnabled = self.context.scope.canWrite && !self.context.scope.isProjectScope
        }
        let addHost = ButtonView("Add host", icon: .plus, variant: .outline, size: .sm)
        addHost.action = { [weak self] in self?.editDeviceHost(nil) }
        let hostRow = row("device-hosts", detail: "Add remote machines with simulator or emulator runtimes installed, and the selected environments will connect over SSH and set up device tools automatically.", control: addHost)
        hostRow.title = "Device hosts"
        let manage = ButtonView("Manage hosts", variant: .outline, size: .sm)
        manage.action = { [weak self, weak manage] in
            guard let self, let manage else { return }
            let hosts = self.context.scope.targets.first?.settings["deviceHosts"].arrayValue ?? []
            let items: [MenuItem] = hosts.map { host in
                var edit = MenuItem("Edit"); edit.action = { [weak self] in self?.editDeviceHost(host) }
                var remove = MenuItem("Remove"); remove.action = { [weak self] in self?.removeDeviceHost(host) }
                return .submenu(host["label"]?.stringValue ?? "Host", [edit, remove])
            }
            MenuPopupView.show(items.isEmpty ? [MenuItem("No remote device hosts")] : items, from: manage, placement: .dropdown)
        }
        let manageRow = row("device-hosts-manage", detail: "SSH aliases and identity files are resolved on each environment.", control: manage)
        manageRow.title = "Remote device hosts"
        binder.add { [weak self, weak addHost, weak manage] in
            guard let self else { return }
            let enabled = self.context.scope.canWrite && !self.context.scope.isProjectScope
            addHost?.isEnabled = enabled; manage?.isEnabled = enabled
        }
        let inspect = ButtonView("Check devices", variant: .outline, size: .sm)
        inspect.action = { [weak self] in self?.showDeviceInventory() }
        let inventoryRow = row("device-inventory", detail: "Check simulator support and installed device tools on each environment.", control: inspect)
        inventoryRow.title = "Device support"
        let s = section("devices", "Devices", [hub, agent, hostRow, manageRow, inventoryRow])
        return s
    }
    private func showDeviceInventory() {
        guard let request = context.request else { return }
        let dialog = DialogView(title: "Device support", message: "Checking devices…")
        guard let modal = context.presentDialog?(dialog) else { return }
        let previous = modal.onDismiss
        modal.onDismiss = { [weak self] in self?.deviceInventoryTask?.cancel(); self?.deviceInventoryTask = nil; previous?() }
        let targets = context.scope.targets
        deviceInventoryTask?.cancel()
        deviceInventoryTask = Task { [weak self, weak dialog] in
            var content: [NSView] = []
            for target in targets {
                do {
                    let reply = try await request(target.environmentId, "device.list", .object(["inspectOnly": .bool(true)]))
                    guard let self, let dialog, !Task.isCancelled else { return }
                    let state = try JSONValueDecoder().decode(DevicePanelState.self, from: reply)
                    content.append(LabelView(target.label, font: DSFont.ui(14, weight: .medium)))
                    if state.hosts.isEmpty {
                        content.append(TextBlockView(state.hostStatusDetail ?? "No simulators or emulators were found on this environment.", font: DSFont.ui(12), color: Themed.color(\.mutedForeground)))
                    }
                    for host in state.hosts {
                        let row = DeviceHostStatusView(host: host, state: state)
                        row.onRequest = { [weak self] payload in
                            guard let self, self.context.scope.canWrite, !self.context.scope.isProjectScope else { return }
                            self.deviceInventoryTask?.cancel()
                            self.deviceInventoryTask = Task { [weak self, weak dialog] in
                                do {
                                    _ = try await request(target.environmentId, "device.list", .object(payload))
                                    guard !Task.isCancelled else { return }
                                    dialog?.message = "Device tools updated. Close and check devices again to refresh the inventory."
                                } catch { if !Task.isCancelled { self?.context.toast?("Unable to configure devices", String(describing: error), .error) } }
                            }
                        }
                        content.append(row)
                    }
                    for device in state.devices {
                        content.append(LabelView("\(device.name) · \(device.version) · \(device.booted ? "Running" : "Stopped")", font: DSFont.ui(12)))
                    }
                    dialog.message = nil; dialog.panelContent = content
                } catch {
                    guard !Task.isCancelled else { return }
                    content.append(LabelView(target.label + ": " + String(describing: error), font: DSFont.ui(12)))
                    dialog?.message = nil; dialog?.panelContent = content
                }
            }
        }
    }
    private func editDeviceHost(_ host: JSONValue?) {
        deviceHostEditor = DeviceHostEditor(context: context, original: host)
        deviceHostEditor?.present()
    }
    private func removeDeviceHost(_ host: JSONValue) {
        guard context.scope.canWrite, !context.scope.isProjectScope, let request = context.request else { return }
        let targets = context.scope.targets
        Task { [weak self] in
            guard let self else { return }
            for target in targets {
                do {
                    let current = self.context.scope.targets.first { $0.environmentId == target.environmentId }?.settings["deviceHosts"].arrayValue ?? []
                    let next = try DeviceHostEditing.update(current, host: host, original: host, remove: true)
                    let result = try await request(target.environmentId, "server.updateSettings", .object(["patch": .object(["deviceHosts": .array(next)])]))
                    context.applySettings?(target.environmentId, result)
                } catch { context.toast?("Device hosts not saved on all environments", String(describing: error), .error) }
            }
        }
    }
    private func configureDevice(_ patch: [String: JSONValue]) {
        guard context.scope.canWrite, let request = context.request else { return }
        let targets = context.scope.targets
        Task { [weak self] in
            do {
                for target in targets { _ = try await request(target.environmentId, "device.configure", .object(patch)) }
                self?.refresh()
            } catch {
                self?.context.toast?("Unable to configure devices", String(describing: error), .error)
                self?.refresh()
            }
        }
    }

}
