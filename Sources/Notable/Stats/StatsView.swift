import Charts
import SwiftUI

/// Loads recordings and turns them into usage statistics via the pure
/// `UsageMetrics`. All aggregation lives in `UsageMetrics`; this only fetches,
/// maps store rows to `UsageRow`, and recomputes when the period or the assumed
/// typing speed changes.
@MainActor
final class StatsModel: ObservableObject {
    private static let zero = UsageTotals(
        dictationCount: 0, dictationWords: 0, dictationSeconds: 0,
        savedSeconds: 0, meetingCount: 0, meetingSeconds: 0)

    /// Lifetime aggregate — the footnote numbers ("insgesamt …").
    @Published private(set) var allTotals = StatsModel.zero
    /// The selected period (today / this week / …) — the headline numbers.
    @Published private(set) var periodTotals = StatsModel.zero
    /// The period before it — the baseline every delta chip compares against.
    @Published private(set) var previousTotals = StatsModel.zero
    /// A contiguous run of periods ending with the current one, zero-filled.
    @Published private(set) var series: [UsageBucket] = []
    /// Summarization spend — lifetime, the selected period, and its baseline.
    /// Separate from `UsageTotals` because these rows are provider round-trips,
    /// not recordings: a single meeting can cost several (a failed summary and
    /// its retry), and some recordings cost none at all.
    @Published private(set) var allLLM = LLMTotals()
    @Published private(set) var periodLLM = LLMTotals()
    @Published private(set) var previousLLM = LLMTotals()
    @Published private(set) var firstRecording: Date?
    @Published private(set) var isEmpty = true
    // Issue #5 — all derived in `recompute` from the rows already in memory, so
    // the detail section costs no extra SQLite round-trip.
    @Published private(set) var heatmap: [[UsageTotals]] = []
    @Published private(set) var engines: [(engine: String, totals: UsageTotals)] = []
    @Published private(set) var latencies: [(engine: String, stats: UsageMetrics.LatencyStats?)] = []
    @Published private(set) var apps: [(sourceApp: String, totals: UsageTotals)] = []
    @Published private(set) var wordsPerMinute: Double = 0
    @Published private(set) var streak = 0

    private var rows: [UsageRow] = []
    private var llmRows: [LLMUsageRow] = []
    private let calendar = Calendar.current

    /// Fetches every recording once and caches the mapped rows.
    func load() async {
        let raw = (try? await RecordingStore.shared.usageRows(from: .distantPast, to: Date())) ?? []
        rows = raw.map {
            UsageRow(
                kind: $0.kind == .dictation ? .dictation : .meeting,
                startedAt: $0.startedAt,
                endedAt: $0.endedAt,
                wordCount: $0.wordCount,
                engine: $0.engine,
                latencyMs: $0.latencyMs,
                sourceApp: $0.sourceApp)
        }
        let llm = (try? await RecordingStore.shared.llmUsageRows(from: .distantPast, to: Date())) ?? []
        llmRows = llm.map {
            LLMUsageRow(at: $0.createdAt, tokens: $0.totalTokens, costUSD: $0.costUSD, billed: $0.billed)
        }
        firstRecording = rows.map(\.startedAt).min()
        isEmpty = rows.isEmpty
    }

    /// Recomputes totals, the current/previous period and the chart series. Pure and
    /// cheap — safe to call on every granularity/WPM change.
    func recompute(granularity: Granularity, typingWPM: Double, span: Int) {
        let now = Date()
        allTotals = UsageMetrics.totals(rows, typingWPM: typingWPM)
        series = UsageMetrics.contiguous(
            UsageMetrics.buckets(rows, by: granularity, calendar: calendar, typingWPM: typingWPM),
            by: granularity, calendar: calendar, endingAt: now, count: span)

        let component = UsageMetrics.calendarComponent(granularity)
        periodTotals = totals(inPeriodOf: now, component: component, typingWPM: typingWPM)
        allLLM = UsageMetrics.llmTotals(llmRows)
        periodLLM = llmTotals(inPeriodOf: now, component: component)
        if let previous = calendar.date(byAdding: component, value: -1, to: now) {
            previousTotals = totals(inPeriodOf: previous, component: component, typingWPM: typingWPM)
            previousLLM = llmTotals(inPeriodOf: previous, component: component)
        } else {
            previousTotals = Self.zero
            previousLLM = LLMTotals()
        }

        heatmap = UsageMetrics.weekdayHourMatrix(rows, calendar: calendar, typingWPM: typingWPM)
        engines = UsageMetrics.engineTotals(rows, typingWPM: typingWPM)
        // One entry per engine actually seen, `nil` where there is not enough to
        // report — the card prints "zu wenig Daten" rather than a fake p95.
        latencies = engines
            .filter { $0.engine != UsageMetrics.unknownKey }
            .map { (engine: $0.engine, stats: UsageMetrics.latency(rows, by: $0.engine)) }
        apps = UsageMetrics.appTotals(rows, typingWPM: typingWPM)
        wordsPerMinute = UsageMetrics.wordsPerMinute(rows)
        streak = UsageMetrics.streak(
            UsageMetrics.buckets(rows, by: .day, calendar: calendar, typingWPM: typingWPM),
            today: now,
            calendar: calendar)
    }

