import Foundation
import os

private let apiLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "APIHandlers")

final class APIHandlers: @unchecked Sendable {
    private let modelManager: ModelManagerService
    private let audioFileService: AudioFileService
    private let translationService: AnyObject? // TranslationService (macOS 15+)
    private let historyService: HistoryService
    private let profileService: ProfileService
    private let dictionaryService: DictionaryService
    private let dictationViewModel: DictationViewModel

    init(modelManager: ModelManagerService, audioFileService: AudioFileService, translationService: AnyObject?, historyService: HistoryService, profileService: ProfileService, dictionaryService: DictionaryService, dictationViewModel: DictationViewModel) {
        self.modelManager = modelManager
        self.audioFileService = audioFileService
        self.translationService = translationService
        self.historyService = historyService
        self.profileService = profileService
        self.dictionaryService = dictionaryService
        self.dictationViewModel = dictationViewModel
    }

    func register(on router: APIRouter) {
        router.register("POST", "/v1/transcribe", handler: handleTranscribe)
        router.register("GET", "/v1/status", handler: handleStatus)
        router.register("GET", "/v1/models", handler: handleModels)
        router.register("GET", "/v1/history", handler: handleGetHistory)
        router.register("DELETE", "/v1/history", handler: handleDeleteHistory)
        router.register("GET", "/v1/profiles", handler: handleGetProfiles)
        router.register("PUT", "/v1/profiles/toggle", handler: handleToggleProfile)
        router.register("POST", "/v1/dictation/start", handler: handleStartDictation)
        router.register("POST", "/v1/dictation/stop", handler: handleStopDictation)
        router.register("GET", "/v1/dictation/status", handler: handleDictationStatus)
        // Dictionary
        router.register("GET", "/v1/dictionary/terms", handler: handleGetTerms)
        router.register("POST", "/v1/dictionary/terms", handler: handleSetTerms)
        router.register("POST", "/v1/dictionary/terms/add", handler: handleAddTerms)
        router.register("POST", "/v1/dictionary/terms/remove", handler: handleRemoveTerms)
        router.register("GET", "/v1/dictionary/corrections", handler: handleGetCorrections)
        router.register("POST", "/v1/dictionary/corrections", handler: handleSetCorrections)
        router.register("POST", "/v1/dictionary/corrections/add", handler: handleAddCorrections)
        router.register("POST", "/v1/dictionary/corrections/remove", handler: handleRemoveCorrections)
    }

    // MARK: - POST /v1/transcribe

