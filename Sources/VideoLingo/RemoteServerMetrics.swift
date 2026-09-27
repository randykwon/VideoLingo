import Foundation
import Observation

/// 외부 STTLMMServer로 오간 요청의 성능을 서버별로 모아 둡니다.
/// 대량 번역 중 어느 서버가 느린지, 실제로 분산되고 있는지 화면에서 확인하는 용도입니다.
@MainActor
@Observable
final class RemoteServerMetrics {
    static let shared = RemoteServerMetrics()

    enum Kind: String, CaseIterable {
        case stt, translation

        var title: String {
            switch self {
            case .stt: String(localized: "STT")
            case .translation: String(localized: "번역")
            }
        }
    }

    /// 서버 한 대의 누적 기록입니다.
    struct ServerStats: Identifiable {
        let id: UUID
        var name: String
        var inFlight: [Kind: Int] = [:]
        var requests: [Kind: Int] = [:]
        var failures: [Kind: Int] = [:]
        /// 클라이언트가 측정한 왕복 시간 합계(초)입니다. 업로드·대기·처리가 모두 포함됩니다.
        var roundTripSeconds: [Kind: Double] = [:]
        /// 서버가 보고한 순수 처리 시간 합계(초)입니다. 왕복과의 차이가 전송·대기 비용입니다.
        var serverSeconds: [Kind: Double] = [:]
        var uploadedBytes: Int64 = 0
        /// 전사한 오디오 길이 합계(초)입니다. 처리량 계산에 씁니다.
        var audioSeconds: Double = 0
        var translatedTexts: Int = 0
        var lastRealtimeFactor: Double?
        var lastError: String?
        var lastFinishedAt: Date?
        /// 연속 실패 횟수입니다. 성공하면 0으로 돌아갑니다.
        var consecutiveFailures = 0
        /// 현재 진행 중인 요청이 시작된 시각입니다. 응답이 오지 않는 상황을 잡는 데 씁니다.
        var inFlightSince: [Kind: Date] = [:]

        var totalRequests: Int { Kind.allCases.reduce(0) { $0 + (requests[$1] ?? 0) } }
        var totalFailures: Int { Kind.allCases.reduce(0) { $0 + (failures[$1] ?? 0) } }
        var totalInFlight: Int { Kind.allCases.reduce(0) { $0 + (inFlight[$1] ?? 0) } }

        /// 오디오 길이 ÷ 왕복 시간. 서버가 보고하는 배속과 달리 전송 비용까지 반영한 체감 속도입니다.
        var effectiveRealtimeFactor: Double? {
            let wall = roundTripSeconds[.stt] ?? 0
            guard wall > 0.01, audioSeconds > 0 else { return nil }
            return audioSeconds / wall
        }

        func averageRoundTrip(_ kind: Kind) -> Double? {
            let count = requests[kind] ?? 0
            guard count > 0, let total = roundTripSeconds[kind] else { return nil }
            return total / Double(count)
        }

        /// 왕복 시간 중 서버 처리가 아닌 부분(전송·큐 대기)의 비율입니다.
        func overheadRatio(_ kind: Kind) -> Double? {
            guard let wall = roundTripSeconds[kind], wall > 0.01 else { return nil }
            let server = serverSeconds[kind] ?? 0
            return max(0, min(1, (wall - server) / wall))
        }
    }

    private(set) var stats: [UUID: ServerStats] = [:]
    private(set) var startedAt: Date?