    /// The calendar the detail cards label their axes with — the same one the
    /// buckets were computed in, so the two can never disagree about Monday.
    var displayCalendar: Calendar { calendar }

    private func totals(inPeriodOf date: Date, component: Calendar.Component, typingWPM: Double) -> UsageTotals {
        guard let interval = calendar.dateInterval(of: component, for: date) else { return Self.zero }
        return UsageMetrics.totals(rows.filter { interval.contains($0.startedAt) }, typingWPM: typingWPM)
    }

    private func llmTotals(inPeriodOf date: Date, component: Calendar.Component) -> LLMTotals {
        guard let interval = calendar.dateInterval(of: component, for: date) else { return LLMTotals() }
        return UsageMetrics.llmTotals(llmRows.filter { interval.contains($0.at) })
    }
}

struct StatsView: View {
    @StateObject private var model = StatsModel()
    @AppStorage("typingWPM") private var typingWPM = 40.0
    @State private var granularity: Granularity = .week
    @State private var showDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if model.isEmpty {
                    emptyState
                } else {
                    hero
                    tiles
                    wordsChart
                    meetingsChart
                    details
                }
                typingSpeedControl
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.windowBackground)
        .frame(minWidth: 620, minHeight: 600)
        .task { await reload() }
        .onChange(of: granularity) { _, _ in recompute() }
        .onChange(of: typingWPM) { _, _ in
            recompute()
            // The menu-bar line rests on the same assumption.
            AppContainer.shared.usage.refreshSoon()
        }
    }

    private func reload() async {
        await model.load()
        recompute()
    }

    private func recompute() {
        model.recompute(granularity: granularity, typingWPM: typingWPM, span: granularity.chartSpan)
    }

    // MARK: Header — title plus the one filter row, scoping everything below it

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Statistik")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textEmphasis)
                Text("Was Notable für dich erledigt hat.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSubtle)
            }
            Spacer(minLength: 16)
            CalSegmented(
                options: [(.day, "Tag"), (.week, "Woche"), (.month, "Monat"), (.year, "Jahr")],
                selection: $granularity)
                .frame(width: 248)
        }
    }

    // MARK: Details — collapsed by default

    /// Deliberately in its own collapsed section rather than added to the main
    /// column: the window leads with one number, and four more charts above the
    /// fold would bury it.
    private var details: some View {
        DisclosureGroup(isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: 12) {
                HeatmapCard(matrix: model.heatmap, calendar: model.displayCalendar)
                EngineUsageCard(totals: model.engines)
                EnginePerformanceCard(stats: model.latencies, wordsPerMinute: model.wordsPerMinute)
                TargetAppsCard(totals: model.apps)
            }
            .padding(.top, 10)
        } label: {
            Text("Details")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textEmphasis)
        }
    }

    // MARK: Hero — the one number the window leads with

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Zeit gespart · \(granularity.periodLabel)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSubtle)
                    // Proportional figures on purpose: tabular digits look loose at
                    // display size (they are for columns that must align).
                    Text(Self.duration(model.periodTotals.savedSeconds))
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(Theme.textEmphasis)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    DeltaChip(
                        delta: UsageMetrics.delta(
                            current: model.periodTotals.savedSeconds,
                            previous: model.previousTotals.savedSeconds),
                        baseline: granularity.baselineLabel)
                }
                Spacer(minLength: 0)
                savedSparkline
                    .frame(width: 200, height: 62)
            }
            Divider().overlay(Theme.border)
            HStack(spacing: 6) {
                Image(systemName: "infinity")
                    .font(.system(size: 11))
                Text("Insgesamt \(Self.duration(model.allTotals.savedSeconds)) gespart\(sinceSuffix)")
                // A line, not a chart: a streak is one number and deserves no
                // more room than that.
                if model.streak > 1 {
                    Text("·")
                    Image(systemName: "flame")
                        .font(.system(size: 11))
                    Text("\(model.streak) Tage in Folge")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSubtle)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Theme.chartPrimary.opacity(0.13), Theme.chartPrimary.opacity(0.02)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1))
    }

    private var sinceSuffix: String {
        guard let first = model.firstRecording else { return "" }
        return " · seit \(first.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    /// Saved time across the visible periods. Trend only — no axes, no labels; the
    /// numbers next to it carry the values.
    private var savedSparkline: some View {
        Chart {
            ForEach(model.series) { bucket in
                AreaMark(
                    x: .value("Zeitraum", bucket.id),
                    y: .value("Gespart", bucket.savedSeconds / 60))
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(
                    colors: [Theme.chartPrimary.opacity(0.28), Theme.chartPrimary.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom))
                LineMark(
                    x: .value("Zeitraum", bucket.id),
                    y: .value("Gespart", bucket.savedSeconds / 60))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(Theme.chartPrimary)
            }
            if let last = model.series.last {
                PointMark(
                    x: .value("Zeitraum", last.id),
                    y: .value("Gespart", last.savedSeconds / 60))
                .symbolSize(60)
                .foregroundStyle(Theme.chartPrimary)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...max(1, model.series.map { $0.savedSeconds / 60 }.max() ?? 1))
        .chartPlotStyle { $0.padding(.vertical, 4) }
        .accessibilityLabel("Verlauf der gesparten Zeit")
    }

    // MARK: Stat tiles — period value, delta, lifetime as the caption

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 12)], spacing: 12) {
            StatTile(
                icon: "text.word.spacing",
                caption: String(localized: "Wörter diktiert"),
                value: Self.integer(model.periodTotals.dictationWords),
                delta: UsageMetrics.delta(
                    current: Double(model.periodTotals.dictationWords),
                    previous: Double(model.previousTotals.dictationWords)),
                baseline: granularity.baselineLabel,
                footnote: "insgesamt \(Self.integer(model.allTotals.dictationWords))")
            StatTile(
                icon: "waveform",
                caption: "Diktate",
                value: Self.integer(model.periodTotals.dictationCount),
                delta: UsageMetrics.delta(
                    current: Double(model.periodTotals.dictationCount),
                    previous: Double(model.previousTotals.dictationCount)),
                baseline: granularity.baselineLabel,
                footnote: model.allTotals.dictationCount > 0
                    ? "⌀ \(Self.duration(model.allTotals.dictationSeconds / Double(model.allTotals.dictationCount)))"
                    : "insgesamt 0")
            StatTile(
                icon: "person.2.wave.2",
                caption: "Meetings",
                value: Self.integer(model.periodTotals.meetingCount),
                delta: UsageMetrics.delta(
                    current: Double(model.periodTotals.meetingCount),
                    previous: Double(model.previousTotals.meetingCount)),
                baseline: granularity.baselineLabel,
                footnote: "\(Self.duration(model.periodTotals.meetingSeconds)) aufgezeichnet")
            // Only once something has actually been summarized: a tile reading
            // "0 Tokens" says nothing, and old databases have no rows at all.
            if !model.allLLM.isEmpty {
                StatTile(
                    icon: "sparkles",
                    caption: "KI-Tokens",
                    value: Self.integer(model.periodLLM.tokens),
                    delta: UsageMetrics.delta(
                        current: Double(model.periodLLM.tokens),
                        previous: Double(model.previousLLM.tokens)),
                    baseline: granularity.baselineLabel,
                    footnote: llmFootnote)
            }
        }
    }

    /// Lifetime cost under the period's token count — the money, kept apart by
    /// `llmCostLine` into what was billed and what a flat-rate plan absorbed. Falls
    /// back to the lifetime token count when no provider reported a cost.
    private var llmFootnote: String {
        let line = UsageMetrics.llmCostLine(model.allLLM)
        return line.isEmpty ? "insgesamt \(Self.integer(model.allLLM.tokens))" : line
    }

    // MARK: Charts — one series each, one axis, one hue

    private var wordsChart: some View {
        BucketChart(
            title: String(localized: "Diktierte Wörter"),
            unitLabel: String(localized: "Wörter"),
            buckets: model.series,
            granularity: granularity,
            tint: Theme.chartPrimary,
            value: { $0.dictationWords })
    }

    private var meetingsChart: some View {
        BucketChart(
            title: "Meetings",
            unitLabel: "Meetings",
            buckets: model.series,
            granularity: granularity,
            tint: Theme.chartSecondary,
            value: { $0.meetingCount })
    }

    // MARK: Typing-speed assumption

    private var typingSpeedControl: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .foregroundStyle(Theme.textMuted)
            VStack(alignment: .leading, spacing: 1) {
                Text("Tippgeschwindigkeit")
                    .foregroundStyle(Theme.textDefault)
                Text("Grundlage der gesparten Zeit: Sprechen gegen Tippen.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSubtle)
            }
            Spacer(minLength: 12)
            Stepper(value: $typingWPM, in: 20...120, step: 5) {
                Text("\(Int(typingWPM)) WPM")
                    .monospacedDigit()
                    .foregroundStyle(Theme.textEmphasis)
            }
            .fixedSize()
        }
        .font(.system(size: 13))
        .calCard(padding: 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 30))
                .foregroundStyle(Theme.chartPrimary.opacity(0.7))
            Text("Noch keine Diktate")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textEmphasis)
            Text("Halt die Diktattaste und leg los — hier erscheinen dann deine Statistiken.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSubtle)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .calCard()
    }

    // MARK: Formatting

    // Shared with the menu-bar line (`UsageMetrics.menuLine`) so the window and
    // the menu can never format the same number two different ways.
    static func integer(_ value: Int) -> String { UsageMetrics.integer(value) }
    static func duration(_ seconds: TimeInterval) -> String { UsageMetrics.duration(seconds) }
}

