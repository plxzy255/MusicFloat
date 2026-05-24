import OSLog
import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState
    @AppStorage("showTranslation") private var showsTranslation = true
    @AppStorage("preferredTranslationLanguage") private var preferredTranslationLanguage = "French"
    @AppStorage("overlayWidthPreset") private var overlayWidthPresetRaw = OverlayWidthPreset.medium.rawValue
    @AppStorage("reduceHiddenMemoryUsage") private var reduceHiddenMemoryUsage = true

    var body: some View {
        Form {
            Section("Overlay") {
                Toggle("Show translation", isOn: $showsTranslation)

                Picker("Width", selection: $overlayWidthPresetRaw) {
                    ForEach(OverlayWidthPreset.allCases) { preset in
                        Text(preset.displayName)
                            .tag(preset.rawValue)
                    }
                }
            }

            Section("Translation") {
                TextField("Preferred language", text: $preferredTranslationLanguage)
            }

            Section("Runtime") {
                Toggle("Reduce hidden memory use", isOn: $reduceHiddenMemoryUsage)
                LabeledContent("Player bridge", value: appState.runtimeFeatureFlags.playerBridgeMode.displayName)
                LabeledContent("Lyrics provider", value: appState.runtimeFeatureFlags.lyricsProviderMode.displayName)
                LabeledContent("Translation provider", value: appState.runtimeFeatureFlags.translationProviderMode.displayName)
                LabeledContent("Hidden refresh", value: appState.runtimeFeatureFlags.allowsHiddenProviderRefresh ? "Enabled" : "Disabled")
                LabeledContent("Provider state", value: appState.providerRuntimeState.displayName)
                LabeledContent("Cache", value: "Ephemeral placeholder")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 420)
        .onAppear {
            AppTelemetry.settings.info("Settings view appeared")
            syncPreferencesToAppState()
        }
        .onChange(of: showsTranslation) {
            syncPreferencesToAppState()
        }
        .onChange(of: preferredTranslationLanguage) {
            syncPreferencesToAppState()
        }
        .onChange(of: overlayWidthPresetRaw) {
            syncPreferencesToAppState()
        }
        .onChange(of: reduceHiddenMemoryUsage) {
            syncPreferencesToAppState()
        }
    }

    private func syncPreferencesToAppState() {
        let widthPreset = OverlayWidthPreset(rawValue: overlayWidthPresetRaw) ?? .medium
        appState.applyPreferences(
            showsTranslation: showsTranslation,
            preferredTranslationLanguage: preferredTranslationLanguage,
            overlayWidthPreset: widthPreset,
            reduceHiddenMemoryUsage: reduceHiddenMemoryUsage
        )
    }
}

#Preview {
    SettingsView(appState: AppState())
}
