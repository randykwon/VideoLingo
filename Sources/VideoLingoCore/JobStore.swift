import Foundation
import SQLite3

public final class JobStore: @unchecked Sendable {
    private let db: OpaquePointer
    private let lock = NSLock()
    private let maximumBusyRetries = 6

    public init(url: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection else {
            throw StoreError.openFailed
        }
        db = connection
        sqlite3_busy_timeout(db, 10_000)
        try execute("PRAGMA foreign_keys=ON;")
        try configureJournalMode()
        try execute("PRAGMA synchronous=NORMAL;")
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    public func createJob(id: UUID, mediaURL: URL, options: ProcessingOptions) throws {
        let optionData = try WireCodec.encode(options)
        try withStatement("""
            INSERT INTO jobs(id, media_url, options, status, progress, current_chunk, total_chunks, message, updated_at)
            VALUES(?, ?, ?, ?, 0, 0, 0, ?, ?)
            ON CONFLICT(id) DO UPDATE SET media_url=excluded.media_url, options=excluded.options, updated_at=excluded.updated_at;
            """) { statement in
            bind(id.uuidString, at: 1, to: statement)
            bind(mediaURL.absoluteString, at: 2, to: statement)
            bind(optionData, at: 3, to: statement)
            bind(JobStatus.queued.rawValue, at: 4, to: statement)
            bind("대기 중", at: 5, to: statement)
            bind(Date.now.timeIntervalSince1970, at: 6, to: statement)
            try step(statement)
        }
    }

    public func save(snapshot: JobSnapshot) throws {
        try withStatement("""
            UPDATE jobs SET status=?, progress=?, current_chunk=?, total_chunks=?, stt_progress=?, translation_progress=?,
                last_transcript_text=?, last_translation_text=?, message=?, error=?, updated_at=?, refinement_pass=?,
                refinement_progress=?, refinement_revision=?, refinement_improvements=? WHERE id=?;
            """) { statement in
            bind(snapshot.status.rawValue, at: 1, to: statement)
            bind(snapshot.progress, at: 2, to: statement)
            bind(snapshot.currentChunk, at: 3, to: statement)
            bind(snapshot.totalChunks, at: 4, to: statement)
            bind(snapshot.sttProgress, at: 5, to: statement)
            bind(snapshot.translationProgress, at: 6, to: statement)
            bind(snapshot.lastTranscriptText, at: 7, to: statement)
            bind(snapshot.lastTranslationText, at: 8, to: statement)
            bind(snapshot.message, at: 9, to: statement)
            bind(snapshot.error, at: 10, to: statement)
            bind(snapshot.updatedAt.timeIntervalSince1970, at: 11, to: statement)
            bind(snapshot.refinementPass, at: 12, to: statement)
            bind(snapshot.refinementProgress, at: 13, to: statement)
            bind(snapshot.refinementRevision, at: 14, to: statement)
            bind(snapshot.refinementImprovements, at: 15, to: statement)
            bind(snapshot.id.uuidString, at: 16, to: statement)
            try step(statement)
        }
    }

    public func snapshot(jobID: UUID) throws -> JobSnapshot? {
        try withStatement("""
            SELECT status, progress, current_chunk, total_chunks, stt_progress, translation_progress,
                last_transcript_text, last_translation_text, message, error, updated_at, refinement_pass,
                refinement_progress, refinement_revision, refinement_improvements FROM jobs WHERE id=?;
            """) { statement in
            bind(jobID.uuidString, at: 1, to: statement)
            guard try next(statement) == SQLITE_ROW else { return nil }
            return JobSnapshot(
                id: jobID,
                status: JobStatus(rawValue: string(statement, 0)) ?? .failed,
                progress: sqlite3_column_double(statement, 1),
                currentChunk: Int(sqlite3_column_int(statement, 2)),
                totalChunks: Int(sqlite3_column_int(statement, 3)),
                sttProgress: sqlite3_column_double(statement, 4),
                translationProgress: sqlite3_column_double(statement, 5),
                lastTranscriptText: optionalString(statement, 6),
                lastTranslationText: optionalString(statement, 7),
                message: string(statement, 8),
                error: optionalString(statement, 9),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                refinementPass: optionalInt(statement, 11),
                refinementProgress: optionalDouble(statement, 12),
                refinementRevision: optionalInt(statement, 13),
                refinementImprovements: optionalInt(statement, 14)
            )
        }
    }

    public func processingOptions(jobID: UUID) throws -> ProcessingOptions? {
        try withStatement("SELECT options FROM jobs WHERE id=?;") { statement in
            bind(jobID.uuidString, at: 1, to: statement)
            guard try next(statement) == SQLITE_ROW,
                  let optionData = data(statement, 0) else { return nil }
            return try WireCodec.decode(ProcessingOptions.self, from: optionData)
        }
    }

    public func mostRecentJobID(for mediaURL: URL) throws -> UUID? {
        try withStatement("SELECT id FROM jobs WHERE media_url=? ORDER BY updated_at DESC LIMIT 1;") { statement in
            bind(mediaURL.absoluteString, at: 1, to: statement)
            guard try next(statement) == SQLITE_ROW else { return nil }
            return UUID(uuidString: string(statement, 0))
        }
    }

    public func saveTranscript(_ transcript: TranscriptSegment, snapshot: JobSnapshot) throws {
        try transaction {
            try insertTranscriptUnlocked(transcript)
            try saveSnapshotUnlocked(snapshot)
        }
    }

    public func saveTranslation(_ translation: TranslationSegment, snapshot: JobSnapshot) throws {
        try transaction {
            try insertTranslationUnlocked(translation)
            try saveSnapshotUnlocked(snapshot)
        }
    }

    public func saveChunk(transcript: TranscriptSegment, translations: [TranslationSegment], snapshot: JobSnapshot) throws {
        try transaction {
            try insertTranscriptUnlocked(transcript)
            for translation in translations {
                try insertTranslationUnlocked(translation)
            }
            try saveSnapshotUnlocked(snapshot)
        }
    }

    public func saveSpeakerResolvedResults(
        transcripts: [TranscriptSegment],
        translations: [TranslationSegment],
        snapshot: JobSnapshot
    ) throws {
        try transaction {
            for transcript in transcripts {
                try insertTranscriptUnlocked(transcript)
            }
            for translation in translations {
                try insertTranslationUnlocked(translation)
            }
            try saveSnapshotUnlocked(snapshot)
        }
    }

    public func completedChunkIndices(jobID: UUID) throws -> Set<Int> {
        try withStatement("SELECT chunk_index FROM transcript_segments WHERE job_id=?;") { statement in
            bind(jobID.uuidString, at: 1, to: statement)
            var indices = Set<Int>()
            while try next(statement) == SQLITE_ROW {
                indices.insert(Int(sqlite3_column_int(statement, 0)))
            }
            return indices
        }
    }

    public func statistics() throws -> DatabaseStatistics {
        DatabaseStatistics(
            jobCount: try rowCount(table: "jobs"),
            transcriptCount: try rowCount(table: "transcript_segments"),
            translationCount: try rowCount(table: "translations")
        )
    }

    public func optimize() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE);")
        try execute("VACUUM;")
        try execute("PRAGMA optimize;")
    }

    public func deleteAllJobs() throws {
        try transaction {
            try executeUnlocked("DELETE FROM jobs;")
        }
        try optimize()
    }

    public func deleteJob(jobID: UUID) throws {
        try withStatement("DELETE FROM jobs WHERE id=?;") { statement in
            bind(jobID.uuidString, at: 1, to: statement)
            try step(statement)
        }
    }

    public func deleteTranslations(jobID: UUID, language: String, modelID: String) throws {
        try withStatement("DELETE FROM translations WHERE job_id=? AND target_language=? AND model_id=?;") { statement in
            bind(jobID.uuidString, at: 1, to: statement)
            bind(language, at: 2, to: statement)
            bind(modelID, at: 3, to: statement)
            try step(statement)
        }
    }

    public func deleteTranscript(jobID: UUID, chunkIndex: Int) throws {
        try withStatement("DELETE FROM transcript_segments WHERE job_id=? AND chunk_index=?;") { statement in
            bind(jobID.uuidString, at: 1, to: statement)
            bind(chunkIndex, at: 2, to: statement)
            try step(statement)
        }
    }

    public func deleteTranslation(transcriptID: UUID, language: String, modelID: String) throws {
        try withStatement("DELETE FROM translations WHERE transcript_id=? AND target_language=? AND model_id=?;") { statement in
            bind(transcriptID.uuidString, at: 1, to: statement)
            bind(language, at: 2, to: statement)
            bind(modelID, at: 3, to: statement)
            try step(statement)
        }
    }

    public func transcript(jobID: UUID) throws -> [TranscriptSegment] {
        try withStatement("""
            SELECT id, chunk_index, start_time, end_time, text, language, confidence, cues,
                   quality_status, retry_count, quality_notes
            FROM transcript_segments WHERE job_id=? ORDER BY start_time;
            """) { statement in
            bind(jobID.uuidString, at: 1, to: statement)
            var result: [TranscriptSegment] = []
            while try next(statement) == SQLITE_ROW {
                guard let id = UUID(uuidString: string(statement, 0)) else { continue }
                let cues = (data(statement, 7).flatMap { try? WireCodec.decode([TranscriptCue].self, from: $0) } ?? []).map {
                    TranscriptCue(
                        startTime: $0.startTime,
                        endTime: $0.endTime,
                        text: SpeakerLabelRewriter.removingInferenceMarkers(from: $0.text)
                    )
                }
                result.append(TranscriptSegment(
                    id: id,
                    jobID: jobID,
                    chunkIndex: Int(sqlite3_column_int(statement, 1)),
                    startTime: sqlite3_column_double(statement, 2),
                    endTime: sqlite3_column_double(statement, 3),
                    text: SpeakerLabelRewriter.removingInferenceMarkers(from: string(statement, 4)),
                    language: optionalString(statement, 5),
                    confidence: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 6),
                    cues: cues,
                    qualityStatus: optionalString(statement, 8).flatMap(SegmentQualityStatus.init(rawValue:)),
                    retryCount: sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 9)),
                    qualityNotes: data(statement, 10).flatMap { try? WireCodec.decode([String].self, from: $0) }
                ))
            }
            return result
        }
    }

    public func translations(jobID: UUID, language: String, modelID: String? = nil) throws -> [UUID: TranslationSegment] {
        let sql = modelID == nil
            ? "SELECT id, transcript_id, model_id, text, quality_status, quality_notes FROM translations WHERE job_id=? AND target_language=?;"
            : "SELECT id, transcript_id, model_id, text, quality_status, quality_notes FROM translations WHERE job_id=? AND target_language=? AND model_id=?;"
        return try withStatement(sql) { statement in
            bind(jobID.uuidString, at: 1, to: statement)
            bind(language, at: 2, to: statement)
            if let modelID { bind(modelID, at: 3, to: statement) }
            var result: [UUID: TranslationSegment] = [:]
            while try next(statement) == SQLITE_ROW {
                guard let id = UUID(uuidString: string(statement, 0)),
                      let transcriptID = UUID(uuidString: string(statement, 1)) else { continue }
                result[transcriptID] = TranslationSegment(
                    id: id,
                    transcriptID: transcriptID,
                    jobID: jobID,
                    targetLanguage: language,
                    modelID: string(statement, 2),
                    text: SpeakerLabelRewriter.removingInferenceMarkers(from: string(statement, 3)),
                    qualityStatus: optionalString(statement, 4).flatMap(SegmentQualityStatus.init(rawValue:)),
                    qualityNotes: data(statement, 5).flatMap { try? WireCodec.decode([String].self, from: $0) }
                )
            }
            return result
        }
    }

    private func migrate() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS jobs(
                id TEXT PRIMARY KEY,
                media_url TEXT NOT NULL,
                options BLOB NOT NULL,
                status TEXT NOT NULL,
                progress REAL NOT NULL DEFAULT 0,
                current_chunk INTEGER NOT NULL DEFAULT 0,
                total_chunks INTEGER NOT NULL DEFAULT 0,
                stt_progress REAL NOT NULL DEFAULT 0,
                translation_progress REAL NOT NULL DEFAULT 0,
                last_transcript_text TEXT,
                last_translation_text TEXT,
                refinement_pass INTEGER,
                refinement_progress REAL,
                refinement_revision INTEGER,
                refinement_improvements INTEGER,
                message TEXT NOT NULL,
                error TEXT,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS transcript_segments(
                id TEXT PRIMARY KEY,
                job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
                chunk_index INTEGER NOT NULL,
                start_time REAL NOT NULL,
                end_time REAL NOT NULL,
                text TEXT NOT NULL,
                language TEXT,
                confidence REAL,
                cues BLOB,
                quality_status TEXT,
                retry_count INTEGER,
                quality_notes BLOB,
                UNIQUE(job_id, chunk_index)
            );
            CREATE TABLE IF NOT EXISTS translations(
                id TEXT PRIMARY KEY,
                transcript_id TEXT NOT NULL REFERENCES transcript_segments(id) ON DELETE CASCADE,
                job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
                target_language TEXT NOT NULL,
                model_id TEXT NOT NULL DEFAULT 'apple-foundation-models',
                text TEXT NOT NULL,
                quality_status TEXT,
                quality_notes BLOB,
                UNIQUE(transcript_id, target_language)
            );
            """)
        let columns = try tableColumns("jobs")
        if !columns.contains("stt_progress") {
            try execute("ALTER TABLE jobs ADD COLUMN stt_progress REAL NOT NULL DEFAULT 0;")
        }
        if !columns.contains("translation_progress") {
            try execute("ALTER TABLE jobs ADD COLUMN translation_progress REAL NOT NULL DEFAULT 0;")
        }
        if !columns.contains("last_transcript_text") {
            try execute("ALTER TABLE jobs ADD COLUMN last_transcript_text TEXT;")
        }
        if !columns.contains("last_translation_text") {
            try execute("ALTER TABLE jobs ADD COLUMN last_translation_text TEXT;")
        }
        if !columns.contains("refinement_pass") {
            try execute("ALTER TABLE jobs ADD COLUMN refinement_pass INTEGER;")
        }
        if !columns.contains("refinement_progress") {
            try execute("ALTER TABLE jobs ADD COLUMN refinement_progress REAL;")
        }
        if !columns.contains("refinement_revision") {
            try execute("ALTER TABLE jobs ADD COLUMN refinement_revision INTEGER;")
        }
        if !columns.contains("refinement_improvements") {
            try execute("ALTER TABLE jobs ADD COLUMN refinement_improvements INTEGER;")
        }
        let translationColumns = try tableColumns("translations")
        if !translationColumns.contains("model_id") {
            try execute("ALTER TABLE translations ADD COLUMN model_id TEXT NOT NULL DEFAULT 'apple-foundation-models';")
        }
        let transcriptColumns = try tableColumns("transcript_segments")
        if !transcriptColumns.contains("cues") {
            try execute("ALTER TABLE transcript_segments ADD COLUMN cues BLOB;")
        }
        if !transcriptColumns.contains("quality_status") {
            try execute("ALTER TABLE transcript_segments ADD COLUMN quality_status TEXT;")
        }
        if !transcriptColumns.contains("retry_count") {
            try execute("ALTER TABLE transcript_segments ADD COLUMN retry_count INTEGER;")
        }
        if !transcriptColumns.contains("quality_notes") {
            try execute("ALTER TABLE transcript_segments ADD COLUMN quality_notes BLOB;")
        }
        if !translationColumns.contains("quality_status") {
            try execute("ALTER TABLE translations ADD COLUMN quality_status TEXT;")
        }
        if !translationColumns.contains("quality_notes") {
            try execute("ALTER TABLE translations ADD COLUMN quality_notes BLOB;")
        }
    }

    private func insertTranscriptUnlocked(_ value: TranscriptSegment) throws {
        let cueData = try WireCodec.encode(value.cues ?? [])
        let qualityNotesData = try value.qualityNotes.map(WireCodec.encode)
        try withStatementUnlocked("""
            INSERT INTO transcript_segments(id, job_id, chunk_index, start_time, end_time, text, language, confidence, cues, quality_status, retry_count, quality_notes)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(job_id, chunk_index) DO UPDATE SET start_time=excluded.start_time, end_time=excluded.end_time,
                text=excluded.text, language=excluded.language, confidence=excluded.confidence, cues=excluded.cues,
                quality_status=excluded.quality_status, retry_count=excluded.retry_count, quality_notes=excluded.quality_notes;
            """) { statement in
            bind(value.id.uuidString, at: 1, to: statement)
            bind(value.jobID.uuidString, at: 2, to: statement)
            bind(value.chunkIndex, at: 3, to: statement)
            bind(value.startTime, at: 4, to: statement)
            bind(value.endTime, at: 5, to: statement)
            bind(value.text, at: 6, to: statement)
            bind(value.language, at: 7, to: statement)
            bind(value.confidence, at: 8, to: statement)
            bind(cueData, at: 9, to: statement)
            bind(value.qualityStatus?.rawValue, at: 10, to: statement)
            bind(value.retryCount, at: 11, to: statement)
            bind(qualityNotesData, at: 12, to: statement)
            try step(statement)
        }
    }

    private func insertTranslationUnlocked(_ value: TranslationSegment) throws {
        let qualityNotesData = try value.qualityNotes.map(WireCodec.encode)
        try withStatementUnlocked("""
            INSERT INTO translations(id, transcript_id, job_id, target_language, model_id, text, quality_status, quality_notes)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(transcript_id, target_language) DO UPDATE SET model_id=excluded.model_id, text=excluded.text,
                quality_status=excluded.quality_status, quality_notes=excluded.quality_notes;
            """) { statement in
            bind(value.id.uuidString, at: 1, to: statement)
            bind(value.transcriptID.uuidString, at: 2, to: statement)
            bind(value.jobID.uuidString, at: 3, to: statement)
            bind(value.targetLanguage, at: 4, to: statement)
            bind(value.modelID, at: 5, to: statement)
            bind(value.text, at: 6, to: statement)
            bind(value.qualityStatus?.rawValue, at: 7, to: statement)
            bind(qualityNotesData, at: 8, to: statement)
            try step(statement)
        }
    }

    private func saveSnapshotUnlocked(_ value: JobSnapshot) throws {
        try withStatementUnlocked("""
            UPDATE jobs SET status=?, progress=?, current_chunk=?, total_chunks=?, stt_progress=?, translation_progress=?,
                last_transcript_text=?, last_translation_text=?, message=?, error=?, updated_at=?, refinement_pass=?,
                refinement_progress=?, refinement_revision=?, refinement_improvements=? WHERE id=?;
            """) { statement in
            bind(value.status.rawValue, at: 1, to: statement)
            bind(value.progress, at: 2, to: statement)
            bind(value.currentChunk, at: 3, to: statement)
            bind(value.totalChunks, at: 4, to: statement)
            bind(value.sttProgress, at: 5, to: statement)
            bind(value.translationProgress, at: 6, to: statement)
            bind(value.lastTranscriptText, at: 7, to: statement)
            bind(value.lastTranslationText, at: 8, to: statement)
            bind(value.message, at: 9, to: statement)
            bind(value.error, at: 10, to: statement)
            bind(value.updatedAt.timeIntervalSince1970, at: 11, to: statement)
            bind(value.refinementPass, at: 12, to: statement)
            bind(value.refinementProgress, at: 13, to: statement)
            bind(value.refinementRevision, at: 14, to: statement)
            bind(value.refinementImprovements, at: 15, to: statement)
            bind(value.id.uuidString, at: 16, to: statement)
            try step(statement)
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try executeUnlocked("BEGIN IMMEDIATE;")
        do {
            try body()
            try executeUnlocked("COMMIT;")
        } catch {
            try? executeUnlocked("ROLLBACK;")
            throw error
        }
    }

    private func tableColumns(_ table: String) throws -> Set<String> {
        try withStatement("PRAGMA table_info(\(table));") { statement in
            var columns = Set<String>()
            while try next(statement) == SQLITE_ROW {
                columns.insert(string(statement, 1))
            }
            return columns
        }
    }

    private func rowCount(table: String) throws -> Int {
        try withStatement("SELECT COUNT(*) FROM \(table);") { statement in
            guard try next(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try executeUnlocked(sql)
    }

    private func executeUnlocked(_ sql: String) throws {
        for attempt in 0...maximumBusyRetries {
            var message: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(db, sql, nil, nil, &message)
            let detail = message.map { String(cString: $0) }
            sqlite3_free(message)
            if result == SQLITE_OK { return }
            if isBusy(result), attempt < maximumBusyRetries {
                backoff(attempt: attempt)
                continue
            }
            throw StoreError.sqlite(detail ?? String(cString: sqlite3_errmsg(db)))
        }
        throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try withStatementUnlocked(sql, body)
    }

    private func withStatementUnlocked<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        var prepareResult = SQLITE_ERROR
        for attempt in 0...maximumBusyRetries {
            prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
            if prepareResult == SQLITE_OK { break }
            if isBusy(prepareResult), attempt < maximumBusyRetries {
                sqlite3_finalize(statement)
                statement = nil
                backoff(attempt: attempt)
                continue
            }
            break
        }
        guard prepareResult == SQLITE_OK, let statement else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func step(_ statement: OpaquePointer) throws {
        for attempt in 0...maximumBusyRetries {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            if isBusy(result), attempt < maximumBusyRetries {
                backoff(attempt: attempt)
                continue
            }
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
    }

    private func next(_ statement: OpaquePointer) throws -> Int32 {
        for attempt in 0...maximumBusyRetries {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW || result == SQLITE_DONE { return result }
            if isBusy(result), attempt < maximumBusyRetries {
                backoff(attempt: attempt)
                continue
            }
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
    }

    private func configureJournalMode() throws {
        let current: String = try withStatement("PRAGMA journal_mode;") { statement in
            for attempt in 0...maximumBusyRetries {
                let result = sqlite3_step(statement)
                if result == SQLITE_ROW { return string(statement, 0).lowercased() }
                if isBusy(result), attempt < maximumBusyRetries {
                    backoff(attempt: attempt)
                    continue
                }
                throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        if current != "wal" {
            try execute("PRAGMA journal_mode=WAL;")
        }
    }

    private func isBusy(_ result: Int32) -> Bool {
        result == SQLITE_BUSY || result == SQLITE_LOCKED
    }

    private func backoff(attempt: Int) {
        let milliseconds = min(400, 25 * (1 << attempt))
        Thread.sleep(forTimeInterval: Double(milliseconds) / 1_000)
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) {
        _ = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    private func bind(_ value: Data?, at index: Int32, to statement: OpaquePointer) {
        if let value { bind(value, at: index, to: statement) } else { sqlite3_bind_null(statement, index) }
    }

    private func bind(_ value: Int, at index: Int32, to statement: OpaquePointer) { sqlite3_bind_int64(statement, index, sqlite3_int64(value)) }
    private func bind(_ value: Int?, at index: Int32, to statement: OpaquePointer) {
        if let value { bind(value, at: index, to: statement) } else { sqlite3_bind_null(statement, index) }
    }
    private func bind(_ value: Double?, at index: Int32, to statement: OpaquePointer) {
        if let value { sqlite3_bind_double(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }
    private func bind(_ value: Double, at index: Int32, to statement: OpaquePointer) { sqlite3_bind_double(statement, index, value) }
    private func string(_ statement: OpaquePointer, _ column: Int32) -> String { String(cString: sqlite3_column_text(statement, column)) }
    private func optionalString(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return string(statement, column)
    }
    private func optionalInt(_ statement: OpaquePointer, _ column: Int32) -> Int? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, column))
    }
    private func optionalDouble(_ statement: OpaquePointer, _ column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, column)
    }
    private func data(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    public enum StoreError: LocalizedError {
        case openFailed
        case sqlite(String)
        public var errorDescription: String? {
            switch self {
            case .openFailed: "데이터베이스를 열 수 없습니다."
            case .sqlite(let message): "데이터베이스 오류: \(message)"
            }
        }
    }
}
