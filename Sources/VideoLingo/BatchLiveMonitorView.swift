import Charts
import SwiftUI

/// 대량 번역의 STT·번역 진행을 일정 간격으로 표본화해 처리량 추이를 만듭니다.
/// 누적값의 차이로 계산하므로, 앱을 켜 둔 동안의 실제 속도를 그대로 보여 줍니다.
@MainActor
@Observable
final class BatchThroughputRecorder {
    static let shared = BatchThroughputRecorder()

    struct Sample: Identifiable {
        let id = UUID()
        let time: Date
        /// 분당 처리한 STT 청크 수입니다.
        let sttRate: Double
        /// 분당 완성한 번역 구간 수입니다.
        let translationRate: Double
    }

    /// 서버 한 대의 표본입니다. 내장 서버도 같은 단위로 넣어 나란히 비교합니다.
    struct ServerSample: Identifiable {
        let id = UUID()
        let time: Date
        let server: String
        /// 실제 시간 1분당 전사한 오디오 분량입니다. 값이 곧 체감 배속입니다.
        let sttMinutesPerMinute: Double
        /// 분당 완성한 번역 구간 수입니다.
        let translationRate: Double
    }

    static let localServerName = String(localized: "내장 서버")

    private(set) var samples: [Sample] = []
    private(set) var serverSamples: [ServerSample] = []
    private var lastSTTUnits: Double?
    private var lastTranslationUnits: Double?
    private var lastSampledAt: Date?
    private var lastServerAudioSeconds: [String: Double] = [:]
    private var lastServerTexts: [String: Double] = [:]

    /// 그래프에 나타난 서버 이름입니다. 범례와 요약에 씁니다.
    var trackedServers: [String] {
        var seen: [String] = []
        for sample in serverSamples where !seen.contains(sample.server) { seen.append(sample.server) }
        return seen
    }

    func recentRate(for server: String, stt: Bool) -> Double {
        let window = serverSamples.filter { $0.server == server }.suffix(6)
        guard !window.isEmpty else { return 0 }
        let total = window.reduce(0.0) { $0 + (stt ? $1.sttMinutesPerMinute : $1.translationRate) }
        return total / Double(window.count)
    }

    /// 최근 표본에서 계산한 평균 처리량입니다. 숫자 요약에 씁니다.
    var recentSTTRate: Double { average(\.sttRate) }
    var recentTranslationRate: Double { average(\.translationRate) }

    private func average(_ key: KeyPath<Sample, Double>) -> Double {
        let window = samples.suffix(6)
        guard !window.isEmpty else { return 0 }
        return window.reduce(0) { $0 + $1[keyPath: key] } / Double(window.count)
    }

    /// 서버별 누적값을 표본화합니다. 원격은 측정값을 그대로 쓰고,
    /// 내장 서버는 전체에서 원격 몫을 뺀 값으로 추정합니다.
    func recordPerServer(items: [BatchProcessor.Item], chunkDuration: TimeInterval) {
        let now = Date.now
        let metrics = RemoteServerMetrics.shared
        var cumulativeAudio: [String: Double] = [:]
        var cumulativeTexts: [String: Double] = [:]
        for entry in metrics.orderedStats {
            cumulativeAudio[entry.name] = entry.audioSeconds
            cumulativeTexts[entry.name] = Double(entry.translatedTexts)
        }
        // 전체 처리량에서 원격 몫을 빼 내장 서버 몫을 구합니다. 단위를 같게 맞춥니다.
        let totalAudio = items.reduce(0.0) { $0 + $1.sttProgress * Double(max($1.totalChunks, 0)) * chunkDuration }
        let totalTexts = items.reduce(0.0) { $0 + $1.translationProgress * Double(max($1.totalChunks, 0)) }
        cumulativeAudio[Self.localServerName] = max(0, totalAudio - cumulativeAudio.values.reduce(0, +))
        cumulativeTexts[Self.localServerName] = max(0, totalTexts - cumulativeTexts.values.reduce(0, +))

        defer {
            lastServerAudioSeconds = cumulativeAudio
            lastServerTexts = cumulativeTexts
        }
        guard let lastSampledAt else { return }
        let minutes = now.timeIntervalSince(lastSampledAt) / 60
        guard minutes > 0.01 else { return }
        for (server, audio) in cumulativeAudio {
            let previousAudio = lastServerAudioSeconds[server] ?? audio
            let previousTexts = lastServerTexts[server] ?? (cumulativeTexts[server] ?? 0)
            let audioMinutes = max(0, (audio - previousAudio) / 60) / minutes
            let texts = max(0, ((cumulativeTexts[server] ?? 0) - previousTexts)) / minutes
            serverSamples.append(
                ServerSample(
                    time: now,
                    server: server,
                    sttMinutesPerMinute: audioMinutes,
                    translationRate: texts
                )
            )
        }
        // 서버 수에 비례해 늘어나므로 넉넉히 두되 무한정 쌓이지 않게 자릅니다.
        if serverSamples.count > 1200 { serverSamples.removeFirst(serverSamples.count - 1200) }
    }

