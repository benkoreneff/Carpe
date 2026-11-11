import Foundation

/// Everything Carpe keeps secret. The raw value is the Keychain account name.
enum Secret: String, CaseIterable, Sendable {
    case anthropicAPIKey = "anthropic-api-key"
    case googleClientID = "google-client-id"
    case googleClientSecret = "google-client-secret"
    case googleRefreshToken = "google-refresh-token"
}

/// Where secrets are kept. The app uses the Keychain; tests use memory.
protocol SecretStore {
    func get(_ secret: Secret) -> String?
    /// Stores the value, or removes it when the value is nil.
    func set(_ value: String?, for secret: Secret) throws
}

final class InMemorySecretStore: SecretStore {
    private var values: [Secret: String]

    init(_ values: [Secret: String] = [:]) { self.values = values }

    func get(_ secret: Secret) -> String? { values[secret] }
    func set(_ value: String?, for secret: Secret) throws { values[secret] = value }
}
