import Foundation

enum PromptProvider: String, CaseIterable {
    case gemini
    case openAI
    case openRouter

    var displayName: String {
        switch self {
        case .gemini:
            return "Gemini"
        case .openAI:
            return "OpenAI"
        case .openRouter:
            return "OpenRouter"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .gemini:
            return "https://generativelanguage.googleapis.com/v1beta"
        case .openAI:
            return "https://api.openai.com/v1"
        case .openRouter:
            return "https://openrouter.ai/api/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .gemini:
            return "gemini-2.5-flash-lite"
        case .openAI:
            return "gpt-4.1-mini"
        case .openRouter:
            return "google/gemini-2.5-flash-lite"
        }
    }
}

struct PromptGenerationSettings {
    var provider: PromptProvider
    var baseURL: String
    var model: String
    var apiKey: String
    var promptTemplate: String
}

struct PromptProviderConfiguration {
    var baseURL: String
    var model: String
    var apiKey: String

    static func `default`(for provider: PromptProvider, apiKey: String = "") -> PromptProviderConfiguration {
        PromptProviderConfiguration(
            baseURL: provider.defaultBaseURL,
            model: provider.defaultModel,
            apiKey: apiKey
        )
    }
}

final class PromptSettingsStore {
    static let defaultPromptTemplate = """
    Take this screenshot of an application UI and convert it into a complete text-only prompt for another coding agent. Preserve the user’s requested changes, the visible context, the relevant layout details, and anything implied by the annotations. The final output should be only the prompt text, written so another agent can understand exactly what to change without seeing the screenshot.
    """

    private enum DefaultsKey {
        static let currentProvider = "promptSettings.currentProvider"
        static let promptTemplate = "promptSettings.promptTemplate"

        static func baseURL(for provider: PromptProvider) -> String {
            "promptSettings.\(provider.rawValue).baseURL"
        }

        static func model(for provider: PromptProvider) -> String {
            "promptSettings.\(provider.rawValue).model"
        }
    }

    private let userDefaults: UserDefaults
    private let keychainService: KeychainService

    init(
        userDefaults: UserDefaults = .standard,
        keychainService: KeychainService = KeychainService(service: "com.quickeye.prompt-settings")
    ) {
        self.userDefaults = userDefaults
        self.keychainService = keychainService
    }

    func currentSettings() -> PromptGenerationSettings {
        let provider = currentProvider()
        let configuration = configuration(for: provider)
        return PromptGenerationSettings(
            provider: provider,
            baseURL: configuration.baseURL,
            model: configuration.model,
            apiKey: configuration.apiKey,
            promptTemplate: promptTemplate()
        )
    }

    func currentProvider() -> PromptProvider {
        guard let rawValue = userDefaults.string(forKey: DefaultsKey.currentProvider),
              let provider = PromptProvider(rawValue: rawValue) else {
            return .gemini
        }

        return provider
    }

    func configuration(for provider: PromptProvider) -> PromptProviderConfiguration {
        let baseURL = userDefaults.string(forKey: DefaultsKey.baseURL(for: provider)) ?? provider.defaultBaseURL
        let model = userDefaults.string(forKey: DefaultsKey.model(for: provider)) ?? provider.defaultModel
        let apiKey = keychainService.string(forAccount: keychainAccount(for: provider)) ?? ""
        return PromptProviderConfiguration(baseURL: baseURL, model: model, apiKey: apiKey)
    }

    func promptTemplate() -> String {
        userDefaults.string(forKey: DefaultsKey.promptTemplate) ?? Self.defaultPromptTemplate
    }

    func save(
        provider: PromptProvider,
        configuration: PromptProviderConfiguration,
        promptTemplate: String
    ) throws {
        userDefaults.set(provider.rawValue, forKey: DefaultsKey.currentProvider)
        userDefaults.set(configuration.baseURL, forKey: DefaultsKey.baseURL(for: provider))
        userDefaults.set(configuration.model, forKey: DefaultsKey.model(for: provider))
        userDefaults.set(promptTemplate, forKey: DefaultsKey.promptTemplate)

        if configuration.apiKey.isEmpty {
            try keychainService.deleteString(forAccount: keychainAccount(for: provider))
        } else {
            try keychainService.setString(configuration.apiKey, forAccount: keychainAccount(for: provider))
        }
    }

    private func keychainAccount(for provider: PromptProvider) -> String {
        "promptAPIKey.\(provider.rawValue)"
    }
}
