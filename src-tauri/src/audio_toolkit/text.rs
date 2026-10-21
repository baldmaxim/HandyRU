use once_cell::sync::Lazy;
use regex::Regex;
use rphonetic::{DoubleMetaphone, Encoder};
use strsim::levenshtein;

/// Double Metaphone encoder used for phonetic custom-word matching.
///
/// The code length is deliberately left unbounded. Apache commons-codec (and
/// rphonetic, which ports it) defaults to a 4-character code, which truncates
/// long compounds into collisions: `flitepath` and `flatpack` both encode to
/// `FLTP` at length 4, but to `FLTP0` and `FLTPK` in full. Custom words are
/// overwhelmingly multi-syllable brand names, so truncation is the difference
/// between a useful signal and a dangerous one.
static DOUBLE_METAPHONE: Lazy<DoubleMetaphone> = Lazy::new(|| DoubleMetaphone::new(Some(64)));

/// A word's primary and alternate Double Metaphone codes.
///
/// Double Metaphone emits two codes for words whose pronunciation is
/// genuinely ambiguous in English (e.g. a trailing `th` -> `0` or `T`). Two
/// words are phonetic equivalents when any of their codes agree.
#[derive(Clone, Debug, PartialEq, Eq)]
struct PhoneticCode {
    primary: String,
    alternate: String,
}

impl PhoneticCode {
    /// Returns `None` for input Double Metaphone cannot meaningfully encode.
    ///
    /// Codes shorter than [`MIN_PHONETIC_CODE_LEN`] are rejected: a one- or
    /// two-character code carries too little information to justify the
    /// phonetic score boost, and short codes collide readily (`rd` and `rt`
    /// both encode to `RT`).
    fn encode(word: &str) -> Option<Self> {
        if !supports_phonetics(word) {
            return None;
        }

        let primary = DOUBLE_METAPHONE.encode(word);
        let alternate = DOUBLE_METAPHONE.encode_alternate(word);

        if primary.chars().count() < MIN_PHONETIC_CODE_LEN {
            return None;
        }

        Some(Self { primary, alternate })
    }

    fn matches(&self, other: &Self) -> bool {
        self.primary == other.primary
            || self.primary == other.alternate
            || self.alternate == other.primary
            || self.alternate == other.alternate
    }

    fn len(&self) -> usize {
        self.primary.chars().count()
    }
}

/// Shortest Double Metaphone code that may drive a phonetic match.
const MIN_PHONETIC_CODE_LEN: usize = 3;

/// Code length at which exact phonetic agreement is treated as strong evidence
/// on its own, rather than merely a hint that edit distance should confirm.
///
/// Five encoded sounds agreeing end to end is well past the range where
/// unrelated English words collide, so spelling may diverge freely underneath
/// it — "easylinks" and "ezlynx" share ASLNKS but are 6 edits apart.
const STRONG_PHONETIC_CODE_LEN: usize = 5;

/// Weight applied to edit distance when phonetic codes agree.
const PHONETIC_SCORE_WEIGHT: f64 = 0.3;

/// Weight applied when the agreeing codes are also long (see
/// [`STRONG_PHONETIC_CODE_LEN`]).
const STRONG_PHONETIC_SCORE_WEIGHT: f64 = 0.2;

/// Builds an n-gram string by cleaning and concatenating words
///
/// Strips punctuation from each word, lowercases, and joins without spaces.
/// This allows matching "Charge B" against "ChargeBee".
fn build_ngram(words: &[&str]) -> String {
    words
        .iter()
        .map(|w| build_match_key(w))
        .collect::<Vec<_>>()
        .concat()
}

fn build_match_key(word: &str) -> String {
    word.chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(|c| c.to_lowercase())
        .collect()
}

/// Writing system of a normalized match key.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum KeyScript {
    /// ASCII letters and digits.
    Latin,
    /// Russian letters, possibly mixed with ASCII letters and digits.
    Cyrillic,
}

struct CustomWordMatchKey {
    word_index: usize,
    key: String,
    script: KeyScript,
    /// The key in Latin letters: the key itself, or its romanization for a
    /// Cyrillic key, so a Latin candidate can be compared with a Russian entry.
    latin: String,
    /// Phonetic code of `latin`. Precomputed so each candidate n-gram costs one
    /// encode, not one per dictionary entry.
    phonetic: Option<PhoneticCode>,
}

impl CustomWordMatchKey {
    fn new(word_index: usize, key: String, script: KeyScript) -> Self {
        let latin = match script {
            KeyScript::Latin => key.clone(),
            KeyScript::Cyrillic => romanize(&key),
        };
        let phonetic = PhoneticCode::encode(&latin);
        Self {
            word_index,
            key,
            script,
            latin,
            phonetic,
        }
    }
}

fn build_custom_word_match_keys(word: &str, word_index: usize) -> Vec<CustomWordMatchKey> {
    let primary_key = build_match_key(word);
    let mut keys = Vec::with_capacity(2);

    // The fallback matcher is intentionally limited to ASCII and Russian
    // terms. Its whitespace tokenization and Double Metaphone scoring are not
    // suitable for CJK scripts. Other Unicode custom words remain available to
    // models that accept them as native decode prompts; they are simply skipped
    // by this fallback.
    if let Some(script) = key_script(&primary_key) {
        keys.push(CustomWordMatchKey::new(
            word_index,
            primary_key.clone(),
            script,
        ));
    }

    if word.contains('&') {
        let expanded_key = build_match_key(&word.replace('&', " and "));
        if is_supported_fuzzy_key(&expanded_key) && expanded_key != primary_key {
            keys.push(CustomWordMatchKey::new(
                word_index,
                expanded_key,
                KeyScript::Latin,
            ));
        }
    }

    keys
}

fn is_supported_fuzzy_key(key: &str) -> bool {
    !key.is_empty() && key.chars().all(|c| c.is_ascii_alphanumeric())
}

fn is_russian_letter(c: char) -> bool {
    matches!(c, 'а'..='я' | 'ё')
}

fn key_script(key: &str) -> Option<KeyScript> {
    if is_supported_fuzzy_key(key) {
        Some(KeyScript::Latin)
    } else if key
        .chars()
        .all(|c| is_russian_letter(c) || c.is_ascii_alphanumeric())
        && key.chars().any(is_russian_letter)
    {
        Some(KeyScript::Cyrillic)
    } else {
        None
    }
}

fn ends_with_russian_letter(word: &str) -> bool {
    word.chars()
        .rev()
        .find(|c| c.is_alphanumeric())
        .is_some_and(|c| c.to_lowercase().all(is_russian_letter))
}

fn supports_phonetics(key: &str) -> bool {
    !key.is_empty() && key.chars().all(|c| c.is_ascii_alphabetic())
}

/// Romanizes the Russian letters of a lowercase key.
///
/// Russian models write English terms the way they sound ("опен роутер",
/// "гитхаб"), so the romanization is what gets compared with a Latin
/// dictionary entry. The scheme follows how English sounds are usually spelled
/// in Russian rather than a formal standard: "дж" is the English "j", and "ч"
/// is "tch", which Double Metaphone never reads as the "k" of "ch" ("дочери"
/// must not sound like "Docker").
fn romanize(key: &str) -> String {
    let mut out = String::with_capacity(key.len());
    let mut chars = key.chars().peekable();

    while let Some(c) = chars.next() {
        if c == 'д' && chars.peek() == Some(&'ж') {
            chars.next();
            out.push('j');
            continue;
        }
        // "тч" sounds as a single "ч" ("скетч" is "sketch").
        if c == 'т' && chars.peek() == Some(&'ч') {
            continue;
        }

        let latin = match c {
            'а' => "a",
            'б' => "b",
            'в' => "v",
            'г' => "g",
            'д' => "d",
            'е' | 'э' => "e",
            'ё' => "yo",
            'ж' => "zh",
            'з' => "z",
            'и' => "i",
            'й' | 'ы' => "y",
            'к' => "k",
            'л' => "l",
            'м' => "m",
            'н' => "n",
            'о' => "o",
            'п' => "p",
            'р' => "r",
            'с' => "s",
            'т' => "t",
            'у' => "u",
            'ф' => "f",
            'х' => "h",
            'ц' => "ts",
            'ч' => "tch",
            'ш' => "sh",
            'щ' => "sch",
            'ъ' | 'ь' => "",
            'ю' => "yu",
            'я' => "ya",
            _ => {
                out.push(c);
                continue;
            }
        };
        out.push_str(latin);
    }

    out
}

