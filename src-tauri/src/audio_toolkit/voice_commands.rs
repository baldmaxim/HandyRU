//! Rule-based spoken commands for Russian dictation: layout ("новая строка"),
//! punctuation ("точка", "запятая") and editing ("удали последнее слово").
//!
//! Text without any applied command is returned unchanged.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Cmd {
    NewLine,
    Paragraph,
    Punct(&'static str),
    DeleteWord,
    DeleteSentence,
}

struct Phrase {
    words: &'static [&'static str],
    cmd: Cmd,
}

const PHRASES: &[Phrase] = &[
    Phrase {
        words: &["новая", "строка"],
        cmd: Cmd::NewLine,
    },
    Phrase {
        words: &["новый", "абзац"],
        cmd: Cmd::Paragraph,
    },
    Phrase {
        words: &["абзац"],
        cmd: Cmd::Paragraph,
    },
    Phrase {
        words: &["точка", "с", "запятой"],
        cmd: Cmd::Punct(";"),
    },
    Phrase {
        words: &["точка"],
        cmd: Cmd::Punct("."),
    },
    Phrase {
        words: &["запятая"],
        cmd: Cmd::Punct(","),
    },
    Phrase {
        words: &["вопросительный", "знак"],
        cmd: Cmd::Punct("?"),
    },
    Phrase {
        words: &["восклицательный", "знак"],
        cmd: Cmd::Punct("!"),
    },
    Phrase {
        words: &["двоеточие"],
        cmd: Cmd::Punct(":"),
    },
    Phrase {
        words: &["тире"],
        cmd: Cmd::Punct(" —"),
    },
    Phrase {
        words: &["открыть", "скобку"],
        cmd: Cmd::Punct("("),
    },
    Phrase {
        words: &["закрыть", "скобку"],
        cmd: Cmd::Punct(")"),
    },
    Phrase {
        words: &["открыть", "кавычки"],
        cmd: Cmd::Punct("«"),
    },
    Phrase {
        words: &["закрыть", "кавычки"],
        cmd: Cmd::Punct("»"),
    },
    Phrase {
        words: &["удали", "последнее", "слово"],
        cmd: Cmd::DeleteWord,
    },
    Phrase {
        words: &["удали", "последнее", "предложение"],
        cmd: Cmd::DeleteSentence,
    },
    Phrase {
        words: &["удали", "последнее"],
        cmd: Cmd::DeleteSentence,
    },
];

/// One whitespace-delimited token split into model punctuation and the word.
struct Token<'a> {
    /// Whitespace before the token.
    gap: &'a str,
    raw: &'a str,
    /// Punctuation attached before / after the word.
    lead: &'a str,
    trail: &'a str,
    /// Lowercase word with ё folded to е; empty for pure punctuation.
    core: String,
}

fn tokenize(text: &str) -> Vec<Token<'_>> {
    let mut tokens = Vec::new();
    let mut pos = 0;
    while pos < text.len() {
        let rest = &text[pos..];
        let gap_len = rest.len() - rest.trim_start().len();
        let gap = &rest[..gap_len];
        pos += gap_len;
        let rest = &text[pos..];
        if rest.is_empty() {
            break;
        }
        let raw_len = rest.find(char::is_whitespace).unwrap_or(rest.len());
        let raw = &rest[..raw_len];
        pos += raw_len;

        let start = raw.find(char::is_alphanumeric);
        let (lead, word, trail) = match start {
            Some(start) => {
                let end = raw
                    .char_indices()
                    .rev()
                    .find(|(_, c)| c.is_alphanumeric())
                    .map_or(raw.len(), |(i, c)| i + c.len_utf8());
                (&raw[..start], &raw[start..end], &raw[end..])
            }
            None => (raw, "", ""),
        };
        tokens.push(Token {
            gap,
            raw,
            lead,
            trail,
            core: word.to_lowercase().replace('ё', "е"),
        });
    }
    tokens
}

