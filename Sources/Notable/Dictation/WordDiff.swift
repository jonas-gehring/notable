import Foundation

/// Pure, deterministic word-level diff that extracts 1:1 word substitutions
/// between an original dictation and its user-corrected version.
///
/// This is Quelle A of Spec 06 (Wörterbuch-Auto-Learn): when the user corrects
/// a past dictation, a word-wise diff of old → new tells us exactly which word
/// Notable *heard* wrong and what it *should* have been. Those pairs feed
/// `PersonalDictionary.recordCorrection` (wired up separately).
///
/// The whole point is honesty: we only learn from substitutions the user
/// explicitly made, and only where the mapping is unambiguous.
enum WordDiff {
    /// Extract heard → corrected word substitutions from `old` to `new`.
    ///
    /// **Only 1:1 substitutions are emitted.** A position where exactly one old
    /// word aligns to exactly one differing new word is a real
    /// "heard → corrected" pair. Insertions and deletions are deliberately
    /// ignored: a word that was merely added or removed has no counterpart, so
    /// it tells us nothing about a mishearing.
    ///
    /// The alignment is a standard word-level LCS. Between two matched (equal)
    /// words lies a *gap* of unmatched old words and unmatched new words:
    ///
    /// - If the gap replaces `k` old words with exactly `k` new words, they are
    ///   paired index-by-index (`old[i]` → `new[i]`) — a contiguous run of 1:1
    ///   substitutions.
    /// - If the replaced and replacement run lengths differ, the gap is
    ///   ambiguous (which old word maps to which new word?) and is skipped
    ///   entirely — no reliable pair can be derived.
    ///
    /// The comparison is word-literal (simple, no fuzzy matching). Before a pair
    /// is emitted, surrounding ASCII punctuation is stripped from each word so
    /// "Hofmann," → "Hoffmann" pairs cleanly. A pair is dropped when either word
    /// becomes empty after trimming, or when the two words are equal
    /// case-insensitively (a case-only change is not a mishearing, and the
    /// active dictionary matches case-insensitively anyway).
    static func substitutions(from old: String, to new: String) -> [(heard: String, corrected: String)] {
        let oldTokens = tokenize(old)
        let newTokens = tokenize(new)

        // Aligned (oldIndex, newIndex) pairs of the longest common subsequence.
        let matches = lcsMatches(oldTokens, newTokens)

        var result: [(heard: String, corrected: String)] = []

        // Each match closes the gap of unmatched words that precedes it. A
        // trailing sentinel closes the final gap after the last match.
        var oi = 0
        var nj = 0
        for (mi, mj) in matches + [(oldTokens.count, newTokens.count)] {
            emitPairs(oldGap: Array(oldTokens[oi..<mi]),
                      newGap: Array(newTokens[nj..<mj]),
                      into: &result)
            oi = mi + 1
            nj = mj + 1
        }

        return result
    }

    // MARK: - Tokenization

    /// Split on any whitespace (spaces, newlines, tabs), dropping empty tokens.
    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    // MARK: - LCS alignment

    /// Longest common subsequence of two token arrays, returned as the list of
    /// aligned index pairs `(i, j)` where `a[i] == b[j]`. Word-literal equality.
    private static func lcsMatches(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count
        let m = b.count
        if n == 0 || m == 0 { return [] }

        // dp[i][j] = LCS length of a[i...] and b[j...].
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if a[i] == b[j] {
                    dp[i][j] = dp[i + 1][j + 1] + 1
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var matches: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                matches.append((i, j))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return matches
    }

    // MARK: - Pair emission

    /// Emit heard → corrected pairs for one aligned gap, applying the equal-run
    /// rule and the punctuation / case filters.
    private static func emitPairs(oldGap: [String],
                                  newGap: [String],
                                  into result: inout [(heard: String, corrected: String)]) {
        // Only equal-length, non-empty runs yield unambiguous 1:1 pairs.
        guard !oldGap.isEmpty, oldGap.count == newGap.count else { return }

        for k in oldGap.indices {
            let heard = trimmingPunctuation(oldGap[k])
            let corrected = trimmingPunctuation(newGap[k])
            if heard.isEmpty || corrected.isEmpty { continue }
            if heard.caseInsensitiveCompare(corrected) == .orderedSame { continue }
            result.append((heard: heard, corrected: corrected))
        }
    }

    /// Strip surrounding ASCII punctuation so "Hofmann," → "Hoffmann" pairs on the
    /// bare words. Only leading/trailing punctuation is removed.
    private static func trimmingPunctuation(_ word: String) -> String {
        let asciiPunctuation = CharacterSet(charactersIn: "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
        return word.trimmingCharacters(in: asciiPunctuation)
    }
}
