import Foundation

/// Text for the approved card, using the portfolio's month and existing money formatter.
struct CompanionPaceLabels {
    let pace: CompanionShopPace
    var sold: String { pace.mtd == nil ? "No sales data yet" : CompanionPace.compactMoney(pace.mtd, currency: pace.currency) }
    var goal: String {
        guard let goal = pace.goal, goal > 0 else { return "No target set" }
        let amount = CompanionPace.compactMoney(goal, currency: pace.targetCurrency ?? pace.currency)
        guard pace.mtd != nil, let pct = pace.progressPct else { return "\(amount) goal" }
        return "\(Int(pct.rounded()))% of \(amount) goal"
    }
    var expected: String? {
        guard (pace.goal ?? 0) > 0, let expected = pace.expectedByToday else { return nil }
        return "today · should be " + CompanionPace.compactMoney(expected, currency: pace.currency)
    }
    var scale: (start: String, end: String)? {
        guard let month = pace.month, let start = month.start, let days = month.daysInMonth,
              (1...31).contains(days) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let first = formatter.date(from: start),
              let last = formatter.calendar.date(byAdding: .day, value: days - 1, to: first) else { return nil }
        formatter.dateFormat = "d MMM"
        return (formatter.string(from: first), formatter.string(from: last))
    }
    var footer: String {
        var parts: [String] = []
        if let day = pace.month?.day, let days = pace.month?.daysInMonth { parts.append("Day \(day) of \(days)") }
        if let through = CompanionPace.metricsText(pace.metricsThrough) { parts.append("numbers to \(through)") }
        return parts.joined(separator: " · ")
    }
}
