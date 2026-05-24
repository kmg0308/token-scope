import CoreGraphics
import Foundation
import TokenMeterCore

struct ChartBarGeometry {
    var buckets: [TimeBucket]
    var nonEmptyBuckets: [TimeBucket]
    var chartInterval: DateInterval
    var plotWidth: CGFloat
    var sparseTimeline: Bool

    init(
        buckets: [TimeBucket],
        nonEmptyBuckets: [TimeBucket] = [],
        chartInterval: DateInterval,
        plotWidth: CGFloat,
        sparseTimeline: Bool
    ) {
        self.buckets = buckets
        self.nonEmptyBuckets = nonEmptyBuckets
        self.chartInterval = chartInterval
        self.plotWidth = plotWidth
        self.sparseTimeline = sparseTimeline
    }

    func barFrame(for bucket: TimeBucket, at index: Int, height: CGFloat) -> CGRect? {
        guard !buckets.isEmpty else { return nil }

        if sparseTimeline {
            let width = barWidth
            return CGRect(
                x: timelineX(for: bucket.start) - width / 2,
                y: 0,
                width: width,
                height: height
            )
        }

        let slotWidth = plotWidth / CGFloat(max(1, buckets.count))
        let width = barWidth
        return CGRect(
            x: slotWidth * CGFloat(index) + (slotWidth - width) / 2,
            y: 0,
            width: width,
            height: height
        )
    }

    func bucket(at plotX: CGFloat) -> TimeBucket? {
        guard !buckets.isEmpty else { return nil }

        if sparseTimeline {
            guard let nearest = nonEmptyBuckets.min(by: {
                abs(timelineX(for: $0.start) - plotX) < abs(timelineX(for: $1.start) - plotX)
            }) else {
                return nil
            }
            let distance = abs(timelineX(for: nearest.start) - plotX)
            return distance <= sparseHoverWidth ? nearest : nil
        }

        let slotWidth = plotWidth / CGFloat(max(1, buckets.count))
        let index = min(max(0, Int(plotX / max(1, slotWidth))), buckets.count - 1)
        return buckets[index].usage.total > 0 ? buckets[index] : nil
    }

    func hoverFrame(for bucket: TimeBucket, height: CGFloat) -> CGRect? {
        guard !buckets.isEmpty else { return nil }

        if sparseTimeline {
            let width = sparseHoverWidth
            return CGRect(
                x: timelineX(for: bucket.start) - width / 2,
                y: 0,
                width: width,
                height: height
            )
        }

        guard let index = buckets.firstIndex(where: { $0.id == bucket.id }) else {
            return nil
        }
        let slotWidth = plotWidth / CGFloat(max(1, buckets.count))
        let width = barWidth
        let centerX = slotWidth * CGFloat(index) + slotWidth / 2
        let bandWidth = min(slotWidth * 0.84, max(width + 12, width))
        return CGRect(x: centerX - bandWidth / 2, y: 0, width: bandWidth, height: height)
    }

    func centerX(for bucket: TimeBucket) -> CGFloat? {
        if sparseTimeline {
            return timelineX(for: bucket.start)
        }

        guard let index = buckets.firstIndex(where: { $0.id == bucket.id }) else {
            return nil
        }
        let slotWidth = plotWidth / CGFloat(max(1, buckets.count))
        return slotWidth * CGFloat(index) + slotWidth / 2
    }

    private var barWidth: CGFloat {
        if sparseTimeline {
            return min(10, max(2, plotWidth / CGFloat(max(80, buckets.count))))
        }

        let slotWidth = plotWidth / CGFloat(max(1, buckets.count))
        let count = buckets.count
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

    private var sparseHoverWidth: CGFloat {
        max(10, barWidth * 1.8)
    }

    private func timelineX(for date: Date) -> CGFloat {
        guard chartInterval.duration > 0 else { return plotWidth / 2 }
        let fraction = min(1, max(0, date.timeIntervalSince(chartInterval.start) / chartInterval.duration))
        return plotWidth * CGFloat(fraction)
    }
}
