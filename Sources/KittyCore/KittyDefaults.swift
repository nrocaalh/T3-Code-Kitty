import Foundation

/// Single source of truth for UserDefaults keys. Values are kept identical
/// to the previous releases so existing user settings survive.
public enum KittyDefaults {
    public static let catX = "catX"
    public static let catY = "catY"
    public static let alertsEnabled = "alertsEnabled"
    public static let soundEnabled = "soundEnabled"
    public static let acknowledgedReviewKeys = "acknowledgedReviewKeys"
    public static let appLanguage = "appLanguage"
    public static let cachedThreadVisits = "cachedThreadVisits"
    public static let reviewedTrackingStartedAt = "reviewedTrackingStartedAt"

    public static let legacyAcknowledgementUntil = "acknowledgementUntil"
    public static let legacyReviewedEpisodes = "reviewedEpisodes"
}