/// Finds the longest command phrase starting at token `at`.
/// Inner words of a phrase must not carry punctuation between them.
fn match_phrase(tokens: &[Token], at: usize) -> Option<(&'static Phrase, usize)> {
    PHRASES
        .iter()
        .filter(|phrase| {
            let len = phrase.words.len();
            at + len <= tokens.len()
                && phrase.words.iter().enumerate().all(|(k, word)| {
                    let token = &tokens[at + k];
                    token.core == *word
                        && (k + 1 == len || token.trail.is_empty())
                        && (k == 0 || token.lead.is_empty())
                })
        })
        .max_by_key(|phrase| phrase.words.len())
        .map(|phrase| (phrase, phrase.words.len()))
}

fn ends_with_open_bracket(out: &str) -> bool {
    out.ends_with('(') || out.ends_with('«')
}

/// Appends a word, separated by a space unless it opens a line or follows an
/// opening bracket/quote.
fn push_word(out: &mut String, raw: &str) {
    let needs_space = out
        .chars()
        .last()
        .is_some_and(|c| !c.is_whitespace() && !ends_with_open_bracket(out));
    if needs_space {
        out.push(' ');
    }
    out.push_str(raw);
}

fn trim_spaces(out: &mut String) {
    let len = out.trim_end_matches([' ', '\t']).len();
    out.truncate(len);
}

fn push_punct(out: &mut String, sym: &str) {
    trim_spaces(out);
    let Some(sym_char) = sym.trim_start().chars().next() else {
        return;
    };
    match sym_char {
        '.' | ',' | ';' | ':' | '!' | '?' => match out.chars().last() {
            Some(last) if last == sym_char => {}
            // A weaker mark is replaced by the spoken one.
            Some('.' | ',' | ';' | ':') => {
                out.pop();
                out.push(sym_char);
            }
            // After "!" / "?" only another "!" / "?" may follow ("?!").
            Some('!' | '?') if !matches!(sym_char, '!' | '?') => {}
            _ => out.push(sym_char),
        },
        '—' => {
            if !out.is_empty() && !out.ends_with(char::is_whitespace) {
                out.push(' ');
            }
            if !out.ends_with('—') {
                out.push('—');
            }
        }
        '(' | '«' => {
            let needs_space = out
                .chars()
                .last()
                .is_some_and(|c| !c.is_whitespace() && !ends_with_open_bracket(out));
            if needs_space {
                out.push(' ');
            }
            out.push(sym_char);
        }
        _ => out.push(sym_char),
    }
}

fn push_layout(out: &mut String, cmd: Cmd) {
    trim_spaces(out);
    match cmd {
        Cmd::NewLine => out.push('\n'),
        _ => {
            let trailing = out.chars().rev().take_while(|c| *c == '\n').count();
            for _ in trailing..2 {
                out.push('\n');
            }
        }
    }
}

fn delete_last_word(out: &mut String) {
    let trimmed = out.trim_end().len();
    out.truncate(trimmed);
    let cut = out
        .rfind(char::is_whitespace)
        .map_or(0, |i| i + out[i..].chars().next().map_or(1, char::len_utf8));
    out.truncate(cut);
}

fn delete_last_sentence(out: &mut String) {
    let trimmed = out.trim_end().len();
    out.truncate(trimmed);
    // The sentence's own terminator does not count as the previous boundary.
    let body_len = out.trim_end_matches(['.', '!', '?']).len();
    match out[..body_len].rfind(['.', '!', '?', '\n']) {
        Some(i) => out.truncate(i + 1),
        None => out.clear(),
    }
}

