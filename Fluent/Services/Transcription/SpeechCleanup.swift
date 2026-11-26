import Foundation

/// Fast, deterministic cleanup of dictated text (Arabic and English), run before punctuation:
/// - a word said several times in a row becomes one ("ما ما ما قدرت" → "ما قدرت", "the the" → "the"),
///   except legitimate reduplication ("شوي شوي", "very very", "no no", numbers);
/// - a phrase of 2–4 words said twice in a row becomes one ("انا بدي انا بدي اقلك" → "انا بدي اقلك");
/// - standalone hesitation sounds are dropped (اممم، ممم، ااا / um, uh, erm, hmm, mm),
///   never the words that mean "yes" (اه، آه، إيه، ايوه).
/// Nothing else changes: no rephrasing, reordering or dialect changes, and the last remaining
/// word of an utterance is never dropped. Linear in the number of words.
enum SpeechCleanup {

    // MARK: - Cleanup

    static func clean(_ text: String) -> String {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count > 1 else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }

        // 1. Hesitation sounds (keep the utterance if it is nothing but hesitation).
        var words: [Token] = []
        words.reserveCapacity(tokens.count)
        for text in tokens {
            let token = Token(text)
            if !token.isFiller { words.append(token) }
        }
        if words.isEmpty { return text.trimmingCharacters(in: .whitespacesAndNewlines) }

        // 2. Repeated words and phrases. Every word is checked once against the tail of the
        //    output, which never ends with a repeat, so one pass is enough.
        var output: [Token] = []
        output.reserveCapacity(words.count)
        for word in words {
            output.append(word)
            for length in 1...maxPhraseLength {
                if collapseRepeat(in: &output, length: length) { break }
            }
        }