    private func handleTranscribe(_ request: HTTPRequest) async -> HTTPResponse {
        // Note: Don't pre-check isModelReady here - let transcribe() handle auto-restore
        // for models that were auto-unloaded but can be re-loaded.
        let hasEngine = await modelManager.selectedProviderId != nil
        guard hasEngine else {
            return .error(status: 503, message: "No engine selected. Select an engine in TypeWhisper first.")
        }

        let audioData: Data
        var fileExtension = "wav"
        var language: String?
        var task: TranscriptionTask = .transcribe
        var targetLanguage: String?
        var responseFormat = "json"

        let contentType = request.headers["content-type"] ?? ""

        if contentType.contains("multipart/form-data"),
           let boundary = extractBoundary(from: contentType) {
            let parts = HTTPRequestParser.parseMultipart(body: request.body, boundary: boundary)

            guard let filePart = parts.first(where: { $0.name == "file" }) else {
                return .error(status: 400, message: "Missing 'file' part in multipart form data")
            }

            audioData = filePart.data

            if let fn = filePart.filename, let ext = fn.split(separator: ".").last {
                fileExtension = String(ext).lowercased()
            } else if let ct = filePart.contentType {
                fileExtension = extensionFromMIME(ct)
            }

            if let langPart = parts.first(where: { $0.name == "language" }),
               let val = String(data: langPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                language = val
            }

            if let taskPart = parts.first(where: { $0.name == "task" }),
               let val = String(data: taskPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let parsed = TranscriptionTask(rawValue: val) {
                task = parsed
            }

            if let targetPart = parts.first(where: { $0.name == "target_language" }),
               let val = String(data: targetPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                targetLanguage = val
            }

            if let formatPart = parts.first(where: { $0.name == "response_format" }),
               let val = String(data: formatPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                responseFormat = val
            }
        } else if !request.body.isEmpty {
            audioData = request.body
            fileExtension = extensionFromMIME(contentType)
            language = request.headers["x-language"]
            if let taskStr = request.headers["x-task"], let parsed = TranscriptionTask(rawValue: taskStr) {
                task = parsed
            }
            targetLanguage = request.headers["x-target-language"]
            if let format = request.headers["x-response-format"], !format.isEmpty {
                responseFormat = format
            }
        } else {
            return .error(status: 400, message: "No audio data provided")
        }

        guard !audioData.isEmpty else {
            return .error(status: 400, message: "Empty audio data")
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".\(fileExtension)")

        do {
            try audioData.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let samples = try await audioFileService.loadAudioSamples(from: tempURL)
            let result = try await modelManager.transcribe(audioSamples: samples, language: language, task: task)

            var finalText = result.text
            if let targetCode = targetLanguage {
                #if canImport(Translation)
                if #available(macOS 15, *), let ts = translationService as? TranslationService {
                    if let targetNormalized = TranslationService.normalizedLanguageIdentifier(from: targetCode) {
                        if targetCode.caseInsensitiveCompare(targetNormalized) != .orderedSame {
                            apiLogger.info("API translation target normalized \(targetCode, privacy: .public) -> \(targetNormalized, privacy: .public)")
                        }
                        let target = Locale.Language(identifier: targetNormalized)
                        let sourceRaw = result.detectedLanguage
                        let sourceNormalized = TranslationService.normalizedLanguageIdentifier(from: sourceRaw)
                        if let sourceRaw {
                            if let sourceNormalized {
                                if sourceRaw.caseInsensitiveCompare(sourceNormalized) != .orderedSame {
                                    apiLogger.info("API translation source normalized \(sourceRaw, privacy: .public) -> \(sourceNormalized, privacy: .public)")
                                }
                            } else {
                                apiLogger.warning("API translation source language \(sourceRaw, privacy: .public) invalid, using auto source")
                            }
                        }
                        let sourceLanguage = sourceNormalized.map { Locale.Language(identifier: $0) }
                        finalText = try await ts.translate(
                            text: finalText,
                            to: target,
                            source: sourceLanguage
                        )
                    } else {
                        apiLogger.error("API translation target language invalid: \(targetCode, privacy: .public)")
                    }
                } else {
                    return .error(status: 501, message: "Translation requires macOS 15 or later")
                }
                #else
                return .error(status: 501, message: "Translation requires macOS 15 or later")
                #endif
            }

            let modelId = await modelManager.selectedModelId

            if responseFormat == "verbose_json" {
                struct SegmentEntry: Encodable {
                    let start: Double
                    let end: Double
                    let text: String
                }

                struct VerboseResponse: Encodable {
                    let text: String
                    let language: String?
                    let duration: Double
                    let processing_time: Double
                    let engine: String
                    let model: String?
                    let segments: [SegmentEntry]
                }

                let segments = result.segments.map {
                    SegmentEntry(start: $0.start, end: $0.end, text: $0.text)
                }

                return .json(VerboseResponse(
                    text: finalText,
                    language: result.detectedLanguage,
                    duration: result.duration,
                    processing_time: result.processingTime,
                    engine: result.engineUsed,
                    model: modelId,
                    segments: segments
                ))
            } else {
                struct TranscribeResponse: Encodable {
                    let text: String
                    let language: String?
                    let duration: Double
                    let processing_time: Double
                    let engine: String
                    let model: String?
                }

                return .json(TranscribeResponse(
                    text: finalText,
                    language: result.detectedLanguage,
                    duration: result.duration,
                    processing_time: result.processingTime,
                    engine: result.engineUsed,
                    model: modelId
                ))
            }
        } catch {
            return .error(status: 500, message: "Transcription failed: \(error.localizedDescription)")
        }
    }

    // MARK: - GET /v1/status

    private func handleStatus(_ request: HTTPRequest) async -> HTTPResponse {
        let providerId = await modelManager.selectedProviderId
        let isReady = await modelManager.isModelReady
        let supportsStreaming = await modelManager.supportsStreaming
        let supportsTranslation = await modelManager.supportsTranslation

        struct StatusResponse: Encodable {
            let status: String
            let engine: String?
            let supports_streaming: Bool
            let supports_translation: Bool
        }

        let response = StatusResponse(
            status: isReady ? "ready" : "no_model",
            engine: providerId,
            supports_streaming: supportsStreaming,
            supports_translation: supportsTranslation
        )
        return .json(response)
    }

