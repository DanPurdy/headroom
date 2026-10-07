import Foundation

/// An account's plan usage over time, for charting.
public enum UsageSeries {
    public struct Point: Equatable, Sendable {
        public var at: Date
        public var fiveHour: Double
        public var sevenDay: Double
    }

    /// The account's usage after each of its sessions' replies since `start`, in time order, with
    /// a drop to 0% wherever a window resets, and a final point at `now`. Each point is the
    /// newest reading known by then, so a late report from an idle session can't pull it back.
    public static func points(_ sessions: [SessionSnapshot], since start: Date, now: Date) -> [Point] {
        let samples = sessions.flatMap { $0.samples ?? [] }.sorted { $0.at < $1.at }
        var fiveHour: LimitWindow?
        var sevenDay: LimitWindow?
        var points: [Point] = []

        func point(at date: Date) -> Point {
            Point(at: date, fiveHour: fiveHour?.usedPercentage(at: date) ?? 0, sevenDay: sevenDay?.usedPercentage(at: date) ?? 0)
        }
        func addResets(before date: Date) {
            let resets = [fiveHour?.resetsAt, sevenDay?.resetsAt].compactMap { $0 }
                .filter { $0 > (points.last?.at ?? start) && $0 <= date && $0 > start }.sorted()
            for reset in resets { points.append(point(at: reset)) }
        }

        for sample in samples where sample.fiveHour != nil || sample.sevenDay != nil {
            if sample.at > start { addResets(before: sample.at) }
            fiveHour = LimitWindow.newer(fiveHour, sample.fiveHour)
            sevenDay = LimitWindow.newer(sevenDay, sample.sevenDay)
            if sample.at > start { points.append(point(at: sample.at)) }
        }
        guard fiveHour != nil || sevenDay != nil else { return [] }
        if points.isEmpty { points.append(point(at: start)) } // readings from before the period still apply
        addResets(before: now)
        points.append(point(at: now))
        return points
    }
}
