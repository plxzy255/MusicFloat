import OSLog
import SwiftUI
@preconcurrency @unsafe import Translation

struct SettingsView: View {
    @Bindable var appState: AppState
    var onTranslationPreferencesChanged: () -> Void = {}
    var onTranslationPreparationCompleted: () -> Void = {}

    @AppStorage("showTranslation") private var showsTranslation = true
    @AppStorage("preferredTranslationLanguageIdentifier") private var preferredTranslationLanguageIdentifier = AppState.systemLanguageIdentifier
    @AppStorage("overlayWidthPreset") private var overlayWidthPresetRaw = OverlayWidthPreset.medium.rawValue
    @AppStorage("reduceHiddenMemoryUsage") private var reduceHiddenMemoryUsage = true
    @AppStorage("lrclibFallbackEnabled") private var lrclibFallbackEnabled = true
    @State private var mediaUserTokenInput: String = ""
    @State private var mediaUserTokenSavedHint: String = ""
    @State private var supportedTranslationLanguages: [Locale.Language] = []
    @State private var preparationConfiguration: TranslationSession.Configuration?

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
                Picker("Target language", selection: $preferredTranslationLanguageIdentifier) {
                    ForEach(translationLanguageOptions, id: \.minimalIdentifier) { language in
                        Text(Self.localizedLanguageName(for: language.minimalIdentifier))
                            .tag(language.minimalIdentifier)
                    }
                }

                LabeledContent("Provider", value: "Apple on-device")
                LabeledContent("Target", value: appState.preferredTranslationLanguageName)
                LabeledContent("Source", value: appState.lyricsSourceLanguageName)
                LabeledContent("Status", value: appState.translationRuntimeState.detailText)

                if let download = appState.pendingTranslationDownload {
                    Button("Prepare Translation Languages") {
                        preparationConfiguration = TranslationSession.Configuration(
                            source: Locale.Language(identifier: download.source),
                            target: Locale.Language(identifier: download.target),
                            preferredStrategy: .lowLatency
                        )
                        AppTelemetry.settings.info("Translation preparation requested")
                    }
                }
            }

            Section("Runtime") {
                Toggle("Reduce hidden memory use", isOn: $reduceHiddenMemoryUsage)
                LabeledContent("Player bridge", value: appState.runtimeFeatureFlags.playerBridgeMode.displayName)
                LabeledContent("Lyrics provider", value: appState.runtimeFeatureFlags.lyricsProviderMode.displayName)
                LabeledContent("Translation provider", value: appState.runtimeFeatureFlags.translationProviderMode.displayName)
                LabeledContent("Hidden refresh", value: appState.runtimeFeatureFlags.allowsHiddenProviderRefresh ? "Enabled" : "Disabled")
                LabeledContent("Provider state", value: appState.providerRuntimeState.displayName)
                LabeledContent("Translation state", value: appState.translationRuntimeState.displayName)
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
        .task {
            let languages = await Self.loadSupportedTranslationLanguages()
            supportedTranslationLanguages = languages.sorted {
                Self.localizedLanguageName(for: $0.minimalIdentifier) < Self.localizedLanguageName(for: $1.minimalIdentifier)
            }
            if !supportedTranslationLanguages.isEmpty,
               !Self.languageList(supportedTranslationLanguages, containsIdentifier: preferredTranslationLanguageIdentifier) {
                preferredTranslationLanguageIdentifier = Self.defaultSupportedTargetLanguageIdentifier(
                    from: supportedTranslationLanguages
                )
                syncPreferencesToAppState()
            }
        }
        .translationTask(preparationConfiguration) { session in
            do {
                try await session.prepareTranslation()
                preparationConfiguration = nil
                appState.setTranslationRuntimeState(.idle)
                onTranslationPreparationCompleted()
                AppTelemetry.settings.info("Translation preparation completed")
            } catch {
                preparationConfiguration = nil
                appState.setTranslationRuntimeState(.failed("Translation preparation failed"))
                AppTelemetry.settings.info("Translation preparation failed")
            }
        }
        .onChange(of: showsTranslation) {
            syncPreferencesToAppState()
        }
        .onChange(of: preferredTranslationLanguageIdentifier) {
            syncPreferencesToAppState()
        }
        .onChange(of: overlayWidthPresetRaw) {
            syncPreferencesToAppState()
        }
        .onChange(of: reduceHiddenMemoryUsage) {
            syncPreferencesToAppState()
        }
    }

    private var translationLanguageOptions: [Locale.Language] {
        let current = Locale.Language(identifier: preferredTranslationLanguageIdentifier)
        guard !supportedTranslationLanguages.isEmpty else {
            return [current]
        }
        if supportedTranslationLanguages.contains(where: { $0.minimalIdentifier == current.minimalIdentifier }) {
            return supportedTranslationLanguages
        }
        return ([current] + supportedTranslationLanguages).sorted {
            Self.localizedLanguageName(for: $0.minimalIdentifier) < Self.localizedLanguageName(for: $1.minimalIdentifier)
        }
    }

    private func syncPreferencesToAppState() {
        let widthPreset = OverlayWidthPreset(rawValue: overlayWidthPresetRaw) ?? .medium
        let translationPreferencesChanged = appState.applyPreferences(
            showsTranslation: showsTranslation,
            preferredTranslationLanguageIdentifier: preferredTranslationLanguageIdentifier,
            overlayWidthPreset: widthPreset,
            reduceHiddenMemoryUsage: reduceHiddenMemoryUsage
        )
        if translationPreferencesChanged {
            onTranslationPreferencesChanged()
        }
    }

    private static func localizedLanguageName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private static func languageList(
        _ languages: [Locale.Language],
        containsIdentifier identifier: String
    ) -> Bool {
        guard let normalized = LyricsDocument.normalizedLanguageIdentifier(identifier) else {
            return false
        }
        return languages.contains { $0.minimalIdentifier == normalized }
    }

    private static func defaultSupportedTargetLanguageIdentifier(
        from languages: [Locale.Language]
    ) -> String {
        if languageList(languages, containsIdentifier: AppState.systemLanguageIdentifier) {
            return AppState.systemLanguageIdentifier
        }
        return languages.first?.minimalIdentifier ?? AppState.systemLanguageIdentifier
    }

    nonisolated private static func loadSupportedTranslationLanguages() async -> [Locale.Language] {
        await Task.detached {
            await LanguageAvailability(preferredStrategy: .lowLatency).supportedLanguages
        }.value
    }
}

#Preview {
    SettingsView(appState: AppState())
}