// MARK: - Granularity presentation

private extension Granularity {
    /// How many periods the charts show. Enough to read a trend, few enough that the
    /// bars stay above hairline width.
    var chartSpan: Int {
        switch self {
        case .day: 14
        case .week: 12
        case .month: 12
        case .year: 5
        }
    }

    var periodLabel: String {
        switch self {
        case .day: "Heute"
        case .week: "Diese Woche"
        case .month: "Diesen Monat"
        case .year: "Dieses Jahr"
        }
    }

    /// What a delta compares against, spelled out so the chip is never ambiguous.
    var baselineLabel: String {
        switch self {
        case .day: String(localized: "ggü. gestern")
        case .week: String(localized: "ggü. Vorwoche")
        case .month: String(localized: "ggü. Vormonat")
        case .year: String(localized: "ggü. Vorjahr")
        }
    }

    /// Derived from ``chartSpan`` so the caption can never claim a range the chart
    /// does not actually plot.
    var rangeLabel: String {
        switch self {
        case .day: "Letzte \(chartSpan) Tage"
        case .week: "Letzte \(chartSpan) Wochen"
        case .month: "Letzte \(chartSpan) Monate"
        case .year: "Letzte \(chartSpan) Jahre"
        }
    }

    /// Axis ticks: short. The hover readout carries the full date.
    func axisLabel(_ date: Date) -> String {
        switch self {
        case .day: date.formatted(.dateTime.day().month(.abbreviated))
        case .week: date.formatted(.dateTime.day().month(.abbreviated))
        case .month: date.formatted(.dateTime.month(.abbreviated))
        case .year: date.formatted(.dateTime.year())
        }
    }

