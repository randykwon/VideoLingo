import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct MobileContentView: View {
    @Environment(MobileVideoLibrary.self) private var library
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isChoosingVideo = false
    @State private var showingInfo = false

    var body: some View {
        NavigationStack {
            Group {
                if let videoURL = library.videoURL {
                    playerLayout(videoURL: videoURL)
                } else {
                    emptyState
                }
            }
            .navigationTitle(library.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .fileImporter(
                isPresented: $isChoosingVideo,
                allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
                allowsMultipleSelection: false
            ) { result in
                guard case let .success(urls) = result, let url = urls.first else {
                    if case let .failure(error) = result { library.errorMessage = error.localizedDescription }
                    return
                }
                Task { await library.importVideo(from: url) }
            }
            .alert("영상을 열 수 없음", isPresented: errorBinding) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(library.errorMessage ?? "알 수 없는 오류가 발생했습니다.")
            }
            .sheet(isPresented: $showingInfo) { capabilityInfo }
            .overlay {
                if library.isImporting { importingOverlay }
            }
        }
    }

    @ViewBuilder
    private func playerLayout(videoURL: URL) -> some View {
        if horizontalSizeClass == .regular {
            HStack(spacing: 0) {
                player(videoURL: videoURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                capabilityPanel
                    .frame(width: 320)
                    .background(.bar)
            }
        } else {
            VStack(spacing: 0) {
                player(videoURL: videoURL)
                    .aspectRatio(16 / 9, contentMode: .fit)
                capabilityPanel
            }
        }
    }

    private func player(videoURL: URL) -> some View {
        VideoPlayer(player: library.player)
            .background(.black)
            .accessibilityLabel("\(videoURL.lastPathComponent) 재생기")
    }

    private var capabilityPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("모바일 플레이어", systemImage: "iphone.and.arrow.forward")
                    .font(.headline)
                Text("가져온 영상은 이 기기에 복사되어 다음 실행에도 이어서 열 수 있습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()

                Label("AI 자막·번역 처리", systemImage: "macbook")
                    .font(.headline)
                Text("현재 AI 처리 엔진은 Mac의 내장 서비스에서 실행됩니다. 모바일에서는 재생과 파일 보관을 먼저 지원합니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("영상을 열어 보세요", systemImage: "play.rectangle")
        } description: {
            Text("파일 앱에서 영상을 선택하면 iPhone 또는 iPad에서 바로 재생할 수 있습니다.")
        } actions: {
            Button("영상 선택", systemImage: "folder") { isChoosingVideo = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("지원 기능", systemImage: "info.circle") { showingInfo = true }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("영상 열기", systemImage: "folder") { isChoosingVideo = true }
        }
        if library.videoURL != nil {
            ToolbarItem(placement: .secondaryAction) {
                Button("현재 영상 닫기", systemImage: "xmark", role: .destructive) {
                    library.clearVideo()
                }
            }
        }
    }

    private var capabilityInfo: some View {
        NavigationStack {
            List {
                Section("iPhone 및 iPad") {
                    Label("파일 앱에서 영상 가져오기", systemImage: "checkmark.circle.fill")
                    Label("기기 회전과 iPad 분할 화면 대응", systemImage: "checkmark.circle.fill")
                    Label("시스템 비디오 플레이어로 재생", systemImage: "checkmark.circle.fill")
                }
                Section("Mac에서 제공") {
                    Label("음성 인식, 번역, 음성 합성, 모자이크 처리", systemImage: "desktopcomputer")
                }
            }
            .navigationTitle("지원 기능")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { showingInfo = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var importingOverlay: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("영상을 이 기기로 복사하는 중…")
                    .font(.subheadline)
            }
            .padding(20)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )
    }
}

#Preview("iPhone") {
    MobileContentView()
        .environment(MobileVideoLibrary())
}
