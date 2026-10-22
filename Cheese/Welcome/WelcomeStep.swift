/// The pages of the welcome window, in order.
enum WelcomeStep: Int, CaseIterable, Sendable {
    case intro
    case permissions
    case shortcuts
    case finish

    var next: WelcomeStep? { WelcomeStep(rawValue: rawValue + 1) }
    var previous: WelcomeStep? { WelcomeStep(rawValue: rawValue - 1) }
    var isFirst: Bool { previous == nil }
    var isLast: Bool { next == nil }
}
