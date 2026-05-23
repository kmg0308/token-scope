import SwiftUI
import TokenMeterCore

enum ChartMode: Equatable {
    case bySource
    case byTokenKind(TokenSource)
}

struct TokenBarChart: View {
    let buckets: [TimeBucket]
    let range: TimeRangePreset
    let bucketInterval: BucketInterval
    let mode: ChartMode
    let numberFormat: TokenNumberFormat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let sparseTimeline = usesSparseTimeline
                let visibleBuckets = visibleBuckets(sparseTimeline: sparseTimeline)
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
        .padding(16)
        .tokenSurface(elevated: true)
    }

    private func plotArea(buckets: [TimeBucket], maxValue: Int, sparseTimeline: Bool) -> some View {
        ZStack {
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                drawPlot(
                    context: &context,
                    size: size,
                    buckets: buckets,
                    maxValue: maxValue,
                    sparseTimeline: sparseTimeline
                )
            }

            if buckets.isEmpty {
                Text("No data")
                    .font(.system(size: 12))
                    .foregroundStyle(TokenMeterTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func drawPlot(
        context: inout GraphicsContext,
        size: CGSize,
        buckets: [TimeBucket],
        maxValue: Int,
        sparseTimeline: Bool
    ) {
        drawGrid(context: &context, size: size)

        guard !buckets.isEmpty else { return }

        if sparseTimeline {
            let interval = range.interval(earliest: buckets.map(\.start).min())
            let width = sparseBarWidth(plotWidth: size.width, bucketCount: buckets.count)
            for bucket in buckets where bucket.usage.total > 0 {
                let x = timelineX(for: bucket.start, width: size.width, interval: interval)
                drawBucket(
                    context: &context,
                    bucket: bucket,
                    maxValue: maxValue,
                    x: x - width / 2,
                    width: width,
                    height: size.height
                )
            }
        } else {
            let slotWidth = size.width / CGFloat(max(1, buckets.count))
            let width = barWidth(slotWidth: slotWidth, count: buckets.count)
            for (index, bucket) in buckets.enumerated() where bucket.usage.total > 0 {
                let x = slotWidth * CGFloat(index) + (slotWidth - width) / 2
                drawBucket(
                    context: &context,
                    bucket: bucket,
                    maxValue: maxValue,
                    x: x,
                    width: width,
                    height: size.height
                )
            }
        }
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        let lineColor = Color.white.opacity(0.055)
        for index in 0..<5 {
            let y = size.height * CGFloat(index) / 4
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(lineColor), lineWidth: 1)
        }
    }

    private func drawBucket(
        context: inout GraphicsContext,
        bucket: TimeBucket,
        maxValue: Int,
        x: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) {
        let totalHeight = max(2, height * CGFloat(bucket.usage.total) / CGFloat(maxValue))
        var y = height - totalHeight

        switch mode {
        case .bySource:
            let codex = bucket.sourceUsage[.codex]?.total ?? 0
            let claude = bucket.sourceUsage[.claude]?.total ?? 0
            let total = max(1, codex + claude)
            drawSegment(
                context: &context,
                value: codex,
                total: total,
                totalHeight: totalHeight,
                x: x,
                width: width,
                y: &y,
                color: sourceColor(.codex)
            )
            drawSegment(
                context: &context,
                value: claude,
                total: total,
                totalHeight: totalHeight,
                x: x,
                width: width,
                y: &y,
                color: sourceColor(.claude)
            )
        case .byTokenKind(let source):
            let input: Int
            let cache: Int
            switch source {
            case .codex:
                input = max(0, bucket.usage.input - bucket.usage.cachedInput)
                cache = bucket.usage.cachedInput
            case .claude:
                input = bucket.usage.input
                cache = bucket.usage.cacheCreation + bucket.usage.cacheRead
            case .all:
                input = max(0, bucket.usage.input - bucket.usage.cachedInput)
                cache = bucket.usage.cachedInput + bucket.usage.cacheCreation + bucket.usage.cacheRead
            }
            let output = max(0, bucket.usage.output - bucket.usage.reasoning)
            let total = max(1, input + cache + output + bucket.usage.reasoning)
            drawSegment(
                context: &context,
                value: input,
                total: total,
                totalHeight: totalHeight,
                x: x,
                width: width,
                y: &y,
                color: componentColor(.input)
            )
            drawSegment(
                context: &context,
                value: cache,
                total: total,
                totalHeight: totalHeight,
                x: x,
                width: width,
                y: &y,
                color: componentColor(.cache)
            )
            drawSegment(
                context: &context,
                value: output,
                total: total,
                totalHeight: totalHeight,
                x: x,
                width: width,
                y: &y,
                color: componentColor(.output)
            )
            drawSegment(
                context: &context,
                value: bucket.usage.reasoning,
                total: total,
                totalHeight: totalHeight,
                x: x,
                width: width,
                y: &y,
                color: componentColor(.reasoning)
            )
        }
    }

    private func drawSegment(
        context: inout GraphicsContext,
        value: Int,
        total: Int,
        totalHeight: CGFloat,
        x: CGFloat,
        width: CGFloat,
        y: inout CGFloat,
        color: Color
    ) {
        guard value > 0 else { return }
        let segmentHeight = max(1, totalHeight * CGFloat(value) / CGFloat(max(1, total)))
        let rect = CGRect(x: x, y: y, width: width, height: segmentHeight)
        context.fill(Path(rect), with: .color(color))
        y += segmentHeight
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
        .foregroundStyle(TokenMeterTheme.tertiaryText)
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
                            .fill(Color.white.opacity(0.14))
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
        .foregroundStyle(TokenMeterTheme.tertiaryText)
    }

    private func axisTicks(buckets: [TimeBucket], width: CGFloat) -> [AxisTick] {
        if buckets.isEmpty {
            return fallbackAxisTicks(width: width)
        }

        let formatter = axisDateFormatter()
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
                title: formatter.string(from: buckets[index].start),
                x: clampedAxisX(rawX, width: width, labelWidth: labelWidth),
                width: labelWidth
            )
        }
    }

    private func fallbackAxisTicks(width: CGFloat) -> [AxisTick] {
        let formatter = axisDateFormatter()
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
                title: formatter.string(from: date),
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
        case .minute, .fiveMinutes, .tenMinutes, .twentyMinutes, .thirtyMinutes:
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

    private func visibleBuckets(sparseTimeline: Bool) -> [TimeBucket] {
        guard let first = buckets.first else { return [] }

        let interval = bucketInterval
        guard !sparseTimeline else { return buckets }

        let calendar = Calendar.current
        let rangeInterval = range.interval(calendar: calendar, earliest: first.start)
        let start = bucketStart(for: rangeInterval.start, interval: interval, calendar: calendar)
        let end = bucketStart(for: rangeInterval.end, interval: interval, calendar: calendar)

        let existing = Dictionary(uniqueKeysWithValues: buckets.map { ($0.start, $0) })
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

    private func timelineX(for date: Date, width: CGFloat, interval: DateInterval) -> CGFloat {
        guard interval.duration > 0 else { return width / 2 }
        let fraction = min(1, max(0, date.timeIntervalSince(interval.start) / interval.duration))
        return width * CGFloat(fraction)
    }

    private func bucketStart(for date: Date, interval: BucketInterval, calendar: Calendar) -> Date {
        switch interval {
        case .minute:
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            return calendar.date(from: components) ?? date
        case .fiveMinutes:
            return minuteBucket(date, size: 5, calendar: calendar)
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
        case .fiveMinutes:
            return calendar.date(byAdding: .minute, value: 5, to: date)
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
        case .minute, .fiveMinutes, .tenMinutes, .twentyMinutes, .thirtyMinutes:
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
        .foregroundStyle(TokenMeterTheme.secondaryText)
    }

    private func legend(_ title: String, _ source: TokenSource) -> some View {
        legend(title, sourceColor(source))
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 12, height: 8)
            Text(title)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background {
            TokenControlChrome(cornerRadius: TokenMeterTheme.compactControlRadius)
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

    private func axisDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        switch bucketInterval {
        case .minute, .fiveMinutes, .tenMinutes, .twentyMinutes, .thirtyMinutes, .hour:
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

        return formatter
    }
}

private struct AxisTick: Identifiable {
    let id: Int
    let title: String
    let x: CGFloat
    let width: CGFloat
}

struct BarSegment {
    let id: String
    let label: String
    let value: Int
    let total: Int
    let color: Color
}

struct ProportionBar: View {
    let value: Int
    let maxValue: Int
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(TokenMeterTheme.control)
                Rectangle()
                    .fill(color)
                    .frame(width: proxy.size.width * CGFloat(value) / CGFloat(max(1, maxValue)))
            }
        }
        .frame(height: 8)
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
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TokenMeterTheme.primaryText)
                .padding(.bottom, 8)
            tableHeader
            Divider()
            ForEach(rows) { row in
                tableRow(row)
                Divider()
            }
            if rows.isEmpty {
                Text("No data")
                    .foregroundStyle(TokenMeterTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .tokenSurface()
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
        .foregroundStyle(TokenMeterTheme.tertiaryText)
        .padding(.vertical, 7)
    }

    private func tableRow(_ row: GroupedUsageRow) -> some View {
        HStack {
            Text(keyFormatter(row.key))
                .lineLimit(1)
                .foregroundStyle(TokenMeterTheme.secondaryText)
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
        .foregroundStyle(TokenMeterTheme.primaryText)
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
        return Color(red: 0.39, green: 0.72, blue: 1.0)
    case .claude:
        return Color(red: 1.0, green: 0.56, blue: 0.25)
    case .all:
        return Color(red: 0.58, green: 0.62, blue: 0.68)
    }
}

func componentColor(_ kind: TokenComponentKind) -> Color {
    switch kind {
    case .input:
        return Color(red: 0.39, green: 0.72, blue: 1.0)
    case .cache:
        return Color(red: 0.30, green: 0.86, blue: 0.72)
    case .output:
        return Color(red: 1.0, green: 0.76, blue: 0.30)
    case .reasoning:
        return Color(red: 0.72, green: 0.53, blue: 1.0)
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
