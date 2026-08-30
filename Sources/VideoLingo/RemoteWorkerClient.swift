import Foundation
import VideoLingoCore

enum RemoteWorkerClientError: LocalizedError {
    case invalidResponse
    case rejected(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "원격 Worker 응답 형식이 올바르지 않습니다."
        case let .rejected(message), let .failed(message): message
        }
    }
}

struct RemoteWorkerClient: Sendable {
    let worker: RemoteWorkerConfiguration

    func run(
        mediaURL: URL,
        manifest: RemoteJobManifest,
        onProgress: @escaping @Sendable (RemoteJobProgress) async -> Void
    ) async throws -> RemoteJobResult {
        let boundary = "VideoLingo-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).upload")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        try makeMultipartBody(mediaURL: mediaURL, manifest: manifest, boundary: boundary, outputURL: bodyURL)

        var request = authenticatedRequest(path: RemoteWorkerAPI.jobsPath)
        request.httpMethod = "POST"
        request.timeoutInterval = 60 * 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL)
        try validate(response)
        let receipt = try WireCodec.decode(RemoteJobReceipt.self, from: data)
        guard receipt.accepted else { throw RemoteWorkerClientError.rejected(receipt.message) }

        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(2))
            var poll = authenticatedRequest(path: RemoteWorkerAPI.jobPath(manifest.jobID))
            poll.timeoutInterval = 10
            let (progressData, progressResponse) = try await URLSession.shared.data(for: poll)
            try validate(progressResponse)
            let progress = try WireCodec.decode(RemoteJobProgress.self, from: progressData)
            await onProgress(progress)
            if progress.status == .completed, let result = progress.result { return result }
            if progress.status == .failed || progress.status == .cancelled {
                throw RemoteWorkerClientError.failed(progress.message)
            }
        }
        try await cancel(jobID: manifest.jobID)
        throw CancellationError()
    }

    func cancel(jobID: UUID) async throws {
        var request = authenticatedRequest(path: RemoteWorkerAPI.jobPath(jobID))
        request.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: request)
    }

    private func authenticatedRequest(path: String) -> URLRequest {
        var request = URLRequest(url: worker.baseURL.appending(path: path))
        request.setValue("Bearer \(worker.authenticationToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RemoteWorkerClientError.invalidResponse
        }
    }

    private func makeMultipartBody(mediaURL: URL, manifest: RemoteJobManifest, boundary: String, outputURL: URL) throws {
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let manifestData = try WireCodec.encode(manifest)
        output.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"manifest\"\r\nContent-Type: application/json\r\n\r\n".utf8))
        output.write(manifestData)
        output.write(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"media\"; filename=\"\(mediaURL.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: mediaURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty { output.write(chunk) }
        output.write(Data("\r\n--\(boundary)--\r\n".utf8))
    }
}
