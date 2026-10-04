import Foundation

public enum Formatting {
    /// "2h 14m", "3d 4h", "45m", "now".
    public static func countdown(until date: Date, from now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds >= 60 else { return seconds > 0 ? "<1m" : "now" }
        let minutes = seconds / 60
        let (days, hours, mins) = (minutes / 1440, (minutes % 1440) / 60, minutes % 60)
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h" }
        return "\(mins)m"
    }

    /// "just now", "5m ago", "3h ago", "2d ago".
    public static func age(of date: Date, at now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date)) / 60
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        if minutes < 1440 { return "\(minutes / 60)h ago" }
        return "\(minutes / 1440)d ago"
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    public static func usd(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}
