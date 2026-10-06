import Foundation
import Translation
import WLCore

/// One provider shared across classroom workers. Actor reentrancy must not allow a
/// timed-out old classroom and a new classroom to run two model operations together.
actor AppleLocalTranslator {
    static let source = Locale.Language(identifier: "en")
    static let target = Locale.Language(identifier: "zh-Hans")
    private var session: TranslationSession?
    private var translating = false
    private var generation = UUID()

    func availability() async -> LanguageAvailability.Status {
        #if targetEnvironment(simulator)
        return .unsupported
        #else
        let availability: LanguageAvailability
        if #available(iOS 26.4, *) { availability = LanguageAvailability(preferredStrategy: .lowLatency) }
        else { availability = LanguageAvailability() }
        return await availability.status(from: Self.source, to: Self.target)
        #endif
    }
    func translate(_ text: String) async throws -> String {
        guard !translating else { throw WLFailure.message("上一项本机翻译尚未结束") }
        translating = true; defer { translating = false }
        let ticket = generation
        if session == nil {
            guard await availability() == .installed else { throw WLFailure.message("英文/简体中文模型未准备，请在设置中准备；录音/GPT 继续") }
            try Task.checkCancellation()
            guard generation == ticket else { throw CancellationError() }
            if #available(iOS 26.4, *) {
                session = TranslationSession(installedSource: Self.source, target: Self.target, preferredStrategy: .lowLatency)
            } else { session = TranslationSession(installedSource: Self.source, target: Self.target) }
        }
        guard let session else { throw WLFailure.message("本机翻译会话不可用") }
        let result = try await session.translate(text)
        try Task.checkCancellation()
        guard generation == ticket else { throw CancellationError() }
        return result.targetText
    }
    func prepareInstalledSession() async {
        guard !translating, session == nil else { return }
        let ticket = generation
        guard await availability() == .installed, generation == ticket, !translating, session == nil else { return }
        if #available(iOS 26.4, *) {
            session = TranslationSession(installedSource: Self.source, target: Self.target, preferredStrategy: .lowLatency)
        } else { session = TranslationSession(installedSource: Self.source, target: Self.target) }
    }
    func cancel() {
        generation = UUID(); session?.cancel(); session = nil
    }
    nonisolated static func preparationConfiguration() -> TranslationSession.Configuration {
        if #available(iOS 26.4, *) {
            return TranslationSession.Configuration(source: source, target: target, preferredStrategy: .lowLatency)
        }
        return TranslationSession.Configuration(source: source, target: target)
    }
}
