import Foundation

/// Who makes the app and where it lives. Everything app-specific that isn't code
/// lives here (and in Config/Base.xcconfig for the bundle id and team).
enum AppConfig {
    // MARK: Developer

    /// Shown in Settings and support emails; the seller name in App Store Connect.
    static let developerName = "Jason Huang"
    /// Where "Contact Support" emails go.
    static let supportEmail = "support@snappercam.com"
    /// The numeric Apple ID from App Store Connect (App Information). Enables
    /// the "Rate Snapper" link; without it the in-app review prompt is used.
    static let appStoreID: String? = "6826104701"

    // MARK: Legal pages (GitHub Pages from /docs on the default branch, at snappercam.com)

    static let privacyPolicyURL = URL(string: "https://snappercam.com/privacy.html")!
    static let termsOfUseURL = URL(string: "https://snappercam.com/terms.html")!

    // MARK: Premium products — must match App Store Connect and Config/Snapper.storekit

    static let yearlyProductID = "snapper.premium.yearly"
    static let monthlyProductID = "snapper.premium.monthly"
    /// A non-consumable: paid once, never renews, never taken back.
    static let lifetimeProductID = "snapper.premium.lifetime"
    static var premiumProductIDs: [String] { [yearlyProductID, monthlyProductID, lifetimeProductID] }
}
