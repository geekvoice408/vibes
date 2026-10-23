#if os(macOS)
import SwiftUI
import Charts
import EeroCore

/// Port of `AddSeriesCharts` (ActivityCharts.cs): one bar chart card per series (up to 12 series of
/// up to 60 values). Without a `series` array the data is shown as plain details instead.
/// Usage: `ActivityChart(data: json, bytes: true)`.
struct ActivityChart: View {
    let data: JSON
    var bytes: Bool = true

    var body: some View {
        let series = data["series"].list
        if series.isEmpty {
            Card { DashboardDetails(value: data) }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(series.prefix(12).enumerated()), id: \.offset) { _, item in
                    ActivitySeriesChart(item: item, bytes: bytes)
                }
            }
        }
    }

    /// Port of `Number`: a non-negative number, 0 when unreadable.
    static func number(_ value: JSON) -> Double {
        guard let n = value.double, n.isFinite else { return 0 }
        return max(0, n)
    }

    /// Port of `Amount`: byte counts as B / kB / MB / GB, other counts with thousands separators.
    static func amount(_ value: Double, bytes: Bool) -> String {
        let f = NumberFormatter()
        f.locale = .current
        if !bytes {
            f.numberStyle = .decimal
            f.maximumFractionDigits = 0
            return f.string(from: NSNumber(value: value)) ?? String(Int(value))
        }
        f.numberStyle = .none
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        f.minimumIntegerDigits = 1
        func fmt(_ v: Double) -> String { f.string(from: NSNumber(value: v)) ?? String(v) }
        if value >= 1_000_000_000 { return fmt(value / 1_000_000_000) + " GB" }
        if value >= 1_000_000 { return fmt(value / 1_000_000) + " MB" }
        if value >= 1000 { return fmt(value / 1000) + " kB" }
        f.maximumFractionDigits = 0
        return fmt(value) + " B"
    }

    /// `DateTime.TryParse` for the API's time stamps.
    static func parseDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: t) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: t) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: t) { return d }
        }
        return nil
    }
}

/// One series card: title, total and bar chart (the inner loop of `AddSeriesCharts`).
struct ActivitySeriesChart: View {
    let item: JSON
    let bytes: Bool
    @State private var selected: String?

    struct Point: Identifiable {
        let id: Int
        let label: String
        let time: String
        let value: Double
        var key: String { String(id) }
    }

    private var points: [Point] {
        let values = Array(item["values"].list.prefix(60))
        let many = values.count > 14
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = many ? "dd" : "MMM d"
        return values.enumerated().map { i, v in
            let time = v.s("time")
            let label = ActivityChart.parseDate(time).map { f.string(from: $0) } ?? time
            return Point(id: i, label: label, time: time, value: ActivityChart.number(v["value"]))
        }
    }

    var body: some View {
        let points = self.points
        let total = item["sum"].isNull ? points.reduce(0) { $0 + $1.value } : ActivityChart.number(item["sum"])
        Card {
            Text(DashboardKit.human(item.first("insight_type_name", "type", "insight_type")))
                .font(.system(size: 20, weight: .semibold))
            Text(ActivityChart.amount(total, bytes: bytes))
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(Palette.accent)
            Chart {
                ForEach(points) { p in
                    BarMark(x: .value("Date", p.key), y: .value("Amount", p.value), width: .ratio(0.8))
                        .foregroundStyle(Palette.accent)
                        .cornerRadius(3)
                        .accessibilityLabel(p.time)
                        .accessibilityValue(ActivityChart.amount(p.value, bytes: bytes))
                }
                if let selected, let p = points.first(where: { $0.key == selected }) {
                    RuleMark(x: .value("Date", p.key))
                        .foregroundStyle(Palette.muted.opacity(0.3))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Text(p.time + " · " + ActivityChart.amount(p.value, bytes: bytes))
                                .font(.system(size: 11))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.edge))
                        }
                }
            }
            .chartXSelection(value: $selected)
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let key = value.as(String.self), let i = Int(key), points.indices.contains(i) {
                            Text(points[i].label).font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(ActivityChart.amount(v, bytes: bytes)).font(.system(size: 10)) }
                    }
                }
            }
            .frame(height: 180)
        }
    }
}
#endif
