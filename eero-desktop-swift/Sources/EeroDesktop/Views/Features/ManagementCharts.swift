#if os(macOS)
import SwiftUI
import EeroCore

/// Port of `AddSeriesCharts` (ActivityCharts.cs): one bar chart card per returned series.
struct ActivitySeriesCharts: View {
    let data: JSON
    let bytes: Bool

    /// Port of `Number`: a non-negative number, 0 when unparseable.
    static func number(_ value: JSON) -> Double {
        let n = Double(value.string.trimmingCharacters(in: .whitespaces)) ?? 0
        return n.isFinite ? max(0, n) : 0
    }

    /// Port of `Amount`.
    static func amount(_ value: Double, bytes: Bool) -> String {
        func trim(_ v: Double) -> String {
            var s = String(format: "%.2f", v)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s
        }
        if !bytes {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.maximumFractionDigits = 0
            return f.string(from: NSNumber(value: value)) ?? String(Int(value))
        }
        if value >= 1_000_000_000 { return trim(value / 1_000_000_000) + " GB" }
        if value >= 1_000_000 { return trim(value / 1_000_000) + " MB" }
        if value >= 1_000 { return trim(value / 1_000) + " kB" }
        return String(format: "%.0f", value) + " B"
    }

    static func label(_ time: String, dense: Bool) -> String {
        let iso = ISO8601DateFormatter()
        var date = iso.date(from: time)
        if date == nil {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
                f.dateFormat = format
                if let d = f.date(from: time) { date = d; break }
            }
        }
        guard let date else { return time }
        let out = DateFormatter()
        out.dateFormat = dense ? "dd" : "MMM d"
        return out.string(from: date)
    }

    var body: some View {
        let series = data["series"].list
        if series.isEmpty {
            FeatureCard { ObjectDetailsView(value: data) }
        } else {
            ForEach(Array(series.prefix(12).enumerated()), id: \.offset) { pair in
                SeriesCard(item: pair.element, bytes: bytes)
            }
        }
    }

    private struct SeriesCard: View {
        let item: JSON
        let bytes: Bool

        var body: some View {
            let values = Array(item["values"].list.prefix(60))
            let numbers = values.map { ActivitySeriesCharts.number($0["value"]) }
            let total = item["sum"].isNull ? numbers.reduce(0, +) : ActivitySeriesCharts.number(item["sum"])
            let maximum = max(1, numbers.max() ?? 1)
            FeatureCard {
                Text(FeatureText.human(item.first("insight_type_name", "type", "insight_type")))
                    .font(.system(size: 20, weight: .semibold))
                Text(ActivitySeriesCharts.amount(total, bytes: bytes))
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(values.indices, id: \.self) { i in
                        VStack(spacing: 8) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor)
                                .frame(minWidth: 3, maxWidth: 72)
                                .frame(height: max(0, 140 * numbers[i] / maximum))
                            Text(ActivitySeriesCharts.label(values[i].s("time"), dense: values.count > 14))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity)
                        .help(values[i].s("time") + " · " + ActivitySeriesCharts.amount(numbers[i], bytes: bytes))
                    }
                }
                .frame(height: 180)
            }
        }
    }
}
#endif
