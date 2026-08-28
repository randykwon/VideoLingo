import AppKit
import Foundation

/// 파일·폴더 선택 창이 마지막으로 사용한 위치를 기억합니다.
/// 매번 홈 폴더에서 다시 찾아 들어가지 않도록, 용도별로 따로 저장합니다.
enum PanelLocationMemory {
    enum Purpose: String {
        /// 단일 영상 열기
        case video
        /// 대량 번역: 영상 파일 추가
        case batchFiles
        /// 대량 번역: 검색할 폴더 추가
        case batchFolders
        /// 대량 번역: 읽기 전용 영상의 결과 저장 폴더
        case batchResultDirectory
        /// 자막·패키지 내보내기 저장 위치
        case export

        var storageKey: String { "panelLocation.\(rawValue)" }
    }

    /// 저장해 둔 위치가 아직 존재할 때만 시작 폴더로 지정합니다.
    /// NSOpenPanel은 NSSavePanel의 하위 클래스라 두 종류 모두 여기로 처리됩니다.
    static func restore(into panel: NSSavePanel, purpose: Purpose) {
        guard let path = UserDefaults.standard.string(forKey: purpose.storageKey) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        panel.directoryURL = URL(filePath: path, directoryHint: .isDirectory)
    }

    /// 사용자가 고른 항목의 폴더를 기억합니다. 파일을 골랐으면 그 파일이 있는 폴더를 저장합니다.
    static func remember(_ url: URL, purpose: Purpose) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let directory = (exists && isDirectory.boolValue) ? url : url.deletingLastPathComponent()
        UserDefaults.standard.set(directory.path(percentEncoded: false), forKey: purpose.storageKey)
    }

    static func remember(first urls: [URL], purpose: Purpose) {
        guard let url = urls.first else { return }
        remember(url, purpose: purpose)
    }
}
