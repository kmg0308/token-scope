import SwiftUI
import TokenMeterCore

enum ChartMode {
    case bySource
    case byTokenKind(TokenSource)
}

struct TokenBarChart: View {
    let buckets: [TimeBucket]
    let range: TimeRangePreset
    let bucketInterval: BucketInterval
    let mode: ChartMode
    let numberFormat: TokenNumberFormat
    @State private var hoveredBucket: TimeBucket?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let visibleBuckets = visibleBuckets
                let sparseTimeline = usesSparseTimeline
                let maxValue = niceMax(max(1, visibleBuckets.map(\.usage.total).max() ?? 1))
                let axisWidth: CGFloat = numberFormat == .full ? 96 : 54
                let xAxisHeight: CGFloat = 28
                let plotWidth = max(180, proxy.size.width - axisWidth - 8)
                let plotHeight = max(80, proxy.size.height - xAxisHeight - 6)

                HStack(alignment: .top, spacing: 8) {
                    yAxis(maxValue: maxValue)
                        .frame(width: axisWidth, height: plotHeight)

                    VStack(spacing: 6) {
                        plotArea(buckets: visibleBuckets, maxValue: maxValue, sparseTimeline: sparseTimeline)
                            .frame(height: plotHeight)
                        xAxis(buckets: sparseTimeline ? [] : visibleBuckets)
                            .frame(height: xAxisHeight)
                    }
                    .frame(width: plotWidth, alignment: .leading)
                }
            }
            chartLegend
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func plotArea(buckets: [TimeBucket], maxValue: Int, sparseTimeline: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            chartGrid(maxValue: maxValue)

            if buckets.isEmpty {
                Text("No data")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { proxy in
                    let slotWidth = proxy.size.width / CGFloat(max(1, buckets.count))
                    let barWidth = barWidth(slotWidth: slotWidth, count: buckets.count)

                    ZStack(alignment: .bottomLeading) {
                        if !sparseTimeline,
                           let hoveredBucket,
                           let index = buckets.firstIndex(where: { $0.id == hoveredBucket.id }) {
                            let slotCenterX = slotWidth * CGFloat(index) + slotWidth / 2
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.primary.opacity(0.055))
                                .frame(width: min(slotWidth * 0.84, max(barWidth + 12, barWidth)), height: proxy.size.height)
                                .position(x: slotCenterX, y: proxy.size.height / 2)
                                .allowsHitTesting(false)
                        }

                        if sparseTimeline {
                            ForEach(buckets.filter { $0.usage.total > 0 }) { bucket in
                                let x = timelineX(for: bucket.start, width: proxy.size.width)
                                let width = sparseBarWidth(plotWidth: proxy.size.width, bucketCount: buckets.count)
                                BarStack(
                                    bucket: bucket,
                                    maxValue: maxValue,
                                    mode: mode,
                                    numberFormat: numberFormat,
                                    isHovered: hoveredBucket?.id == bucket.id,
                                    onHoverBucket: { bucket in
                                        hoveredBucket = bucket
                                    }
                                )
                                .frame(width: width, height: proxy.size.height)
                                .position(x: x, y: proxy.size.height / 2)
                            }
                        } else {
                            HStack(alignment: .bottom, spacing: 0) {
                                ForEach(buckets) { bucket in
                                    ZStack(alignment: .bottom) {
                                        if bucket.usage.total > 0 {
                                            BarStack(
                                                bucket: bucket,
                                                maxValue: maxValue,
                                                mode: mode,
                                                numberFormat: numberFormat,
                                                isHovered: hoveredBucket?.id == bucket.id,
                                                onHoverBucket: { bucket in
                                                    hoveredBucket = bucket
                                                }
                                            )
                                            .frame(width: barWidth)
                                        } else {
                                            Color.clear
                                                .frame(width: barWidth)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                }
                            }
                            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
                        }

                        if let hoveredBucket {
                            if sparseTimeline {
                                let barHeight = max(2, proxy.size.height * CGFloat(hoveredBucket.usage.total) / CGFloat(maxValue))
                                let slotCenterX = timelineX(for: hoveredBucket.start, width: proxy.size.width)
                                let tooltipX = min(
                                    max(tooltipWidth / 2, slotCenterX + tooltipWidth * 0.22),
                                    max(tooltipWidth / 2, proxy.size.width - tooltipWidth / 2)
                                )
                                let tooltipY = min(
                                    max(tooltipHeight / 2, proxy.size.height - barHeight - tooltipHeight / 2 - 10),
                                    max(tooltipHeight / 2, proxy.size.height - tooltipHeight / 2)
                                )

                                ChartTooltip(bucket: hoveredBucket, mode: mode, numberFormat: numberFormat)
                                    .position(x: tooltipX, y: tooltipY)
                                    .zIndex(20)
                                    .allowsHitTesting(false)
                            } else if let index = buckets.firstIndex(where: { $0.id == hoveredBucket.id }) {
                                let barHeight = max(2, proxy.size.height * CGFloat(hoveredBucket.usage.total) / CGFloat(maxValue))
                                let slotCenterX = slotWidth * CGFloat(index) + slotWidth / 2
                                let tooltipX = min(
                                    max(tooltipWidth / 2, slotCenterX + tooltipWidth * 0.22),
                                    max(tooltipWidth / 2, proxy.size.width - tooltipWidth / 2)
                                )
                                let tooltipY = min(
                                    max(tooltipHeight / 2, proxy.size.height - barHeight - tooltipHeight / 2 - 10),
                                    max(tooltipHeight / 2, proxy.size.height - tooltipHeight / 2)
                                )

                                ChartTooltip(bucket: hoveredBucket, mode: mode, numberFormat: numberFormat)
                                    .position(x: tooltipX, y: tooltipY)
                                    .zIndex(20)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
            }
        }
    }

    private func chartGrid(maxValue: Int) -> some View {
        VStack {
            ForEach(yAxisTickValues(maxValue: maxValue).indices, id: \.self) { index in
                gridLine
                if index < yAxisTickValues(maxValue: maxValue).count - 1 {
                    Spacer()
                }
            }
        }
    }

    private var gridLine: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }

    private func yAxis(maxValue: Int) -> some View {
        VStack(alignment: .trailing) {
                let ticks = yAxisTickValues(maxValue: maxValue)
            ForEach(ticks.indices, id: \.self) { index in
                Text(TokenFormatters.tokens(ticks[index], format: numberFormat))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                if index < ticks.count - 1 {
                    Spacer()
                }
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private func yAxisTickValues(maxValue: Int) -> [Int] {
        [maxValue, maxValue * 3 / 4, maxValue / 2, maxValue / 4, 0]
    }

    private func xAxis(buckets: [TimeBucket]) -> some View {
        GeometryReader { proxy in
            let ticks = axisTicks(buckets: buckets, width: proxy.size.width)
            ZStack(alignment: .topLeading) {
                ForEach(ticks) { tick in
                    VStack(spacing: 4) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.16))
                            .frame(width: 1, height: 5)
                        Text(tick.title)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .frame(width: tick.width)
                    .position(x: tick.x, y: 12)
                }
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private func axisTicks(buckets: [TimeBucket], width: CGFloat) -> [AxisTick] {
        if buckets.isEmpty {
            return fallbackAxisTicks(width: width)
        }

        let slotWidth = width / CGFloat(max(1, buckets.count))
        let labelSpacing = minTickSpacing
        let maxLabels = max(2, Int(width / labelSpacing))
        let stride = max(1, Int(ceil(Double(buckets.count) / Double(maxLabels))))
        let indexes = visibleTickIndexes(count: buckets.count, step: stride)
        let labelWidth = min(92, max(42, min(labelSpacing, slotWidth * CGFloat(stride) * 0.94)))

        return indexes.map { index in
            let rawX = slotWidth * CGFloat(index) + slotWidth / 2
            return AxisTick(
                id: index,
                title: axisDate(buckets[index].start),
                x: clampedAxisX(rawX, width: width, labelWidth: labelWidth),
                width: labelWidth
            )
        }
    }

    private func fallbackAxisTicks(width: CGFloat) -> [AxisTick] {
        let interval = range.interval()
        let dates = [
            interval.start,
            Date(timeInterval: interval.duration / 2, since: interval.start),
            interval.end
        ]
        let labelWidth: CGFloat = 76
        return dates.enumerated().map { index, date in
            let rawX = index == 0 ? 0 : (index == 1 ? width / 2 : width)
            return AxisTick(
                id: index,
                title: axisDate(date),
                x: clampedAxisX(rawX, width: width, labelWidth: labelWidth),
                width: labelWidth
            )
        }
    }

    private func visibleTickIndexes(count: Int, step: Int) -> [Int] {
        var indexes = Array(Swift.stride(from: 0, to: count, by: step))
        let last = count - 1
        if !indexes.contains(last) {
            if let previous = indexes.last, last - previous < step {
                indexes[indexes.count - 1] = last
            } else {
                indexes.append(last)
            }
        }
        return indexes
    }

    private var minTickSpacing: CGFloat {
        switch bucketInterval {
        case .minute, .tenMinutes, .twentyMinutes, .thirtyMinutes:
            return 64
        case .hour:
            return 58
        case .day:
            return range == .last7Days ? 54 : 64
        case .week:
            return 70
        case .month:
            return 76
        }
    }

    private func clampedAxisX(_ x: CGFloat, width: CGFloat, labelWidth: CGFloat) -> CGFloat {
        let half = labelWidth / 2
        return min(max(x, half), max(half, width - half))
    }

    private var visibleBuckets: [TimeBucket] {
        let sorted = buckets.sorted { $0.start < $1.start }
        guard let first = sorted.first else { return [] }

        let interval = bucketInterval
        guard !usesSparseTimeline else { return sorted }

        let calendar = Calendar.current
        let rangeInterval = range.interval(calendar: calendar, earliest: first.start)
        let start = bucketStart(for: rangeInterval.start, interval: interval, calendar: calendar)
        let end = bucketStart(for: rangeInterval.end, interval: interval, calendar: calendar)

        let existing = Dictionary(uniqueKeysWithValues: sorted.map { ($0.start, $0) })
        var result: [TimeBucket] = []
        var current = start
        var guardCount = 0

        while current <= end && guardCount < maxVisibleBucketCount(for: interval) {
            result.append(existing[current] ?? TimeBucket(start: current, usage: .zero, sourceUsage: [:]))
            guard let next = nextBucket(after: current, interval: interval, calendar: calendar),
                  next > current else {
                break
            }
            current = next
            guardCount += 1
        }

        return result
    }

    private var usesSparseTimeline: Bool {
        estimatedBucketCount > 2_000
    }

    private var estimatedBucketCount: Int {
        let calendar = Calendar.current
        let rangeInterval = range.interval(calendar: calendar, earliest: buckets.map(\.start).min())
        let start = bucketStart(for: rangeInterval.start, interval: bucketInterval, calendar: calendar)
        let end = bucketStart(for: rangeInterval.end, interval: bucketInterval, calendar: calendar)
        var current = start
        var count = 0

        while current <= end && count <= 2_001 {
            count += 1
            guard let next = nextBucket(after: current, interval: bucketInterval, calendar: calendar),
                  next > current else {
                break
            }
            current = next
        }

        return count
    }

    private func timelineX(for date: Date, width: CGFloat) -> CGFloat {
        let interval = range.interval(earliest: buckets.map(\.start).min())
        guard interval.duration > 0 else { return width / 2 }
        let fraction = min(1, max(0, date.timeIntervalSince(interval.start) / interval.duration))
        return width * CGFloat(fraction)
    }

    private func bucketStart(for date: Date, interval: BucketInterval, calendar: Calendar) -> Date {
        switch interval {
        case .minute:
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            return calendar.date(from: components) ?? date
        case .tenMinutes:
            return minuteBucket(date, size: 10, calendar: calendar)
        case .twentyMinutes:
            return minuteBucket(date, size: 20, calendar: calendar)
        case .thirtyMinutes:
            return minuteBucket(date, size: 30, calendar: calendar)
        case .hour:
            let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            return calendar.date(from: components) ?? date
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return calendar.date(from: components) ?? date
        case .month:
            let components = calendar.dateComponents([.year, .month], from: date)
            return calendar.date(from: components) ?? date
        }
    }

    private func nextBucket(after date: Date, interval: BucketInterval, calendar: Calendar) -> Date? {
        switch interval {
        case .minute:
            return calendar.date(byAdding: .minute, value: 1, to: date)
        case .tenMinutes:
            return calendar.date(byAdding: .minute, value: 10, to: date)
        case .twentyMinutes:
            return calendar.date(byAdding: .minute, value: 20, to: date)
        case .thirtyMinutes:
            return calendar.date(byAdding: .minute, value: 30, to: date)
        case .hour:
            return calendar.date(byAdding: .hour, value: 1, to: date)
        case .day:
            return calendar.date(byAdding: .day, value: 1, to: date)
        case .week:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case .month:
            return calendar.date(byAdding: .month, value: 1, to: date)
        }
    }

    private func maxVisibleBucketCount(for interval: BucketInterval) -> Int {
        switch interval {
        case .minute, .tenMinutes, .twentyMinutes, .thirtyMinutes:
            return 2_000
        case .hour:
            return 800
        case .day, .week, .month:
            return 400
        }
    }

    private func minuteBucket(_ date: Date, size: Int, calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.minute = ((components.minute ?? 0) / size) * size
        return calendar.date(from: components) ?? date
    }

    private func sparseBarWidth(plotWidth: CGFloat, bucketCount: Int) -> CGFloat {
        min(10, max(2, plotWidth / CGFloat(max(80, bucketCount))))
    }

    private func barWidth(slotWidth: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return 6 }
        if count <= 12 {
            return min(34, max(12, slotWidth * 0.58))
        }
        if count <= 35 {
            return min(20, max(6, slotWidth * 0.62))
        }
        if count <= 60 {
            return min(14, max(4, slotWidth * 0.65))
        }
        if count <= 180 {
            return min(9, max(2, slotWidth * 0.72))
        }
        if count <= 800 {
            return min(4, max(1, slotWidth * 0.78))
        }
        return min(3, max(0.6, slotWidth * 0.82))
    }

    private var tooltipWidth: CGFloat {
        numberFormat == .full ? 238 : 178
    }

    private var tooltipHeight: CGFloat {
        numberFormat == .full ? 142 : 132
    }

    private var chartLegend: some View {
        HStack(spacing: 14) {
            switch mode {
            case .bySource:
                legend("Codex", .codex)
                legend("Claude Code", .claude)
            case .byTokenKind:
                legend("Input", componentColor(.input))
                legend("Cache", componentColor(.cache))
                legend("Output", componentColor(.output))
                legend("Reasoning", componentColor(.reasoning))
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func legend(_ title: String, _ source: TokenSource) -> some View {
        legend(title, sourceColor(source))
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Rectangle()
                .fill(color)
                .frame(width: 12, height: 8)
            Text(title)
        }
    }

    private func niceMax(_ value: Int) -> Int {
        guard value > 0 else { return 1 }
        let magnitude = pow(10.0, floor(log10(Double(value))))
        let normalized = Double(value) / magnitude
        let nice: Double
        if normalized <= 1 {
            nice = 1
        } else if normalized <= 2 {
            nice = 2
        } else if normalized <= 5 {
            nice = 5
        } else {
            nice = 10
        }
        return max(1, Int(nice * magnitude))
    }

    private func axisDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        switch bucketInterval {
        case .minute, .tenMinutes, .twentyMinutes, .thirtyMinutes, .hour:
            formatter.dateFormat = "HH:mm"
        case .day:
            switch range {
            case .today, .yesterday, .last30Minutes, .last1Hour, .last3Hours, .last6Hours, .last12Hours, .last24Hours:
                formatter.dateFormat = "HH:mm"
            case .last7Days:
                formatter.dateFormat = "EEE d"
            case .last30Days, .last3Months, .last6Months, .last12Months, .all:
                formatter.dateFormat = "MMM d"
            }
        case .week:
            formatter.dateFormat = "MMM d"
        case .month:
            switch range {
            case .last3Months, .last6Months, .last12Months, .all:
                formatter.dateFormat = "MMM yyyy"
            default:
                formatter.dateFormat = "MMM"
            }
        }

        return formatter.string(from: date)
    }
}

private struct AxisTick: Identifiable {
    let id: Int
    let title: String
    let x: CGFloat
    let width: CGFloat
}

struct MiniBars: View {
    let buckets: [TimeBucket]

    var body: some View {
        GeometryReader { proxy in
            let maxValue = max(1, buckets.map(\.usage.total).max() ?? 1)
            let barWidth = min(7, max(2, (proxy.size.width - CGFloat(max(0, buckets.count - 1)) * 2) / CGFloat(max(1, buckets.count))))
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(buckets) { bucket in
                    BarStack(
                        bucket: bucket,
                        maxValue: maxValue,
                        mode: .bySource,
                        numberFormat: .compact,
                        isHovered: false,
                        onHoverBucket: { _ in }
                    )
                        .frame(width: barWidth)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
        }
    }
}

struct BarStack: View {
    let bucket: TimeBucket
    let maxValue: Int
    let mode: ChartMode
    let numberFormat: TokenNumberFormat
    let isHovered: Bool
    let onHoverBucket: (TimeBucket?) -> Void

    var body: some View {
        GeometryReader { proxy in
            let totalHeight = max(2, proxy.size.height * CGFloat(bucket.usage.total) / CGFloat(maxValue))
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                barBody(totalHeight: totalHeight)
            }
        }
        .opacity(isHovered ? 1.0 : 0.88)
        .zIndex(isHovered ? 10 : 0)
        .onHover { inside in
            onHoverBucket(inside ? bucket : nil)
        }
        .help("\(bucket.start.formatted(date: .abbreviated, time: .shortened)) · \(TokenFormatters.tokens(bucket.usage.total, format: numberFormat)) tokens")
    }

    private var segments: [BarSegment] {
        chartSegments(for: bucket, mode: mode)
    }

    private func barBody(totalHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(segments, id: \.id) { segment in
                Rectangle()
                    .fill(segment.color)
                    .frame(height: max(1, totalHeight * CGFloat(segment.value) / CGFloat(max(1, segment.total))))
            }
        }
        .frame(height: totalHeight)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

struct BarSegment {
    let id: String
    let label: String
    let value: Int
    let total: Int
    let color: Color
}

struct ChartTooltip: View {
    let bucket: TimeBucket
    let mode: ChartMode
    let numberFormat: TokenNumberFormat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(bucket.start.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Text(TokenFormatters.tokens(bucket.usage.total, format: numberFormat))
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Text("tokens")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(chartSegments(for: bucket, mode: mode), id: \.id) { segment in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(segment.color)
                            .frame(width: 7, height: 7)
                        Text(segment.label)
                        Spacer()
                        Text(TokenFormatters.tokens(segment.value, format: numberFormat))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                }
            }
            .font(.system(size: 11))
        }
        .padding(10)
        .frame(width: numberFormat == .full ? 238 : 178, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 6)
    }
}

struct ProportionBar: View {
    let value: Int
    let maxValue: Int
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                Rectangle()
                    .fill(color)
                    .frame(width: proxy.size.width * CGFloat(value) / CGFloat(max(1, maxValue)))
            }
        }
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

struct ResponsiveDetails: View {
    let projectRows: [GroupedUsageRow]
    let modelRows: [GroupedUsageRow]
    let sessionRows: [GroupedUsageRow]
    let numberFormat: TokenNumberFormat

    var body: some View {
        ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    UsageTable(title: "Projects", rows: projectRows, keyLabel: "Project", numberFormat: numberFormat, density: .regular, keyFormatter: shortProject)
                    UsageTable(title: "Models", rows: modelRows, keyLabel: "Model", numberFormat: numberFormat, density: .regular)
                }
                UsageTable(title: "Sessions", rows: sessionRows, keyLabel: "Session", numberFormat: numberFormat, density: .regular)
            }

            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        UsageTable(title: "Projects", rows: projectRows, keyLabel: "Project", numberFormat: numberFormat, density: .compact, keyFormatter: shortProject)
                        UsageTable(title: "Models", rows: modelRows, keyLabel: "Model", numberFormat: numberFormat, density: .compact)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        UsageTable(title: "Projects", rows: projectRows, keyLabel: "Project", numberFormat: numberFormat, density: .compact, keyFormatter: shortProject)
                        UsageTable(title: "Models", rows: modelRows, keyLabel: "Model", numberFormat: numberFormat, density: .compact)
                    }
                }
                UsageTable(title: "Sessions", rows: sessionRows, keyLabel: "Session", numberFormat: numberFormat, density: .compact)
            }
        }
    }
}