/// Largest normalized edit distance between a romanized candidate and a Latin
/// entry whose phonetic code is shorter than [`STRONG_PHONETIC_CODE_LEN`].
const MAX_ROMANIZED_SPELLING_GAP: f64 = 0.5;

/// Shortest Russian entry whose case endings are kept ("СНиП" -> "СНиПа").
/// Shorter entries ("ППР") would swallow unrelated words that merely start
/// with the same letters.
const MIN_INFLECTED_KEY_LEN: usize = 4;

/// Longest Russian case ending carried over from the transcript.
const MAX_CASE_ENDING_LEN: usize = 3;

/// A dictionary entry that matched a candidate span.
struct WordMatch<'a> {
    replacement: &'a String,
    score: f64,
    /// Trailing letters of the candidate that are a Russian case ending on an
    /// exactly recognized entry. They are kept from the transcript rather than
    /// replaced, so "снипа" becomes "СНиПа", not "СНиП".
    ending_len: usize,
}

/// Scores a candidate against a dictionary key, both in Latin letters; `None`
/// when the pair is not comparable.
///
/// `cross_script` is set when exactly one side was romanized from Cyrillic
/// (a Russian word against a Latin entry, or a Latin word against a Russian
/// entry). Such a pair must also sound alike, unless it is identical after
/// romanization: the romanization only approximates English spelling, and edit
/// distance alone would let ordinary words drift onto dictionary terms.
fn score_latin_key(
    candidate: &str,
    candidate_phonetic: Option<&PhoneticCode>,
    key: &str,
    key_phonetic: Option<&PhoneticCode>,
    cross_script: bool,
) -> Option<f64> {
    let phonetic_match = match (candidate_phonetic, key_phonetic) {
        (Some(candidate_code), Some(key_code)) => candidate_code.matches(key_code),
        _ => false,
    };

    // Skip if lengths are too different (optimization + prevents over-matching).
    // Use a percentage-based check: max 25% length difference (prevents n-grams
    // from matching significantly shorter custom words, e.g. "openaigpt" vs
    // "openai"), widened to 50% behind an exact phonetic agreement.
    //
    // The wider gate is what lets a spelling shed or gain several letters
    // without changing its sound ("hightech" -> "HiTek", "throughput" ->
    // "ThruPut"). Agreement is only reachable for codes of at least
    // MIN_PHONETIC_CODE_LEN, which keeps the gate off short, collision-prone
    // terms.
    let candidate_len = candidate.chars().count();
    let custom_word_len = key.chars().count();
    let len_diff = candidate_len.abs_diff(custom_word_len) as f64;
    let max_len = candidate_len.max(custom_word_len) as f64;
    let len_ratio = if phonetic_match { 0.5 } else { 0.25 };
    let max_allowed_diff = (max_len * len_ratio).max(2.0); // At least 2 chars difference allowed
    if len_diff > max_allowed_diff {
        return None;
    }

    // Calculate Levenshtein distance (normalized by length)
    let levenshtein_dist = levenshtein(candidate, key);
    if cross_script && !phonetic_match && levenshtein_dist > 0 {
        return None;
    }
    let levenshtein_score = if max_len > 0.0 {
        levenshtein_dist as f64 / max_len
    } else {
        1.0
    };

    let strong = candidate_phonetic.is_some_and(|code| code.len() >= STRONG_PHONETIC_CODE_LEN);
    // Romanized Russian keeps its own vowels, which Double Metaphone ignores:
    // "выросла" and "Vercel" share FRSL. A short code is weak evidence there,
    // so the spelling has to stay close as well.
    if cross_script && phonetic_match && !strong && levenshtein_score > MAX_ROMANIZED_SPELLING_GAP {
        return None;
    }

    // Combine scores: favor phonetic matches, but also consider string
    // similarity. The longer the agreeing code, the less the remaining
    // spelling difference should count against the match.
    let combined_score = if phonetic_match {
        let weight = if strong {
            STRONG_PHONETIC_SCORE_WEIGHT
        } else {
            PHONETIC_SCORE_WEIGHT
        };
        levenshtein_score * weight
    } else {
        levenshtein_score
    };

    Some(combined_score)
}

/// Scores a Cyrillic candidate against a Cyrillic dictionary key, returning
/// the score and the length of a case ending to keep.
///
/// Russian inflects names and abbreviations ("Одинцова", "СНиПа"). Read as a
/// spelling error, the ending would be dropped and the word put in the wrong
/// case, so a candidate that extends an entry either keeps its ending (single
/// words) or is left alone.
fn score_cyrillic_key(candidate: &str, key: &str, allow_ending: bool) -> Option<(f64, usize)> {
    let candidate_len = candidate.chars().count();
    let key_len = key.chars().count();

    if let Some(ending) = candidate.strip_prefix(key).filter(|e| !e.is_empty()) {
        let ending_len = candidate_len - key_len;
        let keeps_ending = allow_ending
            && key_len >= MIN_INFLECTED_KEY_LEN
            && ending_len <= MAX_CASE_ENDING_LEN
            && ending.chars().all(is_russian_letter);
        return keeps_ending.then_some((0.0, ending_len));
    }

    let len_diff = candidate_len.abs_diff(key_len) as f64;
    let max_len = candidate_len.max(key_len) as f64;
    if len_diff > (max_len * 0.25).max(2.0) {
        return None;
    }

    Some((levenshtein(candidate, key) as f64 / max_len, 0))
}

/// Finds the best matching custom word for a candidate string
///
/// Uses Levenshtein distance and Double Metaphone phonetic matching to find
/// the best match above the given threshold.
///
/// # Arguments
/// * `candidate` - The cleaned/lowercased candidate string to match
/// * `replacements` - What each dictionary entry writes, indexed by entry
/// * `custom_word_match_keys` - Normalized custom-word keys for comparison
/// * `threshold` - Maximum similarity score to accept
/// * `allow_ending` - Whether a Russian case ending may follow an entry
///
/// # Returns
/// The best matching custom word and its score, if any match was found
fn find_best_match<'a>(
    candidate: &str,
    replacements: &'a [String],
    custom_word_match_keys: &[CustomWordMatchKey],
    threshold: f64,
    allow_ending: bool,
) -> Option<WordMatch<'a>> {
    if candidate.chars().count() > 50 {
        return None;
    }
    let script = key_script(candidate)?;
    let romanized = script == KeyScript::Cyrillic;
    let latin = if romanized {
        romanize(candidate)
    } else {
        candidate.to_string()
    };

    // Double Metaphone is an English/ASCII algorithm. Numeric terms can still
    // use edit distance, but must not receive a phonetic boost.
    let latin_phonetic = PhoneticCode::encode(&latin);

    let mut best_match: Option<WordMatch<'a>> = None;

    for custom_word_key in custom_word_match_keys {
        let scored = match custom_word_key.script {
            KeyScript::Latin => score_latin_key(
                &latin,
                latin_phonetic.as_ref(),
                &custom_word_key.latin,
                custom_word_key.phonetic.as_ref(),
                romanized,
            )
            .map(|score| (score, 0)),
            KeyScript::Cyrillic if romanized => {
                score_cyrillic_key(candidate, &custom_word_key.key, allow_ending)
            }
            // Latin spelling of a Russian term ("snip" for "СНиП") must match
            // the entry's romanization exactly: English words sit too close
            // phonetically ("ghost" sounds like "gost") to allow any slack.
            KeyScript::Cyrillic => (latin == custom_word_key.latin).then_some((0.0, 0)),
        };
        let Some((score, ending_len)) = scored else {
            continue;
        };

        // Accept if the score is good enough (configurable threshold)
        if score < threshold && best_match.as_ref().is_none_or(|best| score < best.score) {
            let replacement = &replacements[custom_word_key.word_index];
            // A Russian ending only belongs on a Russian word: "клода" with
            // "клод = Claude" is "Claude", not "Claudeа".
            let ending_len = if ends_with_russian_letter(replacement) {
                ending_len
            } else {
                0
            };
            best_match = Some(WordMatch {
                replacement,
                score,
                ending_len,
            });
        }
    }

    best_match
}