    // MARK: - GET /v1/models

    @MainActor
    private func handleModels(_ request: HTTPRequest) async -> HTTPResponse {
        struct ModelEntry: Encodable {
            let id: String
            let engine: String
            let name: String
            let size_description: String
            let language_count: Int
            let status: String
            let selected: Bool
        }

        let selectedProviderId = modelManager.selectedProviderId
        var models: [ModelEntry] = []

        for engine in PluginManager.shared.transcriptionEngines {
            let isSelected = engine.providerId == selectedProviderId
            for model in engine.transcriptionModels {
                models.append(ModelEntry(
                    id: model.id,
                    engine: engine.providerId,
                    name: model.displayName,
                    size_description: model.sizeDescription,
                    language_count: model.languageCount,
                    status: engine.isConfigured ? "ready" : "not_configured",
                    selected: isSelected && engine.selectedModelId == model.id
                ))
            }
        }

        struct ModelsResponse: Encodable { let models: [ModelEntry] }
        return .json(ModelsResponse(models: models))
    }

    // MARK: - GET /v1/history

    private func handleGetHistory(_ request: HTTPRequest) async -> HTTPResponse {
        let query = request.queryParams["q"]
        let limit = min(Int(request.queryParams["limit"] ?? "") ?? 50, 200)
        let offset = max(Int(request.queryParams["offset"] ?? "") ?? 0, 0)

        let historyService = self.historyService
        return await MainActor.run {
            let allRecords: [TranscriptionRecord]
            if let query, !query.isEmpty {
                allRecords = historyService.searchRecords(query: query)
            } else {
                allRecords = historyService.records
            }

            let total = allRecords.count
            let sliceEnd = min(offset + limit, total)
            let sliceStart = min(offset, total)
            let page = Array(allRecords[sliceStart..<sliceEnd])

            struct HistoryEntry: Encodable {
                let id: String
                let text: String
                let raw_text: String
                let timestamp: Date
                let app_name: String?
                let app_bundle_id: String?
                let app_url: String?
                let duration: Double
                let language: String?
                let engine: String
                let model: String?
                let words_count: Int
            }

            struct HistoryResponse: Encodable {
                let entries: [HistoryEntry]
                let total: Int
                let limit: Int
                let offset: Int
            }

            let entries = page.map { record in
                HistoryEntry(
                    id: record.id.uuidString,
                    text: record.finalText,
                    raw_text: record.rawText,
                    timestamp: record.timestamp,
                    app_name: record.appName,
                    app_bundle_id: record.appBundleIdentifier,
                    app_url: record.appURL,
                    duration: record.durationSeconds,
                    language: record.language,
                    engine: record.engineUsed,
                    model: record.modelUsed,
                    words_count: record.wordsCount
                )
            }

            return .json(HistoryResponse(entries: entries, total: total, limit: limit, offset: offset))
        }
    }

    // MARK: - DELETE /v1/history

    private func handleDeleteHistory(_ request: HTTPRequest) async -> HTTPResponse {
        guard let idString = request.queryParams["id"],
              let uuid = UUID(uuidString: idString) else {
            return .error(status: 400, message: "Missing or invalid 'id' query parameter")
        }

        let historyService = self.historyService
        return await MainActor.run {
            guard let record = historyService.records.first(where: { $0.id == uuid }) else {
                return .error(status: 404, message: "History entry not found")
            }

            historyService.deleteRecord(record)
            return .json(["deleted": true])
        }
    }

    // MARK: - GET /v1/profiles

