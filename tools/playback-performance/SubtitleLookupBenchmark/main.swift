import Foundation
let job = UUID()
let segments = (0..<20_000).map { i in TranscriptSegment(jobID: job, chunkIndex: i, startTime: Double(i * 3), endTime: Double(i * 3 + 1), text: "subtitle") }
let index = PlaybackSubtitleIndex(segments)
let probes = (0..<5_000).map { Double(($0 * 7919) % 60_000) + 0.5 }
var linearChecksum = 0
var indexedChecksum = 0
let start = ContinuousClock.now
for time in probes { linearChecksum += segments.firstIndex { time >= $0.startTime && time < $0.endTime } ?? -1 }
let linear = start.duration(to: .now)
let second = ContinuousClock.now
for time in probes { indexedChecksum += index.segmentIndex(at: time) ?? -1 }
let indexed = second.duration(to: .now)
precondition(linearChecksum == indexedChecksum)
print("20,000 subtitles / 5,000 mixed seeks and gaps: linear=\(linear), indexed=\(indexed); checksums match")