        // A sentence that started with a capital keeps it when its first word was dropped.
        var result = output.map(\.text)
        if let original = tokens.first?.first, original.isUppercase,
           let first = result.first, let letter = first.first, letter.isLowercase {
            result[0] = letter.uppercased() + first.dropFirst()
        }
        return result.joined(separator: " ")
    }

    private static let maxPhraseLength = 4
    private static let sentenceEndings: Set<Character> = [".", "?", "!", "؟", "…"]

    /// If `output` ends with the same `length` words twice, drops the earlier copy and keeps the
    /// later one (it carries the punctuation that belongs to what follows).
    private static func collapseRepeat(in output: inout [Token], length: Int) -> Bool {
        let n = output.count
        guard n >= 2 * length else { return false }
        let first = n - 2 * length
        let second = n - length
        // A repeat across a sentence end ("… left. Left …") is not a stutter.
        if let end = output[second - 1].text.last, sentenceEndings.contains(end) { return false }
        var repeatsMeaningfulWord = false
        for k in 0..<length {
            let a = output[first + k], b = output[second + k]
            guard !a.key.isEmpty, a.key == b.key else { return false }
            if !a.allowsReduplication { repeatsMeaningfulWord = true }
        }
        // "شوي شوي", "very very", "10 10": said on purpose.
        guard repeatsMeaningfulWord else { return false }
        output.removeSubrange(first..<second)
        return true
    }

    // MARK: - Tokens

    private struct Token {
        let text: String
        /// Lower-cased, without surrounding punctuation, tashkeel and tatweel, أ/إ/آ folded to ا.
        let key: String
        let isFiller: Bool
        let allowsReduplication: Bool

        init(_ text: String) {
            self.text = text
            let bare = SpeechCleanup.bareWord(text)
            key = SpeechCleanup.foldHamza(bare)
            isFiller = SpeechCleanup.isFiller(bare)
            allowsReduplication = SpeechCleanup.reduplicationWords.contains(key) || SpeechCleanup.isNumber(key)
        }
    }

    /// Lower-cased word without leading/trailing punctuation, tashkeel or tatweel.
    private static func bareWord(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            switch scalar.value {
            case 0x064B...0x0652, 0x0670, 0x0640:   // tashkeel, superscript alef, tatweel
                continue
            default:
                scalars.append(scalar)
            }
        }
        let word = String(scalars)
        guard let start = word.firstIndex(where: { !isEdgePunctuation($0) }),
              let end = word.lastIndex(where: { !isEdgePunctuation($0) }) else { return "" }
        return String(word[start...end])
    }

    private static func isEdgePunctuation(_ character: Character) -> Bool {
        character.isPunctuation || character.isSymbol
    }

    private static func foldHamza(_ word: String) -> String {
        guard word.unicodeScalars.contains(where: { (0x0622...0x0625).contains($0.value) }) else { return word }
        var scalars = String.UnicodeScalarView()
        for scalar in word.unicodeScalars {
            switch scalar.value {
            case 0x0622, 0x0623, 0x0625: scalars.append("\u{0627}")   // آ أ إ → ا
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private static func isNumber(_ key: String) -> Bool {
        guard key.contains(where: \.isNumber) else { return numberWords.contains(key) }
        return key.allSatisfy { $0.isNumber || ".,:٫٬/-".contains($0) }
    }

    // MARK: - Hesitation sounds

    /// Elongated hesitation only. Matched before hamza folding, so «أمم» (nations) and
    /// «آه» / «اه» / «إيه» / «ايوه» (yes) are never fillers.
    private static let fillerPatterns: [NSRegularExpression] = [
        #"^[اإ]م{2,}$"#,            // امم، اممم، إمم
        #"^م{3,}$"#,                 // ممم
        #"^ا{3,}ه*$"#,               // ااا، اااه
        #"^(?:u+m+|u+h+m*|e+r+m+|h+m+|m{2,})$"#   // um, umm, uh, uhm, erm, hmm, hm, mm
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Every letter the patterns use: most words are rejected without running a regex.
    private static let fillerLetters: Set<Character> = ["ا", "إ", "م", "ه", "u", "m", "h", "e", "r"]

    private static func isFiller(_ bare: String) -> Bool {
        guard bare.count >= 2, bare.count <= 12,
              bare.allSatisfy({ fillerLetters.contains($0) }) else { return false }
        let range = NSRange(bare.startIndex..., in: bare)
        return fillerPatterns.contains { $0.firstMatch(in: bare, range: range) != nil }
    }

    // MARK: - Legitimate reduplication

    /// Words that are repeated on purpose ("شوي شوي", "خطوة خطوة", "very very", "no no",
    /// "that that"), in key form (hamza folded).
    private static let reduplicationWords: Set<String> = [
        // Arabic
        "شوي", "شويه", "شوية", "شوى", "حبة", "حبه", "خطوة", "خطوه", "واحد", "واحدة", "واحده", "وحدة", "وحده",
        "يوم", "رويدا", "بشويش", "قليلا", "كثيرا", "كثير", "جدا", "بين", "كلمة", "كلمه", "حرف", "سطر",
        "مرة", "مره", "ساعة", "ساعه", "نقطة", "نقطه", "طيب", "يلا",
        // English
        "very", "really", "so", "bye", "no", "yes", "yeah", "ha", "that", "had", "knock",
    ]

    /// Number words, so dictated digits ("خمسة خمسة", "one one") stay as said.
    private static let numberWords: Set<String> = [
        "صفر", "اثنين", "اتنين", "ثنين", "اثنان", "ثلاثة", "ثلاثه", "تلاتة", "تلاته", "ثلاث", "تلات",
        "اربعة", "اربعه", "اربع", "خمسة", "خمسه", "خمس", "ستة", "سته", "ست", "سبعة", "سبعه", "سبع",
        "ثمانية", "ثمانيه", "تمنية", "تمنيه", "ثمان", "تمن", "تسعة", "تسعه", "تسع", "عشرة", "عشره", "عشر",
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "double",
    ]

    // MARK: - Bracketed text

    /// Square or round brackets with no brackets inside: "[CRM]", "(applause)".
    private static let bracketGroup = try! NSRegularExpression(pattern: #"[\[(]([^\[\]()]*)[\])]"#)

    /// Engines put two different things in brackets: non-speech tags ("[Music]", "(applause)",
    /// "[ضحك]") and, in Audar's case, English words said inside Arabic speech ("ال [CRM]").
    /// Tags are removed; anything else is speech and keeps its words without the brackets.
    /// - Parameter nonSpeechPhrases: lower-cased phrases that are tags on their own.
    static func unwrapBrackets(_ text: String, nonSpeechPhrases: Set<String>) -> String {
        guard text.contains(where: { $0 == "[" || $0 == "(" }) else { return text }
        let nsText = text as NSString
        var result = ""
        var last = 0
        for match in bracketGroup.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            result += nsText.substring(with: NSRange(location: last, length: match.range.location - last))
            let inner = nsText.substring(with: match.range(at: 1))
            if !isNonSpeechTag(inner, phrases: nonSpeechPhrases) {
                result += " " + inner.trimmingCharacters(in: .whitespaces) + " "
            } else {
                result += " "
            }
            last = match.range.location + match.range.length
        }
        result += nsText.substring(from: last)
        // Collapse the spaces left behind (line breaks stay), and keep punctuation attached to
        // the word before it: "تمام [Music] ." → "تمام."
        result = result.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "[ \\t]+([.,?!;:،؟؛…])(?=\\s|$)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True for a sound or non-speech tag (bracket content), false for speech.
    static func isNonSpeechTag(_ inner: String, phrases: Set<String>) -> Bool {
        let normalized = inner.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters)
        if normalized.isEmpty { return true }
        if phrases.contains(normalized) { return true }

        let words = normalized.split(whereSeparator: { !$0.isLetter }).map(String.init)
        for word in words {
            if latinSoundStems.contains(where: { word.hasPrefix($0) }) { return true }
            let arabic = foldArabicForTags(word)
            if arabicSoundStems.contains(where: { arabic.contains($0) }) { return true }
        }
        return false
    }

    /// Word starts of sound descriptions ("laugh" covers laughs, laughter, laughing).
    private static let latinSoundStems: [String] = [
        "music", "noise", "silence", "silent", "applau", "laugh", "chuckl", "giggl",
        "inaudible", "unintelligible", "indistinct", "muffled", "blank", "cough", "sneez", "sniff",
        "breath", "sigh", "gasp", "groan", "yawn", "beep", "click", "static", "typing", "footstep",
    ]

    /// Arabic tags, in the form produced by `foldArabicForTags` (ى → ي, no tashkeel or hamza seats).
    private static let arabicSoundStems: [String] = [
        "موسيقي", "ضحك", "تصفيق", "صمت", "ضوضاء", "ضجيج", "فراغ", "تنفس", "سعال", "كحه",
    ]

    private static func foldArabicForTags(_ word: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in word.unicodeScalars {
            switch scalar.value {
            case 0x064B...0x0652, 0x0670, 0x0640: continue
            case 0x0622, 0x0623, 0x0625: scalars.append("\u{0627}")
            case 0x0649: scalars.append("\u{064A}")   // ى → ي
            case 0x0629: scalars.append("\u{0647}")   // ة → ه
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}