    private func handleGetProfiles(_ request: HTTPRequest) async -> HTTPResponse {
        let profileService = self.profileService
        return await MainActor.run {
            struct ProfileEntry: Encodable {
                let id: String
                let name: String
                let is_enabled: Bool
                let priority: Int
                let bundle_identifiers: [String]
                let url_patterns: [String]
                let input_language: String?
                let translation_target_language: String?
            }

            struct ProfilesResponse: Encodable {
                let profiles: [ProfileEntry]
            }

            let entries = profileService.profiles.map { profile in
                ProfileEntry(
                    id: profile.id.uuidString,
                    name: profile.name,
                    is_enabled: profile.isEnabled,
                    priority: profile.priority,
                    bundle_identifiers: profile.bundleIdentifiers,
                    url_patterns: profile.urlPatterns,
                    input_language: profile.inputLanguage,
                    translation_target_language: profile.translationTargetLanguage
                )
            }

            return .json(ProfilesResponse(profiles: entries))
        }
    }

    // MARK: - PUT /v1/profiles/toggle

    private func handleToggleProfile(_ request: HTTPRequest) async -> HTTPResponse {
        guard let idString = request.queryParams["id"],
              let uuid = UUID(uuidString: idString) else {
            return .error(status: 400, message: "Missing or invalid 'id' query parameter")
        }

        let profileService = self.profileService
        return await MainActor.run {
            guard let profile = profileService.profiles.first(where: { $0.id == uuid }) else {
                return .error(status: 404, message: "Profile not found")
            }

            profileService.toggleProfile(profile)

            struct ToggleResponse: Encodable {
                let id: String
                let name: String
                let is_enabled: Bool
            }

            return .json(ToggleResponse(
                id: profile.id.uuidString,
                name: profile.name,
                is_enabled: profile.isEnabled
            ))
        }
    }

    // MARK: - POST /v1/dictation/start

    private func handleStartDictation(_ request: HTTPRequest) async -> HTTPResponse {
        let dictationViewModel = self.dictationViewModel
        return await MainActor.run {
            guard !dictationViewModel.isRecording else {
                return .error(status: 409, message: "Already recording")
            }
            dictationViewModel.apiStartRecording()

            struct StartResponse: Encodable { let status: String }
            return .json(StartResponse(status: "recording"))
        }
    }

    // MARK: - POST /v1/dictation/stop

    private func handleStopDictation(_ request: HTTPRequest) async -> HTTPResponse {
        let dictationViewModel = self.dictationViewModel
        return await MainActor.run {
            guard dictationViewModel.isRecording else {
                return .error(status: 409, message: "Not recording")
            }
            dictationViewModel.apiStopRecording()

            struct StopResponse: Encodable { let status: String }
            return .json(StopResponse(status: "stopped"))
        }
    }

    // MARK: - GET /v1/dictation/status

    private func handleDictationStatus(_ request: HTTPRequest) async -> HTTPResponse {
        let dictationViewModel = self.dictationViewModel
        return await MainActor.run {
            struct DictationStatusResponse: Encodable { let is_recording: Bool }
            return .json(DictationStatusResponse(is_recording: dictationViewModel.isRecording))
        }
    }

    // MARK: - Dictionary helpers

    private struct TermEntry: Codable {
        let id: String
        let original: String
        let is_enabled: Bool
        let usage_count: Int
        let created_at: Date
    }

    private struct CorrectionEntry: Codable {
        let id: String
        let original: String
        let replacement: String
        let case_sensitive: Bool
        let is_enabled: Bool
        let usage_count: Int
        let created_at: Date
    }

    private func termEntry(from e: DictionaryEntry) -> TermEntry {
        TermEntry(id: e.id.uuidString, original: e.original, is_enabled: e.isEnabled, usage_count: e.usageCount, created_at: e.createdAt)
    }

    private func correctionEntry(from e: DictionaryEntry) -> CorrectionEntry {
        CorrectionEntry(id: e.id.uuidString, original: e.original, replacement: e.replacement ?? "", case_sensitive: e.caseSensitive, is_enabled: e.isEnabled, usage_count: e.usageCount, created_at: e.createdAt)
    }

    // MARK: - GET /v1/dictionary/terms

    private func handleGetTerms(_ request: HTTPRequest) async -> HTTPResponse {
        let ds = dictionaryService
        return await MainActor.run {
            struct TermsResponse: Encodable {
                let terms: [TermEntry]
                let count: Int
                let prompt: String?
            }
            let entries = ds.entries.filter { $0.type == .term }
            let mapped = entries.map { self.termEntry(from: $0) }
            return .json(TermsResponse(terms: mapped, count: mapped.count, prompt: ds.getTermsForPrompt()))
        }
    }

