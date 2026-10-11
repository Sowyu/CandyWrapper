import AppKit
import DesignSystem
import T3Protocol

/// Settings > Integrations (IntegrationsSettings.tsx, ProjectDefaultsSettings.tsx with `category="integrations"`):
/// agent browser access, the browser defaults this device keeps, and the device hub rows.
public final class IntegrationsSettingsView: ScopedSettingsPage {
    public init(context: SettingsPageContext) {
        super.init(context: context)
        body = [browserAccessSection(), browserSection(), devicesSection()]
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

    // ponytail: these rows store T3's client settings; the built-in browser that reads them comes with WP7.6b.
    // Browser profiles (create, rename, import, clear) and custom viewport sizes are not drawn yet
    private func browserSection() -> SettingsSectionView {
        let viewport = settingsSelect(["Fill panel", "Responsive"], width: 176)
        viewport.setAccessibilityLabel("Default browser viewport")
        let viewportRow = row("browser-default-viewport", detail: "Tab size for you and agents. Fill fits the panel; other sizes show the device toolbar.",
                              control: viewport)
        let viewportReset = ResetSlot(label: "default browser viewport")
        viewportRow.accessories = [viewportReset]
        viewportReset.action = { [weak self] in self?.context.writeClient?(["browserDefaultViewport": .object(["_tag": .string("fill")])]) }
        viewport.onChange = { [weak self] i in
            self?.context.writeClient?(["browserDefaultViewport": i == 0 ? .object(["_tag": .string("fill")])
                : .object(["_tag": .string("freeform"), "width": .number(1280), "height": .number(800)])])
        }
        binder.add { [weak self, weak viewport] in
            guard let self else { return }
            let fill = self.client["browserDefaultViewport"]["_tag"]?.stringValue == "fill"
            viewport?.selectedIndex = fill ? 0 : 1
            viewportReset.isShown = !fill
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
        let s = section("devices", "Devices", [hub, agent])
        return s
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
