import Foundation

/// Values to fill in before shipping. Everything app-specific that isn't code
/// lives here (and in Config/Base.xcconfig for the bundle id and team).
enum AppConfig {
    // MARK: Developer — placeholders, replace before submitting

    /// Shown in Settings and support emails.
    static let developerName = "Your Name or Company"
    /// Where "Contact Support" emails go.
    static let supportEmail = "support@example.com"
    /// The numeric Apple ID from App Store Connect (App Information), e.g.
    /// "6740000000". Enables the "Rate Snapper" link; until it's set the
    /// in-app review prompt is used instead.
    static let appStoreID: String? = nil

    // MARK: Legal pages (GitHub Pages from /docs on the default branch)

    static let privacyPolicyURL = URL(string: "https://jasonh-1.github.io/snapper/privacy.html")!
    static let termsOfUseURL = URL(string: "https://jasonh-1.github.io/snapper/terms.html")!

    // MARK: Subscriptions — must match App Store Connect and Config/Snapper.storekit

    static let yearlyProductID = "snapper.premium.yearly"
    static let monthlyProductID = "snapper.premium.monthly"
    static var subscriptionProductIDs: [String] { [yearlyProductID, monthlyProductID] }
}
