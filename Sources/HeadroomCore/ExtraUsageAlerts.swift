import Foundation

/// Notifications about extra usage: when an account starts drawing on it, and when this
/// month's spend passes an amount the user chose. Only Live knows either, so callers pass
/// Live accounts.
public enum ExtraUsageAlerts {
    /// Plan windows reaching 100% on accounts with extra usage on, one alert per window per
    /// period. Ignore `reset` and persist `fired` under its own key.
    public static func evaluate(_ accounts: [AccountSnapshot], fired: [String: Date], now: Date) -> LimitAlerts.Outcome {
        LimitAlerts.evaluate(accounts.filter { $0.extraUsage != nil }, threshold: 100, fired: fired, now: now)
    }

    public static func notices(for crossed: [LimitAlerts.Alert], accounts: [AccountSnapshot], now: Date,
                               locale: Locale = .current) -> [LimitAlerts.Notice] {
        Dictionary(grouping: crossed, by: \.accountKey).values.sorted { $0[0].label < $1[0].label }.compactMap { alerts in
            guard let account = accounts.first(where: { $0.key == alerts[0].accountKey }),
                  let extra = account.extraUsage else { return nil }
            // The account stays on extra usage until every full window has reset, including ones
            // that filled before this alert.
            let full = [(LimitAlerts.Window.fiveHour, account.fiveHour), (.weekly, account.sevenDay)]
                .compactMap { window, reading in reading.flatMap { $0.usedPercentage(at: now) >= 100 ? (window, $0.resetsAt) : nil } }
            let until = full.max { $0.1 < $1.1 } ?? (alerts[0].window, alerts[0].resetsAt)
            return LimitAlerts.Notice(
                id: "extra-" + alerts.map { LimitAlerts.key($0.accountKey, $0.window) }.joined(separator: ","),
                title: "\(account.label): now on extra usage",
                body: "\(SpendAlerts.spent(extra, locale: locale)) used this month. Claude Code uses the 5-minute prompt cache until the \(until.0.rawValue) limit resets in \(Formatting.countdown(until: until.1, from: now)).")
        }
    }
}

public enum SpendAlerts {
    public struct Alert: Equatable, Sendable {
        public var accountKey: String
        public var label: String
        public var extraUsage: ExtraUsage
    }

    public struct Outcome: Equatable, Sendable {
        public var due: [Alert] = []
        /// The amount each account was alerted at, by account key. Persist it.
        public var fired: [String: Decimal] = [:]
    }

    /// `amount` is nil or zero when off. An account alerts once its spend reaches the amount,
    /// and again after its spend drops back below it (a new month) or the amount is changed.
    public static func evaluate(accounts: [AccountSnapshot], amount: Decimal?, fired: [String: Decimal]) -> Outcome {
        var outcome = Outcome()
        guard let amount, amount > 0 else { return outcome }
        for account in accounts {
            guard let extra = account.extraUsage, extra.used >= amount else { continue }
            outcome.fired[account.key] = amount
            if fired[account.key] != amount {
                outcome.due.append(Alert(accountKey: account.key, label: account.label, extraUsage: extra))
            }
        }
        return outcome
    }

    public static func notices(for outcome: Outcome, amount: Decimal, locale: Locale = .current) -> [LimitAlerts.Notice] {
        outcome.due.sorted { $0.label < $1.label }.map { alert in
            LimitAlerts.Notice(
                id: "spend-\(alert.accountKey)",
                title: "\(alert.label): extra usage passed \(Formatting.money(amount, alert.extraUsage.currency, locale: locale))",
                body: "\(spent(alert.extraUsage, locale: locale)) used this month.")
        }
    }

    /// The amount typed in Settings, in the user's locale, ignoring any currency symbol; nil
    /// (off) when empty, unreadable or not positive.
    public static func amount(from text: String, locale: Locale = .current) -> Decimal? {
        let digits = text.filter { $0.isNumber || $0 == "." || $0 == "," }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.generatesDecimalNumbers = true
        guard let number = formatter.number(from: digits) as? NSDecimalNumber else { return nil }
        let amount = number.decimalValue
        return amount > 0 ? amount : nil
    }

    /// "£4.20 of £20.00", or "£4.20" with no cap.
    static func spent(_ extra: ExtraUsage, locale: Locale) -> String {
        let used = Formatting.money(extra.used, extra.currency, locale: locale)
        guard let limit = extra.limit else { return used }
        return "\(used) of \(Formatting.money(limit, extra.currency, locale: locale))"
    }
}