    func record(items: [BatchProcessor.Item]) {
        // 진행률 × 청크 수로 지금까지 처리한 양을 추정합니다.
        let sttUnits = items.reduce(0.0) { $0 + $1.sttProgress * Double(max($1.totalChunks, 0)) }
        let translationUnits = items.reduce(0.0) { $0 + $1.translationProgress * Double(max($1.totalChunks, 0)) }
        let now = Date.now
        defer {
            lastSTTUnits = sttUnits
            lastTranslationUnits = translationUnits
            lastSampledAt = now
        }
        guard let lastSTTUnits, let lastTranslationUnits, let lastSampledAt else { return }
        let minutes = now.timeIntervalSince(lastSampledAt) / 60
        guard minutes > 0.01 else { return }
        // 작업이 목록에서 빠지면 누적값이 줄어들 수 있어 음수는 0으로 처리합니다.
        let sample = Sample(
            time: now,
            sttRate: max(0, (sttUnits - lastSTTUnits) / minutes),
            translationRate: max(0, (translationUnits - lastTranslationUnits) / minutes)
        )
        samples.append(sample)
        // 최근 10분만 유지합니다.
        if samples.count > 120 { samples.removeFirst(samples.count - 120) }
    }

    func reset() {
        samples.removeAll()
        serverSamples.removeAll()
        lastSTTUnits = nil
        lastTranslationUnits = nil
        lastSampledAt = nil
        lastServerAudioSeconds.removeAll()
        lastServerTexts.removeAll()
    }
}

/// 대량 번역의 실시간 현황을 그래프로 보여 줍니다.
struct BatchLiveMonitorView: View {
    @Environment(BatchProcessor.self) private var processor
    @State private var recorder = BatchThroughputRecorder.shared
    @State private var metrics = RemoteServerMetrics.shared

    /// 화면에 나눠 보여 줄 단계입니다. 순서가 곧 파이프라인 순서입니다.
    private enum Stage: String, CaseIterable, Plottable {
        case waiting, extracting, transcribing, translating, refining, completed, failed

        var primitivePlottable: String { rawValue }
        init?(primitivePlottable: String) { self.init(rawValue: primitivePlottable) }

        var title: String {
            switch self {
            case .waiting: String(localized: "대기")
            case .extracting: String(localized: "추출")
            case .transcribing: String(localized: "STT")
            case .translating: String(localized: "번역")
            case .refining: String(localized: "개선")
            case .completed: String(localized: "완료")
            case .failed: String(localized: "실패")
            }
        }

        var color: Color {
            switch self {
            case .waiting: .gray.opacity(0.4)
            case .extracting: .teal
            case .transcribing: .blue
            case .translating: .purple
            case .refining: .indigo
            case .completed: .green
            case .failed: .orange
            }
        }
    }

    private func count(_ stage: Stage) -> Int {
        processor.items.filter { item in
            switch stage {
            case .waiting: item.status == .queued && !item.isProcessing
            case .extracting: item.status == .extracting
            case .transcribing: item.status == .transcribing
            case .translating: item.status == .translating || item.status == .synthesizing
            case .refining: item.status == .refining
            case .completed: item.status == .completed
            case .failed: item.status == .failed || item.status == .cancelled
            }
        }.count
    }

