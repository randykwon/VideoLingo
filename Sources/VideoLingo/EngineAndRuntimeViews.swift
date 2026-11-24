import AppKit
import SwiftUI
import Translation
import UniformTypeIdentifiers
import VideoLingoCore

/// SpikDoum의 EngineSettingsView와 동일한 흐름으로
/// STT·번역 엔진 선택, Keychain API 키 관리, Apple 전용 번역 언어 준비, 연결 테스트를 제공합니다.
struct EngineSettingsTabView: View {
    @Environment(AppModel.self) private var model
    @State private var runtime = ManagedRuntimeManager.shared
    @State private var deepgramKey = ""
    @State private var azureKey = ""
    @State private var localTranslationKey = ""
    @State private var externalOpenAIKey = ""
    @State private var showingManagedModels = false
    @State private var statusMessage: String?
    @State private var isTestingLocalAPI = false
    @State private var localTestSample = "Hello. How are you today?"
    @State private var localTestResult: String?
    @State private var localTestTask: Task<Void, Never>?
    @State private var isTestingAzure = false
    @State private var azureTestResult: String?
    @State private var translationPrepConfig: TranslationSession.Configuration?
    @State private var isPreparingAppleTranslation = false
    @State private var appleTranslationStatus: String?
    @State private var customWhisperInput = ""
    @State private var customMLXInput = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section("음성 인식 (STT) 엔진") {
                Picker("STT 엔진", selection: $model.sttEngine) {
                    ForEach(STTEngineKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                switch model.sttEngine {
                case .whisperKit:
                    Picker("WhisperKit 모델", selection: $model.sttModel) {
                        ForEach(model.models, id: \.self) { id in
                            Text(ModelCatalog.whisperKitDescriptor(for: id)?.pickerLabel ?? "\(id) (사용자 추가)").tag(id)
                        }
                    }
                    if let desc = ModelCatalog.whisperKitDescriptor(for: model.sttModel) {
                        Text(desc.note).font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("사용자 정의 WhisperKit 모델 추가") {
                        HStack(spacing: 8) {
                            TextField("예: openai_whisper-large-v3_947MB", text: $customWhisperInput)
                                .textFieldStyle(.roundedBorder)
                            Button("추가") {
                                model.addCustomWhisperKitModel(customWhisperInput)
                                customWhisperInput = ""
                            }
                            .disabled(customWhisperInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(.top, 4)
                    }
                    Text("내장 WhisperKit(12종 + 사용자 추가) + SpeakerKit 화자 분리를 사용합니다.")
                        .font(.caption).foregroundStyle(.secondary)

                case .managedWhisper:
                    let installedSTT = runtime.models(for: .stt).filter { runtime.installed.contains($0.id) }
                    if !installedSTT.isEmpty {
                        Picker("설치된 GGML 모델", selection: Binding(
                            get: { runtime.selectedSTT },
                            set: { newID in
                                if let chosen = installedSTT.first(where: { $0.id == newID }) {
                                    Task { await runtime.select(chosen) }
                                }
                            }
                        )) {
                            ForEach(installedSTT) { item in
                                Text("\(item.name) (\(item.sizeLabel))").tag(item.id)
                            }
                        }
                    } else {
                        LabeledContent("선택된 GGML 모델", value: "설치된 모델 없음")
                    }
                    HStack(spacing: 8) {
                        Button("자체 모델 · 서버 관리…", systemImage: "cpu") {
                            showingManagedModels = true
                        }
                        if !runtime.hasRuntimeExecutable(for: .stt) {
                            Label("whisper-server 미설치", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Text("Metal GPU 기반 자체 whisper.cpp 서버(127.0.0.1:\(ManagedRuntimeRole.stt.port))로 9종 GGML 모델 또는 로컬 .bin 파일을 실행합니다.")
                        .font(.caption).foregroundStyle(.secondary)

                case .appleSpeech:
                    Text("macOS 온디바이스 음성 인식(SFSpeechRecognizer)으로 추가 모델 다운로드 없이 빠르게 전사합니다.")
                        .font(.caption).foregroundStyle(.secondary)

                case .deepgram:
                    Picker("Deepgram 모델", selection: $model.deepgramModel) {
                        ForEach(ModelCatalog.deepgramModels) { item in
                            Text(item.pickerLabel).tag(item.id)
                        }
                    }
                    if let desc = ModelCatalog.deepgramDescriptor(for: model.deepgramModel) {
                        Text(desc.note).font(.caption).foregroundStyle(.secondary)
                    }
                    SecureField("Deepgram API 키", text: $deepgramKey)
                        .textFieldStyle(.roundedBorder)
                    Text("Deepgram API로 다국어 전사 및 자동 화자 구분을 수행합니다. 오디오가 Deepgram 서버로 전송됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("번역 엔진") {
                Picker("번역 엔진", selection: $model.translationEngine) {
                    ForEach(TranslationEngineKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .onChange(of: model.translationEngine) { _, _ in
                    model.syncTranslationModelForEngine()
                    model.refreshResults()
                }

                switch model.translationEngine {
                case .mlx:
                    Picker("MLX 번역 모델", selection: $model.translationModel) {
                        ForEach(model.mlxTranslationModels, id: \.self) { id in
                            Text(ModelCatalog.mlxDescriptor(for: id)?.pickerLabel ?? "\(id) (사용자 추가)").tag(id)
                        }
                    }
                    .onChange(of: model.translationModel) { _, _ in model.refreshResults() }
                    if let desc = ModelCatalog.mlxDescriptor(for: model.translationModel) {
                        Text(desc.note).font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("사용자 정의 Hugging Face MLX 모델 추가") {
                        HStack(spacing: 8) {
                            TextField("예: mlx-community/Qwen3-30B-A3B-4bit", text: $customMLXInput)
                                .textFieldStyle(.roundedBorder)
                            Button("추가") {
                                model.addCustomMLXModel(customMLXInput)
                                customMLXInput = ""
                            }
                            .disabled(customMLXInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(.top, 4)
                    }
                    Text("Apple Silicon 온디바이스 MLX(Qwen3 · Qwen2.5 · Gemma 3 · Llama 3.2 · Mistral 등 13종 + 사용자 추가)를 지원합니다.")
                        .font(.caption).foregroundStyle(.secondary)

                case .appleTranslation:
                    HStack(spacing: 8) {
                        Button(isPreparingAppleTranslation ? "언어 팩 준비 중…" : "번역 언어 준비", systemImage: "arrow.down.circle") {
                            prepareAppleTranslationPack()
                        }
                        .disabled(isPreparingAppleTranslation)
                        if isPreparingAppleTranslation { ProgressView().controlSize(.small) }
                    }
                    if let appleTranslationStatus {
                        Text(appleTranslationStatus)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Apple 전용 온디바이스 NMT(.lowLatency 우선 + 기본 세션 자동 폴백)로 매우 빠르고 적은 메모리로 번역합니다.")
                        .font(.caption).foregroundStyle(.secondary)

                case .managedLlama:
                    let installedLLM = runtime.models(for: .translation).filter { runtime.installed.contains($0.id) }
                    if !installedLLM.isEmpty {
                        Picker("설치된 GGUF 모델", selection: Binding(
                            get: { runtime.selectedTranslation },
                            set: { newID in
                                if let chosen = installedLLM.first(where: { $0.id == newID }) {
                                    Task {
                                        await runtime.select(chosen)
                                        model.syncTranslationModelForEngine()
                                        model.refreshResults()
                                    }
                                }
                            }
                        )) {
                            ForEach(installedLLM) { item in
                                Text("\(item.name) (\(item.sizeLabel))").tag(item.id)
                            }
                        }
                    } else {
                        LabeledContent("선택된 GGUF 모델", value: "설치된 모델 없음")
                    }
                    HStack(spacing: 8) {
                        Button("자체 모델 · 서버 관리…", systemImage: "cpu") {
                            showingManagedModels = true
                        }
                        if !runtime.hasRuntimeExecutable(for: .translation) {
                            Label("llama-server 미설치", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Text("Metal GPU 기반 자체 llama.cpp 서버(127.0.0.1:\(ManagedRuntimeRole.translation.port))로 10종 GGUF 또는 로컬 .gguf 모델을 실행합니다.")
                        .font(.caption).foregroundStyle(.secondary)

                case .appleFoundation:
                    Text("macOS Apple Intelligence 온디바이스 Foundation Models를 사용합니다.")
                        .font(.caption).foregroundStyle(.secondary)

                case .azure:
                    SecureField("Azure Translator API 키", text: $azureKey)
                        .textFieldStyle(.roundedBorder)
                    TextField("Azure 리전 (예: koreacentral)", text: $model.azureRegion)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 8) {
                        Button(isTestingAzure ? "확인 중…" : "Azure 연결 테스트") {
                            Task { await testAzureTranslation() }
                        }
                        .disabled(isTestingAzure || azureKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if isTestingAzure { ProgressView().controlSize(.small) }
                    }
                    if let azureTestResult {
                        Text(azureTestResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }

                case .localAPI:
                    TextField("번역 API 주소", text: $model.localTranslationAPI.endpoint)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Bearer API 키 (선택)", text: $localTranslationKey)
                        .textFieldStyle(.roundedBorder)
                    Stepper(
                        "응답 대기: \(Int(model.localTranslationAPI.timeout))초",
                        value: $model.localTranslationAPI.timeout,
                        in: 5...180,
                        step: 5
                    )
                    DisclosureGroup("API 요청 · 응답 형식") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("{{text}}는 원문, {{source}}는 원문 언어 코드, {{target}}은 대상 언어 코드로 치환됩니다.")
                                .font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $model.localTranslationAPI.requestJSON)
                                .font(.caption.monospaced())
                                .frame(height: 84)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                            TextField("응답 JSON 경로 (비우면 자동 감지)", text: $model.localTranslationAPI.responsePath)
                                .textFieldStyle(.roundedBorder)
                            Text("예: translation, translated_text, data.translation, translations.0.text, choices.0.message.content")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                    TextField("테스트 원문", text: $localTestSample)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 8) {
                        Button(isTestingLocalAPI ? "번역 확인 중…" : "로컬 번역 테스트") {
                            localTestTask = Task { await testLocalAPITranslation() }
                        }
                        .disabled(isTestingLocalAPI || localTestSample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if isTestingLocalAPI {
                            Button("취소") { localTestTask?.cancel() }
                            ProgressView().controlSize(.small)
                        }
                    }
                    if let localTestResult {
                        Text(localTestResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }

                case .externalOpenAI:
                    HStack(spacing: 6) {
                        Button("Ollama") { model.externalServerEndpoint = "http://localhost:11434/v1" }
                        Button("LM Studio") { model.externalServerEndpoint = "http://localhost:1234/v1" }
                        Button("vLLM") { model.externalServerEndpoint = "http://localhost:8000/v1" }
                        Button("OpenAI") { model.externalServerEndpoint = "https://api.openai.com/v1" }
                        Button("OpenRouter") { model.externalServerEndpoint = "https://openrouter.ai/api/v1" }
                    }
                    .controlSize(.small)
                    TextField("서버 주소", text: $model.externalServerEndpoint, prompt: Text("http://localhost:11434/v1"))
                        .textFieldStyle(.roundedBorder)
                    TextField("모델 이름", text: $model.externalServerModel, prompt: Text("qwen3:8b · gemma3:12b · gpt-4.1-mini"))
                        .textFieldStyle(.roundedBorder)
                    if !model.discoveredExternalModels.isEmpty {
                        Picker("서버에서 불러온 모델", selection: $model.externalServerModel) {
                            ForEach(model.discoveredExternalModels, id: \.self) { id in
                                Text(id).tag(id)
                            }
                        }
                    }
                    SecureField("서버 API 키 (인증 없는 로컬 서버는 비워 두세요)", text: $externalOpenAIKey)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 8) {
                        Button(model.isFetchingExternalModels ? "조회 중…" : "서버 모델 목록 불러오기", systemImage: "arrow.triangle.2.circlepath") {
                            Task {
                                try? APIKeyStore.write(externalOpenAIKey, account: .externalOpenAI)
                                await model.fetchExternalServerModels()
                            }
                        }
                        .disabled(model.isFetchingExternalModels || model.externalServerEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button(model.isTestingExternalServer ? "확인 중…" : "연결 테스트") {
                            Task {
                                try? APIKeyStore.write(externalOpenAIKey, account: .externalOpenAI)
                                await model.testExternalServerConnection()
                            }
                        }
                        .disabled(model.isTestingExternalServer)
                        if model.isTestingExternalServer || model.isFetchingExternalModels {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if !model.externalServerTestMessage.isEmpty {
                        Text(model.externalServerTestMessage)
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }

            Section("자체 모델 · API 키 관리") {
                HStack(spacing: 12) {
                    Button("자체 모델 · 서버 관리…", systemImage: "server.rack") {
                        showingManagedModels = true
                    }
                    Spacer()
                    Button("API 키 키체인에 저장", systemImage: "key.fill") {
                        saveAllAPIKeys()
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("외부 API 키(Deepgram · Azure · 로컬 번역 API · OpenAI 호환 서버)는 macOS 키체인에 안전하게 보관됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingManagedModels) {
            ManagedRuntimeModelsSheet()
                .environment(model)
        }
        .translationTask(translationPrepConfig) { session in
            await runAppleTranslationPreparation(session)
        }
        .onAppear { loadAPIKeys() }
        .onDisappear { localTestTask?.cancel() }
    }

    private func loadAPIKeys() {
        deepgramKey = APIKeyStore.read(.deepgram)
        azureKey = APIKeyStore.read(.azure)
        localTranslationKey = APIKeyStore.read(.localTranslation)
        let storedOpenAI = APIKeyStore.read(.externalOpenAI)
        externalOpenAIKey = storedOpenAI.isEmpty ? model.externalServerAPIKey : storedOpenAI
    }

    private func saveAllAPIKeys() {
        do {
            try APIKeyStore.write(deepgramKey, account: .deepgram)
            try APIKeyStore.write(azureKey, account: .azure)
            try APIKeyStore.write(localTranslationKey, account: .localTranslation)
            try APIKeyStore.write(externalOpenAIKey, account: .externalOpenAI)
            // 기존 UserDefaults 평문 키는 키체인 이관 후 제거합니다.
            model.externalServerAPIKey = ""
            AppModel.notifyAPIKeysUpdated()
            statusMessage = "API 키를 macOS 키체인에 저장했습니다."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private struct TranslationSessionPrepBox: @unchecked Sendable {
        let session: TranslationSession
    }

    private func runAppleTranslationPreparation(_ session: TranslationSession) async {
        let box = TranslationSessionPrepBox(session: session)
        isPreparingAppleTranslation = true
        defer { isPreparingAppleTranslation = false }
        do {
            try await box.session.prepareTranslation()
            appleTranslationStatus = "선택한 언어 쌍의 Apple 온디바이스 번역 모델이 준비되었습니다."
        } catch {
            appleTranslationStatus = "번역 언어 준비 실패: \(error.localizedDescription)"
        }
    }

    private func prepareAppleTranslationPack() {
        let sourceCode = VideoLingoLanguageCatalog.appleTranslationCode(for: model.sourceLanguage.isEmpty ? "en" : model.sourceLanguage)
        let targetCode = VideoLingoLanguageCatalog.appleTranslationCode(for: model.selectedLanguage)
        guard sourceCode != targetCode else {
            appleTranslationStatus = "원문 언어와 대상 언어가 같아 별도 언어 팩이 필요하지 않습니다."
            return
        }
        let source = Locale.Language(identifier: sourceCode)
        let target = Locale.Language(identifier: targetCode)
        if translationPrepConfig?.source == source && translationPrepConfig?.target == target {
            translationPrepConfig?.invalidate()
        } else if #available(macOS 26.4, *) {
            translationPrepConfig = TranslationSession.Configuration(source: source, target: target, preferredStrategy: .lowLatency)
        } else {
            translationPrepConfig = TranslationSession.Configuration(source: source, target: target)
        }
    }

    private func testLocalAPITranslation() async {
        isTestingLocalAPI = true
        localTestResult = nil
        defer { isTestingLocalAPI = false }
        do {
            let started = Date()
            let sourceCode = VideoLingoLanguageCatalog.whisperParameter(for: model.sourceLanguage.isEmpty ? "en" : model.sourceLanguage)
            let result = try await CustomLocalTranslatorClient(
                settings: model.localTranslationAPI,
                apiKey: localTranslationKey
            ).translate(localTestSample, source: sourceCode, target: model.selectedLanguage)
            localTestResult = "번역 성공 · \(Int(Date().timeIntervalSince(started) * 1000))ms · \(result)"
        } catch {
            localTestResult = Task.isCancelled ? "테스트를 취소했습니다." : "실패: \(error.localizedDescription)"
        }
    }

    private func testAzureTranslation() async {
        isTestingAzure = true
        azureTestResult = nil
        defer { isTestingAzure = false }
        do {
            let started = Date()
            let result = try await AzureTranslatorClient(
                apiKey: azureKey,
                region: model.azureRegion
            ).translate("Hello, how are you?", targetLanguage: model.selectedLanguage)
            azureTestResult = "연결 성공 · \(Int(Date().timeIntervalSince(started) * 1000))ms · \(result)"
        } catch {
            azureTestResult = "실패: \(error.localizedDescription)"
        }
    }
}

/// SpikDoum의 ManagedModelsView와 동일한 자체 모델(19종 + 로컬 .bin/.gguf) 다운로드·적용 및 서버 모니터 시트입니다.
struct ManagedRuntimeModelsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var manager = ManagedRuntimeManager.shared
    @State private var removing: ManagedRuntimeModel?
    @State private var working: Set<ManagedRuntimeRole> = []
    @State private var selectedTab = "models"
    @State private var roleFilter = "all"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("자체 모델 · 서버 관리")
                    .font(.title2.bold())
                Spacer()
                Button("모델 폴더 열기", systemImage: "folder") {
                    try? FileManager.default.createDirectory(at: manager.store.root, withIntermediateDirectories: true)
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: manager.store.root.path)
                }
                Button("완료") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Text("검증된 GGML/GGUF 모델을 다운로드하거나 로컬 .bin/.gguf 파일을 추가하면 외부 Python·Ollama 설치 없이 Metal GPU로 실행합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("관리 화면", selection: $selectedTab) {
                Text("모델 다운로드 · 적용").tag("models")
                Text("서버 모니터 · 로그").tag("servers")
            }
            .pickerStyle(.segmented)

            if let error = manager.lastError {
                HStack(spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    Spacer()
                    Button("닫기") { manager.lastError = nil }
                        .controlSize(.small)
                }
            }

            if selectedTab == "models" {
                HStack(spacing: 12) {
                    Picker("종류", selection: $roleFilter) {
                        Text("전체 (\(manager.allModels.count))").tag("all")
                        Text("STT (\(manager.models(for: .stt).count))").tag(ManagedRuntimeRole.stt.rawValue)
                        Text("번역 (\(manager.models(for: .translation).count))").tag(ManagedRuntimeRole.translation.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                    Spacer()
                    Text("설치됨 \(manager.installed.count)개")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("로컬 STT (.bin)", systemImage: "plus") { importCustomModel(role: .stt) }
                        .controlSize(.small)
                        .help("직접 내려받은 Whisper GGML .bin 모델 파일 추가")
                    Button("로컬 번역 (.gguf)", systemImage: "plus") { importCustomModel(role: .translation) }
                        .controlSize(.small)
                        .help("직접 내려받은 llama.cpp .gguf 번역 모델 파일 추가")
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if selectedTab == "models" {
                        let visibleRoles = ManagedRuntimeRole.allCases.filter { roleFilter == "all" || roleFilter == $0.rawValue }
                        ForEach(visibleRoles) { role in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Text(role.title + " 모델").font(.headline)
                                    Text(role == .stt ? "whisper.cpp · Metal GPU" : "llama.cpp · Metal GPU")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(manager.models(for: role)) { item in
                                    modelRow(item)
                                }
                            }
                        }
                        Text("다운로드는 Hugging Face 고정 리비전의 파일 크기와 SHA-256을 검증한 뒤 설치합니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ManagedRuntimeRole.allCases) { role in
                            serverCard(role)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        .frame(width: 880, height: 700)
        .confirmationDialog(
            "모델 파일을 삭제할까요?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { target in
            Button("모델 삭제", role: .destructive) {
                Task { await manager.remove(target) }
                removing = nil
            }
            Button("취소", role: .cancel) { removing = nil }
        } message: { target in
            Text("\(target.name) 파일만 삭제합니다. 저장된 전사·번역 결과는 유지됩니다.")
        }
    }

    private func modelRow(_ item: ManagedRuntimeModel) -> some View {
        let isInstalled = manager.installed.contains(item.id)
        let isSelected = manager.selected(item.role)?.id == item.id
        let isApplied = isSelected && (item.role == .stt ? model.sttEngine == .managedWhisper : model.translationEngine == .managedLlama)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.name).font(.callout.weight(.semibold))
                        if let badge = item.badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background((item.isCustom ? Color.purple : Color.accentColor).opacity(0.15), in: Capsule())
                                .foregroundStyle(item.isCustom ? .purple : Color.accentColor)
                        }
                        if isApplied {
                            Label("적용됨", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                        }
                    }
                    Text("\(item.sizeLabel) · \(item.note)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if let sourceURL = item.sourceURL {
                    Link("출처", destination: sourceURL).font(.caption)
                }
                if manager.transfers[item.id] != nil {
                    Button("취소") { manager.cancelDownload(item.id) }
                } else if isInstalled {
                    Button(isApplied ? "다시 적용" : "적용") { apply(item) }
                        .disabled(working.contains(item.role))
                    Button(role: .destructive) { removing = item } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("모델 파일 삭제")
                    .disabled(working.contains(item.role))
                } else {
                    Button("다운로드") {
                        Task { try? await manager.download(item) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if let transfer = manager.transfers[item.id] {
                ProgressView(value: transfer.progress)
                Text("\(transfer.phase) · \(Int((transfer.progress * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text(isInstalled ? (item.isCustom ? "로컬 파일 추가됨" : "다운로드 완료 · SHA-256 검증됨") : "다운로드되지 않음")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func serverCard(_ role: ManagedRuntimeRole) -> some View {
        let status = manager.servers[role] ?? ManagedRuntimeServerStatus()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("\(role.title) 서버", systemImage: "server.rack").font(.headline)
                Label(
                    status.phase.rawValue,
                    systemImage: status.phase == .ready ? "checkmark.circle.fill" : (status.phase == .failed ? "exclamationmark.triangle.fill" : "circle.fill")
                )
                .font(.caption)
                .foregroundStyle(status.phase == .ready ? .green : (status.phase == .failed ? .orange : .secondary))
                Spacer()
                Button("시작") { serverAction(role, restart: false) }
                    .disabled(working.contains(role) || status.phase == .starting || status.phase == .ready || status.phase == .stopping)
                Button("재시작") { serverAction(role, restart: true) }
                    .disabled(working.contains(role) || status.phase == .stopping)
                Button("중지") { Task { await manager.stop(role) } }
                    .disabled(status.pid == nil || status.phase == .stopping)
            }
            Text("모델: \(manager.selected(role)?.name ?? "미선택") · \(role.baseURL.absoluteString)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 16) {
                Text("PID \(status.pid.map(String.init) ?? "—")")
                Text(String(format: "CPU %.1f%%", status.cpu))
                Text(String(format: "메모리 %.0f MB", status.memoryMB))
                Text("처리 \(status.requests)회")
                if let latency = status.lastLatencyMS { Text("최근 \(latency)ms") }
            }
            .font(.caption)
            .monospacedDigit()
            if let started = status.startedAt {
                Text("시작 시각: \(started.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = status.error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            DisclosureGroup("서버 로그 · 최근 24,000자") {
                ScrollView {
                    Text(manager.logs[role].flatMap { $0.isEmpty ? nil : $0 } ?? "서버를 시작하면 로그가 표시됩니다.")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
            }
            .font(.caption)
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func importCustomModel(role: ManagedRuntimeRole) {
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
            let added = try manager.importCustomModel(from: url, role: role)
            manager.lastError = nil
            apply(added)
        } catch {
            manager.lastError = error.localizedDescription
        }
    }

    private func apply(_ item: ManagedRuntimeModel) {
        working.insert(item.role)
        Task {
            defer { working.remove(item.role) }
            await manager.select(item)
            if item.role == .stt {
                model.sttEngine = .managedWhisper
            } else {
                model.translationEngine = .managedLlama
                model.syncTranslationModelForEngine()
            }
            do {
                try await manager.ensureReady(item.role)
            } catch {
                manager.lastError = error.localizedDescription
            }
        }
    }

    private func serverAction(_ role: ManagedRuntimeRole, restart: Bool) {
        working.insert(role)
        Task {
            defer { working.remove(role) }
            do {
                if restart { try await manager.restart(role) }
                else { try await manager.ensureReady(role) }
            } catch {
                manager.lastError = error.localizedDescription
            }
        }
    }
}
