import Foundation

/// How Cheese describes itself. "Swiss Army" is a Victorinox trademark: it appears only in the
/// tagline text, never in the app's name, icon or bundle metadata. Cheese is described by what you
/// do with it (`Verb`), never by counting its tools.
enum Brand {
    static let name = "Cheese"
    static let tagline = "The Swiss Army knife for your Mac."
    static let subline = "Every little tool your Mac forgot."
    static let privacy = "Everything runs on your Mac. No accounts, no telemetry, no cloud."
    static let repository = URL(string: "https://github.com/maanit-gupta/Cheese")
}
