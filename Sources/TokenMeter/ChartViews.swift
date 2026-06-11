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
    @State private var hoveredBucket: TimeBucket?

    var body: some View {
        GeometryReader { proxy in
            let calendar = Calendar.current
            let bucketStarts = buckets.lazy.map(\.start)
            let chartInterval = range.interval(
                calendar: calendar,
                earliest: bucketStarts.min(),
                latest: bucketStarts.max()
            )
            let sparseTimeline = usesSparseTimeline(interval: chartInterval, calendar: calendar)
            let visibleBuckets = visibleBuckets(sparseTimeline: sparseTimeline, interval: chartInterval, calendar: calendar)
            let nonEmptyBuckets = visibleBuckets.filter { $0.usage.total > 0 }
            let maxValue = niceMax(max(1, visibleBuckets.map(\.usage.total).max() ?? 1))

            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                drawChart(
                    context: &context,
                    size: size,
                    buckets: visibleBuckets,
                    nonEmptyBuckets: nonEmptyBuckets,
                    chartInterval: chartInterval,
                    maxValue: maxValue,
                    sparseTimeline: sparseTimeline
                )
            }
            .overlay {
                GeometryReader { hoverProxy in
                    ChartHoverTrackingView { point in
                        guard let point else {
                            if hoveredBucket != nil {
                                hoveredBucket = nil
                            }
                            return
                        }

                        let bucket = hoveredBucket(
                            at: point,
                            in: proxy.size,
                            buckets: visibleBuckets,
                            nonEmptyBuckets: nonEmptyBuckets,
                            chartInterval: chartInterval,
                            sparseTimeline: sparseTimeline
                        )
                        if hoveredBucket?.id != bucket?.id {
                            hoveredBucket = bucket
                        }
                    }
                    .frame(width: hoverProxy.size.width, height: hoverProxy.size.height)
                }
            }
        }
        .padding(16)
        .tokenSurface(elevated: true)
    }

    private func drawChart(
        context: inout GraphicsContext,
        size: CGSize,
        buckets: [TimeBucket],
        nonEmptyBuckets: [TimeBucket],
        chartInterval: DateInterval,
        maxValue: Int,
        sparseTimeline: Bool
    ) {
        let layout = chartLayout(size: size)

        drawYAxis(context: &context, maxValue: maxValue, axisWidth: layout.axisWidth, plotHeight: layout.plotHeight)
        drawPlot(
            context: &context,
            size: CGSize(width: layout.plotWidth, height: layout.plotHeight),
            origin: CGPoint(x: layout.plotX, y: 0),
            buckets: buckets,
            chartInterval: chartInterval,
            maxValue: maxValue,
            sparseTimeline: sparseTimeline
        )
        drawXAxis(
            context: &context,
            buckets: sparseTimeline ? [] : buckets,
            plotX: layout.plotX,
            y: layout.plotHeight + 6,
            width: layout.plotWidth,
            fallbackInterval: chartInterval
        )
        drawLegend(context: &context, y: layout.plotHeight + layout.xAxisHeight + 10)

        if let hoveredBucket,
           nonEmptyBuckets.contains(where: { $0.id == hoveredBucket.id }) {
            drawHoverBand(
                context: &context,
                bucket: hoveredBucket,
                layout: layout,
                buckets: buckets,
                chartInterval: chartInterval,
                sparseTimeline: sparseTimeline
            )
            drawTooltip(
                context: &context,
                bucket: hoveredBucket,
                size: size,
                layout: layout,
                buckets: buckets,
                chartInterval: chartInterval,
                maxValue: maxValue,
                sparseTimeline: sparseTimeline
            )
        }

        if buckets.isEmpty {
            context.draw(
                Text("No data")
                    .font(.system(size: 12))
                    .foregroundColor(TokenMeterTheme.secondaryText),
                at: CGPoint(x: layout.plotX + layout.plotWidth / 2, y: layout.plotHeight / 2),
                anchor: .center
            )
        }
    }

    private func chartLayout(size: CGSize) -> ChartLayout {
        let axisWidth: CGFloat = numberFormat == .full ? 96 : 54
        let xAxisHeight: CGFloat = 28
        let legendHeight: CGFloat = 24
        let plotX = axisWidth + 8
        let plotWidth = max(180, size.width - plotX)
        let plotHeight = max(80, size.height - xAxisHeight - legendHeight - 14)
        return ChartLayout(
            axisWidth: axisWidth,
            xAxisHeight: xAxisHeight,
            legendHeight: legendHeight,
            plotX: plotX,
            plotWidth: plotWidth,
            plotHeight: plotHeight
        )
    }

    private func drawPlot(
        context: inout GraphicsContext,
        size: CGSize,
        origin: CGPoint,
        buckets: [TimeBucket],
        chartInterval: DateInterval,
        maxValue: Int,
        sparseTimeline: Bool
    ) {
        drawGrid(context: &context, origin: origin, size: size)

        guard !buckets.isEmpty else { return }

        let geometry = ChartBarGeometry(
            buckets: buckets,
            chartInterval: chartInterval,
            plotWidth: size.width,
            sparseTimeline: sparseTimeline
        )
        for (index, bucket) in buckets.enumerated() where bucket.usage.total > 0 {
            guard let frame = geometry.barFrame(for: bucket, at: index, height: size.height) else {
                continue
            }
            drawBucket(
                context: &context,
                bucket: bucket,
                maxValue: maxValue,
                x: origin.x + frame.minX,
                width: frame.width,
                originY: origin.y,
                height: size.height
            )
        }
    }

    private func drawGrid(context: inout GraphicsContext, origin: CGPoint, size: CGSize) {
        let lineColor = Color.white.opacity(0.055)
        for index in 0..<5 {
            let y = origin.y + size.height * CGFloat(index) / 4
            var path = Path()
            path.move(to: CGPoint(x: origin.x, y: y))
            path.addLine(to: CGPoint(x: origin.x + size.width, y: y))
            context.stroke(path, with: .color(lineColor), lineWidth: 1)
        }
    }

    private func drawBucket(
        context: inout GraphicsContext,
        bucket: TimeBucket,
        maxValue: Int,
        x: CGFloat,
        width: CGFloat,
        originY: CGFloat,
        height: CGFloat
    ) {
        let totalHeight = max(2, height * CGFloat(bucket.usage.total) / CGFloat(maxValue))
        drawStackedSegments(
            context: &context,
            segments: chartSegments(for: bucket),
            totalHeight: totalHeight,
            x: x,
            width: width,
            y: originY + height - totalHeight
        )
    }

    private func drawStackedSegments(
        context: inout GraphicsContext,
        segments: [ChartSegment],
        totalHeight: CGFloat,
        x: CGFloat,
        width: CGFloat,
        y: CGFloat
    ) {
        let visibleSegments = segments.filter { $0.value > 0 }
        guard !visibleSegments.isEmpty else { return }

        let total = max(1, visibleSegments.reduce(0.0) { $0 + Double(max(0, $1.value)) })
        var currentY = y
        var remainingHeight = totalHeight

        for (index, segment) in visibleSegments.enumerated() {
            let isLast = index == visibleSegments.index(before: visibleSegments.endIndex)
            let segmentHeight = isLast
                ? remainingHeight
                : min(remainingHeight, totalHeight * CGFloat(Double(segment.value) / total))
            guard segmentHeight > 0 else { continue }
            let rect = CGRect(x: x, y: currentY, width: width, height: segmentHeight)
            context.fill(Path(rect), with: .color(segment.color))
            currentY += segmentHeight
            remainingHeight = max(0, remainingHeight - segmentHeight)
        }
    }

    private func drawHoverBand(
        context: inout GraphicsContext,
        bucket: TimeBucket,
        layout: ChartLayout,
        buckets: [TimeBucket],
        chartInterval: DateInterval,
        sparseTimeline: Bool
    ) {
        guard let frame = hoverFrame(
            for: bucket,
            layout: layout,
            buckets: buckets,
            chartInterval: chartInterval,
            sparseTimeline: sparseTimeline
        ) else {
            return
        }

        context.fill(
            Path(roundedRect: frame, cornerRadius: 5),
            with: .color(Color.white.opacity(0.055))
        )
    }

    private func drawTooltip(
        context: inout GraphicsContext,
        bucket: TimeBucket,
        size: CGSize,
        layout: ChartLayout,
        buckets: [TimeBucket],
        chartInterval: DateInterval,
        maxValue: Int,
        sparseTimeline: Bool
    ) {
        let segments = chartSegments(for: bucket)
        let width = tooltipWidth
        let height = tooltipHeight(segmentCount: segments.count)
        let frame = tooltipFrame(
            for: bucket,
            size: size,
            layout: layout,
            buckets: buckets,
            chartInterval: chartInterval,
            maxValue: maxValue,
            sparseTimeline: sparseTimeline,
            width: width,
            height: height
        )
        let shape = Path(roundedRect: frame, cornerRadius: TokenMeterTheme.controlRadius)

        context.fill(shape, with: .color(TokenMeterTheme.elevatedSurface))
        context.stroke(shape, with: .color(TokenMeterTheme.border), lineWidth: 1)

        let left = frame.minX + 10
        var y = frame.minY + 9
        context.draw(
            Text(bucket.start.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(TokenMeterTheme.secondaryText),
            at: CGPoint(x: left, y: y),
            anchor: .topLeading
        )

        y += 20
        context.draw(
            Text(TokenFormatters.tokens(bucket.usage.total, format: numberFormat))
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(TokenMeterTheme.primaryText)
                .monospacedDigit(),
            at: CGPoint(x: left, y: y),
            anchor: .topLeading
        )
        context.draw(
            Text("tokens")
                .font(.system(size: 10))
                .foregroundColor(TokenMeterTheme.secondaryText),
            at: CGPoint(x: frame.maxX - 10, y: y + 5),
            anchor: .topTrailing
        )

        y += 29
        for segment in segments {
            context.fill(
                Path(ellipseIn: CGRect(x: left, y: y + 4, width: 7, height: 7)),
                with: .color(segment.color)
            )
            context.draw(
                Text(segment.label)
                    .font(.system(size: 11))
                    .foregroundColor(TokenMeterTheme.secondaryText),
                at: CGPoint(x: left + 14, y: y),
                anchor: .topLeading
            )
            context.draw(
                Text(TokenFormatters.tokens(segment.value, format: numberFormat))
                    .font(.system(size: 11))
                    .foregroundColor(TokenMeterTheme.primaryText)
                    .monospacedDigit(),
                at: CGPoint(x: frame.maxX - 10, y: y),
                anchor: .topTrailing
            )
            y += 18
        }
    }

    private func drawYAxis(
        context: inout GraphicsContext,
        maxValue: Int,
        axisWidth: CGFloat,
        plotHeight: CGFloat
    ) {
        let ticks = yAxisTickValues(maxValue: maxValue)
        for index in ticks.indices {
            let y = plotHeight * CGFloat(index) / CGFloat(max(1, ticks.count - 1))
            let anchor: UnitPoint = {
                if index == ticks.startIndex { return .topTrailing }
                if index == ticks.index(before: ticks.endIndex) { return .bottomTrailing }
                return .trailing
            }()
            context.draw(
                Text(TokenFormatters.tokens(ticks[index], format: numberFormat))
                    .font(.system(size: 10))
                    .foregroundColor(TokenMeterTheme.tertiaryText)
                    .monospacedDigit(),
                at: CGPoint(x: axisWidth, y: y),
                anchor: anchor
            )
        }
    }

    private func yAxisTickValues(maxValue: Int) -> [Int] {
        [
            maxValue,
            scaledYAxisTick(maxValue, multiplier: 0.75),
            scaledYAxisTick(maxValue, multiplier: 0.5),
            scaledYAxisTick(maxValue, multiplier: 0.25),
            0
        ]
    }

    private func scaledYAxisTick(_ value: Int, multiplier: Double) -> Int {
        guard value > 0 else { return 0 }
        return max(0, Int(Double(value) * multiplier))
    }

    private func drawXAxis(
        context: inout GraphicsContext,
        buckets: [TimeBucket],
        plotX: CGFloat,
        y: CGFloat,
        width: CGFloat,
        fallbackInterval: DateInterval
    ) {
        for tick in axisTicks(buckets: buckets, width: width, fallbackInterval: fallbackInterval) {
            let x = plotX + tick.x
            let tickRect = CGRect(x: x - 0.5, y: y, width: 1, height: 5)
            context.fill(Path(tickRect), with: .color(Color.white.opacity(0.14)))
            context.draw(
                Text(tick.title)
                    .font(.system(size: 10))
                    .foregroundColor(TokenMeterTheme.tertiaryText),
                at: CGPoint(x: x, y: y + 10),
                anchor: .top
            )
        }
    }

    private func axisTicks(buckets: [TimeBucket], width: CGFloat, fallbackInterval: DateInterval) -> [AxisTick] {
        if buckets.isEmpty {
            return fallbackAxisTicks(width: width, interval: fallbackInterval)
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
                title: axisDateTitle(for: buckets[index].start),
                x: clampedAxisX(rawX, width: width, labelWidth: labelWidth),
                width: labelWidth
            )
        }
    }

    private func fallbackAxisTicks(width: CGFloat, interval: DateInterval) -> [AxisTick] {
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
                title: axisDateTitle(for: date),
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

    private func hoveredBucket(
        at point: CGPoint,
        in size: CGSize,
        buckets: [TimeBucket],
        nonEmptyBuckets: [TimeBucket],
        chartInterval: DateInterval,
        sparseTimeline: Bool
    ) -> TimeBucket? {
        let layout = chartLayout(size: size)
        guard point.x >= layout.plotX,
              point.x <= layout.plotX + layout.plotWidth,
              point.y >= 0,
              point.y <= layout.plotHeight,
              !buckets.isEmpty else {
            return nil
        }

        let geometry = ChartBarGeometry(
            buckets: buckets,
            nonEmptyBuckets: nonEmptyBuckets,
            chartInterval: chartInterval,
            plotWidth: layout.plotWidth,
            sparseTimeline: sparseTimeline
        )
        return geometry.bucket(at: point.x - layout.plotX)
    }

    private func hoverFrame(
        for bucket: TimeBucket,
        layout: ChartLayout,
        buckets: [TimeBucket],
        chartInterval: DateInterval,
        sparseTimeline: Bool
    ) -> CGRect? {
        guard !buckets.isEmpty else { return nil }

        let geometry = ChartBarGeometry(
            buckets: buckets,
            chartInterval: chartInterval,
            plotWidth: layout.plotWidth,
            sparseTimeline: sparseTimeline
        )
        return geometry
            .hoverFrame(for: bucket, height: layout.plotHeight)?
            .offsetBy(dx: layout.plotX, dy: 0)
    }

    private func tooltipFrame(
        for bucket: TimeBucket,
        size: CGSize,
        layout: ChartLayout,
        buckets: [TimeBucket],
        chartInterval: DateInterval,
        maxValue: Int,
        sparseTimeline: Bool,
        width: CGFloat,
        height: CGFloat
    ) -> CGRect {
        let geometry = ChartBarGeometry(
            buckets: buckets,
            chartInterval: chartInterval,
            plotWidth: layout.plotWidth,
            sparseTimeline: sparseTimeline
        )
        let centerX = geometry.centerX(for: bucket).map { layout.plotX + $0 }
            ?? (layout.plotX + layout.plotWidth / 2)
        let barHeight = max(2, layout.plotHeight * CGFloat(bucket.usage.total) / CGFloat(maxValue))
        let rawX = centerX - width / 2
        let rawY = layout.plotHeight - barHeight - height - 10
        let maxX = max(0, size.width - width)
        let maxY = max(0, size.height - height)
        return CGRect(
            x: min(max(0, rawX), maxX),
            y: min(max(4, rawY), maxY),
            width: width,
            height: height
        )
    }

    private func visibleBuckets(sparseTimeline: Bool, interval rangeInterval: DateInterval, calendar: Calendar) -> [TimeBucket] {
        guard !buckets.isEmpty else { return [] }

        guard !sparseTimeline else { return buckets }
        return Aggregation.filledBuckets(
            buckets: buckets,
            range: range,
            bucket: bucketInterval,
            interval: rangeInterval,
            maxCount: maxVisibleBucketCount(for: bucketInterval),
            calendar: calendar
        )
    }

    private func usesSparseTimeline(interval: DateInterval, calendar: Calendar) -> Bool {
        estimatedBucketCount(interval: interval, calendar: calendar) > 2_000
    }

    private func estimatedBucketCount(interval: DateInterval, calendar: Calendar) -> Int {
        let start = bucketInterval.start(for: interval.start, calendar: calendar)
        let end = bucketInterval.start(for: interval.end, calendar: calendar)
        var current = start
        var count = 0

        while current <= end && count <= 2_001 {
            count += 1
            guard let next = bucketInterval.nextStart(after: current, calendar: calendar),
                  next > current else {
                break
            }
            current = next
        }

        return count
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

    private func drawLegend(context: inout GraphicsContext, y: CGFloat) {
        var x: CGFloat = 0

        for item in legendItems {
            let width = legendWidth(for: item.title)
            let rect = CGRect(x: x, y: y, width: width, height: 24)
            context.fill(
                Path(roundedRect: rect, cornerRadius: TokenMeterTheme.compactControlRadius),
                with: .color(TokenMeterTheme.control)
            )
            context.stroke(
                Path(roundedRect: rect, cornerRadius: TokenMeterTheme.compactControlRadius),
                with: .color(TokenMeterTheme.subtleBorder),
                lineWidth: 1
            )
            context.fill(
                Path(roundedRect: CGRect(x: x + 8, y: y + 8, width: 12, height: 8), cornerRadius: 2),
                with: .color(item.color)
            )
            context.draw(
                Text(item.title)
                    .font(.system(size: 11))
                    .foregroundColor(TokenMeterTheme.secondaryText),
                at: CGPoint(x: x + 26, y: y + 12),
                anchor: .leading
            )
            x += width + 10
        }
    }

    private var legendItems: [(title: String, color: Color)] {
        switch mode {
        case .bySource:
            [
                ("Codex", sourceColor(.codex)),
                ("Claude Code", sourceColor(.claude))
            ]
        case .byTokenKind:
            [
                ("Input", componentColor(.input)),
                ("Cache", componentColor(.cache)),
                ("Output", componentColor(.output)),
                ("Reasoning", componentColor(.reasoning))
            ]
        }
    }

    private func legendWidth(for title: String) -> CGFloat {
        max(58, CGFloat(title.count) * 6.4 + 34)
    }

    private var tooltipWidth: CGFloat {
        numberFormat == .full ? 246 : 196
    }

    private func tooltipHeight(segmentCount: Int) -> CGFloat {
        CGFloat(76 + segmentCount * 18)
    }

    private func chartSegments(for bucket: TimeBucket) -> [ChartSegment] {
        switch mode {
        case .bySource:
            let codex = bucket.sourceUsage[.codex]?.total ?? 0
            let claude = bucket.sourceUsage[.claude]?.total ?? 0
            return [
                ChartSegment(label: "Codex", value: codex, color: sourceColor(.codex)),
                ChartSegment(label: "Claude Code", value: claude, color: sourceColor(.claude))
            ].filter { $0.value > 0 }
        case .byTokenKind(let source):
            return bucket.usage.displayComponents(source: source).map { component in
                ChartSegment(
                    label: component.kind.rawValue,
                    value: component.value,
                    color: componentColor(component.kind)
                )
            }
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
        let scaled = nice * magnitude
        guard scaled.isFinite, scaled < Double(Int.max) else {
            return Int.max
        }
        return max(1, Int(scaled))
    }

    private func axisDateTitle(for date: Date) -> String {
        Self.dateFormatterCache.string(from: date, dateFormat: axisDateFormat)
    }

    private var axisDateFormat: String {
        switch bucketInterval {
        case .minute, .fiveMinutes, .tenMinutes, .twentyMinutes, .thirtyMinutes, .hour:
            return "HH:mm"
        case .day:
            switch range {
            case .today, .yesterday, .last30Minutes, .last1Hour, .last3Hours, .last6Hours, .last8Hours, .last12Hours, .last24Hours:
                return "HH:mm"
            case .last7Days:
                return "EEE d"
            case .last30Days, .last3Months, .last6Months, .last12Months, .all:
                return "MMM d"
            }
        case .week:
            return "MMM d"
        case .month:
            switch range {
            case .last3Months, .last6Months, .last12Months, .all:
                return "MMM yyyy"
            default:
                return "MMM"
            }
        }
    }

    private static let dateFormatterCache = ChartDateFormatterCache()
}

private struct AxisTick: Identifiable {
    let id: Int
    let title: String
    let x: CGFloat
    let width: CGFloat
}

private struct ChartLayout {
    let axisWidth: CGFloat
    let xAxisHeight: CGFloat
    let legendHeight: CGFloat
    let plotX: CGFloat
    let plotWidth: CGFloat
    let plotHeight: CGFloat
}

private struct ChartSegment {
    let label: String
    let value: Int
    let color: Color
}

private final class ChartDateFormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var formatters: [String: DateFormatter] = [:]

    func string(from date: Date, dateFormat: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        let formatter: DateFormatter
        if let cached = formatters[dateFormat] {
            formatter = cached
        } else {
            let created = DateFormatter()
            created.locale = Locale(identifier: "en_US_POSIX")
            created.dateFormat = dateFormat
            formatters[dateFormat] = created
            formatter = created
        }

        return formatter.string(from: date)
    }
}