/// Splits a dictionary entry into what it writes and the spoken forms that
/// produce it.
///
/// `"клод, клауд = Claude"` writes "Claude" for either spoken form; a plain
/// entry is matched by its own spelling.
fn parse_custom_word(entry: &str) -> (String, Vec<String>) {
    if let Some((spoken, written)) = entry.split_once('=') {
        let written = written.trim();
        if !written.is_empty() {
            let mut forms: Vec<String> = spoken
                .split(',')
                .map(str::trim)
                .filter(|form| !form.is_empty())
                .map(String::from)
                .collect();
            if forms.is_empty() {
                forms.push(written.to_string());
            }
            return (written.to_string(), forms);
        }
    }

    let word = entry.trim().to_string();
    (word.clone(), vec![word])
}

fn is_custom_word_alias(entry: &str) -> bool {
    entry
        .split_once('=')
        .is_some_and(|(_, written)| !written.trim().is_empty())
}

/// What the dictionary writes, without spoken forms: the terms a model that
/// accepts a vocabulary can be prompted with.
pub fn custom_word_terms(custom_words: &[String]) -> Vec<String> {
    let mut terms: Vec<String> = Vec::with_capacity(custom_words.len());
    for entry in custom_words {
        let (written, _) = parse_custom_word(entry);
        if !terms.contains(&written) {
            terms.push(written);
        }
    }
    terms
}

/// Entries with explicit spoken forms. They still apply after the model was
/// prompted with the written terms: a prompt cannot teach a model that
/// "клод" is spelled "Claude".
pub fn custom_word_aliases(custom_words: &[String]) -> Vec<String> {
    custom_words
        .iter()
        .filter(|entry| is_custom_word_alias(entry))
        .cloned()
        .collect()
}

/// The last `len` letters of a word, without its surrounding punctuation.
fn case_ending(word: &str, len: usize) -> String {
    let (prefix, suffix) = extract_punctuation(word);
    if len == 0 || prefix.len() + suffix.len() >= word.len() {
        return String::new();
    }

    let core = &word[prefix.len()..word.len() - suffix.len()];
    let count = core.chars().count();
    core.chars().skip(count.saturating_sub(len)).collect()
}

/// Applies custom word corrections to transcribed text using fuzzy matching
///
/// This function corrects words in the input text by finding the best matches
/// from a list of custom words using a combination of:
/// - Levenshtein distance for string similarity
/// - Double Metaphone phonetic matching for pronunciation similarity
/// - N-gram matching for multi-word speech artifacts (e.g., "Charge B" -> "ChargeBee")
/// - Romanization of Russian text, so "опен роутер" matches "OpenRouter"
/// - The reverse direction: a Latin spelling of a Russian term ("snip",
///   "gost") is compared with the romanization of a Cyrillic entry ("СНиП",
///   "ГОСТ") and replaced by the entry
///
/// An entry written as `spoken = written` ("клод, клауд = Claude") matches
/// its spoken forms and writes the right-hand side.
///
/// # Arguments
/// * `text` - The input text to correct
/// * `custom_words` - List of custom words to match against
/// * `threshold` - Maximum similarity score to accept (0.0 = exact match, 1.0 = any match)
///
/// # Returns
/// The corrected text with custom words applied
pub fn apply_custom_words(text: &str, custom_words: &[String], threshold: f64) -> String {
    if custom_words.is_empty() {
        return text.to_string();
    }

    let entries: Vec<(String, Vec<String>)> = custom_words
        .iter()
        .map(|entry| parse_custom_word(entry))
        .collect();
    let replacements: Vec<String> = entries.iter().map(|(written, _)| written.clone()).collect();

    // Pre-compute normalized comparison keys to avoid repeated allocations.
    let custom_word_match_keys: Vec<CustomWordMatchKey> = entries
        .iter()
        .enumerate()
        .flat_map(|(index, (_, spoken))| {
            spoken
                .iter()
                .flat_map(move |form| build_custom_word_match_keys(form, index))
        })
        .collect();

    let words: Vec<&str> = text.split_whitespace().collect();
    let mut result = Vec::new();
    let mut i = 0;

    while i < words.len() {
        let mut best_match: Option<(usize, WordMatch)> = None;

        // Consider n-grams up to three words and choose the closest match. A
        // longest-first match can consume a following ordinary word when both
        // candidates happen to share a Soundex code (for example,
        // "Charge B, che" matching "ChargeBee").
        for n in (1..=3).rev() {
            if i + n > words.len() {
                continue;
            }

            let ngram_words = &words[i..i + n];
            // Do not consume across a punctuation boundary. In
            // "Charge B, che", the comma closes the candidate at "B,".
            if ngram_words[..n.saturating_sub(1)]
                .iter()
                .any(|word| !extract_punctuation(word).1.is_empty())
            {
                continue;
            }
            let ngram = build_ngram(ngram_words);

            // A case ending is only unambiguous on a single word; across an
            // n-gram it could be a following preposition ("снип а также").
            if let Some(found) = find_best_match(
                &ngram,
                &replacements,
                &custom_word_match_keys,
                threshold,
                n == 1,
            ) {
                let is_better = best_match
                    .as_ref()
                    .is_none_or(|(_, best)| found.score < best.score);
                if is_better {
                    best_match = Some((n, found));
                }
            }
        }

        if let Some((n, found)) = best_match {
            let ngram_words = &words[i..i + n];
            // Extract punctuation from first and last words of the n-gram.
            let (prefix, _) = extract_punctuation(ngram_words[0]);
            let (_, suffix) = extract_punctuation(ngram_words[n - 1]);

            // Case is judged across the whole span, not just its first word.
            let corrected = preserve_case_pattern_for_span(ngram_words, found.replacement);
            let ending = case_ending(ngram_words[n - 1], found.ending_len);

            result.push(format!("{}{}{}{}", prefix, corrected, ending, suffix));
            i += n;
        } else {
            // No whole-token match. The token may still be a compound whose
            // separator the n-gram key threw away ("brightcore.com"), so retry
            // against its individual alphanumeric runs.
            let rewritten = apply_custom_words_within_token(
                words[i],
                &replacements,
                &custom_word_match_keys,
                threshold,
            );
            result.push(rewritten.unwrap_or_else(|| words[i].to_string()));
            i += 1;
        }
    }

    result.join(" ")
}

/// True when a dictionary entry carries capitalization that the speaker cannot
/// convey and that the transcript therefore must not overwrite.
///
/// A brand name like `FlitePath`, `ChargeBee` or `SQLAlchemy` is the entire
/// reason the user added the entry; rebuilding its case from the spoken words
/// would yield `Flitepath`, which is exactly the spelling they were fixing.
/// An entry that is uniformly lower- or upper-case expresses no such intent, so
/// it keeps following the surrounding sentence.
fn has_intentional_case(replacement: &str) -> bool {
    let mut chars = replacement.chars();
    let Some(first) = chars.next() else {
        return false;
    };

    // Uppercase after the first character (`FlitePath`, `SQLAlchemy`), or a
    // lowercase lead-in before one (`iPhone`, `eBay`).
    chars.any(|c| c.is_uppercase()) && (first.is_lowercase() || chars.any(|c| c.is_lowercase()))
}

/// True when an entire matched span is capitalized, i.e. the transcript is
/// shouting rather than merely leading with an acronym.
///
/// Judged across every word in the span. Inspecting only the first word reads
/// "SQL Alchemy" as a shout and yields SQLALCHEMY, destroying exactly the
/// capitalization the dictionary entry exists to supply.
fn is_shouted(words: &[&str]) -> bool {
    let letters: usize = words
        .iter()
        .flat_map(|word| word.chars())
        .filter(|c| c.is_alphabetic())
        .count();

    letters > 1
        && words
            .iter()
            .flat_map(|word| word.chars())
            .filter(|c| c.is_alphabetic())
            .all(char::is_uppercase)
}

/// Preserves the case pattern of the original word when applying a replacement
fn preserve_case_pattern(original: &str, replacement: &str) -> String {
    preserve_case_pattern_for_span(&[original], replacement)
}

/// Chooses the casing for `replacement` given the whole span it replaces.
fn preserve_case_pattern_for_span(original: &[&str], replacement: &str) -> String {
    let first = original.first().copied().unwrap_or("");

    // An all-caps utterance is an explicit emphasis signal in the transcript,
    // so it still wins over the entry's own casing.
    if is_shouted(original) {
        replacement.to_uppercase()
    } else if has_intentional_case(replacement) {
        replacement.to_string()
    } else if first.chars().next().is_some_and(|c| c.is_uppercase()) {
        let mut chars: Vec<char> = replacement.chars().collect();
        if let Some(first_char) = chars.get_mut(0) {
            *first_char = first_char.to_uppercase().next().unwrap_or(*first_char);
        }
        chars.into_iter().collect()
    } else {
        replacement.to_string()
    }
}

