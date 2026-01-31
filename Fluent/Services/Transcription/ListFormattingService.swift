import Foundation

/// Service for detecting and formatting spoken list patterns in transcribed text
/// Uses rule-based pattern matching to convert spoken lists into numbered format
class ListFormattingService {

    // MARK: - List Indicators

    /// Ordinal words that indicate list items (first, second, third...)
    private let ordinals = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10
    ]

    /// Ordinal variants (firstly, secondly...)
    private let ordinalVariants = [
        "firstly": 1, "secondly": 2, "thirdly": 3, "fourthly": 4, "fifthly": 5
    ]

    /// Number words (one, two, three...)
    private let numberWords = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10
    ]

    /// Prefixes that can precede numbers (number one, item two, step three...)
    private let listPrefixes = ["number", "item", "point", "step"]

    // MARK: - Public API

    /// Detect and format lists in transcribed text
    /// - Parameter text: The transcribed text to process
    /// - Returns: Formatted text with numbered lists, or original text if no list detected
    func format(text: String) -> String {
        // Try each pattern detector in order of specificity
        if let formatted = detectPrefixedNumberList(text) {
            return formatted
        }
        if let formatted = detectOrdinalList(text) {
            return formatted
        }
        if let formatted = detectOrdinalVariantList(text) {
            return formatted
        }
        if let formatted = detectNumberWordList(text) {
            return formatted
        }

        // No list pattern found
        return text
    }

    // MARK: - Pattern Detectors

    /// Detect pattern: "number one X number two Y" or "item one X item two Y"
    private func detectPrefixedNumberList(_ text: String) -> String? {
        for prefix in listPrefixes {
            if let result = detectListWithPattern(
                text: text,
                indicators: numberWords,
                prefixPattern: prefix
            ) {
                return result
            }
        }
        return nil
    }

    /// Detect pattern: "first X second Y third Z"
    private func detectOrdinalList(_ text: String) -> String? {
        return detectListWithPattern(text: text, indicators: ordinals, prefixPattern: nil)
    }

    /// Detect pattern: "firstly X secondly Y thirdly Z"
    private func detectOrdinalVariantList(_ text: String) -> String? {
        return detectListWithPattern(text: text, indicators: ordinalVariants, prefixPattern: nil)
    }

    /// Detect pattern: "one X two Y three Z"
    private func detectNumberWordList(_ text: String) -> String? {
        return detectListWithPattern(text: text, indicators: numberWords, prefixPattern: nil)
    }

    // MARK: - Core Detection Logic

    /// Generic list detection with configurable indicators and optional prefix
    /// - Parameters:
    ///   - text: The text to search
    ///   - indicators: Dictionary mapping indicator words to their numeric values
    ///   - prefixPattern: Optional prefix that must precede the indicator (e.g., "number" for "number one")
    /// - Returns: Formatted text if a valid list is found, nil otherwise
    private func detectListWithPattern(
        text: String,
        indicators: [String: Int],
        prefixPattern: String?
    ) -> String? {
        let words = tokenize(text)
        var listItems: [(number: Int, startIndex: Int, endIndex: Int, content: String)] = []

        var i = 0
        while i < words.count {
            let word = words[i]

            // Check for prefix pattern if required
            if let prefix = prefixPattern {
                if word.text.lowercased() == prefix && i + 1 < words.count {
                    let nextWord = words[i + 1]
                    if let number = indicators[nextWord.text.lowercased()] {
                        listItems.append((number: number, startIndex: word.position, endIndex: nextWord.position + nextWord.text.count, content: ""))
                        i += 2
                        continue
                    }
                }
            } else {
                // Direct indicator match
                let cleanWord = word.text.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters)
                if let number = indicators[cleanWord] {
                    listItems.append((number: number, startIndex: word.position, endIndex: word.position + word.text.count, content: ""))
                    i += 1
                    continue
                }
            }
            i += 1
        }

        // Need at least 2 sequential items to be a list
        guard listItems.count >= 2 else { return nil }

        // Verify items are sequential (1, 2, 3... or at least increasing)
        guard isSequential(listItems.map { $0.number }) else { return nil }

        // Extract content for each list item
        var itemsWithContent = extractContent(from: text, items: listItems)

        // Filter out items with no meaningful content
        itemsWithContent = itemsWithContent.filter { !$0.content.trimmingCharacters(in: .whitespaces).isEmpty }

        // Still need at least 2 items
        guard itemsWithContent.count >= 2 else { return nil }

        // Build the formatted output
        return buildFormattedList(from: text, items: itemsWithContent)
    }

    // MARK: - Helper Methods

    /// Token representing a word and its position in the original text
    private struct Token {
        let text: String
        let position: Int
    }

    /// Tokenize text into words with their positions
    private func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var currentWord = ""
        var wordStart = 0

        for (index, char) in text.enumerated() {
            if char.isWhitespace {
                if !currentWord.isEmpty {
                    tokens.append(Token(text: currentWord, position: wordStart))
                    currentWord = ""
                }
            } else {
                if currentWord.isEmpty {
                    wordStart = index
                }
                currentWord.append(char)
            }
        }

        // Don't forget the last word
        if !currentWord.isEmpty {
            tokens.append(Token(text: currentWord, position: wordStart))
        }

        return tokens
    }

    /// Check if numbers form a sequential or increasing sequence
    private func isSequential(_ numbers: [Int]) -> Bool {
        guard numbers.count >= 2 else { return false }

        // Check if it starts with 1 and is sequential
        var isStrictlySequential = numbers[0] == 1
        for i in 1..<numbers.count {
            if numbers[i] != numbers[i-1] + 1 {
                isStrictlySequential = false
                break
            }
        }

        if isStrictlySequential { return true }

        // Also accept increasing sequences (e.g., 1, 3, 5 for partial lists)
        for i in 1..<numbers.count {
            if numbers[i] <= numbers[i-1] {
                return false
            }
        }

        return true
    }

    /// Extract content between list indicators
    private func extractContent(
        from text: String,
        items: [(number: Int, startIndex: Int, endIndex: Int, content: String)]
    ) -> [(number: Int, startIndex: Int, endIndex: Int, content: String)] {
        var result: [(number: Int, startIndex: Int, endIndex: Int, content: String)] = []

        for (index, item) in items.enumerated() {
            let contentStart = item.endIndex
            let contentEnd: Int

            if index + 1 < items.count {
                contentEnd = items[index + 1].startIndex
            } else {
                contentEnd = text.count
            }

            let startIdx = text.index(text.startIndex, offsetBy: min(contentStart, text.count))
            let endIdx = text.index(text.startIndex, offsetBy: min(contentEnd, text.count))

            var content = String(text[startIdx..<endIdx])
                .trimmingCharacters(in: .whitespaces)

            // Remove leading/trailing punctuation from content
            content = content.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
                .trimmingCharacters(in: .whitespaces)

            // Capitalize first letter
            if let firstChar = content.first {
                content = firstChar.uppercased() + content.dropFirst()
            }

            result.append((number: item.number, startIndex: item.startIndex, endIndex: item.endIndex, content: content))
        }

        return result
    }

    /// Build the final formatted list string
    private func buildFormattedList(
        from text: String,
        items: [(number: Int, startIndex: Int, endIndex: Int, content: String)]
    ) -> String {
        guard let firstItem = items.first else { return text }

        // Get any text before the list starts
        var prefix = ""
        if firstItem.startIndex > 0 {
            let prefixEndIdx = text.index(text.startIndex, offsetBy: firstItem.startIndex)
            prefix = String(text[text.startIndex..<prefixEndIdx])
                .trimmingCharacters(in: .whitespaces)

            // Clean up prefix - remove trailing punctuation if it ends with list-like patterns
            prefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
                .trimmingCharacters(in: .whitespaces)
        }

        // Build the numbered list
        var listLines: [String] = []
        for (index, item) in items.enumerated() {
            let lineNumber = index + 1
            listLines.append("\(lineNumber). \(item.content)")
        }

        // Combine prefix with list
        if prefix.isEmpty {
            return listLines.joined(separator: "\n")
        } else {
            return prefix + ":\n" + listLines.joined(separator: "\n")
        }
    }
}
