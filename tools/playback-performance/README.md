# Multiple-player performance checks

The app keeps independent `AVPlayer` instances per window. The changes below reduce repeated work without reducing video resolution or pausing other windows.

- Create the playback time observer only after a video is opened; settings and empty windows need no playback clock.
- Attach an `AVPlayerItemVideoOutput` only while screen-text OCR is enabled.
- Release the decoder, time observer, OCR/effect tasks and XPC monitoring when an idle player window closes. Active AI jobs retain their monitor until a terminal status arrives.
- Index subtitle intervals and cache visible text so gaps and seeks do not repeatedly scan the entire transcript. Preserve cue gaps, overlap priority, and end-exclusive timestamps.
- Isolate clock-driven transport updates from the video surface and transcript inspector.
- Coalesce picture-adjustment changes for 100 ms and share a Core Image context without intermediate frame caching.
- Check AI health every 15 seconds during idle playback (3 seconds during processing), and avoid holding window models across monitoring sleeps.
- Serialize OCR across windows on a separate actor. Reject results from a replaced video or a disabled OCR/translation session.
- Mark XPC error callbacks explicitly `@Sendable` before dispatching UI changes to the main actor. This avoids actor-isolation traps when a service connection fails.

## Subtitle benchmark

From the repository root:

```sh
xcrun swiftc -O Sources/VideoLingoCore/Models.swift Sources/VideoLingoCore/TranscriptCoverage.swift tools/playback-performance/SubtitleLookupBenchmark/main.swift -o /tmp/videolingo-subtitle-benchmark
/tmp/videolingo-subtitle-benchmark
```

Measured on the development machine on 2026-10-26: 20,000 subtitles and 5,000 mixed seek/gap lookups took 291 ms using linear lookup and 0.98 ms using the interval index, with matching results. This measures lookup cost only, not total app speed or GPU performance.

Regression tests in `VideoLingoCoreTests` cover empty transcripts, exact boundaries, gaps within cue-based segments, out-of-order segments, overlaps, backward seeks, invalid times, and a 10,000-segment transcript.

## Three-player smoke check

After building the Release app, run on Apple Silicon with a local video at least 12 seconds long:

```sh
python3 tools/playback-performance/run_smoke.py /path/to/video.mp4
```

This compiles the actual app sources into an independent test process, exercises three AVPlayer timelines, changes effects on one player, seeks another, closes the third and checks that its model and current item are released. It does not open visible windows or measure rendered frame drops. The test process has its own preferences domain; the fixture's media path must not have active AI work associated with it.

Verified on 2026-10-26 using a generated 12-second 1280×720 H.264 fixture: all three timelines reached approximately 3.77 seconds after four seconds; independent effect/seek and closed-model release checks passed. All 32 core tests passed in a temporary Swift Package test configuration. The existing Xcode Release test action cannot import its core module with `@testable` because Release does not enable testability; the Release application build is checked separately.

The standalone process intentionally has no embedded XPC service, which also exercises the service-error callback path.

4K/HDR frame drops, GPU load, and overall CPU/RAM savings still require profiling visible windows with representative media. No automatic resolution reduction or frame-rate cap was introduced.
