import AppKit
import Foundation
import Observation
import Security

@MainActor
@Observable
final class RemoteWorkerInstaller {
    var isExporting = false
    var message = ""
    var exportedURL: URL?

    func exportPackage(token: String) async {
        guard !isExporting else { return }
        guard let source = Bundle.main.resourceURL?.appending(path: "RemoteWorker", directoryHint: .isDirectory),
              FileManager.default.fileExists(atPath: source.path) else {
            message = String(localized: "앱에 Worker 설치 파일이 포함되어 있지 않습니다. 앱을 다시 빌드해 주세요.")
            return
        }

        let panel = NSSavePanel()
        panel.title = String(localized: "원격 Worker 설치 패키지 저장")
        panel.nameFieldStringValue = "VideoLingo-RemoteWorker.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "패키지 저장")
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        message = String(localized: "Windows·Linux·macOS 설치 패키지를 만드는 중…")
        exportedURL = nil
        do {
            try await Task.detached(priority: .userInitiated) {
                let manager = FileManager.default
                let temporaryRoot = manager.temporaryDirectory.appending(path: "VideoLingoWorker-\(UUID().uuidString)", directoryHint: .isDirectory)
                let package = temporaryRoot.appending(path: "VideoLingo-RemoteWorker", directoryHint: .isDirectory)
                defer { try? manager.removeItem(at: temporaryRoot) }
                try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
                try manager.copyItem(at: source, to: package)
                let example = package.appending(path: ".env.example")
                var configuration = try String(contentsOf: example, encoding: .utf8)
                configuration = configuration.replacingOccurrences(
                    of: "VIDEOLINGO_TOKEN=replace-with-a-long-random-token",
                    with: "VIDEOLINGO_TOKEN=\(token)"
                )
                try configuration.write(to: package.appending(path: ".env"), atomically: true, encoding: .utf8)

                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/ditto")
                process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", package.path, destination.path]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }.value
            exportedURL = destination
            message = String(localized: "설치 패키지를 저장했습니다. 다른 PC로 복사해 README의 순서대로 실행하세요.")
        } catch {
            message = String(localized: "설치 패키지를 만들지 못했습니다: \(error.localizedDescription)")
        }
        isExporting = false
    }

    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            return Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return UUID().uuidString + UUID().uuidString
    }
}