    func hoverLabel(_ date: Date) -> String {
        switch self {
        case .day: date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .week: "Woche ab \(date.formatted(.dateTime.day().month(.abbreviated)))"
        case .month: date.formatted(.dateTime.month(.wide).year())
        case .year: date.formatted(.dateTime.year())
        }
    }
}

// MARK: - Stat tile

/// A single headline number on a card: muted icon + caption, large
/// value, an optional signed delta against the previous period, and a quiet
/// footnote for the lifetime/average context.
private struct StatTile: View {
    let icon: String
    let caption: String
    let value: String
    var delta: Double?
    var baseline: String
    var footnote: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(caption)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Theme.textSubtle)

            Text(value)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.textEmphasis)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            HStack(spacing: 6) {
                DeltaChip(delta: delta, baseline: nil)
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            .help("\(footnote) · \(baseline)")
        }
        .calCard(padding: 12)
    }
}

/// Signed change against the previous period. Up is good here (more dictated, more
/// time saved), so up is green — and the arrow + text carry the same meaning as the
/// colour, never colour alone. Renders a quiet placeholder when there is no baseline.
private struct DeltaChip: View {
    let delta: Double?
    var baseline: String?

    var body: some View {
        if let delta, delta != 0 {
            let up = delta > 0
            let tint = up ? Theme.success : Theme.danger
            HStack(spacing: 3) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
                Text(percent(delta))
                    .monospacedDigit()
                if let baseline {
                    Text(baseline)
                        .foregroundStyle(Theme.textSubtle)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .fill(tint.opacity(0.12)))
        } else {
            Text(baseline.map { "unverändert \($0)" } ?? "–")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .padding(.vertical, 2)
        }
    }

