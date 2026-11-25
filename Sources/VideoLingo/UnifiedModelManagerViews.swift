import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VideoLingoCore

/// 번역 모드·심플 메뉴 사이드바에서 현재 STT·번역 LLM을 한눈에 보고
/// 1클릭 메뉴로 즉시 전환하거나 통합 관리 시트를 열 수 있는 컴팩트 카드입니다.
struct SidebarModelQuickCard: View {
    @Environment(AppModel.self) private var model
    @State private var runtime = ManagedRuntimeManager.shared

    var body: some View {
        let locked = !model.canMutateStorage
        let sttWarning = model.sttReadinessWarning
        let trWarning = model.translationReadinessWarning

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("STT · 번역 LLM", systemImage: "cpu")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("관리…") {
                    model.openModelManager(section: trWarning != nil && sttWarning == nil ? "translation" : "stt")
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .help("STT·번역 LLM 선택, 다운로드, 삭제 및 서버 관리를 한 창에서 수행합니다 (⌘⇧L)")
            }

            // STT 1클릭 전환 행
            HStack(spacing: 6) {
                Circle()
                    .fill(sttWarning == nil ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text("STT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .leading)
                Menu {
                    sttQuickMenuItems
                } label: {
                    HStack(spacing: 4) {
                        Text(model.activeSTTDisplayName)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
                }
                .menuStyle(.borderlessButton)
                .disabled(locked)
                .help(locked ? "작업 진행 중에는 STT 모델을 변경할 수 없습니다." : "클릭해 STT 엔진·모델을 바로 전환합니다.")
            }

            // 번역 LLM 1클릭 전환 행
            HStack(spacing: 6) {
                Circle()
                    .fill(trWarning == nil ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text("번역")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .leading)
                Menu {
                    translationQuickMenuItems
                } label: {
                    HStack(spacing: 4) {
                        Text(model.activeTranslationDisplayName)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
                }
                .menuStyle(.borderlessButton)
                .disabled(locked)
                .help(locked ? "작업 진행 중에는 번역 LLM을 변경할 수 없습니다." : "클릭해 번역 엔진·LLM을 바로 전환합니다.")
            }

            if let warning = sttWarning ?? trWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button("해결") {
                        model.openModelManager(section: sttWarning != nil ? "stt" : "translation")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2.weight(.semibold))
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var sttQuickMenuItems: some View {
        let downloadedWhisper = model.models.filter { model.isModelDownloaded(kind: .stt, modelID: $0) }
        let installedGGML = runtime.models(for: .stt).filter { runtime.installed.contains($0.id) }

        Section("빠른 전환") {
            Button {
                model.sttEngine = .appleSpeech
            } label: {
                menuCheckLabel("Apple 음성 인식 (빠름 · 다운로드 불필요)", checked: model.sttEngine == .appleSpeech)
            }
            Button {
                model.sttEngine = .whisperKit
                model.sttModel = "large-v3-v20240930_626MB"
            } label: {
                menuCheckLabel(
                    "WhisperKit Large v3 Turbo (균형)",
                    checked: model.sttEngine == .whisperKit && model.sttModel == "large-v3-v20240930_626MB"
                )
            }
            Button {
                model.sttEngine = .whisperKit
                model.sttModel = "openai_whisper-large-v3"
            } label: {
                menuCheckLabel(
                    "WhisperKit Large v3 (고정확도)",
                    checked: model.sttEngine == .whisperKit && model.sttModel == "openai_whisper-large-v3"
                )
            }
        }

        if !downloadedWhisper.isEmpty {
            Section("설치된 WhisperKit") {
                ForEach(downloadedWhisper, id: \.self) { id in
                    Button {
                        model.sttEngine = .whisperKit
                        model.sttModel = id
                    } label: {
                        menuCheckLabel(
                            ModelCatalog.whisperKitDescriptor(for: id)?.displayName ?? id,
                            checked: model.sttEngine == .whisperKit && model.sttModel == id
                        )
                    }
                }
            }
        }

        if !installedGGML.isEmpty {
            Section("설치된 whisper.cpp (GGML)") {
                ForEach(installedGGML) { item in
                    Button {
                        model.sttEngine = .managedWhisper
                        Task { await runtime.select(item) }
                    } label: {
                        menuCheckLabel(
                            item.name,
                            checked: model.sttEngine == .managedWhisper && runtime.selectedSTT == item.id
                        )
                    }
                }
            }
        }

        Section("클라우드") {
            Button {
                model.sttEngine = .deepgram
            } label: {
                menuCheckLabel("Deepgram (\(model.deepgramModel))", checked: model.sttEngine == .deepgram)
            }
        }

        Divider()
        Button("모든 STT 모델 관리 · 다운로드…", systemImage: "slider.horizontal.3") {
            model.openModelManager(section: "stt")
        }
    }

    @ViewBuilder
    private var translationQuickMenuItems: some View {
        let downloadedMLX = model.mlxTranslationModels.filter { model.isModelDownloaded(kind: .translation, modelID: $0) }
        let installedGGUF = runtime.models(for: .translation).filter { runtime.installed.contains($0.id) }

        Section("빠른 전환") {
            Button {
                model.translationEngine = .appleTranslation
                model.syncTranslationModelForEngine()
                model.refreshResults()
            } label: {
                menuCheckLabel("Apple 전용 번역 (초고속 · 온디바이스)", checked: model.translationEngine == .appleTranslation)
            }
            Button {
                model.translationEngine = .mlx
                model.translationModel = "mlx-community/Qwen3-8B-4bit"
                model.refreshResults()
            } label: {
                menuCheckLabel(
                    "MLX Qwen3 8B (균형 · 추천)",
                    checked: model.translationEngine == .mlx && model.translationModel == "mlx-community/Qwen3-8B-4bit"
                )
            }
            Button {
                model.translationEngine = .mlx
                model.translationModel = "mlx-community/gemma-3-12b-it-4bit"
                model.refreshResults()
            } label: {
                menuCheckLabel(
                    "MLX Gemma 3 12B (고품질)",
                    checked: model.translationEngine == .mlx && model.translationModel == "mlx-community/gemma-3-12b-it-4bit"
                )
            }
            Button {
                model.translationEngine = .appleFoundation
                model.syncTranslationModelForEngine()
                model.refreshResults()
            } label: {
                menuCheckLabel("Apple Intelligence", checked: model.translationEngine == .appleFoundation)
            }
        }

        if !downloadedMLX.isEmpty {
            Section("설치된 MLX LLM") {
                ForEach(downloadedMLX, id: \.self) { id in
                    Button {
                        model.translationEngine = .mlx
                        model.translationModel = id
                        model.refreshResults()
                    } label: {
                        menuCheckLabel(
                            ModelCatalog.mlxDescriptor(for: id)?.displayName ?? id,
                            checked: model.translationEngine == .mlx && model.translationModel == id
                        )
                    }
                }
            }
        }

        if !installedGGUF.isEmpty {
            Section("설치된 llama.cpp (GGUF)") {
                ForEach(installedGGUF) { item in
                    Button {
                        model.translationEngine = .managedLlama
                        Task {
                            await runtime.select(item)
                            model.syncTranslationModelForEngine()
                            model.refreshResults()
                        }
                    } label: {
                        menuCheckLabel(
                            item.name,
                            checked: model.translationEngine == .managedLlama && runtime.selectedTranslation == item.id
                        )
                    }
                }
            }
        }

        Section("외부 서버 · API") {
            Button {
                model.translationEngine = .externalOpenAI
                model.syncTranslationModelForEngine()
                model.refreshResults()
            } label: {
                let serverLabel = model.externalServerModel.isEmpty ? "외부 LLM 서버 (Ollama / LM Studio)" : "외부 서버 · \(model.externalServerModel)"
                menuCheckLabel(serverLabel, checked: model.translationEngine == .externalOpenAI)
            }
            Button {
                model.translationEngine = .azure
                model.syncTranslationModelForEngine()
                model.refreshResults()
            } label: {
                menuCheckLabel("Azure Translator", checked: model.translationEngine == .azure)
            }
            Button {
                model.translationEngine = .localAPI
                model.syncTranslationModelForEngine()
                model.refreshResults()
            } label: {
                menuCheckLabel("로컬 커스텀 API", checked: model.translationEngine == .localAPI)
            }
        }

        Divider()
        Button("모든 번역 LLM 관리 · 다운로드…", systemImage: "slider.horizontal.3") {
            model.openModelManager(section: "translation")
        }
    }

    @ViewBuilder
    private func menuCheckLabel(_ title: String, checked: Bool) -> some View {
        if checked {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

/// STT와 번역 LLM을 한 창에서 선택·전환·다운로드·삭제·서버 관리할 수 있는 통합 시트입니다.
struct UnifiedModelManagerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var runtime = ManagedRuntimeManager.shared

    enum ManagerTab: String, CaseIterable, Identifiable {
        case stt
        case translation
        var id: String { rawValue }
        var title: String { self == .stt ? "음성 인식 (STT)" : "번역 LLM" }
        var symbol: String { self == .stt ? "waveform" : "character.bubble" }
    }

    private struct UnifiedDeleteTarget: Identifiable {
        enum Source {
            case xpc(ManagedModelKind, String)
            case managedRuntime(ManagedRuntimeModel)
        }
        let title: String
        let source: Source
        var id: String { title }
    }

    @State private var tab: ManagerTab
    @State private var searchText = ""
    @State private var installedOnly = false
    @State private var customModelInput = ""
    @State private var deepgramKey = ""
    @State private var azureKey = ""
    @State private var localAPIKey = ""
    @State private var keySaveNotice: String?
    @State private var deleteTarget: UnifiedDeleteTarget?
    @State private var showingDetailedServerSheet = false
    @State private var busyServerRoles: Set<ManagedRuntimeRole> = []

    init(initialSection: String = "stt") {
        _tab = State(initialValue: initialSection == "translation" ? .translation : .stt)
    }

    private var isLocked: Bool { !model.canMutateStorage }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            // 상단 헤더 + 탭 전환
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("STT · 번역 LLM 선택 및 관리")
                        .font(.title2.weight(.semibold))
                    Text("엔진과 모델을 바로 선택하고, 설치·삭제·로컬 서버 실행까지 한곳에서 관리합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("관리 탭", selection: $tab) {
                    ForEach(ManagerTab.allCases) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }

            // 현재 선택 요약 바
            activeSummaryBanner

            if isLocked {
                Label("현재 작업이 실행 중입니다. 중지 또는 완료 후 모델을 변경·삭제할 수 있습니다.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()

            // 탭 본문
            Group {
                if tab == .stt {
                    sttTabBody
                } else {
                    translationTabBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            // 하단 도구 바
            HStack(spacing: 10) {
                Button("모델 폴더 열기", systemImage: "folder") {
                    model.revealModelsFolder()
                }
                .controlSize(.small)
                Button("새로 고침", systemImage: "arrow.clockwise") {
                    model.refreshModelManager()
                    runtime.refreshInstalled()
                }
                .controlSize(.small)
                Button("자체 서버 로그…", systemImage: "server.rack") {
                    showingDetailedServerSheet = true
                }
                .controlSize(.small)
                if let notice = keySaveNotice ?? runtime.lastError {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(runtime.lastError != nil ? .orange : .secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("완료") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 780, height: 640)
        .onAppear {
            model.refreshModelManager()
            runtime.refreshInstalled()
            deepgramKey = APIKeyStore.read(.deepgram)
            azureKey = APIKeyStore.read(.azure)
            localAPIKey = APIKeyStore.read(.localTranslation)
        }
        .onChange(of: tab) { _, _ in
            searchText = ""
            customModelInput = ""
            keySaveNotice = nil
        }
        .task(id: model.hasDownloadingManagedModels) {
            while model.hasDownloadingManagedModels && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.refreshModelManager()
            }
        }
        .sheet(isPresented: $showingDetailedServerSheet) {
            ManagedRuntimeModelsSheet()
                .environment(model)
        }
        .confirmationDialog(
            "모델 파일을 삭제할까요?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            presenting: deleteTarget
        ) { target in
            Button("\(target.title) 삭제", role: .destructive) {
                switch target.source {
                case .xpc(let kind, let modelID):
                    model.deleteModel(kind: kind, modelID: modelID)
                case .managedRuntime(let item):
                    Task { await runtime.remove(item) }
                }
                deleteTarget = nil
            }
            Button("취소", role: .cancel) { deleteTarget = nil }
        } message: { target in
            Text("\(target.title) 모델 파일만 삭제합니다. 기존 STT·번역 결과는 유지됩니다.")
        }
    }

    // MARK: - 현재 선택 요약 배너

    private var activeSummaryBanner: some View {
        HStack(spacing: 12) {
            summaryChip(
                roleTitle: "현재 STT",
                value: model.activeSTTDisplayName,
                engineTitle: model.sttEngine.displayName,
                warning: model.sttReadinessWarning,
                isActiveTab: tab == .stt
            ) {
                tab = .stt
            }
            summaryChip(
                roleTitle: "현재 번역 LLM",
                value: model.activeTranslationDisplayName,
                engineTitle: model.translationEngine.displayName,
                warning: model.translationReadinessWarning,
                isActiveTab: tab == .translation
            ) {
                tab = .translation
            }
        }
    }

    private func summaryChip(
        roleTitle: String,
        value: String,
        engineTitle: String,
        warning: String?,
        isActiveTab: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: warning == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(warning == nil ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(roleTitle) · \(engineTitle)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if let warning {
                        Text(warning)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                (isActiveTab ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isActiveTab ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - STT 탭

    private var sttTabBody: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            // 추천 원클릭 프리셋
            HStack(spacing: 6) {
                Text("빠른 프리셋")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                presetButton("Apple 빠름", active: model.sttEngine == .appleSpeech) {
                    model.sttEngine = .appleSpeech
                }
                presetButton("WhisperKit Turbo (추천)", active: model.sttEngine == .whisperKit && model.sttModel == "large-v3-v20240930_626MB") {
                    model.sttEngine = .whisperKit
                    model.sttModel = "large-v3-v20240930_626MB"
                }
                presetButton("WhisperKit Large v3", active: model.sttEngine == .whisperKit && model.sttModel == "openai_whisper-large-v3") {
                    model.sttEngine = .whisperKit
                    model.sttModel = "openai_whisper-large-v3"
                }
                presetButton("whisper.cpp 서버", active: model.sttEngine == .managedWhisper) {
                    model.sttEngine = .managedWhisper
                }
                Spacer()
            }
            .disabled(isLocked)

            Picker("STT 엔진", selection: $model.sttEngine) {
                ForEach(STTEngineKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isLocked)

            switch model.sttEngine {
            case .whisperKit:
                catalogSearchBar(placeholder: "WhisperKit 모델 검색 (예: turbo, large, distil)")
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredWhisperKitModels, id: \.self) { id in
                            xpcModelRow(
                                kind: .stt,
                                modelID: id,
                                title: ModelCatalog.whisperKitDescriptor(for: id)?.displayName ?? id,
                                subtitle: ModelCatalog.whisperKitDescriptor(for: id).map { "\($0.sizeLabel) · \($0.note)" } ?? "사용자 추가 WhisperKit 모델",
                                isSelected: model.sttModel == id
                            ) {
                                model.sttEngine = .whisperKit
                                model.sttModel = id
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                customModelAddBar(placeholder: "사용자 WhisperKit 모델 ID 추가 (예: openai_whisper-large-v3_947MB)") {
                    model.addCustomWhisperKitModel(customModelInput)
                    customModelInput = ""
                }

            case .managedWhisper:
                managedServerCompactBar(role: .stt)
                catalogSearchBar(placeholder: "GGML 모델 검색 (예: turbo, medium, q5)")
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredManagedModels(role: .stt)) { item in
                            managedRuntimeRow(item)
                        }
                    }
                    .padding(.vertical, 2)
                }

            case .appleSpeech:
                infoCard(
                    title: "Apple 온디바이스 음성 인식",
                    symbol: "apple.logo",
                    description: "macOS 내장 SFSpeechRecognizer를 사용합니다. 별도 모델 다운로드 없이 즉시 실행되며, 가볍고 빠르게 전사할 때 적합합니다."
                )

            case .deepgram:
                Form {
                    Picker("Deepgram 모델", selection: $model.deepgramModel) {
                        ForEach(ModelCatalog.deepgramModels) { item in
                            Text(item.pickerLabel).tag(item.id)
                        }
                    }
                    .disabled(isLocked)
                    if let desc = ModelCatalog.deepgramDescriptor(for: model.deepgramModel) {
                        Text(desc.note).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        SecureField("Deepgram API 키", text: $deepgramKey)
                            .textFieldStyle(.roundedBorder)
                        Button("키체인 저장") {
                            saveKey(deepgramKey, account: .deepgram, label: "Deepgram API 키를 저장했습니다.")
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
    }

    // MARK: - 번역 LLM 탭

    private var translationTabBody: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            // 추천 원클릭 프리셋
            HStack(spacing: 6) {
                Text("빠른 프리셋")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                presetButton("Apple 초고속", active: model.translationEngine == .appleTranslation) {
                    selectTranslationEngine(.appleTranslation)
                }
                presetButton("Qwen3 8B (추천)", active: model.translationEngine == .mlx && model.translationModel == "mlx-community/Qwen3-8B-4bit") {
                    model.translationEngine = .mlx
                    model.translationModel = "mlx-community/Qwen3-8B-4bit"
                    model.refreshResults()
                }
                presetButton("Gemma 3 12B", active: model.translationEngine == .mlx && model.translationModel == "mlx-community/gemma-3-12b-it-4bit") {
                    model.translationEngine = .mlx
                    model.translationModel = "mlx-community/gemma-3-12b-it-4bit"
                    model.refreshResults()
                }
                presetButton("llama.cpp 서버", active: model.translationEngine == .managedLlama) {
                    selectTranslationEngine(.managedLlama)
                }
                presetButton("외부 서버", active: model.translationEngine == .externalOpenAI) {
                    selectTranslationEngine(.externalOpenAI)
                }
                Spacer()
            }
            .disabled(isLocked)

            Picker("번역 엔진", selection: Binding(
                get: { model.translationEngine },
                set: { selectTranslationEngine($0) }
            )) {
                ForEach(TranslationEngineKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .disabled(isLocked)

            switch model.translationEngine {
            case .mlx:
                catalogSearchBar(placeholder: "MLX LLM 검색 (예: Qwen3, Gemma, Llama, 4bit)")
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredMLXModels, id: \.self) { id in
                            xpcModelRow(
                                kind: .translation,
                                modelID: id,
                                title: ModelCatalog.mlxDescriptor(for: id)?.displayName ?? id,
                                subtitle: ModelCatalog.mlxDescriptor(for: id).map { "\($0.sizeLabel) · \($0.note)" } ?? "사용자 추가 Hugging Face MLX 모델",
                                isSelected: model.translationModel == id
                            ) {
                                model.translationEngine = .mlx
                                model.translationModel = id
                                model.refreshResults()
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                customModelAddBar(placeholder: "Hugging Face MLX 모델 ID 추가 (예: mlx-community/Qwen3-30B-A3B-4bit)") {
                    model.addCustomMLXModel(customModelInput)
                    customModelInput = ""
                }

            case .managedLlama:
                managedServerCompactBar(role: .translation)
                catalogSearchBar(placeholder: "GGUF 모델 검색 (예: Gemma, Qwen, Llama)")
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredManagedModels(role: .translation)) { item in
                            managedRuntimeRow(item)
                        }
                    }
                    .padding(.vertical, 2)
                }

            case .externalOpenAI:
                Form {
                    Section("Ollama · LM Studio · vLLM · OpenAI 호환 서버") {
                        ExternalServerFields()
                    }
                }
                .formStyle(.grouped)
                .disabled(isLocked)

            case .appleTranslation:
                infoCard(
                    title: "Apple 전용 온디바이스 번역 (NMT)",
                    symbol: "translate",
                    description: "macOS 내장 저지연 신경망 번역을 사용합니다. 메모리를 거의 쓰지 않고 매우 빠릅니다. 언어 팩 설치가 필요하면 설정 › 엔진 탭에서 준비할 수 있습니다."
                )

            case .appleFoundation:
                infoCard(
                    title: "Apple Intelligence 온디바이스 모델",
                    symbol: "sparkles",
                    description: "macOS 시스템의 Apple Foundation Models를 사용해 별도 모델 다운로드 없이 번역합니다."
                )

            case .azure:
                Form {
                    HStack(spacing: 8) {
                        SecureField("Azure Translator API 키", text: $azureKey)
                            .textFieldStyle(.roundedBorder)
                        Button("키체인 저장") {
                            saveKey(azureKey, account: .azure, label: "Azure API 키를 저장했습니다.")
                        }
                    }
                    TextField("Azure 리전 (예: koreacentral)", text: $model.azureRegion)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isLocked)
                }
                .formStyle(.grouped)

            case .localAPI:
                Form {
                    TextField("로컬 번역 API 주소", text: $model.localTranslationAPI.endpoint)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isLocked)
                    HStack(spacing: 8) {
                        SecureField("Bearer API 키 (선택)", text: $localAPIKey)
                            .textFieldStyle(.roundedBorder)
                        Button("키체인 저장") {
                            saveKey(localAPIKey, account: .localTranslation, label: "로컬 API 키를 저장했습니다.")
                        }
                    }
                    Text("요청/응답 JSON 템플릿과 테스트는 설정(⌘,) › 엔진 탭에서 세부 조정할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
            }
        }
    }

    // MARK: - 필터 및 공통 컴포넌트

    private var filteredWhisperKitModels: [String] {
        model.models.filter { id in
            if installedOnly && !model.isModelDownloaded(kind: .stt, modelID: id) { return false }
            guard !searchText.isEmpty else { return true }
            let desc = ModelCatalog.whisperKitDescriptor(for: id)
            return id.localizedCaseInsensitiveContains(searchText)
                || (desc?.displayName.localizedCaseInsensitiveContains(searchText) ?? false)
                || (desc?.note.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var filteredMLXModels: [String] {
        model.mlxTranslationModels.filter { id in
            if installedOnly && !model.isModelDownloaded(kind: .translation, modelID: id) { return false }
            guard !searchText.isEmpty else { return true }
            let desc = ModelCatalog.mlxDescriptor(for: id)
            return id.localizedCaseInsensitiveContains(searchText)
                || (desc?.displayName.localizedCaseInsensitiveContains(searchText) ?? false)
                || (desc?.note.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private func filteredManagedModels(role: ManagedRuntimeRole) -> [ManagedRuntimeModel] {
        runtime.models(for: role).filter { item in
            if installedOnly && !runtime.installed.contains(item.id) { return false }
            guard !searchText.isEmpty else { return true }
            return item.name.localizedCaseInsensitiveContains(searchText)
                || item.note.localizedCaseInsensitiveContains(searchText)
                || item.id.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func presetButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(active ? .semibold : .regular))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    active ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10),
                    in: Capsule()
                )
                .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func catalogSearchBar(placeholder: String) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $searchText)
                .textFieldStyle(.roundedBorder)
            Toggle("설치됨만", isOn: $installedOnly)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
    }

    private func customModelAddBar(placeholder: String, onAdd: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $customModelInput)
                .textFieldStyle(.roundedBorder)
            Button("목록에 추가", systemImage: "plus") {
                onAdd()
            }
            .disabled(isLocked || customModelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func xpcModelRow(
        kind: ManagedModelKind,
        modelID: String,
        title: String,
        subtitle: String,
        isSelected: Bool,
        onSelect: @escaping () -> Void
    ) -> some View {
        let record = model.managedModel(kind: kind, modelID: modelID)
        let state = record?.state ?? .notDownloaded

        return HStack(spacing: 12) {
            Button(action: onSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isLocked)
            .help(isSelected ? "현재 선택된 모델입니다" : "이 모델로 전환")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                    if isSelected {
                        Text("사용 중")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    if state == .downloaded {
                        Text("설치됨 · \(formattedModelSize(record?.sizeInBytes ?? 0))")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if state == .downloading {
                    HStack(spacing: 8) {
                        ProgressView(value: record?.progress ?? 0)
                            .frame(maxWidth: 180)
                        Text("\(Int(((record?.progress ?? 0) * 100).rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else if state == .failed, let err = record?.error {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if !isSelected {
                Button("선택", action: onSelect)
                    .controlSize(.small)
                    .disabled(isLocked)
            }

            switch state {
            case .downloaded:
                Button(role: .destructive) {
                    deleteTarget = UnifiedDeleteTarget(title: title, source: .xpc(kind, modelID))
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(isLocked)
                .help("모델 파일 삭제")
            case .downloading:
                ProgressView().controlSize(.small)
            case .notDownloaded, .failed:
                Button("다운로드") {
                    model.downloadModel(kind: kind, modelID: modelID)
                }
                .controlSize(.small)
                .disabled(!model.serviceIsAvailable || isLocked)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            isSelected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func managedServerCompactBar(role: ManagedRuntimeRole) -> some View {
        let status = runtime.servers[role] ?? ManagedRuntimeServerStatus()
        let hasBinary = runtime.hasRuntimeExecutable(for: role)
        let isBusy = busyServerRoles.contains(role)
        return HStack(spacing: 8) {
            Image(systemName: status.phase == .ready ? "checkmark.circle.fill" : (hasBinary ? "server.rack" : "exclamationmark.triangle.fill"))
                .foregroundStyle(status.phase == .ready ? .green : (hasBinary ? .secondary : .orange))
            Text(hasBinary ? "\(role.executable) · \(status.phase.rawValue) (:\(role.port))" : "\(role.executable) 미설치")
                .font(.caption)
                .monospacedDigit()
            Spacer()
            if hasBinary {
                if status.phase == .ready {
                    Button("중지") {
                        Task { await runtime.stop(role) }
                    }
                    .controlSize(.small)
                } else {
                    Button(isBusy ? "시작 중…" : "서버 시작") {
                        startManagedServer(role)
                    }
                    .controlSize(.small)
                    .disabled(isBusy || isLocked)
                }
            }
            Button("로컬 .\(role.customFileExtension) 추가…", systemImage: "plus") {
                importLocalManagedModel(role: role)
            }
            .controlSize(.small)
            .disabled(isLocked)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func managedRuntimeRow(_ item: ManagedRuntimeModel) -> some View {
        let isInstalled = runtime.installed.contains(item.id)
        let isSelected = runtime.selected(item.role)?.id == item.id
        let isApplied = isSelected && (item.role == .stt ? model.sttEngine == .managedWhisper : model.translationEngine == .managedLlama)
        let transfer = runtime.transfers[item.id]

        return HStack(spacing: 12) {
            Button {
                applyManagedModel(item)
            } label: {
                Image(systemName: isApplied ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isApplied ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!isInstalled || isLocked || busyServerRoles.contains(item.role))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.callout.weight(isApplied ? .semibold : .medium))
                    if let badge = item.badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    if isApplied {
                        Text("사용 중")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                Text("\(item.sizeLabel) · \(item.note)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let transfer {
                    HStack(spacing: 8) {
                        ProgressView(value: transfer.progress)
                            .frame(maxWidth: 180)
                        Text("\(transfer.phase) · \(Int((transfer.progress * 100).rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            if transfer != nil {
                Button("취소") { runtime.cancelDownload(item.id) }
                    .controlSize(.small)
            } else if isInstalled {
                if !isApplied {
                    Button("적용") { applyManagedModel(item) }
                        .controlSize(.small)
                        .disabled(isLocked || busyServerRoles.contains(item.role))
                }
                Button(role: .destructive) {
                    deleteTarget = UnifiedDeleteTarget(title: item.name, source: .managedRuntime(item))
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(isLocked || busyServerRoles.contains(item.role))
                .help("모델 파일 삭제")
            } else {
                Button("다운로드") {
                    Task { try? await runtime.download(item) }
                }
                .controlSize(.small)
                .disabled(isLocked)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            isApplied ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func infoCard(title: String, symbol: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 동작

    private func selectTranslationEngine(_ engine: TranslationEngineKind) {
        model.translationEngine = engine
        model.syncTranslationModelForEngine()
        if model.canMutateStorage {
            model.refreshResults()
        }
    }

    private func saveKey(_ value: String, account: KeychainAccount, label: String) {
        do {
            try APIKeyStore.write(value, account: account)
            AppModel.notifyAPIKeysUpdated()
            keySaveNotice = label
        } catch {
            keySaveNotice = error.localizedDescription
        }
    }

    private func applyManagedModel(_ item: ManagedRuntimeModel) {
        busyServerRoles.insert(item.role)
        Task {
            defer { busyServerRoles.remove(item.role) }
            await runtime.select(item)
            if item.role == .stt {
                model.sttEngine = .managedWhisper
            } else {
                model.translationEngine = .managedLlama
                model.syncTranslationModelForEngine()
                model.refreshResults()
            }
            if runtime.hasRuntimeExecutable(for: item.role) {
                try? await runtime.ensureReady(item.role)
            }
        }
    }

    private func startManagedServer(_ role: ManagedRuntimeRole) {
        busyServerRoles.insert(role)
        Task {
            defer { busyServerRoles.remove(role) }
            do {
                try await runtime.ensureReady(role)
            } catch {
                runtime.lastError = error.localizedDescription
            }
        }
    }

    private func importLocalManagedModel(role: ManagedRuntimeRole) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = role == .stt ? "로컬 Whisper STT 모델(.bin) 선택" : "로컬 GGUF 번역 모델(.gguf) 선택"
        if let type = UTType(filenameExtension: role.customFileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let added = try runtime.importCustomModel(from: url, role: role)
            runtime.lastError = nil
            applyManagedModel(added)
        } catch {
            runtime.lastError = error.localizedDescription
        }
    }

    private func formattedModelSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "설치됨" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
