import SwiftUI
import TokenMeterCore

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
                Text("Reasoning").frame(width: tokenColumnWidth, alignment: .trailing)
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
                .accessibilityValue(row.key)
                .frame(maxWidth: .infinity, alignment: .leading)
            tokenCell(row.usage.total, width: totalColumnWidth)
            if density == .regular {
                tokenCell(componentValue(.input, in: row.usage), width: tokenColumnWidth)
                tokenCell(componentValue(.cache, in: row.usage), width: tokenColumnWidth)
                tokenCell(componentValue(.output, in: row.usage), width: tokenColumnWidth)
                tokenCell(componentValue(.reasoning, in: row.usage), width: tokenColumnWidth)
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
            710
        case (.compact, .regular):
            590
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

    private func componentValue(_ kind: TokenComponentKind, in usage: TokenUsage) -> Int {
        usage.displayComponents(source: .all).first { $0.kind == kind }?.value ?? 0
    }
}