struct UsageTable: View {
    enum Density {
        case regular
        case compact
    }

    let title: String
    let rows: [GroupedUsageRow]
    let keyLabel: String
    let numberFormat: TokenNumberFormat
    var density: Density = .regular
    var keyFormatter: (String) -> String = { $0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title)
            VStack(spacing: 0) {
                tableHeader
                Divider()
                ForEach(rows) { row in
                    tableRow(row)
                    Divider()
                }
                if rows.isEmpty {
                    Text("No data")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 14)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(minWidth: minWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var tableHeader: some View {
        HStack {
            Text(keyLabel).frame(maxWidth: .infinity, alignment: .leading)
            Text("Total").frame(width: totalColumnWidth, alignment: .trailing)
            if density == .regular {
                Text("Input").frame(width: tokenColumnWidth, alignment: .trailing)
                Text("Cache").frame(width: tokenColumnWidth, alignment: .trailing)
                Text("Output").frame(width: tokenColumnWidth, alignment: .trailing)
            }
            Text("Count").frame(width: 52, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.vertical, 7)
    }

    private func tableRow(_ row: GroupedUsageRow) -> some View {
        HStack {
            Text(keyFormatter(row.key))
                .lineLimit(1)
                .help(row.key)
                .frame(maxWidth: .infinity, alignment: .leading)
            tokenCell(row.usage.total, width: totalColumnWidth)
            if density == .regular {
                tokenCell(row.usage.input, width: tokenColumnWidth)
                tokenCell(row.usage.cachedInput + row.usage.cacheCreation + row.usage.cacheRead, width: tokenColumnWidth)
                tokenCell(row.usage.output, width: tokenColumnWidth)
            }
            Text(TokenFormatters.integer(row.count)).frame(width: 52, alignment: .trailing)
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .padding(.vertical, 8)
    }

    private var totalColumnWidth: CGFloat {
        switch (numberFormat, density) {
        case (.full, .regular):
            116
        case (.full, .compact):
            132
        case (.compact, .regular):
            90
        case (.compact, .compact):
            96
        }
    }

    private var tokenColumnWidth: CGFloat {
        numberFormat == .full ? 108 : 80
    }

    private var minWidth: CGFloat {
        switch (numberFormat, density) {
        case (.full, .regular):
            600
        case (.compact, .regular):
            500
        case (.full, .compact):
            330
        case (.compact, .compact):
            290
        }
    }

    private func tokenCell(_ value: Int, width: CGFloat) -> some View {
        Text(TokenFormatters.tokens(value, format: numberFormat))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .frame(width: width, alignment: .trailing)
    }
}

func sourceColor(_ source: TokenSource) -> Color {
    switch source {
    case .codex:
        return Color(red: 0.24, green: 0.48, blue: 0.95)
    case .claude:
        return Color(red: 0.93, green: 0.48, blue: 0.20)
    case .all:
        return Color(red: 0.48, green: 0.52, blue: 0.58)
    }
}

func componentColor(_ kind: TokenComponentKind) -> Color {
    switch kind {
    case .input:
        return Color(red: 0.24, green: 0.48, blue: 0.95)
    case .cache:
        return Color(red: 0.18, green: 0.63, blue: 0.58)
    case .output:
        return Color(red: 0.88, green: 0.64, blue: 0.20)
    case .reasoning:
        return Color(red: 0.57, green: 0.43, blue: 0.86)
    }
}

func chartSegments(for bucket: TimeBucket, mode: ChartMode) -> [BarSegment] {
    switch mode {
    case .bySource:
        let codex = bucket.sourceUsage[.codex]?.total ?? 0
        let claude = bucket.sourceUsage[.claude]?.total ?? 0
        let total = max(1, codex + claude)
        return [
            BarSegment(id: "codex", label: "Codex", value: codex, total: total, color: sourceColor(.codex)),
            BarSegment(id: "claude", label: "Claude Code", value: claude, total: total, color: sourceColor(.claude))
        ].filter { $0.value > 0 }
    case .byTokenKind(let source):
        let components = bucket.usage.displayComponents(source: source)
        let total = max(1, components.map(\.value).reduce(0, +))
        return components.map { component in
            BarSegment(
                id: component.kind.rawValue,
                label: component.kind.rawValue,
                value: component.value,
                total: total,
                color: componentColor(component.kind)
            )
        }
    }
}
