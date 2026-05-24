import OSLog
import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState
    @AppStorage("showTranslation") private var showsTranslation = true
    @AppStorage("preferredTranslationLanguage") private var preferredTranslationLanguage = "French"
    @AppStorage("overlayWidthPreset") private var overlayWidthPresetRaw = OverlayWidthPreset.medium.rawValue
    @AppStorage("reduceHiddenMemoryUsage") private var reduceHiddenMemoryUsage = true
    @AppStorage("lrclibFallbackEnabled") private var lrclibFallbackEnabled = true
    @State private var mediaUserTokenInput: String = ""
    @State private var mediaUserTokenSavedHint: String = ""

    var body: some View {
        Form {
            Section("Apple Music") {
                if MediaUserTokenStore.isConfigured {
                    LabeledContent("media-user-token", value: "Configured")
                } else {
                    LabeledContent("media-user-token", value: "Not configured")
                        .foregroundStyle(.secondary)
                }
                SecureField("Paste media-user-token", text: $mediaUserTokenInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") {
                        MediaUserTokenStore.save(mediaUserTokenInput)
                        mediaUserTokenInput = ""
                        mediaUserTokenSavedHint = MediaUserTokenStore.isConfigured ? "Saved." : "Cleared."
                        AppTelemetry.settings.info("media-user-token saved configured=\(MediaUserTokenStore.isConfigured)")
                    }
                    .disabled(mediaUserTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Clear") {
                        MediaUserTokenStore.clear()
                        mediaUserTokenInput = ""
                        mediaUserTokenSavedHint = "Cleared."
                        AppTelemetry.settings.info("media-user-token cleared")
                    }
                    .disabled(!MediaUserTokenStore.isConfigured)
                    Spacer()
                    if !mediaUserTokenSavedHint.isEmpty {
                        Text(mediaUserTokenSavedHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Sign in at music.apple.com, copy the `media-user-token` cookie value from your browser's devtools, paste it here. Required to fetch the same timed lyrics Music.app uses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Allow LRCLIB / Music app UI fallback", isOn: $lrclibFallbackEnabled)
                Text("When Apple has no lyrics for a track, fall back to LRCLIB and the Music.app lyrics panel. Disable to pin lyrics to Apple's data only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