/// Splits a token into alphanumeric runs and the separators between them.
///
/// `"brightcore.com"` becomes `["brightcore", ".", "com"]`. Runs sit at even
/// indices, separators at odd ones, so a caller can rewrite individual runs and
/// rejoin without losing the punctuation between them.
fn split_token_segments(token: &str) -> Vec<String> {
    let mut segments: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut current_is_alnum = true;

    for c in token.chars() {
        let is_alnum = c.is_alphanumeric();
        if is_alnum != current_is_alnum && !current.is_empty() {
            segments.push(std::mem::take(&mut current));
            current_is_alnum = is_alnum;
        } else if current.is_empty() {
            current_is_alnum = is_alnum;
        }
        current.push(c);
    }

    if !current.is_empty() {
        segments.push(current);
    }

    // Normalize so runs are always at even indices.
    if segments
        .first()
        .is_some_and(|segment| !segment.chars().next().is_some_and(char::is_alphanumeric))
    {
        segments.insert(0, String::new());
    }

    segments
}

/// Applies custom words to the alphanumeric runs inside a single token.
///
/// Handles compounds the whole-token matcher cannot express, such as
/// `flightpath.com` -> `FlitePath.com`, where the replacement has to land on
/// part of the token and leave the rest — including the separator — intact.
/// Returns `None` when no run matched, so the caller can keep the original.
fn apply_custom_words_within_token(
    token: &str,
    replacements: &[String],
    custom_word_match_keys: &[CustomWordMatchKey],
    threshold: f64,
) -> Option<String> {
    let mut segments = split_token_segments(token);
    // Nothing to gain unless the token has an internal separator, i.e. at
    // least two alphanumeric runs.
    if segments.len() < 3 {
        return None;
    }

    let mut matched = false;
    for index in (0..segments.len()).step_by(2) {
        let run = &segments[index];
        let key = build_match_key(run);
        if key.is_empty() {
            continue;
        }

        if let Some(found) =
            find_best_match(&key, replacements, custom_word_match_keys, threshold, false)
        {
            segments[index] = preserve_case_pattern(run, found.replacement);
            matched = true;
        }
    }

    matched.then(|| segments.concat())
}

/// Extracts punctuation prefix and suffix from a word
fn extract_punctuation(word: &str) -> (&str, &str) {
    // String slices use byte offsets. Derive both boundaries from char_indices
    // so multibyte punctuation such as `。` and `「」` can never be split.
    let prefix_end = word
        .char_indices()
        .find(|(_, c)| c.is_alphanumeric())
        .map(|(index, _)| index)
        .unwrap_or(word.len());
    let suffix_start = word
        .char_indices()
        .rev()
        .find(|(_, c)| c.is_alphanumeric())
        .map(|(index, c)| index + c.len_utf8())
        .unwrap_or(0);

    let prefix = if prefix_end > 0 {
        &word[..prefix_end]
    } else {
        ""
    };

    let suffix = if suffix_start < word.len() {
        &word[suffix_start..]
    } else {
        ""
    };

    (prefix, suffix)
}

/// Evidence for the language of the text being cleaned.
///
/// This intentionally describes the transcription output, not Handy's UI
/// language. Unknown output languages fail closed: built-in filler removal is
/// skipped rather than applying a language profile speculatively.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OutputLanguageEvidence {
    UserSelected(String),
    ModelConstrained(String),
    /// The transcription model itself identified the language (audio-based
    /// LID, e.g. Whisper in auto mode).
    ModelDetected(String),
    /// Detected from the transcribed text with high confidence, constrained to
    /// the model's supported languages. Weakest accepted evidence.
    TextDetected(String),
    TranslatedToEnglish,
    Unknown,
}

impl OutputLanguageEvidence {
    pub(crate) fn language(&self) -> Option<&str> {
        match self {
            Self::UserSelected(language)
            | Self::ModelConstrained(language)
            | Self::ModelDetected(language)
            | Self::TextDetected(language) => Some(language),
            Self::TranslatedToEnglish => Some("en"),
            Self::Unknown => None,
        }
    }
}

/// Filler tokens that are not lexical words in any language Handy's models can
/// output, so removing them cannot corrupt text regardless of the (possibly
/// unknown) output language. Kept deliberately conservative: anything that is a
/// real word somewhere ("um" pt/de, "ha" es, "ah"/"eh" interjections, "mm"
/// millimetres) belongs in the language-gated lists instead.
const UNIVERSAL_FILLER_WORDS: &[&str] = &[
    "uh", "uhm", "umm", "uhh", "uhhh", "ehh", "ehm", "ahm", "hmm", "hm", "mmm", "хм", "ммм",
];

/// Filler words that are only safe to remove with evidence for the output
/// language, because the same token is a real word elsewhere (e.g. Portuguese
/// "um" = "a/an", German "um" = "at/around", Spanish "ha" = "has").
fn gated_filler_words_for_language(lang: &str) -> &'static [&'static str] {
    let base_lang = lang.split(&['-', '_'][..]).next().unwrap_or(lang);

    match base_lang {
        "en" => &["um", "ah", "eh"],
        "de" => &["äh", "ähm"],
        "fr" => &["euh"],
        // Not "мм": it is the millimetre unit.
        "ru" => &["э", "ээ", "эээ", "эм", "эмм"],
        _ => &[],
    }
}

static MULTI_SPACE_PATTERN: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s{2,}").unwrap());

/// Collapses repeated words (3+ repetitions) to a single instance.
/// E.g., "wh wh wh wh" -> "wh", "I I I I" -> "I"
fn collapse_stutters(text: &str) -> String {
    let words: Vec<&str> = text.split_whitespace().collect();
    if words.is_empty() {
        return text.to_string();
    }

    let mut result: Vec<&str> = Vec::new();
    let mut i = 0;

    while i < words.len() {
        let word = words[i];
        let word_lower = word.to_lowercase();

        if word_lower.chars().all(|c| c.is_alphabetic()) {
            // Count consecutive repetitions (case-insensitive)
            let mut count = 1;
            while i + count < words.len() && words[i + count].to_lowercase() == word_lower {
                count += 1;
            }

            // If 3+ repetitions, collapse to single instance
            if count >= 3 {
                result.push(word);
                i += count;
            } else {
                result.push(word);
                i += 1;
            }
        } else {
            result.push(word);
            i += 1;
        }
    }

    result.join(" ")
}

/// Whether a word appended to `kept` would open a sentence: nothing but
/// whitespace so far, or the last visible character ends a sentence.
fn opens_sentence(kept: &str) -> bool {
    kept.trim_end()
        .chars()
        .next_back()
        .is_none_or(|c| matches!(c, '.' | '!' | '?' | '…'))
}

/// Appends `segment` to `kept`. While `capital_owed` is set, the first
/// alphanumeric character of `segment` is uppercased and the debt is settled.
fn push_restoring_capital(kept: &mut String, segment: &str, capital_owed: &mut bool) {
    if *capital_owed {
        if let Some((index, first)) = segment.char_indices().find(|(_, c)| c.is_alphanumeric()) {
            *capital_owed = false;
            kept.push_str(&segment[..index]);
            kept.extend(first.to_uppercase());
            kept.push_str(&segment[index + first.len_utf8()..]);
            return;
        }
    }
    kept.push_str(segment);
}

/// Deletes every match of one filler pattern. A capitalized filler that opened
/// a sentence hands its capital to the word that takes its place, so
/// "Um, so I think" becomes "So I think" rather than "so I think".
fn remove_filler_matches(text: &str, pattern: &Regex) -> String {
    let mut kept = String::with_capacity(text.len());
    let mut resume = 0;
    let mut capital_owed = false;

    for filler in pattern.find_iter(text) {
        push_restoring_capital(&mut kept, &text[resume..filler.start()], &mut capital_owed);
        let capitalized = filler.as_str().starts_with(char::is_uppercase);
        capital_owed |= capitalized && opens_sentence(&kept);
        resume = filler.end();
    }
    push_restoring_capital(&mut kept, &text[resume..], &mut capital_owed);

    kept
}

