/// OAuth clients the app renews saved logins with.
public enum OAuthClients {
    /// The Antigravity CLI's installed-app client.
    public static let antigravityClientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"

    /// The secret embedded for `id`; nil when the app embeds none for that client.
    public static func antigravitySecret(forClientID id: String) -> String? {
        id == antigravityClientID ? "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" : nil
    }
}
