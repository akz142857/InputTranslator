import Foundation
import Translation

nonisolated enum TranslationMode: Hashable, Sendable {
    case compose, readReply
}

nonisolated struct TranslationLanguage: Hashable, Identifiable, Sendable {
    let id: String

    init(_ identifier: String) {
        self.init(Locale.Language(identifier: identifier))
    }

    init(_ language: Locale.Language) {
        id = language.minimalIdentifier
    }

    var localeLanguage: Locale.Language { Locale.Language(identifier: id) }

    var name: String {
        switch id {
        case "zh": L10n.text("简体中文")
        case "zh-TW": L10n.text("繁体中文")
        case "en": L10n.text("英语")
        case "en-GB": L10n.text("英语（英国）")
        default: L10n.locale.localizedString(forIdentifier: id) ?? id
        }
    }
}

nonisolated struct TranslationPair: Equatable, Sendable {
    let source: TranslationLanguage
    let target: TranslationLanguage

    static let english = TranslationLanguage("en")

    static func systemDefault(preferredLanguage: String?) -> Self {
        let systemLanguage = Locale.Language(identifier: preferredLanguage ?? "en")
        // Match the system language and script without requiring its regional variant.
        let source = TranslationLanguage(Locale.Language(
            languageCode: systemLanguage.languageCode, script: systemLanguage.script, region: nil
        ))
        return Self(source: source, target: english)
    }

    var isSelectable: Bool { source != target || source == Self.english }
    var reverse: Self { Self(source: target, target: source) }
    var label: String {
        let arrow = L10n.language == .arabic ? "←" : "→"
        return "\(source.name) \(arrow) \(target.name)"
    }
}

enum TranslationService {
    static func translate(_ prompt: ProtectedPrompt, in pair: TranslationPair,
                          with session: TranslationSession) async throws -> String {
        let response = try await session.translate(prompt.source)
        try Task.checkCancellation()
        let result: String
        do {
            result = try prompt.restore(in: response.targetText)
        } catch TranslationFailure.damagedCode {
            result = try await prompt.translateProse(in: pair, with: session)
        }
        guard result.contains(where: { !$0.isWhitespace }) else { throw TranslationFailure.emptyResponse }
        return result
    }

    static func translateReply(_ reply: ReplyMarkdown, at ranges: [Range<String.Index>],
                               with session: TranslationSession) async throws -> String {
        let requests = ranges.enumerated().map { index, range in
            TranslationSession.Request(sourceText: String(reply.source[range]), clientIdentifier: String(index))
        }
        let responses = try await session.translations(from: requests)
        try Task.checkCancellation()
        var translations: [Int: String] = [:]
        for response in responses {
            if let id = response.clientIdentifier, let index = Int(id) {
                translations[index] = response.targetText
            }
        }
        return reply.replacingProse(at: ranges, with: translations)
    }
}

enum TranslationFailure: LocalizedError {
    case emptyClipboard, emptyResponse, damagedCode, timeout, service
    case unsupported(TranslationPair)
    case languageDownload(TranslationPair)

    var errorDescription: String? {
        switch self {
        case .emptyClipboard: L10n.text("剪贴板里没有可翻译的文本。请先复制要翻译的回复。")
        case .emptyResponse: L10n.text("翻译结果为空。请检查原文后重试。")
        case .damagedCode: L10n.text("译文中的代码标记发生变化。请缩短原文或分段翻译。")
        case .unsupported(let pair): L10n.text("这台 Mac 上的 Apple Translation 暂不支持 %@。请选择其他语言。", pair.label)
        case .timeout: L10n.text("等待翻译超时。首次使用时，请在系统设置中下载翻译语言后重试。")
        case .languageDownload(let pair): L10n.text("%@ 的语言资源尚未就绪。请联网并允许系统下载，然后重试。", pair.label)
        case .service: L10n.text("Apple Translation 暂时无法完成翻译，请重试。")
        }
    }
}