/// Removes filler words from transcription output when enabled.
///
/// Built-in removal is two-tiered: [`UNIVERSAL_FILLER_WORDS`] apply regardless
/// of language evidence, while [`gated_filler_words_for_language`] tokens are
/// only removed when the output language is known. A custom list is an
/// explicit user override and replaces both tiers without requiring language
/// evidence. `Some(empty vec)` disables removal, preserving the legacy
/// power-user setting. The master toggle takes precedence over both built-in
/// and custom lists.
///
/// # Arguments
/// * `text` - The raw transcription text to filter
/// * `language` - Evidence for the language of the transcription output
/// * `custom_filler_words` - Optional user-provided filler word list. `Some(vec)` overrides
///   language defaults; `Some(empty vec)` disables filtering; `None` uses language defaults.
/// * `enabled` - Whether filler-word removal is enabled
///
/// # Returns
/// The text with configured filler words removed
pub fn remove_filler_words(
    text: &str,
    language: &OutputLanguageEvidence,
    custom_filler_words: &Option<Vec<String>>,
    enabled: bool,
) -> String {
    if !enabled {
        return text.to_string();
    }

    // Build filler patterns from custom list or the built-in tiers
    let patterns: Vec<Regex> = match custom_filler_words {
        Some(words) => words
            .iter()
            .filter_map(|word| Regex::new(&format!(r"(?i)\b{}\b[,.]?", regex::escape(word))).ok())
            .collect(),
        None => UNIVERSAL_FILLER_WORDS
            .iter()
            .chain(
                language
                    .language()
                    .map(gated_filler_words_for_language)
                    .unwrap_or_default(),
            )
            .map(|word| Regex::new(&format!(r"(?i)\b{}\b[,.]?", regex::escape(word))).unwrap())
            .collect(),
    };

    // Remove filler words
    let mut filtered = text.to_string();
    for pattern in &patterns {
        filtered = remove_filler_matches(&filtered, pattern);
    }

    filtered
}