    var orderedStats: [ServerStats] {
        stats.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var hasRecords: Bool { stats.values.contains { $0.totalRequests > 0 || $0.totalInFlight > 0 } }

    // MARK: 기록

    func requestStarted(worker: RemoteWorkerConfiguration, kind: Kind) {
        if startedAt == nil { startedAt = .now }
        var entry = stats[worker.id] ?? ServerStats(id: worker.id, name: worker.name)
        entry.name = worker.name.isEmpty ? (worker.baseURL.host() ?? "STTLMMServer") : worker.name
        entry.inFlight[kind, default: 0] += 1
        if entry.inFlightSince[kind] == nil { entry.inFlightSince[kind] = .now }
        stats[worker.id] = entry
        evaluateHealth()
    }

    func requestFinished(
        worker: RemoteWorkerConfiguration,
        kind: Kind,
        roundTrip: Double,
        serverSeconds: Double?,
        uploadedBytes: Int64 = 0,
        audioSeconds: Double? = nil,
        translatedTexts: Int = 0,
        realtimeFactor: Double? = nil,
        failure: String? = nil
    ) {
        var entry = stats[worker.id] ?? ServerStats(id: worker.id, name: worker.name)
        entry.inFlight[kind] = max(0, (entry.inFlight[kind] ?? 0) - 1)
        entry.requests[kind, default: 0] += 1
        entry.roundTripSeconds[kind, default: 0] += roundTrip
        if let serverSeconds { entry.serverSeconds[kind, default: 0] += serverSeconds }
        entry.uploadedBytes += uploadedBytes
        if let audioSeconds { entry.audioSeconds += audioSeconds }
        entry.translatedTexts += translatedTexts
        if let realtimeFactor { entry.lastRealtimeFactor = realtimeFactor }
        if let failure {
            entry.failures[kind, default: 0] += 1
            entry.lastError = failure
            entry.consecutiveFailures += 1
        } else {
            entry.consecutiveFailures = 0
            entry.lastError = nil
        }
        if (entry.inFlight[kind] ?? 0) == 0 { entry.inFlightSince[kind] = nil }
        entry.lastFinishedAt = .now
        stats[worker.id] = entry
        evaluateHealth()
    }

    func reset() {
        stats.removeAll()
        startedAt = nil
        warnings = []
        acknowledged = []
    }

    // MARK: 이상 감지

    enum Severity { case failing, stalled, slow }

    struct HealthWarning: Identifiable, Equatable {
        let id: UUID
        let serverName: String
        let severity: Severity
        let reasons: [String]
        /// 같은 상황에서 경고를 반복해 띄우지 않도록 쓰는 서명입니다.
        let signature: String
    }

    private(set) var warnings: [HealthWarning] = []
    private var acknowledged: Set<String> = []

    /// 아직 사용자가 확인하지 않은 경고 중 가장 심각한 하나입니다. 화면은 이것만 띄웁니다.
    var pendingWarning: HealthWarning? {
        warnings
            .filter { !acknowledged.contains($0.signature) }
            .min { severityRank($0.severity) < severityRank($1.severity) }
    }

    func acknowledge(_ warning: HealthWarning) {
        acknowledged.insert(warning.signature)
    }

    private func severityRank(_ severity: Severity) -> Int {
        switch severity {
        case .failing: 0
        case .stalled: 1
        case .slow: 2
        }
    }

    /// 실패·무응답·지연을 판정합니다. 오디오 길이에 따라 정상 소요가 크게 달라서 기준을 넉넉히 둡니다.
    func evaluateHealth() {
        let now = Date.now
        var found: [HealthWarning] = []
        for entry in stats.values {
            var reasons: [String] = []
            var severity: Severity?

            if entry.consecutiveFailures >= 3 {
                severity = .failing
                reasons.append(String(localized: "요청이 연속 \(entry.consecutiveFailures)회 실패했습니다."))
                if let error = entry.lastError { reasons.append(error) }
            }

            // 응답이 오지 않는 경우. STT는 긴 오디오에서 수 분이 정상이라 기준을 크게 잡습니다.
            for kind in Kind.allCases {
                guard (entry.inFlight[kind] ?? 0) > 0, let since = entry.inFlightSince[kind] else { continue }
                let waited = now.timeIntervalSince(since)
                let limit: TimeInterval = kind == .stt ? 1800 : 300
                if waited > limit {
                    if severity == nil { severity = .stalled }
                    reasons.append(String(localized: "\(kind.title) 요청이 \(Int(waited / 60))분째 응답이 없습니다."))
                }
            }

            // 체감 속도가 실시간의 2배 미만이면 전송이나 서버가 막혀 있다고 봅니다.
            if severity == nil, (entry.requests[.stt] ?? 0) >= 2, let factor = entry.effectiveRealtimeFactor, factor < 2 {
                severity = .slow
                reasons.append(String(localized: "체감 처리 속도가 실시간의 \(String(format: "%.1f", factor))배로 느립니다."))
            }
            if severity == nil, (entry.requests[.translation] ?? 0) >= 3,
               let overhead = entry.overheadRatio(.translation), overhead > 0.8 {
                severity = .slow
                reasons.append(String(localized: "번역 요청 시간의 \(Int(overhead * 100))%가 전송·대기에 쓰이고 있습니다."))
            }

            guard let severity, !reasons.isEmpty else { continue }
            // 서명에 실패 횟수를 넣어, 상황이 더 나빠지면 다시 알립니다.
            let signature = "\(entry.id)-\(severity)-\(entry.consecutiveFailures)-\(entry.totalFailures)"
            found.append(
                HealthWarning(
                    id: entry.id,
                    serverName: entry.name,
                    severity: severity,
                    reasons: reasons,
                    signature: signature
                )
            )
        }
        warnings = found
    }

    // MARK: 합계

    var totalRequests: Int { stats.values.reduce(0) { $0 + $1.totalRequests } }
    var totalFailures: Int { stats.values.reduce(0) { $0 + $1.totalFailures } }
    var totalInFlight: Int { stats.values.reduce(0) { $0 + $1.totalInFlight } }
    var totalUploadedBytes: Int64 { stats.values.reduce(0) { $0 + $1.uploadedBytes } }
    var totalAudioSeconds: Double { stats.values.reduce(0) { $0 + $1.audioSeconds } }
    var totalTranslatedTexts: Int { stats.values.reduce(0) { $0 + $1.translatedTexts } }
}