    private var stageCounts: [(stage: Stage, count: Int)] {
        Stage.allCases.map { ($0, count($0)) }.filter { $0.1 > 0 }
    }

    /// 원격이 처리 중인 건수와, 그 밖에 로컬에서 도는 건수입니다.
    private var distribution: [(label: String, value: Int, color: Color)] {
        var rows: [(String, Int, Color)] = []
        let remoteTotal = metrics.totalInFlight
        let activeTotal = Stage.allCases
            .filter { [.extracting, .transcribing, .translating, .refining].contains($0) }
            .reduce(0) { $0 + count($1) }
        rows.append((String(localized: "내장 서버"), max(0, activeTotal - remoteTotal), .blue))
        for entry in metrics.orderedStats where entry.totalInFlight > 0 || entry.totalRequests > 0 {
            rows.append((entry.name, entry.totalInFlight, .green))
        }
        return rows.map { (label: $0.0, value: $0.1, color: $0.2) }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                header

                if !stageCounts.isEmpty {
                    stageBar
                }

                if recorder.samples.count >= 2 {
                    throughputChart
                } else {
                    Text("처리량 그래프는 잠시 뒤부터 표시됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                distributionChart
            }
            .padding(4)
        } label: {
            Label("실시간 처리 현황", systemImage: "chart.line.uptrend.xyaxis")
        }
        .task {
            // 5초마다 표본을 남겨 추이를 만듭니다.
            while !Task.isCancelled {
                recorder.record(items: processor.items)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            metric(String(localized: "완료"), "\(count(.completed))/\(processor.items.count)")
            metric(String(localized: "STT 청크/분"), String(format: "%.1f", recorder.recentSTTRate), tint: .blue)
            metric(String(localized: "번역 구간/분"), String(format: "%.1f", recorder.recentTranslationRate), tint: .purple)
            if metrics.totalFailures > 0 {
                metric(String(localized: "원격 실패"), "\(metrics.totalFailures)", tint: .orange)
            }
            Spacer()
        }
        .font(.callout.monospacedDigit())
    }

    private func metric(_ title: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).foregroundStyle(tint ?? .primary)
        }
    }

    /// 단계별 항목 수를 한 줄 누적 막대로 보여 줍니다. 어디에 몰려 있는지 바로 보입니다.
    private var stageBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Chart(stageCounts, id: \.stage) { row in
                BarMark(x: .value("건수", row.count), stacking: .normalized)
                    .foregroundStyle(row.stage.color)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            HStack(spacing: 10) {
                ForEach(stageCounts, id: \.stage) { row in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(row.stage.color)
                            .frame(width: 7, height: 7)
                        Text("\(row.stage.title) \(row.count)")
                    }
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var throughputChart: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("처리량 (최근 10분)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Chart {
                ForEach(recorder.samples) { sample in
                    AreaMark(
                        x: .value("시각", sample.time),
                        y: .value("STT 청크/분", sample.sttRate),
                        series: .value("항목", "STT")
                    )
                    .foregroundStyle(Color.blue.opacity(0.28))
                    LineMark(
                        x: .value("시각", sample.time),
                        y: .value("STT 청크/분", sample.sttRate),
                        series: .value("항목", "STT")
                    )
                    .foregroundStyle(.blue)
                }
                ForEach(recorder.samples) { sample in
                    LineMark(
                        x: .value("시각", sample.time),
                        y: .value("번역 구간/분", sample.translationRate),
                        series: .value("항목", "번역")
                    )
                    .foregroundStyle(.purple)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .frame(height: 96)
            HStack(spacing: 12) {
                legend("STT", .blue)
                legend(String(localized: "번역"), .purple)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 10, height: 3)
            Text(title)
        }
    }

    /// 지금 어디서 처리하고 있는지(내장 서버 vs 원격) 막대로 보여 줍니다.
    private var distributionChart: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("처리 위치")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Chart(distribution, id: \.label) { row in
                BarMark(
                    x: .value("건수", row.value),
                    y: .value("위치", row.label)
                )
                .foregroundStyle(row.color)
                .annotation(position: .trailing) {
                    Text("\(row.value)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(max(1, distribution.count)) * 24 + 8)
        }
    }
}