/// Applies non-filler transcription cleanup.
///
/// Kept separate from [`remove_filler_words`] so disabling filler deletion
/// does not also disable the existing repeated-word and whitespace cleanup.
pub fn normalize_transcription_output(text: &str) -> String {
    let mut normalized = collapse_stutters(text);

    // Clean up multiple spaces to single space
    normalized = MULTI_SPACE_PATTERN
        .replace_all(&normalized, " ")
        .to_string();

    // Trim leading/trailing whitespace
    normalized.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Exercise the complete cleanup sequence with an explicitly selected
    /// language. Individual tests below predate the split between filler
    /// removal and non-filler normalization.
    fn filter_transcription_output(
        text: &str,
        language: &str,
        custom_filler_words: &Option<Vec<String>>,
    ) -> String {
        let language = OutputLanguageEvidence::UserSelected(language.to_string());
        let filtered = remove_filler_words(text, &language, custom_filler_words, true);
        normalize_transcription_output(&filtered)
    }

    #[test]
    fn test_apply_custom_words_exact_match() {
        let text = "hello world";
        let custom_words = vec!["Hello".to_string(), "World".to_string()];
        let result = apply_custom_words(text, &custom_words, 0.5);
        assert_eq!(result, "Hello World");
    }

    #[test]
    fn test_apply_custom_words_fuzzy_match() {
        let text = "helo wrold";
        let custom_words = vec!["hello".to_string(), "world".to_string()];
        let result = apply_custom_words(text, &custom_words, 0.5);
        assert_eq!(result, "hello world");
    }

    #[test]
    fn test_preserve_case_pattern() {
        assert_eq!(preserve_case_pattern("HELLO", "world"), "WORLD");
        assert_eq!(preserve_case_pattern("Hello", "world"), "World");
        assert_eq!(preserve_case_pattern("hello", "WORLD"), "WORLD");
    }

    #[test]
    fn test_extract_punctuation() {
        assert_eq!(extract_punctuation("hello"), ("", ""));
        assert_eq!(extract_punctuation("!hello?"), ("!", "?"));
        assert_eq!(extract_punctuation("...hello..."), ("...", "..."));
    }

    #[test]
    fn test_extract_punctuation_uses_unicode_boundaries() {
        assert_eq!(extract_punctuation("你好。"), ("", "。"));
        assert_eq!(extract_punctuation("「你好」"), ("「", "」"));
        assert_eq!(extract_punctuation("你好！"), ("", "！"));
    }

    #[test]
    fn test_empty_custom_words() {
        let text = "hello world";
        let custom_words = vec![];
        let result = apply_custom_words(text, &custom_words, 0.5);
        assert_eq!(result, "hello world");
    }

    #[test]
    fn test_filter_filler_words() {
        let text = "So uhm I was thinking uh about this";
        let result = filter_transcription_output(text, "en", &None);
        assert_eq!(result, "So I was thinking about this");
    }

    #[test]
    fn test_filter_filler_words_case_insensitive() {
        let text = "UHM this is UH a test";
        let result = filter_transcription_output(text, "en", &None);
        assert_eq!(result, "This is a test");
    }

    #[test]
    fn test_filter_filler_words_with_punctuation() {
        let text = "Well, uhm, I think, uh. that's right";
        let result = filter_transcription_output(text, "en", &None);
        assert_eq!(result, "Well, I think, that's right");
    }

    #[test]
    fn test_filter_cleans_whitespace() {
        let text = "Hello    world   test";
        let result = filter_transcription_output(text, "en", &None);
        assert_eq!(result, "Hello world test");
    }

    #[test]
    fn test_filter_trims() {
        let text = "  Hello world  ";
        let result = filter_transcription_output(text, "en", &None);
        assert_eq!(result, "Hello world");
    }

    #[test]
    fn test_filter_combined() {
        let text = "  Uhm, so I was, uh, thinking about this  ";
        let result = filter_transcription_output(text, "en", &None);
        assert_eq!(result, "So I was, thinking about this");
    }

    #[test]
    fn test_filter_leading_filler_keeps_sentence_capital() {
        let result = filter_transcription_output("Um, so I think we should ship it.", "en", &None);
        assert_eq!(result, "So I think we should ship it.");

        let result = filter_transcription_output("That works. Um, let me check.", "en", &None);
        assert_eq!(result, "That works. Let me check.");

        // Mid-sentence there is no capital to hand over.
        let result = filter_transcription_output("He said, Um, not today.", "en", &None);
        assert_eq!(result, "He said, not today.");
    }

    #[test]
    fn test_filter_preserves_valid_text() {
        let text = "This is a completely normal sentence.";
        let result = filter_transcription_output(text, "en", &None);
        assert_eq!(result, "This is a completely normal sentence.");
    }

    #[test]
    fn test_filter_stutter_collapse() {
        let text = "w wh wh wh wh wh wh wh wh wh why";
        let result = filter_transcription_output(text, "en", &None);
        assert_eq!(result, "w wh why");
    }

    #[test]
    fn test_filter_stutter_short_words() {
        let text = "I I I I think so so so so";
        let result = filter_transcription_output(text, "en", &None);
        assert_eq!(result, "I think so");
    }

    #[test]
    fn test_filter_stutter_longer_words() {
        let text = "Check data doc doc doc doc documentation.";
        let result = filter_transcription_output(text, "en", &None);
        assert_eq!(result, "Check data doc documentation.");
    }

    #[test]
    fn test_filter_stutter_mixed_case() {
        let text = "No NO no NO no";
        let result = filter_transcription_output(text, "en", &None);
        assert_eq!(result, "No");
    }

    #[test]
    fn test_filter_stutter_preserves_two_repetitions() {
        let text = "no no is fine";
        let result = filter_transcription_output(text, "en", &None);
        assert_eq!(result, "no no is fine");
    }

    #[test]
    fn test_filter_english_removes_um() {
        let text = "um I think um this is good";
        let result = filter_transcription_output(text, "en", &None);
        assert_eq!(result, "I think this is good");
    }

    #[test]
    fn test_filter_portuguese_preserves_um() {
        // "um" means "a/an" in Portuguese
        let text = "um gato bonito";
        let result = filter_transcription_output(text, "pt", &None);
        assert_eq!(result, "um gato bonito");
    }

    #[test]
    fn test_filter_spanish_preserves_ha() {
        // "ha" means "has" in Spanish
        let text = "ha sido un buen día";
        let result = filter_transcription_output(text, "es", &None);
        assert_eq!(result, "ha sido un buen día");
    }

    #[test]
    fn test_filter_language_code_with_region() {
        // "pt-BR" should normalize to "pt"
        let text = "um gato bonito";
        let result = filter_transcription_output(text, "pt-BR", &None);
        assert_eq!(result, "um gato bonito");
    }

    #[test]
    fn test_filter_custom_filler_words_override() {
        let custom = Some(vec!["okay".to_string(), "right".to_string()]);
        let text = "okay so I think right this works";
        let result = filter_transcription_output(text, "en", &custom);
        assert_eq!(result, "so I think this works");
    }

    #[test]
    fn test_filter_custom_filler_words_empty_disables() {
        let custom = Some(vec![]);
        let text = "So uhm I was thinking uh about this";
        let result = filter_transcription_output(text, "en", &custom);
        // No filler words removed since custom list is empty
        assert_eq!(result, "So uhm I was thinking uh about this");
    }

    #[test]
    fn test_filter_unknown_language_still_removes_universal_fillers() {
        let text = "uh I think uhm this works";
        let result = filter_transcription_output(text, "xx", &None);
        assert_eq!(result, "I think this works");
    }

    #[test]
    fn test_filter_unknown_language_does_not_remove_um() {
        let text = "um I think this works";
        let result = filter_transcription_output(text, "xx", &None);
        assert_eq!(result, "um I think this works");
    }

    #[test]
    fn test_filter_unknown_evidence_removes_universal_keeps_gated() {
        let filtered = remove_filler_words(
            "uhh bueno hmm creo que um ha llegado",
            &OutputLanguageEvidence::Unknown,
            &None,
            true,
        );
        assert_eq!(
            normalize_transcription_output(&filtered),
            "bueno creo que um ha llegado"
        );

        let cyrillic = remove_filler_words(
            "хм я думаю ммм это работает",
            &OutputLanguageEvidence::Unknown,
            &None,
            true,
        );
        assert_eq!(
            normalize_transcription_output(&cyrillic),
            "я думаю это работает"
        );
    }

    #[test]
    fn test_filter_german_gated_fillers_require_evidence() {
        let text = "äh ich glaube ähm das passt";

        let unknown = remove_filler_words(text, &OutputLanguageEvidence::Unknown, &None, true);
        assert_eq!(normalize_transcription_output(&unknown), text);

        let result = filter_transcription_output(text, "de", &None);
        assert_eq!(result, "ich glaube das passt");
    }

    #[test]
    fn test_filter_preserves_millimetre_unit() {
        // "mm" was removed from the filler lists because it eats units.
        let text = "the screw is 5 mm long";
        let result = filter_transcription_output(text, "en", &None);
        assert_eq!(result, "the screw is 5 mm long");
    }

    #[test]
    fn test_filter_detected_evidence_unlocks_gated_fillers() {
        let model = remove_filler_words(
            "um I think this works",
            &OutputLanguageEvidence::ModelDetected("en".to_string()),
            &None,
            true,
        );
        assert_eq!(normalize_transcription_output(&model), "I think this works");

        let text = remove_filler_words(
            "euh je pense que ça marche",
            &OutputLanguageEvidence::TextDetected("fr".to_string()),
            &None,
            true,
        );
        assert_eq!(
            normalize_transcription_output(&text),
            "je pense que ça marche"
        );
    }

    #[test]
    fn test_filter_master_toggle_disables_custom_and_builtin_removal() {
        let text = "um customword I think";
        let language = OutputLanguageEvidence::UserSelected("en".to_string());
        let custom = Some(vec!["customword".to_string()]);

        let result = remove_filler_words(text, &language, &custom, false);

        assert_eq!(result, text);
    }

    #[test]
    fn test_filter_custom_words_apply_without_language_evidence() {
        let custom = Some(vec!["customword".to_string()]);
        let text = "customword should be removed but um should remain";

        let filtered = remove_filler_words(text, &OutputLanguageEvidence::Unknown, &custom, true);
        let result = normalize_transcription_output(&filtered);

        assert_eq!(result, "should be removed but um should remain");
    }

    #[test]
    fn test_apply_custom_words_ngram_two_words() {
        let text = "il cui nome è Charge B, che permette";
        let custom_words = vec!["ChargeBee".to_string()];
        let result = apply_custom_words(text, &custom_words, 0.5);
        assert!(result.contains("ChargeBee,"), "unexpected result: {result}");
        assert!(!result.contains("Charge B"));
    }

    #[test]
    fn test_apply_custom_words_ngram_three_words() {
        let text = "use Chat G P T for this";
        let custom_words = vec!["ChatGPT".to_string()];
        let result = apply_custom_words(text, &custom_words, 0.5);
        assert!(result.contains("ChatGPT"));
    }

    #[test]
    fn test_apply_custom_words_prefers_longer_ngram() {
        let text = "Open AI GPT model";
        let custom_words = vec!["OpenAI".to_string(), "GPT".to_string()];
        let result = apply_custom_words(text, &custom_words, 0.5);
        assert_eq!(result, "OpenAI GPT model");
    }

    #[test]
    fn test_apply_custom_words_ngram_preserves_case() {
        let text = "CHARGE B is great";
        let custom_words = vec!["ChargeBee".to_string()];
        let result = apply_custom_words(text, &custom_words, 0.5);
        assert!(result.contains("CHARGEBEE"));
    }

    #[test]
    fn test_apply_custom_words_ngram_with_spaces_in_custom() {
        // Custom word with space should also match against split words
        let text = "using Mac Book Pro";
        let custom_words = vec!["MacBook Pro".to_string()];
        let result = apply_custom_words(text, &custom_words, 0.5);
        assert_eq!(result, "using MacBook Pro");
    }

    #[test]
    fn test_apply_custom_words_trailing_number_not_doubled() {
        // Verify that trailing non-alpha chars (like numbers) aren't double-counted
        // between build_ngram stripping them and extract_punctuation capturing them
        let text = "use GPT4 for this";
        let custom_words = vec!["GPT-4".to_string()];
        let result = apply_custom_words(text, &custom_words, 0.5);
        // Should NOT produce "GPT-44" (double-counting the trailing 4)
        assert!(
            !result.contains("GPT-44"),
            "got double-counted result: {}",
            result
        );
    }

    #[test]
    fn test_apply_custom_words_matches_ampersand_word() {
        let text = "send it to RD for review";
        let custom_words = vec!["R&D".to_string()];
        let result = apply_custom_words(text, &custom_words, 0.18);
        assert_eq!(result, "send it to R&D for review");
    }

    #[test]
    fn test_apply_custom_words_matches_spoken_ampersand_word() {
        let text = "send it to R and D for review";
        let custom_words = vec!["R&D".to_string()];
        let result = apply_custom_words(text, &custom_words, 0.18);
        assert_eq!(result, "send it to R&D for review");
    }

    #[test]
    fn test_apply_custom_words_preserves_ampersand_word() {
        let text = "send it to R&D for review";
        let custom_words = vec!["R&D".to_string()];
        let result = apply_custom_words(text, &custom_words, 0.18);
        assert_eq!(result, "send it to R&D for review");
    }

    #[test]
    fn test_apply_custom_words_handles_unicode_punctuation() {
        let text = "「Handee。」";
        let custom_words = vec!["Handy".to_string()];
        let result = apply_custom_words(text, &custom_words, 0.5);
        assert_eq!(result, "「Handy。」");
    }

    /// Soundex cannot see a silent `gh`. It encodes the `g` in "flight" using
    /// its `cgjkqsxz` -> `2` group *before* the `t`'s `3`, giving FL23, while
    /// "flite" goes straight to FL30. The two disagree, so the phonetic boost
    /// never fired and raw edit distance alone could not clear the threshold —
    /// the single most common silent digraph in English defeated the matcher.
    /// Double Metaphone silences it: both "flightpath" and "flitepath" encode
    /// to FLTP0/FLTPT.
    #[test]
    fn test_apply_custom_words_matches_silent_gh_compound() {
        let custom_words = vec!["FlitePath".to_string()];

        for text in [
            "flight path",
            "Flight Path",
            "the flight path is clear",
            "flight path, the shortest route",
        ] {
            let result = apply_custom_words(text, &custom_words, 0.18);
            assert!(
                result.contains("FlitePath"),
                "expected FlitePath in {result:?} (from {text:?})"
            );
            assert!(!result.to_lowercase().contains("flight"));
        }
    }

    /// Exact phonetic agreement widens the length guard, so a spelling may shed
    /// several letters without changing its sound. "hightech" (8) against
    /// "hitek" (5) exceeds the default 25% gate and would otherwise be skipped
    /// before it was ever scored.
    #[test]
    fn test_apply_custom_words_matches_across_length_gap() {
        let custom_words = vec!["HiTek".to_string(), "ThruPut".to_string()];

        assert_eq!(
            apply_custom_words("high tech", &custom_words, 0.18),
            "HiTek"
        );
        assert_eq!(
            apply_custom_words("through put", &custom_words, 0.18),
            "ThruPut"
        );
    }

    #[test]
    fn test_apply_custom_words_preserves_entry_casing() {
        let custom_words = vec!["FlitePath".to_string()];

        // Speech carries no case information, so the entry's own
        // capitalization must survive rather than being rebuilt from the
        // spoken words into "Flitepath" — the intercap is the whole reason the
        // user added the entry.
        assert_eq!(
            apply_custom_words("flight path", &custom_words, 0.18),
            "FlitePath"
        );
        assert_eq!(
            apply_custom_words("Flight path", &custom_words, 0.18),
            "FlitePath"
        );

        // An all-caps utterance is explicit emphasis and still wins.
        assert_eq!(
            apply_custom_words("FLIGHT PATH", &custom_words, 0.18),
            "FLITEPATH"
        );
    }

    #[test]
    fn test_apply_custom_words_rewrites_run_inside_token() {
        let custom_words = vec!["FlitePath".to_string()];

        // The n-gram key drops the separator, so a whole-token match would
        // return "FlitePath" and silently eat the ".com".
        assert_eq!(
            apply_custom_words("visit flightpath.com today", &custom_words, 0.18),
            "visit FlitePath.com today"
        );
        assert_eq!(
            apply_custom_words("the flight-path planner", &custom_words, 0.18),
            "the FlitePath planner"
        );
    }

    #[test]
    fn test_apply_custom_words_matches_sibling_entries() {
        let custom_words = vec!["FlitePath".to_string(), "FliteOps".to_string()];

        assert_eq!(
            apply_custom_words("flight path and flight ops", &custom_words, 0.18),
            "FlitePath and FliteOps"
        );
    }

    /// The flip side of a more permissive matcher: ordinary English that merely
    /// shares a prefix — or a whole Soundex code — with an entry must survive
    /// untouched. Every phrase here encodes to FLT under Soundex, the same as
    /// "flite".
    #[test]
    fn test_apply_custom_words_does_not_swallow_ordinary_words() {
        let custom_words = vec!["FlitePath".to_string(), "HiTek".to_string()];

        for text in [
            "flat pack",
            "the fleet",
            "a flightless bird",
            "flight deck",
            "she took flight",
            "float plane",
            "the light path",
            "high tea",
        ] {
            let result = apply_custom_words(text, &custom_words, 0.18);
            assert_eq!(result, text, "unexpected correction of {text:?}");
        }
    }

    /// Double Metaphone truncated to commons-codec's 4-character default would
    /// collide "flitepath" (FLTP) with "flatpack" (FLTP). Full-length codes keep
    /// them apart as FLTP0 and FLTPK.
    #[test]
    fn test_phonetic_codes_are_not_truncated() {
        let flitepath = PhoneticCode::encode("flitepath").expect("encodable");
        let flightpath = PhoneticCode::encode("flightpath").expect("encodable");
        let flatpack = PhoneticCode::encode("flatpack").expect("encodable");

        assert!(flitepath.matches(&flightpath));
        assert!(!flitepath.matches(&flatpack));
        assert!(flitepath.len() > 4 && flatpack.len() > 4);
    }

    #[test]
    fn test_phonetic_code_rejects_short_and_non_alphabetic() {
        // Two-character codes collide freely ("rd" and "rt" both encode RT),
        // so they must not earn the phonetic boost.
        assert!(PhoneticCode::encode("rd").is_none());
        assert!(PhoneticCode::encode("gpt4").is_none());
        assert!(PhoneticCode::encode("").is_none());
    }

    #[test]
    fn test_split_token_segments() {
        assert_eq!(
            split_token_segments("flightpath.com"),
            vec!["flightpath", ".", "com"]
        );
        assert_eq!(split_token_segments("plain"), vec!["plain"]);
        assert_eq!(
            split_token_segments("(flight-path)"),
            vec!["", "(", "flight", "-", "path", ")"]
        );
    }

    #[test]
    fn test_has_intentional_case() {
        assert!(has_intentional_case("FlitePath"));
        assert!(has_intentional_case("ChargeBee"));
        assert!(has_intentional_case("SQLAlchemy"));
        assert!(has_intentional_case("iPhone"));
        assert!(!has_intentional_case("flitepath"));
        assert!(!has_intentional_case("ACORD"));
        assert!(!has_intentional_case("Handy"));
    }

    /// A span that merely *starts* with an acronym is not a shout. Judging
    /// case from the first word alone read "SQL Alchemy" as shouting and
    /// returned SQLALCHEMY, destroying the very capitalization the entry
    /// exists to supply.
    #[test]
    fn test_apply_custom_words_acronym_lead_is_not_a_shout() {
        let custom_words = vec!["SQLAlchemy".to_string(), "XMLParser".to_string()];

        assert_eq!(
            apply_custom_words("SQL Alchemy", &custom_words, 0.18),
            "SQLAlchemy"
        );
        assert_eq!(
            apply_custom_words("XML parser", &custom_words, 0.18),
            "XMLParser"
        );
        // Lower-case speech reaches the same entry by sound alone.
        assert_eq!(
            apply_custom_words("sequel alchemy", &custom_words, 0.18),
            "SQLAlchemy"
        );
        // A genuine shout — every letter in the span — still wins.
        assert_eq!(
            apply_custom_words("SQL ALCHEMY", &custom_words, 0.18),
            "SQLALCHEMY"
        );
    }

    /// Vowel-dropped brand spellings sit far apart in edit distance while
    /// sounding identical: "quickserve" and "kwksrv" share KKSRF but are 6
    /// edits apart (ratio 0.600), which scores 0.180 at the ordinary phonetic
    /// weight and just misses a 0.18 threshold. Agreement across a code this
    /// long is strong enough to carry the match on its own.
    #[test]
    fn test_apply_custom_words_strong_phonetic_agreement_outweighs_spelling() {
        let custom_words = vec!["KwkSrv".to_string()];

        assert_eq!(
            apply_custom_words("quick serve", &custom_words, 0.18),
            "KwkSrv"
        );
    }

    #[test]
    fn test_is_shouted() {
        assert!(is_shouted(&["BRIGHT", "CORE"]));
        assert!(is_shouted(&["SHOUT"]));
        assert!(is_shouted(&["CHARGE", "B"]));
        // A leading acronym with ordinary words after it is not a shout.
        assert!(!is_shouted(&["SQL", "Alchemy"]));
        assert!(!is_shouted(&["PL", "rating"]));
        assert!(!is_shouted(&["quiet"]));
        // A single letter carries no case signal.
        assert!(!is_shouted(&["A"]));
    }

    /// Corpus check that custom-word correction leaves ordinary English alone.
    ///
    /// Custom-word matching is a trade: a matcher loose enough to reach the
    /// word you wanted will sometimes rewrite a word you did not. This
    /// measures the second half of that trade over a large corpus, so a future
    /// change that buys recall by spending precision is visible rather than
    /// silent.
    ///
    /// Ignored by default because it needs the system word list, which is
    /// present on macOS and on Linux via the `words` / `wamerican` package.
    /// Run it with:
    ///
    /// ```text
    /// cargo test --lib false_positive_sweep -- --ignored --nocapture
    /// ```
    ///
    /// The ceilings sit between what Double Metaphone produces and what the
    /// Soundex implementation this replaced produced (149 unigram / 97 bigram
    /// on the same inputs), so a regression to that behaviour fails the test.
    #[test]
    #[ignore = "requires the system word list at /usr/share/dict/words"]
    fn false_positive_sweep() {
        const WORD_LIST: &str = "/usr/share/dict/words";

        let Ok(raw) = std::fs::read_to_string(WORD_LIST) else {
            eprintln!("skipping sweep: {WORD_LIST} not available");
            return;
        };

        // A representative mix: intercapped brands, an acronym-led term, a
        // vowel-dropped name, a short common word and an ampersand entry.
        let custom_words: Vec<String> = [
            "ChargeBee",
            "SQLAlchemy",
            "OpenAI",
            "FlitePath",
            "HiTek",
            "ThruPut",
            "KwkSrv",
            "NiteLite",
            "dict",
            "R&D",
        ]
        .iter()
        .map(|word| word.to_string())
        .collect();

        let words: Vec<String> = raw
            .lines()
            .filter(|word| word.len() >= 3)
            .map(str::to_lowercase)
            .collect();

        let unigram_hits = words
            .iter()
            .filter(|word| apply_custom_words(word, &custom_words, 0.18) != **word)
            .count();

        // Consecutive dictionary pairs rather than hand-picked leading words,
        // so the sample is not selected around a known collision.
        let mut bigram_hits = 0;
        let mut bigrams = 0;
        for pair in words.windows(2).step_by(3) {
            let phrase = format!("{} {}", pair[0], pair[1]);
            bigrams += 1;
            if apply_custom_words(&phrase, &custom_words, 0.18) != phrase {
                bigram_hits += 1;
            }
        }

        println!(
            "corpus {} words: {unigram_hits} unigram, {bigram_hits} bigram (of {bigrams}) spurious corrections",
            words.len()
        );

        assert!(
            unigram_hits < 120,
            "unigram false positives regressed: {unigram_hits}"
        );
        assert!(
            bigram_hits < 70,
            "bigram false positives regressed: {bigram_hits}"
        );
    }

    #[test]
    fn test_apply_custom_words_skips_cjk_fuzzy_matching() {
        let text = "你好。";
        let custom_words = vec!["你号".to_string()];
        let result = apply_custom_words(text, &custom_words, 1.0);
        assert_eq!(result, text);
    }

    fn words(list: &[&str]) -> Vec<String> {
        list.iter().map(|word| word.to_string()).collect()
    }

    #[test]
    fn test_romanize() {
        assert_eq!(romanize("опенроутер"), "openrouter");
        assert_eq!(romanize("джира"), "jira");
        assert_eq!(romanize("гитхаб"), "githab");
        assert_eq!(romanize("щука"), "schuka");
        assert_eq!(romanize("скетч"), "sketch");
        assert_eq!(romanize("подъезд"), "podezd");
        assert_eq!(romanize("кс2"), "ks2");
    }

    #[test]
    fn test_russian_speech_matches_latin_entries() {
        let custom_words = words(&[
            "OpenRouter",
            "GitHub",
            "Claude Code",
            "Supabase",
            "Docker",
            "Microsoft",
            "Google",
        ]);
        let cases = [
            (
                "подключи опен роутер сегодня",
                "подключи OpenRouter сегодня",
            ),
            ("залей на гитхаб.", "залей на GitHub."),
            ("запусти клод код", "запусти Claude Code"),
            ("база в супабейс", "база в Supabase"),
            ("собери в докер", "собери в Docker"),
            ("Майкрософт выпустил", "Microsoft выпустил"),
            ("найди в гугл", "найди в Google"),
        ];
        for (text, expected) in cases {
            assert_eq!(apply_custom_words(text, &custom_words, 0.18), expected);
        }
    }

    #[test]
    fn test_russian_text_without_terms_is_untouched() {
        let custom_words = words(&["OpenRouter", "GitHub", "Claude", "Docker", "СНиП"]);
        let text = "мы сегодня обсудили смету по объекту, график работ и кладку стен";
        assert_eq!(apply_custom_words(text, &custom_words, 0.18), text);

        let custom_words = words(&["Docker", "Vercel"]);
        let text = "дочери выросли, он выразил и вырезал";
        assert_eq!(apply_custom_words(text, &custom_words, 0.18), text);
    }

    #[test]
    fn test_russian_entry_fixes_case_and_spelling() {
        let custom_words = words(&["СНиП", "Одинцов", "ППР"]);
        assert_eq!(
            apply_custom_words("по снип и ппр", &custom_words, 0.18),
            "по СНиП и ППР"
        );
        assert_eq!(
            apply_custom_words("адинцов сказал", &custom_words, 0.18),
            "Одинцов сказал"
        );
    }

    #[test]
    fn test_latin_spelling_matches_russian_entries() {
        let custom_words = words(&["СНиП", "ГОСТ", "хоткей"]);
        assert_eq!(
            apply_custom_words("по snip и gost", &custom_words, 0.18),
            "по СНиП и ГОСТ"
        );
        assert_eq!(
            apply_custom_words("нажми hotkey", &custom_words, 0.18),
            "нажми хоткей"
        );
    }

    #[test]
    fn test_english_text_is_not_rewritten_into_russian_entries() {
        let custom_words = words(&["СНиП", "ГОСТ", "Одинцов"]);
        let text = "the ghost snippet is good";
        assert_eq!(apply_custom_words(text, &custom_words, 0.18), text);
    }

    #[test]
    fn test_russian_entry_keeps_case_ending() {
        let custom_words = words(&["СНиП", "Одинцов", "ППР"]);
        assert_eq!(
            apply_custom_words("согласно снипа,", &custom_words, 0.18),
            "согласно СНиПа,"
        );
        assert_eq!(
            apply_custom_words("позвони Одинцову", &custom_words, 0.18),
            "позвони Одинцову"
        );
        // Too short to tell an ending from a different word.
        assert_eq!(apply_custom_words("ппрх", &custom_words, 0.18), "ппрх");
        // An n-gram must not read the next word as an ending.
        assert_eq!(
            apply_custom_words("снип а также", &custom_words, 0.18),
            "СНиП а также"
        );
    }

    #[test]
    fn test_spoken_form_entries() {
        let custom_words = words(&["клод, клауд = Claude", "эл эм студио = LM Studio"]);
        assert_eq!(
            apply_custom_words("спроси клода", &custom_words, 0.18),
            "спроси Claude"
        );
        assert_eq!(
            apply_custom_words("Клауд ответил", &custom_words, 0.18),
            "Claude ответил"
        );
        assert_eq!(
            apply_custom_words("открой эл эм студио", &custom_words, 0.18),
            "открой LM Studio"
        );
    }

    #[test]
    fn test_custom_word_terms_and_aliases() {
        let custom_words = words(&["клод = Claude", "Claude", "GitHub", "= ", "ппр=ППР"]);
        assert_eq!(
            custom_word_terms(&custom_words),
            words(&["Claude", "GitHub", "=", "ППР"])
        );
        assert_eq!(
            custom_word_aliases(&custom_words),
            words(&["клод = Claude", "ппр=ППР"])
        );
    }

    #[test]
    fn test_filter_russian_fillers() {
        let result = filter_transcription_output("Э, мы начали эм работу", "ru", &None);
        assert_eq!(result, "Мы начали работу");
        // "мм" is the millimetre unit, not a filler.
        let result = filter_transcription_output("арматура 12 мм", "ru", &None);
        assert_eq!(result, "арматура 12 мм");
    }

    /// Corpus check that custom-word correction leaves ordinary Russian alone.
    ///
    /// Russian speech reaches Latin entries through romanization, which makes
    /// every Russian word a candidate for an English term. This measures how
    /// many frequent word forms get rewritten. Needs a word list, one form per
    /// line (a trailing frequency column is ignored), for example the 50k
    /// list from github.com/hermitdave/FrequencyWords:
    ///
    /// ```text
    /// HANDY_RU_WORDS=ru_50k.txt cargo test --lib russian_false_positive_sweep -- --ignored --nocapture
    /// ```
    #[test]
    #[ignore = "requires a Russian word list in HANDY_RU_WORDS"]
    fn russian_false_positive_sweep() {
        let Ok(path) = std::env::var("HANDY_RU_WORDS") else {
            eprintln!("skipping sweep: HANDY_RU_WORDS not set");
            return;
        };
        let raw = std::fs::read_to_string(&path).expect("word list readable");

        let custom_words = words(&[
            "OpenRouter",
            "GitHub",
            "Claude Code",
            "Supabase",
            "Docker",
            "Telegram",
            "Vercel",
            "Microsoft",
            "Google",
            "Excel",
            "СНиП",
            "Одинцов",
            "ППР",
        ]);

        let forms: Vec<&str> = raw
            .lines()
            .filter_map(|line| line.split_whitespace().next())
            .filter(|form| form.chars().count() >= 3)
            .collect();

        let mut hits = Vec::new();
        for form in &forms {
            let result = apply_custom_words(form, &custom_words, 0.18);
            if result != *form {
                hits.push(format!("{form} -> {result}"));
            }
        }
        // Adjacent pairs exercise the n-gram path ("клод код").
        let unigram_hits = hits.len();
        for pair in forms.windows(2) {
            let text = pair.join(" ");
            let result = apply_custom_words(&text, &custom_words, 0.18);
            if result != text {
                hits.push(format!("{text} -> {result}"));
            }
        }

        println!(
            "{} forms: {unigram_hits} unigram, {} bigram rewritten:",
            forms.len(),
            hits.len() - unigram_hits
        );
        for hit in &hits {
            println!("  {hit}");
        }
    }
}