    /// Capped: past +999 % the exact figure says nothing a "≫" doesn't.
    private func percent(_ delta: Double) -> String {
        let pct = (delta * 100).rounded()
        if pct > 999 { return "+999 %" }
        return "\(pct > 0 ? "+" : "")\(Int(pct)) %"
    }
}

// MARK: - Bucket chart

/// One measure over the visible periods: capped-width bars from a single baseline,
/// one hue, hairline grid. Hovering dims the other bars and prints the exact value
/// in the card header — the values also stay readable on the y-axis, so the hover is
/// an enhancement, never the only way to read one.
private struct BucketChart: View {
    let title: String
    let unitLabel: String
    let buckets: [UsageBucket]
    let granularity: Granularity
    let tint: Color
    let value: (UsageBucket) -> Int

    @State private var hovered: Date?

    private var hoveredBucket: UsageBucket? {
        hovered.flatMap { id in buckets.first { $0.id == id } }
    }

    private var total: Int { buckets.reduce(0) { $0 + value($1) } }

    /// The one bar worth a direct label — labelling every bar is noise.
    private var peak: UsageBucket? {
        buckets.filter { value($0) > 0 }.max { value($0) < value($1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textEmphasis)
                Spacer(minLength: 12)
                Text(readout)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(hoveredBucket == nil ? Theme.textMuted : Theme.textSubtle)
                    .lineLimit(1)
            }

            GeometryReader { geo in
                chart(barWidth: barWidth(for: geo.size.width))
            }
            .frame(height: 140)
        }
        .calCard()
    }

    private var readout: String {
        if let bucket = hoveredBucket {
            return "\(granularity.hoverLabel(bucket.id)) · \(UsageMetrics.integer(value(bucket))) \(unitLabel)"
        }
        return "\(granularity.rangeLabel) · \(UsageMetrics.integer(total)) \(unitLabel)"
    }

    /// Bars stay thin: never wider than 22 pt, and never so wide that the gap between
    /// neighbours closes up.
    private func barWidth(for width: CGFloat) -> CGFloat {
        let slot = width / CGFloat(max(buckets.count, 1))
        return max(3, min(22, slot - 6))
    }

    private func chart(barWidth: CGFloat) -> some View {
        Chart {
            ForEach(buckets) { bucket in
                BarMark(
                    x: .value("Zeitraum", bucket.id, unit: UsageMetrics.calendarComponent(granularity)),
                    y: .value(unitLabel, value(bucket)),
                    width: .fixed(barWidth))
                .foregroundStyle(LinearGradient(
                    colors: [tint, tint.opacity(0.62)],
                    startPoint: .top, endPoint: .bottom))
                .opacity(hovered == nil || hovered == bucket.id ? 1 : 0.3)
                .cornerRadius(3)
                .annotation(position: .top, spacing: 4) {
                    if hovered == nil, bucket.id == peak?.id {
                        Text(UsageMetrics.integer(value(bucket)))
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSubtle)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { mark in
                AxisValueLabel {
                    if let date = mark.as(Date.self) {
                        Text(granularity.axisLabel(date))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel()
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            hovered = bucket(at: point, proxy: proxy, geo: geo)?.id
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    /// Nearest bucket to the cursor's x — a bar's hit area is its whole slot, not the
    /// few points the bar itself covers.
    private func bucket(at point: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> UsageBucket? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let x = point.x - geo[plotFrame].origin.x
        guard let date: Date = proxy.value(atX: x) else { return nil }
        return buckets.min {
            abs($0.id.timeIntervalSince(date)) < abs($1.id.timeIntervalSince(date))
        }
    }
}
