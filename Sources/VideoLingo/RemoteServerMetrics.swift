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
        stats[worker.id] = entry
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
        }
        entry.lastFinishedAt = .now
        stats[worker.id] = entry
    }

    func reset() {
        stats.removeAll()
        startedAt = nil
    }

    // MARK: 합계

    var totalRequests: Int { stats.values.reduce(0) { $0 + $1.totalRequests } }
    var totalFailures: Int { stats.values.reduce(0) { $0 + $1.totalFailures } }
    var totalInFlight: Int { stats.values.reduce(0) { $0 + $1.totalInFlight } }
    var totalUploadedBytes: Int64 { stats.values.reduce(0) { $0 + $1.uploadedBytes } }
    var totalAudioSeconds: Double { stats.values.reduce(0) { $0 + $1.audioSeconds } }
    var totalTranslatedTexts: Int { stats.values.reduce(0) { $0 + $1.translatedTexts } }
}
