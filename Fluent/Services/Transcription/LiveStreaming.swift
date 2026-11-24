import Foundation

/// Word-level rules of streaming live typing, pure (no model, no events) so the DEBUG
/// self-test can check them. Words are compared by `key`, never by their exact spelling.
enum StreamingText {
    /// Comparison key of a word: lower-cased, without punctuation, brackets, symbols,
    /// tashkeel or tatweel, with أ/إ/آ folded to ا, ة to ه and ى to ي.
    static func key(_ word: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in word.lowercased().unicodeScalars {
            switch scalar.value {
            case 0x064B...0x0652, 0x0670, 0x0640:   // tashkeel, superscript alef, tatweel
                continue
            case 0x0622, 0x0623, 0x0625: scalars.append("\u{0627}")
            case 0x0629: scalars.append("\u{0647}")
            case 0x0649: scalars.append("\u{064A}")
            default:
                if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) { continue }
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// The words of `text`, leaving out tokens that are only punctuation.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init).filter { !key($0).isEmpty }
    }

    /// Where `committed` ends inside `hypothesis`: the `end` that makes `hypothesis[..<end]`
    /// closest to `committed` (word edit distance on keys; on a tie the later end, so a word
    /// already typed is not typed again).
    static func alignEnd(_ committed: [String], in hypothesis: [String]) -> Int {
        guard !committed.isEmpty else { return 0 }
        let a = committed.map(key), b = hypothesis.map(key)
        // row[j] = edit distance between the words of `a` seen so far and b[..<j].
        var row = Array(0...b.count)
        for i in 1...a.count {
            var next = [i] + Array(repeating: 0, count: b.count)
            for j in stride(from: 1, through: b.count, by: 1) {
                next[j] = min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            row = next
        }
        var best = 0
        for j in 0...b.count where row[j] <= row[best] { best = j }
        return best
    }

    /// Word edit distance between `a` and `b`, on keys.
    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        let a = a.map(key), b = b.map(key)
        guard !a.isEmpty else { return b.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var next = [i] + Array(repeating: 0, count: b.count)
            for j in stride(from: 1, through: b.count, by: 1) {
                next[j] = min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            row = next
        }
        return row[b.count]
    }

    /// For each word of `a`, the index of the equal word of `b` it lines up with on one
    /// minimal edit path, or nil (substituted or inserted).
    static func matches(_ a: [String], _ b: [String]) -> [Int?] {
        let a = a.map(key), b = b.map(key)
        guard !a.isEmpty else { return [] }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        for i in stride(from: 1, through: a.count, by: 1) {
            for j in stride(from: 1, through: b.count, by: 1) {
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1,
                                  table[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
        }
        var result = [Int?](repeating: nil, count: a.count)
        var i = a.count, j = b.count
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] && table[i][j] == table[i - 1][j - 1] {
                result[i - 1] = j - 1
                i -= 1; j -= 1
            } else if table[i][j] == table[i - 1][j - 1] + 1 {
                i -= 1; j -= 1
            } else if table[i][j] == table[i - 1][j] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return result
    }
}

/// Decides which words of an open segment are safe to type while it is still being spoken,
/// from successive hypotheses of the segment's audio so far. A committed word is never taken
/// back: later hypotheses and the final text are aligned after it.
struct StreamingCommitter {
    enum Policy: Equatable {
        /// Commit the words two hypotheses in a row agree on (longest common prefix).
        case localAgreement
        /// Commit every word of the latest hypothesis except the last `n`.
        case hold(Int)
    }

    struct Update: Equatable {
        /// Words committed now, in order.
        var words: [String]
        /// The rest of the latest hypothesis after the committed words (not committed).
        var lookahead: [String]
    }

    let policy: Policy
    /// Every word committed in this segment, in order.
    private(set) var committed: [String] = []
    /// False until a hypothesis has at least two words and is not a hallucination: nothing is
    /// committed before (a lone word on noise or a credit line like «شكرا للمشاهدة» on silence).
    private(set) var isAccepted = false
    private var previous: [String]?

    init(policy: Policy) {
        self.policy = policy
    }

    /// A new hypothesis of the open segment (cleanup applied). `acceptable` is false for a
    /// hallucination, which commits nothing and breaks the agreement chain.
    mutating func update(_ words: [String], acceptable: Bool) -> Update {
        guard acceptable else {
            previous = nil
            return Update(words: [], lookahead: [])
        }
        if !isAccepted { isAccepted = words.count >= 2 }
        let rest = Array(words[StreamingText.alignEnd(committed, in: words)...])
        defer { previous = words }
        guard isAccepted else { return Update(words: [], lookahead: rest) }

        let take: Int
        switch policy {
        case .localAgreement:
            if let previous {
                let earlier = Array(previous[StreamingText.alignEnd(committed, in: previous)...])
                take = zip(earlier, rest).prefix { StreamingText.key($0) == StreamingText.key($1) }.count
            } else {
                take = 0
            }
        case .hold(let n):
            take = max(0, rest.count - n)
        }
        let new = Array(rest.prefix(take))
        committed += new
        return Update(words: new, lookahead: Array(rest.dropFirst(take)))
    }

    /// The segment's final words: returns what follows the committed words in them (all of
    /// them when nothing was committed). Committed words that the final text changed stay.
    mutating func finish(_ words: [String]) -> [String] {
        let rest = Array(words[StreamingText.alignEnd(committed, in: words)...])
        committed += rest
        return rest
    }
}

/// Punctuation of a streamed segment: each word is typed as soon as it is committed, the
/// punctuation after it only once the next word (or the end of the segment) is known, so the
/// model sees the words around it first. Nothing typed is ever changed.
struct StreamingSegmentTyping {
    /// What to type for one step: punctuation that goes right after the text already typed,
    /// then the new words (empty when there are none).
    struct Step: Equatable {
        var punctuation: String
        var text: String
    }

    /// Punctuation the model writes after a word (Arabic forms included).
    static let marks: Set<Character> = [".", ",", "?", ";", "؟", "،", "؛", "？", "，", "。", "、", "・", "।", "።", "፣", "፧"]

    /// Words of this segment typed so far (as typed, without the punctuation after the last).
    private(set) var typed: [String] = []

    /// Text the punctuation model reads for this step: the segment so far, the new words and
    /// the uncommitted rest of the hypothesis as right context.
    func modelInput(new: [String], lookahead: [String]) -> String {
        (typed + new + lookahead).joined(separator: " ")
    }

    /// The model's output for `modelInput`, read word by word: each word's form (the model's
    /// casing when only the case differs) and the punctuation after it. nil when the output
    /// does not line up with the input word for word.
    static func read(_ formatted: String, words: [String]) -> [(form: String, mark: String)]? {
        let output = formatted.split(whereSeparator: \.isWhitespace).map(String.init)
        guard output.count == words.count else { return nil }
        return zip(output, words).map { out, word in
            var core = Substring(out)
            while let last = core.last, marks.contains(last) { core = core.dropLast() }
            guard !core.isEmpty, core.lowercased() == word.lowercased() else { return (word, "") }
            return (String(core), String(out.dropFirst(core.count)))
        }
    }

    /// The step for `new` committed words. `formatted` is the model output for
    /// `modelInput(new:lookahead:)` (nil: no punctuation). At the end of the segment
    /// (`isEnd`) the last word gets its punctuation too.
    mutating func step(new: [String], lookahead: [String], formatted: String?, isEnd: Bool) -> Step {
        let all = typed + new + lookahead
        let read = formatted.flatMap { Self.read($0, words: all) }
        var punctuation = ""
        if let read, !typed.isEmpty, !new.isEmpty || isEnd {
            punctuation = read[typed.count - 1].mark
        }
        var pieces: [String] = []
        for (offset, word) in new.enumerated() {
            let index = typed.count + offset
            var piece = read?[index].form ?? word
            if offset < new.count - 1 || isEnd { piece += read?[index].mark ?? "" }
            pieces.append(piece)
        }
        typed += new
        return Step(punctuation: punctuation, text: pieces.joined(separator: " "))
    }
}

extension LiveTyping {
    /// What is typed for a streamed step after `previous`: the punctuation stuck to the last
    /// word, then a separator and the new words.
    static func part(after previous: String, _ step: StreamingSegmentTyping.Step) -> String {
        guard !step.text.isEmpty else { return step.punctuation }
        let before = previous + step.punctuation
        return step.punctuation + separator(after: before, before: step.text) + step.text
    }
}