    // MARK: - POST /v1/dictionary/terms (replace all)

    private func handleSetTerms(_ request: HTTPRequest) async -> HTTPResponse {
        struct Body: Decodable { let terms: [String] }
        guard let body = try? JSONDecoder().decode(Body.self, from: request.body) else {
            return .error(status: 400, message: "Expected JSON body: {\"terms\": [\"word1\", ...]}")
        }
        let ds = dictionaryService
        return await MainActor.run {
            // Remove existing terms
            let existing = ds.entries.filter { $0.type == .term }
            ds.deleteEntries(existing)
            // Add new ones
            let items = body.terms.map { (type: DictionaryEntryType.term, original: $0, replacement: String?.none, caseSensitive: false) }
            ds.addEntries(items)
            let newEntries = ds.entries.filter { $0.type == .term }
            struct TermsResponse: Encodable { let terms: [TermEntry]; let count: Int; let prompt: String? }
            return .json(TermsResponse(terms: newEntries.map { self.termEntry(from: $0) }, count: newEntries.count, prompt: ds.getTermsForPrompt()))
        }
    }

    // MARK: - POST /v1/dictionary/terms/add

    private func handleAddTerms(_ request: HTTPRequest) async -> HTTPResponse {
        struct Body: Decodable { let terms: [String] }
        guard let body = try? JSONDecoder().decode(Body.self, from: request.body) else {
            return .error(status: 400, message: "Expected JSON body: {\"terms\": [\"word1\", ...]}")
        }
        let ds = dictionaryService
        return await MainActor.run {
            let existingSet = Set(ds.entries.filter { $0.type == .term }.map { $0.original.lowercased() })
            var added: [String] = []
            var skipped: [String] = []
            for term in body.terms {
                if existingSet.contains(term.lowercased()) { skipped.append(term) } else { added.append(term) }
            }
            let items = added.map { (type: DictionaryEntryType.term, original: $0, replacement: String?.none, caseSensitive: false) }
            ds.addEntries(items)
            struct AddResponse: Encodable { let added: [String]; let skipped: [String]; let count: Int; let prompt: String? }
            return .json(AddResponse(added: added, skipped: skipped, count: ds.entries.filter { $0.type == .term }.count, prompt: ds.getTermsForPrompt()))
        }
    }

    // MARK: - POST /v1/dictionary/terms/remove

    private func handleRemoveTerms(_ request: HTTPRequest) async -> HTTPResponse {
        struct Body: Decodable { let terms: [String] }
        guard let body = try? JSONDecoder().decode(Body.self, from: request.body) else {
            return .error(status: 400, message: "Expected JSON body: {\"terms\": [\"word1\", ...]}")
        }
        let ds = dictionaryService
        return await MainActor.run {
            let lowercased = Set(body.terms.map { $0.lowercased() })
            let toDelete = ds.entries.filter { $0.type == .term && lowercased.contains($0.original.lowercased()) }
            let removed = toDelete.map { $0.original }
            let notFound = body.terms.filter { t in !toDelete.contains(where: { $0.original.lowercased() == t.lowercased() }) }
            ds.deleteEntries(toDelete)
            struct RemoveResponse: Encodable { let removed: [String]; let not_found: [String]; let count: Int }
            return .json(RemoveResponse(removed: removed, not_found: notFound, count: ds.entries.filter { $0.type == .term }.count))
        }
    }

    // MARK: - GET /v1/dictionary/corrections

    private func handleGetCorrections(_ request: HTTPRequest) async -> HTTPResponse {
        let ds = dictionaryService
        return await MainActor.run {
            struct CorrectionsResponse: Encodable { let corrections: [CorrectionEntry]; let count: Int }
            let entries = ds.entries.filter { $0.type == .correction }
            return .json(CorrectionsResponse(corrections: entries.map { self.correctionEntry(from: $0) }, count: entries.count))
        }
    }

    // MARK: - POST /v1/dictionary/corrections (replace all)

