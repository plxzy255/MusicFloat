import OSLog
import SwiftUI
#if ENABLE_APPLE_TRANSLATION
@preconcurrency @unsafe import Translation
#endif

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
    #if ENABLE_APPLE_TRANSLATION
    @State private var preparationConfiguration: TranslationSession.Configuration?
    #endif

    var body: some View {
        #if ENABLE_APPLE_TRANSLATION
        settingsForm
            .translationTask(preparationConfiguration) { session in
                let document = appState.lyricsDocument
                let targetLanguageIdentifier = appState.preferredTranslationLanguageIdentifier
                let activeTrackID = appState.playerState.track?.id
                do {
                    try await session.prepareTranslation()
                    preparationConfiguration = nil
                    AppTelemetry.settings.info("Translation preparation completed")

                    appState.setTranslationRuntimeState(.translating)
                    if let translation = try await PreparedTranslationSessionTranslator.translation(
                        using: session,
                        for: document,
                        targetLanguageIdentifier: targetLanguageIdentifier
                    ) {
                        guard appState.playerState.track?.id == activeTrackID,
                              appState.lyricsDocument.hasSameTranslationContent(as: document),
                              appState.preferredTranslationLanguageIdentifier == targetLanguageIdentifier else {
                            AppTelemetry.settings.info("Prepared translation ignored because live context changed")
                            appState.setTranslationRuntimeState(.idle)
                            onTranslationPreparationCompleted()
                            return
                        }
                        appState.applyTranslation(translation)
                        appState.setTranslationRuntimeState(.ready)
                        AppTelemetry.settings.info("Prepared translation completed")
                        return
                    }

                    appState.setTranslationRuntimeState(.idle)
                    onTranslationPreparationCompleted()
                } catch is CancellationError {
                    preparationConfiguration = nil
                    appState.setTranslationRuntimeState(.idle)
                    AppTelemetry.settings.info("Translation preparation cancelled")
                } catch {
                    preparationConfiguration = nil
                    let reason = Self.translationFailureMessage(
                        prefix: "Translation preparation failed",
                        error: error
                    )
                    appState.setTranslationRuntimeState(.failed(reason))
                    AppTelemetry.settings.error("Translation preparation failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        #else
        settingsForm
        #endif
    }

    private var settingsForm: some View {
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

                LabeledContent("Provider", value: appState.runtimeFeatureFlags.translationProviderMode.translationProviderDisplayName)
                LabeledContent("Target", value: appState.preferredTranslationLanguageName)
                LabeledContent("Source", value: appState.lyricsSourceLanguageName)
                LabeledContent("Status", value: appState.translationRuntimeState.detailText)

                #if ENABLE_APPLE_TRANSLATION
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
                #endif
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
            Task {
                await loadTranslationLanguageOptions()
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

    private func loadTranslationLanguageOptions() async {
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

    private static func localizedLanguageName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private static func translationFailureMessage(prefix: String, error: any Error) -> String {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else {
            return prefix
        }
        return "\(prefix): \(detail)"
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
        #if ENABLE_APPLE_TRANSLATION
        await Task.detached {
            await LanguageAvailability(preferredStrategy: .lowLatency).supportedLanguages
        }.value
        #else
        []
        #endif
    }
}

#Preview {
    SettingsView(appState: AppState())
}