nonisolated struct ProtectedPrompt: Sendable {
    // Fenced blocks take precedence over inline spans. Protect an unclosed fence through EOF.
    private static let codePattern = try! NSRegularExpression(
        pattern: #"(?m)^ {0,3}((`)`{2,}|(~)~{2,})[^\r\n]*\r?$(?:\n[\s\S]*?^ {0,3}\1(?:\2|\3)*[ \t]*(?=\r?$)|[\s\S]*\z)|(?<!`)(`+)(?!`)[\s\S]*?(?<!`)\4(?!`)"#
    )
    private let tokenPrefix: String
    private let fragments: [(token: String, code: String, fenced: Bool)]
    private let prose: [Substring]
    let source: String

    init(_ text: String) {
        guard text.utf8.contains(where: { $0 == 0x60 || $0 == 0x7E }) else {
            tokenPrefix = ""
            fragments = []
            prose = [text[...]]
            source = text
            return
        }
        var prefix: String
        repeat {
            prefix = "ZXQ" + UUID().uuidString.prefix(8)
        } while text.localizedCaseInsensitiveContains(prefix)
        tokenPrefix = prefix
        var fragments: [(token: String, code: String, fenced: Bool)] = []
        var source = ""
        var prose: [Substring] = []
        var cursor = text.startIndex

        Self.codePattern.enumerateMatches(in: text, options: .reportProgress,
                                          range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            if Task.isCancelled {
                stop.pointee = true
                return
            }
            guard let match, let range = Range(match.range, in: text) else { return }
            let token = "\(prefix)CODE\(fragments.count)QXZ"
            let fenced = match.range(at: 1).location != NSNotFound
            let code = String(text[range])
            let leadingText = text[cursor..<range.lowerBound]
            source += leadingText + token
            prose.append(leadingText)
            fragments.append((token, code, fenced))
            cursor = range.upperBound
        }
        source += text[cursor...]
        prose.append(text[cursor...])
        self.source = source
        self.prose = prose
        self.fragments = fragments
    }

    func requiresTranslation(in pair: TranslationPair) -> Bool {
        pair.source != pair.target && prose.contains { Self.hasTranslatableProse($0, in: pair) }
    }

    // If the system changes a placeholder, translate the prose around each code span independently.
    @MainActor func translateProse(in pair: TranslationPair, with session: TranslationSession) async throws -> String {
        var requests: [TranslationSession.Request] = []
        var ranges: [Int: Range<String.Index>] = [:]
        for (index, segment) in prose.enumerated() where Self.hasTranslatableProse(segment, in: pair) {
            guard let start = segment.firstIndex(where: { !$0.isWhitespace }),
                  let end = segment.lastIndex(where: { !$0.isWhitespace }) else { continue }
            let range = start..<segment.index(after: end)
            ranges[index] = range
            requests.append(.init(sourceText: String(segment[range]), clientIdentifier: String(index)))
        }
        let responses = requests.isEmpty ? [] : try await session.translations(from: requests)
        try Task.checkCancellation()
        var translated: [Int: String] = [:]
        for response in responses {
            if let id = response.clientIdentifier, let index = Int(id) { translated[index] = response.targetText }
        }
        var result = ""
        for (index, segment) in prose.enumerated() {
            if let range = ranges[index] {
                guard let translation = translated[index]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !translation.isEmpty else { throw TranslationFailure.emptyResponse }
                result += segment[..<range.lowerBound] + translation + segment[range.upperBound...]
            } else {
                result += segment
            }
            if index < fragments.count { result += fragments[index].code }
        }
        return result
    }

    static func hasTranslatableProse(_ text: Substring, in pair: TranslationPair) -> Bool {
        let source = pair.source.localeLanguage.languageCode?.identifier
        let target = pair.target.localeLanguage.languageCode?.identifier
        switch (source, target) {
        case ("zh", "en"):
            return text.unicodeScalars.contains { $0.properties.isIdeographic }
        case ("en", "zh"):
            return text.range(of: #"\p{Latin}"#, options: .regularExpression) != nil
        default:
            return text.contains(where: \.isLetter)
        }
    }

    func restore(in translated: String) throws -> String {
        guard !fragments.isEmpty else { return translated }
        var result = ""
        var cursor = translated.startIndex
        for fragment in fragments {
            guard let range = translated.range(of: fragment.token, range: cursor..<translated.endIndex),
                  !translated[cursor..<range.lowerBound].localizedCaseInsensitiveContains(tokenPrefix) else {
                throw TranslationFailure.damagedCode
            }
            if fragment.fenced {
                // A fence must still occupy its own line after translation.
                let before = translated[..<range.lowerBound].reversed().prefix { !$0.isNewline }
                let after = translated[range.upperBound...].prefix { !$0.isNewline }
                guard before.allSatisfy(\.isWhitespace), after.allSatisfy(\.isWhitespace) else {
                    throw TranslationFailure.damagedCode
                }
            }
            result += translated[cursor..<range.lowerBound] + fragment.code
            cursor = range.upperBound
        }
        let rest = translated[cursor...]
        guard !rest.localizedCaseInsensitiveContains(tokenPrefix) else { throw TranslationFailure.damagedCode }
        return result + rest
    }
}