    private func handleSetCorrections(_ request: HTTPRequest) async -> HTTPResponse {
        struct CorrectionInput: Decodable { let original: String; let replacement: String; let case_sensitive: Bool? }
        struct Body: Decodable { let corrections: [CorrectionInput] }
        guard let body = try? JSONDecoder().decode(Body.self, from: request.body) else {
            return .error(status: 400, message: "Expected JSON body: {\"corrections\": [{\"original\": \"x\", \"replacement\": \"y\"}]}")
        }
        let ds = dictionaryService
        return await MainActor.run {
            let existing = ds.entries.filter { $0.type == .correction }
            ds.deleteEntries(existing)
            let items = body.corrections.map { c in (type: DictionaryEntryType.correction, original: c.original, replacement: Optional(c.replacement), caseSensitive: c.case_sensitive ?? false) }
            ds.addEntries(items)
            let newEntries = ds.entries.filter { $0.type == .correction }
            struct CorrectionsResponse: Encodable { let corrections: [CorrectionEntry]; let count: Int }
            return .json(CorrectionsResponse(corrections: newEntries.map { self.correctionEntry(from: $0) }, count: newEntries.count))
        }
    }

    // MARK: - POST /v1/dictionary/corrections/add

    private func handleAddCorrections(_ request: HTTPRequest) async -> HTTPResponse {
        struct CorrectionInput: Decodable { let original: String; let replacement: String; let case_sensitive: Bool? }
        struct Body: Decodable { let corrections: [CorrectionInput] }
        guard let body = try? JSONDecoder().decode(Body.self, from: request.body) else {
            return .error(status: 400, message: "Expected JSON body: {\"corrections\": [{\"original\": \"x\", \"replacement\": \"y\"}]}")
        }
        let ds = dictionaryService
        return await MainActor.run {
            let existingSet = Set(ds.entries.filter { $0.type == .correction }.map { $0.original.lowercased() })
            var added: [String] = []
            var skipped: [String] = []
            var items: [(type: DictionaryEntryType, original: String, replacement: String?, caseSensitive: Bool)] = []
            for c in body.corrections {
                if existingSet.contains(c.original.lowercased()) { skipped.append(c.original) }
                else { added.append(c.original); items.append((type: .correction, original: c.original, replacement: c.replacement, caseSensitive: c.case_sensitive ?? false)) }
            }
            ds.addEntries(items)
            struct AddResponse: Encodable { let added: [String]; let skipped: [String]; let count: Int }
            return .json(AddResponse(added: added, skipped: skipped, count: ds.entries.filter { $0.type == .correction }.count))
        }
    }

    // MARK: - POST /v1/dictionary/corrections/remove

    private func handleRemoveCorrections(_ request: HTTPRequest) async -> HTTPResponse {
        struct Body: Decodable { let originals: [String] }
        guard let body = try? JSONDecoder().decode(Body.self, from: request.body) else {
            return .error(status: 400, message: "Expected JSON body: {\"originals\": [\"x\", ...]}")
        }
        let ds = dictionaryService
        return await MainActor.run {
            let lowercased = Set(body.originals.map { $0.lowercased() })
            let toDelete = ds.entries.filter { $0.type == .correction && lowercased.contains($0.original.lowercased()) }
            let removed = toDelete.map { $0.original }
            let notFound = body.originals.filter { o in !toDelete.contains(where: { $0.original.lowercased() == o.lowercased() }) }
            ds.deleteEntries(toDelete)
            struct RemoveResponse: Encodable { let removed: [String]; let not_found: [String]; let count: Int }
            return .json(RemoveResponse(removed: removed, not_found: notFound, count: ds.entries.filter { $0.type == .correction }.count))
        }
    }

    // MARK: - Helpers

    private func extractBoundary(from contentType: String) -> String? {
        for part in contentType.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("boundary=") {
                var boundary = String(trimmed.dropFirst("boundary=".count))
                if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") {
                    boundary = String(boundary.dropFirst().dropLast())
                }
                return boundary
            }
        }
        return nil
    }

    private func extensionFromMIME(_ mime: String) -> String {
        let lower = mime.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.contains("wav") || lower.contains("wave") { return "wav" }
        if lower.contains("mp3") || lower.contains("mpeg") { return "mp3" }
        if lower.contains("m4a") || lower.contains("mp4") { return "m4a" }
        if lower.contains("flac") { return "flac" }
        if lower.contains("ogg") { return "ogg" }
        if lower.contains("aac") { return "aac" }
        return "wav"
    }
}
