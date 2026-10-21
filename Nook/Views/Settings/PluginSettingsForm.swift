import AppKit
import SwiftUI

/// Auto-generated settings form for a plugin, plus code-level customisation (Edit code / Revert).
struct PluginSettingsForm: View {
    let tab: TabItem
    var compact = false
    var grouped = false
    @State private var confirmingRevert = false
    var onDone: (() -> Void)?
    @State private var values: [String: JSONValue]
    @State private var valuesLoaded = false
    @State private var working = false
    @State private var actionError: String?
    @ObservedObject private var plugins = Services.shared.plugins

    init(tab: TabItem, compact: Bool = false, grouped: Bool = false, onDone: (() -> Void)? = nil) {
        self.tab = tab
        self.compact = compact
        self.grouped = grouped
        self.onDone = onDone
        _values = State(initialValue: [:])
    }

    var body: some View {
        Group {
            if grouped {
                Section("Appearance") { heightControl }
                if !tab.settings.isEmpty {
                    Section("Plugin Options") {
                        if !valuesLoaded { ProgressView("Loading options…").controlSize(.small) }
                        settingControls.disabled(!valuesLoaded)
                    }
                }
                if tab.isWeb || !tab.settings.isEmpty {
                    Section {
                        actions
                    } header: {
                        Text("Customization")
                    } footer: {
                        if tab.isWeb {
                            Text("Edit code to customize this plugin. Reverting moves your custom copy to the Trash; saved settings are kept.")
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                    heightControl
                    if tab.settings.isEmpty, tab.isWeb {
                        Text("No additional options. Edit the plugin’s code to customize it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    settingControls.disabled(!valuesLoaded)
                    actions
                }
                .font(.system(size: compact ? 12 : 13))
                .tint(.orange)
            }
        }
        .task(id: tab.id) {
            guard !tab.settings.isEmpty else { valuesLoaded = true; return }
            let snapshot = await Task.detached(priority: .utility) { PluginSettingsStore.values(for: tab) }.value
            guard !Task.isCancelled else { return }
            values = snapshot
            valuesLoaded = true
        }
        .confirmationDialog("Revert \(tab.name) to the built-in plugin?", isPresented: $confirmingRevert) {
            Button("Move Custom Copy to Trash", role: .destructive) {
                perform { await SettingsPluginActions.revert(tab) }
            }
        } message: {
            Text("Your edited plugin folder will move to the Trash. Saved settings will be kept.")
        }
    }

    private var settingControls: some View {
        ForEach(tab.settings) { setting in
            VStack(alignment: .leading, spacing: 5) {
                if [.text, .secret, .textarea, .number].contains(setting.type), !(setting.type == .number && setting.min != nil && setting.max != nil) {
                    Text(setting.label).font(.callout).foregroundStyle(.secondary)
                }
                control(for: setting).accessibilityLabel(setting.label)
                if let help = setting.help {
                    Text(help).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, grouped ? 3 : 0)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { codeActions; Spacer(minLength: 0); resetAction; doneAction }
                VStack(alignment: .leading, spacing: 12) { codeActions; resetAction; doneAction }
            }
            .disabled(working)
            if working { ProgressView("Updating plugin…").controlSize(.small) }
            if let actionError {
                Text(actionError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(compact ? .small : .regular)
    }

    @ViewBuilder private var codeActions: some View {
        if tab.isWeb {
            Button(plugins.isBundled(tab) ? "Edit Code…" : "Show Code") {
                perform { await SettingsPluginActions.customize(tab) }
            }
                .help(plugins.isBundled(tab) ? "Copy this plugin into your Plugins folder and reveal it in Finder" : "Open the plugin folder")
            if plugins.overridesBundled(tab) {
                Button("Revert to Built-in…") { confirmingRevert = true }
            }
        }
    }

    @MainActor private func perform(_ action: @escaping () async -> String?) {
        working = true
        actionError = nil
        Task { actionError = await action(); working = false }
    }

    @ViewBuilder private var resetAction: some View {
        if !tab.settings.isEmpty {
            Button("Reset Options") {
                PluginSettingsStore.reset(tab)
                values = PluginSettingsStore.values(for: tab)
            }
            .disabled(!valuesLoaded)
        }
    }

    @ViewBuilder private var doneAction: some View {
        if let onDone { Button("Done", action: onDone).keyboardShortcut(.defaultAction) }
    }

    /// Every tab: how tall the notch opens for it. Live while dragging.
    private var heightControl: some View {
        let height = Binding<Double>(
            get: { Double(plugins.height(for: tab)) },
            set: { plugins.setHeight(tab.id, CGFloat($0)) }
        )
        return LabeledContent("Height") {
            HStack(spacing: 8) {
                Slider(value: height, in: Double(PluginRegistry.minHeight)...Double(PluginRegistry.maxHeight), step: 10)
                    .accessibilityLabel("Tab height")
                Text("\(Int(height.wrappedValue)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
                if plugins.userHeights[tab.id] != nil {
                    Button("Default") { plugins.setHeight(tab.id, nil) }.buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private func binding(_ setting: PluginSetting) -> Binding<JSONValue> {
        Binding(
            get: { values[setting.key] ?? setting.fallback },
            set: { value in
                values[setting.key] = value
                PluginSettingsStore.set(tab, setting.key, value)
            }
        )
    }

    @ViewBuilder
    private func control(for s: PluginSetting) -> some View {
        let value = binding(s)
        switch s.type {
        case .shortcut:
            PluginShortcutSetting(pluginID: tab.id, key: s.key, title: s.label, value: Binding(get: { value.wrappedValue.string }, set: { value.wrappedValue = .string($0) }))
        case .toggle:
            Toggle(s.label, isOn: Binding(get: { value.wrappedValue.bool }, set: { value.wrappedValue = .bool($0) }))
        case .select:
            Picker(s.label, selection: Binding(get: { value.wrappedValue.string }, set: { value.wrappedValue = .string($0) })) {
                ForEach(s.options ?? [], id: \.self) { Text($0).tag($0) }
            }
        case .number where s.min != nil && s.max != nil:
            LabeledContent(s.label) {
                HStack {
                    Slider(value: Binding(get: { value.wrappedValue.number }, set: { value.wrappedValue = .number($0) }),
                           in: s.min!...s.max!, step: s.step ?? 1)
                    Text(value.wrappedValue.string).monospacedDigit().frame(width: 38, alignment: .trailing)
                }
            }
        case .number:
            TextField("", value: Binding(get: { value.wrappedValue.number }, set: { value.wrappedValue = .number($0) }), format: .number)
                .labelsHidden()
        case .color:
            ColorPicker(s.label, selection: Binding(
                get: { Color(css: value.wrappedValue.string) },
                set: { value.wrappedValue = .string(NSColor($0).usingColorSpace(.sRGB).map { String(format: "#%02x%02x%02x", Int($0.redComponent * 255), Int($0.greenComponent * 255), Int($0.blueComponent * 255)) } ?? "#ffffff") }
            ), supportsOpacity: false)
        case .secret:
            SecureField("", text: Binding(get: { value.wrappedValue.string }, set: { value.wrappedValue = .string($0) }))
        case .textarea:
            TextField("", text: Binding(get: { value.wrappedValue.string }, set: { value.wrappedValue = .string($0) }), axis: .vertical)
                .lineLimit(2...5)
        case .text:
            TextField("", text: Binding(get: { value.wrappedValue.string }, set: { value.wrappedValue = .string($0) }))
        }
    }
}