/// Removes spaces before closing marks and after opening ones, collapses
/// space runs and strips line edges.
fn tidy_spacing(text: &str) -> String {
    text.split('\n')
        .map(|line| {
            let mut result = String::with_capacity(line.len());
            let mut pending_space = false;
            for c in line.chars() {
                if c == ' ' || c == '\t' {
                    pending_space = true;
                    continue;
                }
                let closes = matches!(c, '.' | ',' | ';' | ':' | '!' | '?' | ')' | '»');
                if pending_space
                    && !result.is_empty()
                    && !closes
                    && !ends_with_open_bracket(&result)
                {
                    result.push(' ');
                }
                pending_space = false;
                result.push(c);
            }
            result
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Capitalizes the text start and the first letter after ". ! ?" and newlines.
/// A dotted abbreviation ("т.д.") does not end a sentence.
fn capitalize_sentences(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut result = String::with_capacity(text.len());
    let mut cap = true;
    for (i, &c) in chars.iter().enumerate() {
        if c.is_alphabetic() {
            if cap {
                result.extend(c.to_uppercase());
            } else {
                result.push(c);
            }
            cap = false;
            continue;
        }
        match c {
            '\n' => cap = true,
            '.' | '!' | '?' => {
                let closes_sentence = chars
                    .get(i + 1)
                    .is_none_or(|n| n.is_whitespace() || matches!(n, ')' | '»' | '"'));
                let dotted_abbreviation =
                    c == '.' && i >= 2 && chars[i - 1].is_alphabetic() && chars[i - 2] == '.';
                cap = closes_sentence && !dotted_abbreviation;
            }
            c if c.is_whitespace() || matches!(c, '«' | '(' | '"' | ')' | '»' | '—') => {}
            _ => cap = false,
        }
        result.push(c);
    }
    result
}

/// Applies spoken layout, punctuation and editing commands.
pub fn apply_voice_commands(text: &str) -> String {
    let tokens = tokenize(text);
    let mut out = String::with_capacity(text.len());
    let mut applied = false;
    let mut prev_applied = false;
    let mut i = 0;

    while i < tokens.len() {
        let token = &tokens[i];
        // Newlines already present in the input survive.
        let newlines = token.gap.matches('\n').count();
        if newlines > 0 && !out.is_empty() {
            trim_spaces(&mut out);
            out.push_str(&"\n".repeat(newlines));
        }

        let decision = match_phrase(&tokens, i).and_then(|(phrase, len)| {
            let last = &tokens[i + len - 1];
            let own_punct = !tokens[i].lead.is_empty() || !last.trail.is_empty();
            let next_is_command = match_phrase(&tokens, i + len).is_some();
            let right_boundary = i + len == tokens.len() || own_punct || next_is_command;
            let left_boundary = i == 0
                || prev_applied
                || !tokens[i - 1].trail.is_empty()
                || tokens[i].gap.contains('\n');
            let applies = match (phrase.cmd, phrase.words.len()) {
                // Ambiguous single words need a clear boundary after them.
                (Cmd::Punct(_), 1) => right_boundary,
                // A lone "абзац" must stand on its own.
                (Cmd::Paragraph, 1) => left_boundary && right_boundary,
                _ => true,
            };
            applies.then_some((phrase.cmd, len))
        });

        match decision {
            Some((cmd, len)) => {
                match cmd {
                    Cmd::NewLine | Cmd::Paragraph => push_layout(&mut out, cmd),
                    Cmd::Punct(sym) => push_punct(&mut out, sym),
                    Cmd::DeleteWord => delete_last_word(&mut out),
                    Cmd::DeleteSentence => delete_last_sentence(&mut out),
                }
                applied = true;
                prev_applied = true;
                i += len;
            }
            None => {
                push_word(&mut out, token.raw);
                prev_applied = false;
                i += 1;
            }
        }
    }

    if !applied {
        return text.to_string();
    }
    capitalize_sentences(&tidy_spacing(&out))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(text: &str) -> String {
        apply_voice_commands(text)
    }

    #[test]
    fn text_without_commands_is_unchanged() {
        for text in [
            "",
            "привет мир",
            "Привет, мир!",
            "т.д. и т.п. слово",
            "  пробелы   сохраняются  ",
        ] {
            assert_eq!(v(text), text);
        }
    }

    #[test]
    fn new_line_command() {
        assert_eq!(v("привет новая строка мир"), "Привет\nМир");
        assert_eq!(v("Привет. Новая строка. Мир."), "Привет.\nМир.");
        assert_eq!(v("Новая строка"), "\n");
        assert_eq!(v("Новая строка мир"), "\nМир");
        assert_eq!(v("привет новая строка"), "Привет\n");
        assert_eq!(v("НОВАЯ СТРОКА."), "\n");
    }

    #[test]
    fn paragraph_commands() {
        assert_eq!(v("привет новый абзац мир"), "Привет\n\nМир");
        assert_eq!(v("Привет. Абзац. Мир."), "Привет.\n\nМир.");
        assert_eq!(v("Абзац. Мир"), "\n\nМир");
        assert_eq!(v("Привет. Абзац"), "Привет.\n\n");
        assert_eq!(v("Привет. Новый абзац."), "Привет.\n\n");
    }

    #[test]
    fn standalone_paragraph_needs_boundaries() {
        assert_eq!(v("первый абзац текста"), "первый абзац текста");
        assert_eq!(v("в этом абзаце"), "в этом абзаце");
        assert_eq!(v("закончили абзац дальше"), "закончили абзац дальше");
    }

    #[test]
    fn paragraph_after_newline_adds_only_missing_break() {
        assert_eq!(v("привет новая строка новый абзац мир"), "Привет\n\nМир");
    }

    #[test]
    fn punctuation_at_end_of_text() {
        assert_eq!(v("мы закончили точка"), "Мы закончили.");
        assert_eq!(v("как дела вопросительный знак"), "Как дела?");
        assert_eq!(v("ура восклицательный знак"), "Ура!");
        assert_eq!(v("вот так двоеточие"), "Вот так:");
        assert_eq!(v("раз точка с запятой"), "Раз;");
        assert_eq!(v("раз запятая"), "Раз,");
    }

    #[test]
    fn punctuation_before_another_command() {
        assert_eq!(
            v("мы закончили точка новая строка дальше"),
            "Мы закончили.\nДальше"
        );
        assert_eq!(v("раз запятая новая строка два"), "Раз,\nДва");
        assert_eq!(v("раз точка новый абзац два"), "Раз.\n\nДва");
    }

    #[test]
    fn punctuation_with_model_punctuation_on_the_word() {
        assert_eq!(
            v("Мы закончили. Точка. Новая строка. Дальше."),
            "Мы закончили.\nДальше."
        );
        assert_eq!(v("Привет запятая, как дела"), "Привет, как дела");
        assert_eq!(v("Привет, запятая. Мир"), "Привет, Мир");
        assert_eq!(v("Итак двоеточие. Первое"), "Итак: Первое");
    }

    #[test]
    fn ambiguous_words_without_boundary_stay() {
        assert_eq!(v("точка зрения"), "точка зрения");
        assert_eq!(v("в этой точке"), "в этой точке");
        assert_eq!(v("это точка отсчета"), "это точка отсчета");
        assert_eq!(v("запятая в тексте"), "запятая в тексте");
        assert_eq!(
            v("поставь тире между словами"),
            "поставь тире между словами"
        );
        assert_eq!(v("точка с другой стороны"), "точка с другой стороны");
    }

    #[test]
    fn dash_command() {
        assert_eq!(v("Москва тире."), "Москва —");
        assert_eq!(v("Москва тире новая строка Питер"), "Москва —\nПитер");
        assert_eq!(v("тире."), "—");
    }

    #[test]
    fn brackets_and_quotes() {
        assert_eq!(
            v("смотри открыть скобку рисунок один закрыть скобку дальше"),
            "Смотри (рисунок один) дальше"
        );
        assert_eq!(
            v("он сказал открыть кавычки привет закрыть кавычки точка"),
            "Он сказал «привет»."
        );
        assert_eq!(v("открыть скобку да закрыть скобку"), "(Да)");
    }

    #[test]
    fn tidy_spacing_around_marks() {
        assert_eq!(v("раз запятая, два запятая, три точка"), "Раз, два, три.");
        assert_eq!(v("Привет , мир . новая строка да"), "Привет, мир.\nДа");
        assert_eq!(v("( мир ) новая строка"), "(Мир)\n");
        assert_eq!(v("« мир » новая строка"), "«Мир»\n");
    }

    #[test]
    fn capitalization_after_sentence_ends() {
        assert_eq!(v("раз точка. два точка. три"), "Раз. Два. Три");
        assert_eq!(v("кто там вопросительный знак я"), "Кто там? Я");
        assert_eq!(v("раз новая строка два новая строка три"), "Раз\nДва\nТри");
        assert_eq!(v("раз точка новая строка два"), "Раз.\nДва");
    }

    #[test]
    fn dotted_abbreviations_do_not_capitalize() {
        assert_eq!(v("и т.д. и т.п. новая строка да"), "И т.д. и т.п.\nДа");
        assert_eq!(
            v("сайт example.com новая строка да"),
            "Сайт example.com\nДа"
        );
    }

    #[test]
    fn no_trailing_spaces_on_lines() {
        assert_eq!(v("раз   новая строка   два   новая строка"), "Раз\nДва\n");
        for line in v("раз  запятая  новая строка  два  точка новая строка").split('\n')
        {
            assert_eq!(line, line.trim_end());
        }
    }

    #[test]
    fn duplicate_punctuation_is_collapsed() {
        assert_eq!(v("Конец. Точка."), "Конец.");
        assert_eq!(v("Конец, запятая"), "Конец,");
        assert_eq!(v("Конец. вопросительный знак"), "Конец?");
        assert_eq!(v("Что? Восклицательный знак"), "Что?!");
        assert_eq!(v("Что? точка"), "Что?");
    }

    #[test]
    fn delete_last_word() {
        assert_eq!(v("один два три удали последнее слово"), "Один два");
        assert_eq!(
            v("один два три удали последнее слово четыре"),
            "Один два четыре"
        );
        assert_eq!(v("Привет мир. Удали последнее слово."), "Привет");
        assert_eq!(v("один удали последнее слово"), "");
        assert_eq!(v("удали последнее слово"), "");
        assert_eq!(
            v("один два удали последнее слово удали последнее слово"),
            ""
        );
    }

    #[test]
    fn delete_last_word_across_newline_keeps_the_break() {
        assert_eq!(
            v("один новая строка два удали последнее слово три"),
            "Один\nТри"
        );
    }

    #[test]
    fn delete_last_sentence() {
        assert_eq!(
            v("Первое предложение. Второе тут удали последнее предложение"),
            "Первое предложение."
        );
        assert_eq!(
            v("Первое предложение. Второе. Удали последнее предложение."),
            "Первое предложение."
        );
        assert_eq!(v("Раз два три удали последнее предложение"), "");
        assert_eq!(
            v("Первое! Второе тут удали последнее предложение и дальше"),
            "Первое! И дальше"
        );
        assert_eq!(
            v("Первое? Второе тут удали последнее предложение"),
            "Первое?"
        );
    }

    #[test]
    fn short_delete_form_removes_sentence() {
        assert_eq!(v("Раз. Два три удали последнее"), "Раз.");
        assert_eq!(v("Раз. Два три. Удали последнее."), "Раз.");
        assert_eq!(v("Удали последнее"), "");
    }

    #[test]
    fn delete_sentence_stops_at_newline() {
        assert_eq!(
            v("раз новая строка два три удали последнее предложение"),
            "Раз\n"
        );
    }

    #[test]
    fn delete_word_wins_over_short_form() {
        assert_eq!(v("Раз. Два три удали последнее слово"), "Раз. Два");
    }

    #[test]
    fn commands_are_case_and_yo_insensitive() {
        assert_eq!(v("Раз ТОЧКА"), "Раз.");
        assert_eq!(v("раз Новая Строка два"), "Раз\nДва");
        assert_eq!(v("привет  НОВЫЙ  АБЗАЦ  мир"), "Привет\n\nМир");
    }

    #[test]
    fn existing_newlines_survive() {
        assert_eq!(v("раз\nдва точка"), "Раз\nДва.");
        assert_eq!(v("раз\n\nдва новая строка три"), "Раз\n\nДва\nТри");
    }

    #[test]
    fn phrase_with_punctuation_inside_is_not_a_command() {
        assert_eq!(v("новая, строка"), "новая, строка");
        assert_eq!(v("Новая. Строка"), "Новая. Строка");
    }

    #[test]
    fn unicode_does_not_panic() {
        assert_eq!(v("😀 точка"), "😀.");
        assert_eq!(v("«точка»"), ".");
    }
}
