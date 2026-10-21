//! Rule-based conversion of spoken Russian cardinal numbers to digits.
//!
//! A number is rewritten only when it is followed by a known unit word or its
//! value is at least 10, so small numbers in ordinary speech ("один из",
//! "в два раза", "три дня") stay words. Ordinals are never touched.

/// One recognised number word, classified by its role in a number.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum NumTok {
    Zero,
    Unit(u64),
    Teen(u64),
    Tens(u64),
    Hundreds(u64),
    /// `bare_ok`: the form may stand alone as 1 x scale ("тысяча", "миллион").
    Scale {
        value: u64,
        bare_ok: bool,
    },
}

/// Normalised (lowercase, ё -> е) word forms of every number word, all cases.
/// Bare-capable scale forms come before the plural ones so they win the lookup.
const NUMBER_FORMS: &[(&[&str], NumTok)] = &[
    (&["ноль", "нуль", "ноля", "нуля"], NumTok::Zero),
    (
        &[
            "один",
            "одна",
            "одно",
            "одну",
            "одного",
            "одной",
            "одному",
            "одним",
            "одном",
        ],
        NumTok::Unit(1),
    ),
    (&["два", "две", "двух", "двум", "двумя"], NumTok::Unit(2)),
    (&["три", "трех", "трем", "тремя"], NumTok::Unit(3)),
    (
        &["четыре", "четырех", "четырем", "четырьмя"],
        NumTok::Unit(4),
    ),
    (&["пять", "пяти", "пятью"], NumTok::Unit(5)),
    (&["шесть", "шести", "шестью"], NumTok::Unit(6)),
    // "семью" is deliberately absent: it is mostly the noun "family".
    (&["семь", "семи"], NumTok::Unit(7)),
    (&["восемь", "восьми", "восемью", "восьмью"], NumTok::Unit(8)),
    (&["девять", "девяти", "девятью"], NumTok::Unit(9)),
    (&["десять", "десяти", "десятью"], NumTok::Teen(10)),
    (
        &["одиннадцать", "одиннадцати", "одиннадцатью"],
        NumTok::Teen(11),
    ),
    (
        &["двенадцать", "двенадцати", "двенадцатью"],
        NumTok::Teen(12),
    ),
    (
        &["тринадцать", "тринадцати", "тринадцатью"],
        NumTok::Teen(13),
    ),
    (
        &["четырнадцать", "четырнадцати", "четырнадцатью"],
        NumTok::Teen(14),
    ),
    (
        &["пятнадцать", "пятнадцати", "пятнадцатью"],
        NumTok::Teen(15),
    ),
    (
        &["шестнадцать", "шестнадцати", "шестнадцатью"],
        NumTok::Teen(16),
    ),
    (
        &["семнадцать", "семнадцати", "семнадцатью"],
        NumTok::Teen(17),
    ),
    (
        &["восемнадцать", "восемнадцати", "восемнадцатью"],
        NumTok::Teen(18),
    ),
    (
        &["девятнадцать", "девятнадцати", "девятнадцатью"],
        NumTok::Teen(19),
    ),
    (&["двадцать", "двадцати", "двадцатью"], NumTok::Tens(20)),
    (&["тридцать", "тридцати", "тридцатью"], NumTok::Tens(30)),
    (&["сорок", "сорока"], NumTok::Tens(40)),
    (
        &["пятьдесят", "пятидесяти", "пятьюдесятью"],
        NumTok::Tens(50),
    ),
    (
        &["шестьдесят", "шестидесяти", "шестьюдесятью"],
        NumTok::Tens(60),
    ),
    (
        &["семьдесят", "семидесяти", "семьюдесятью"],
        NumTok::Tens(70),
    ),
    (
        &["восемьдесят", "восьмидесяти", "восемьюдесятью"],
        NumTok::Tens(80),
    ),
    (&["девяносто", "девяноста"], NumTok::Tens(90)),
    (
        &["сто", "ста", "стам", "стами", "стах"],
        NumTok::Hundreds(100),
    ),
    (
        &["двести", "двухсот", "двумстам", "двумястами", "двухстах"],
        NumTok::Hundreds(200),
    ),
    (
        &["триста", "трехсот", "тремстам", "тремястами", "трехстах"],
        NumTok::Hundreds(300),
    ),
    (
        &[
            "четыреста",
            "четырехсот",
            "четыремстам",
            "четырьмястами",
            "четырехстах",
        ],
        NumTok::Hundreds(400),
    ),
    (
        &["пятьсот", "пятисот", "пятистам", "пятьюстами", "пятистах"],
        NumTok::Hundreds(500),
    ),
    (
        &[
            "шестьсот",
            "шестисот",
            "шестистам",
            "шестьюстами",
            "шестистах",
        ],
        NumTok::Hundreds(600),
    ),
    (
        &["семьсот", "семисот", "семистам", "семьюстами", "семистах"],
        NumTok::Hundreds(700),
    ),
    (
        &[
            "восемьсот",
            "восьмисот",
            "восьмистам",
            "восемьюстами",
            "восьмистах",
        ],
        NumTok::Hundreds(800),
    ),
    (
        &[
            "девятьсот",
            "девятисот",
            "девятистам",
            "девятьюстами",
            "девятистах",
        ],
        NumTok::Hundreds(900),
    ),
    (
        &["тысяча", "тысячу"],
        NumTok::Scale {
            value: 1_000,
            bare_ok: true,
        },
    ),
    (
        &[
            "тысячи",
            "тысяче",
            "тысячей",
            "тысячью",
            "тысяч",
            "тысячам",
            "тысячами",
            "тысячах",
        ],
        NumTok::Scale {
            value: 1_000,
            bare_ok: false,
        },
    ),
    (
        &["миллион"],
        NumTok::Scale {
            value: 1_000_000,
            bare_ok: true,
        },
    ),
    (
        &[
            "миллиона",
            "миллиону",
            "миллионом",
            "миллионе",
            "миллионы",
            "миллионов",
            "миллионам",
            "миллионами",
            "миллионах",
        ],
        NumTok::Scale {
            value: 1_000_000,
            bare_ok: false,
        },
    ),
];

const MASC: &[&str] = &["", "а", "у", "ом", "е", "ы", "ов", "ам", "ами", "ах"];
const MASC_SOFT: &[&str] = &["ь", "я", "ей", "ю", "ем", "е", "и", "ям", "ями", "ях"];
const FEM_A: &[&str] = &["а", "ы", "и", "е", "у", "ой", "", "ам", "ами", "ах"];

struct UnitDef {
    stem: &'static str,
    endings: &'static [&'static str],
    abbr: &'static str,
    /// Written right after the number without a space ("20°").
    attach: bool,
}

const UNITS: &[UnitDef] = &[
    UnitDef {
        stem: "миллиметр",
        endings: MASC,
        abbr: "мм",
        attach: false,
    },
    UnitDef {
        stem: "сантиметр",
        endings: MASC,
        abbr: "см",
        attach: false,
    },
    UnitDef {
        stem: "метр",
        endings: MASC,
        abbr: "м",
        attach: false,
    },
    UnitDef {
        stem: "километр",
        endings: MASC,
        abbr: "км",
        attach: false,
    },
    UnitDef {
        stem: "килограмм",
        endings: MASC,
        abbr: "кг",
        attach: false,
    },
    UnitDef {
        stem: "грамм",
        endings: MASC,
        abbr: "г",
        attach: false,
    },
    UnitDef {
        stem: "тонн",
        endings: FEM_A,
        abbr: "т",
        attach: false,
    },
    UnitDef {
        stem: "процент",
        endings: MASC,
        abbr: "%",
        attach: false,
    },
    UnitDef {
        stem: "градус",
        endings: MASC,
        abbr: "°",
        attach: true,
    },
    UnitDef {
        stem: "рубл",
        endings: MASC_SOFT,
        abbr: "₽",
        attach: false,
    },
    UnitDef {
        stem: "штук",
        endings: FEM_A,
        abbr: "шт.",
        attach: false,
    },
    UnitDef {
        stem: "мегапаскал",
        endings: MASC_SOFT,
        abbr: "МПа",
        attach: false,
    },
    UnitDef {
        stem: "килоньютон",
        endings: MASC,
        abbr: "кН",
        attach: false,
    },
];

/// Lowercase and fold ё to е so lookups ignore both case and the ё spelling.
fn fold(word: &str) -> String {
    word.to_lowercase().replace('ё', "е")
}

fn classify(word: &str) -> Option<NumTok> {
    let folded = fold(word);
    NUMBER_FORMS
        .iter()
        .find(|(forms, _)| forms.contains(&folded.as_str()))
        .map(|(_, tok)| *tok)
}

/// Parses one group of up to three digits (hundreds, tens/teens, units).
fn parse_group(toks: &[NumTok]) -> (u64, usize) {
    let mut value = 0;
    let mut len = 0;
    if let Some(NumTok::Hundreds(h)) = toks.get(len) {
        value += h;
        len += 1;
    }
    match toks.get(len) {
        Some(NumTok::Teen(t)) => {
            value += t;
            len += 1;
        }
        Some(NumTok::Tens(t)) => {
            value += t;
            len += 1;
            if let Some(NumTok::Unit(u)) = toks.get(len) {
                value += u;
                len += 1;
            }
        }
        Some(NumTok::Unit(u)) => {
            value += u;
            len += 1;
        }
        _ => {}
    }
    (value, len)
}

/// Parses the longest valid number at the start of `toks`.
/// Returns the value and the count of consumed tokens.
fn parse_number(toks: &[NumTok]) -> Option<(u64, usize)> {
    if matches!(toks.first(), Some(NumTok::Zero)) {
        return Some((0, 1));
    }
    let mut total = 0;
    let mut pos = 0;
    let mut last_scale = u64::MAX;
    let mut parsed = false;
    loop {
        let (group, len) = parse_group(&toks[pos..]);
        if len > 0 {
            parsed = true;
            match toks.get(pos + len) {
                Some(NumTok::Scale { value, .. }) if *value < last_scale => {
                    total += group * value;
                    last_scale = *value;
                    pos += len + 1;
                }
                _ => {
                    total += group;
                    pos += len;
                    break;
                }
            }
        } else if let Some(NumTok::Scale {
            value,
            bare_ok: true,
        }) = toks.get(pos)
        {
            if *value >= last_scale {
                break;
            }
            parsed = true;
            total += value;
            last_scale = *value;
            pos += 1;
        } else {
            break;
        }
    }
    parsed.then_some((total, pos))
}

/// Splits text into alternating non-word / word pieces. A word is a run of
/// letters; a hyphen between two letters stays inside the word.
fn split_pieces(text: &str) -> Vec<(bool, &str)> {
    let chars: Vec<(usize, char)> = text.char_indices().collect();
    let is_word_char = |i: usize| -> bool {
        let c = chars[i].1;
        c.is_alphabetic()
            || (c == '-'
                && i > 0
                && i + 1 < chars.len()
                && chars[i - 1].1.is_alphabetic()
                && chars[i + 1].1.is_alphabetic())
    };
    let mut pieces = Vec::new();
    let mut start = 0;
    while start < chars.len() {
        let word = is_word_char(start);
        let mut end = start + 1;
        while end < chars.len() && is_word_char(end) == word {
            end += 1;
        }
        let from = chars[start].0;
        let to = chars.get(end).map_or(text.len(), |c| c.0);
        pieces.push((word, &text[from..to]));
        start = end;
    }
    pieces
}

/// A separator made only of spaces/tabs (never a newline or punctuation).
fn is_blank_gap(piece: &(bool, &str)) -> bool {
    !piece.0 && !piece.1.is_empty() && piece.1.chars().all(|c| c.is_whitespace() && c != '\n')
}

fn matches_unit_word(word: &str, def: &UnitDef) -> bool {
    word.strip_prefix(def.stem)
        .is_some_and(|rest| def.endings.contains(&rest))
}

/// Recognises a unit starting at piece `at` (which must be a word).
/// Returns the abbreviation, whether it attaches, and the last piece index used.
fn match_unit(pieces: &[(bool, &str)], at: usize) -> Option<(String, bool, usize)> {
    let word = fold(pieces.get(at)?.1);

    // "квадратных метров" -> "м²", "кубических метров" -> "м³"
    let power = if word.starts_with("квадратн") {
        Some("²")
    } else if word.starts_with("кубическ") {
        Some("³")
    } else {
        None
    };
    if let Some(power) = power {
        let gap_ok = pieces.get(at + 1).is_some_and(is_blank_gap);
        let next = pieces.get(at + 2).filter(|p| p.0).map(|p| fold(p.1));
        let metre = UNITS.iter().find(|u| u.stem == "метр")?;
        return match next {
            Some(next) if gap_ok && matches_unit_word(&next, metre) => {
                Some((format!("м{power}"), false, at + 2))
            }
            _ => None,
        };
    }

    UNITS
        .iter()
        .find(|def| matches_unit_word(&word, def))
        .map(|def| (def.abbr.to_string(), def.attach, at))
}

/// Replaces spoken Russian numbers (0..999 999 999) with digits when they are
/// followed by a known unit or are at least 10. Text without number words,
/// including text that already contains digits, is returned unchanged.
pub fn normalize_russian_numbers(text: &str) -> String {
    let pieces = split_pieces(text);
    let mut out = String::with_capacity(text.len());
    let mut i = 0;

    while i < pieces.len() {
        let (is_word, piece) = pieces[i];
        if !is_word || classify(piece).is_none() {
            out.push_str(piece);
            i += 1;
            continue;
        }

        // Collect the run of number words separated by blanks only.
        let mut run: Vec<(usize, NumTok)> = Vec::new();
        let mut j = i;
        while let Some(tok) = classify(pieces[j].1) {
            run.push((j, tok));
            if j + 2 < pieces.len() && is_blank_gap(&pieces[j + 1]) && pieces[j + 2].0 {
                j += 2;
            } else {
                break;
            }
        }
        let toks: Vec<NumTok> = run.iter().map(|(_, t)| *t).collect();

        let mut pos = i;
        let mut k = 0;
        while k < run.len() {
            let parsed = parse_number(&toks[k..]);
            let (value, len) = parsed.unwrap_or((0, 1));
            let first = run[k].0;
            let last = run[k + len - 1].0;

            for (_, text) in &pieces[pos..first] {
                out.push_str(text);
            }

            let unit = (last + 2 < pieces.len() && is_blank_gap(&pieces[last + 1]))
                .then(|| match_unit(&pieces, last + 2))
                .flatten();
            let bare_scale = len == 1 && matches!(toks[k], NumTok::Scale { .. });

            if parsed.is_some() && (unit.is_some() || (value >= 10 && !bare_scale)) {
                out.push_str(&value.to_string());
                pos = last + 1;
                if let Some((abbr, attach, unit_end)) = unit {
                    if !attach {
                        out.push(' ');
                    }
                    out.push_str(&abbr);
                    pos = unit_end + 1;
                    // "шт." followed by a sentence period must not double up.
                    if abbr.ends_with('.') {
                        if let Some((false, gap)) = pieces.get(pos) {
                            if let Some(rest) = gap.strip_prefix('.') {
                                out.push_str(rest);
                                pos += 1;
                            }
                        }
                    }
                }
            } else {
                for (_, text) in &pieces[first..=last] {
                    out.push_str(text);
                }
                pos = last + 1;
            }
            k += len;
        }
        i = pos;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn n(text: &str) -> String {
        normalize_russian_numbers(text)
    }

    #[test]
    fn converts_number_with_unit() {
        assert_eq!(n("двенадцать миллиметров"), "12 мм");
        assert_eq!(n("двадцать пять процентов"), "25 %");
        assert_eq!(n("пять метров"), "5 м");
        assert_eq!(n("три килограмма"), "3 кг");
        assert_eq!(n("один грамм"), "1 г");
        assert_eq!(n("две тонны"), "2 т");
        assert_eq!(n("пять штук"), "5 шт.");
        assert_eq!(n("десять рублей"), "10 ₽");
        assert_eq!(n("один рубль"), "1 ₽");
        assert_eq!(n("тридцать мегапаскалей"), "30 МПа");
        assert_eq!(n("пятнадцать килоньютонов"), "15 кН");
        assert_eq!(n("пять сантиметров"), "5 см");
        assert_eq!(n("три километра"), "3 км");
    }

    #[test]
    fn degree_attaches_without_space() {
        assert_eq!(n("двадцать градусов"), "20°");
        assert_eq!(n("ноль градусов"), "0°");
        assert_eq!(n("при минус пяти градусах"), "при минус 5°");
        assert_eq!(n("при пяти градусах тепла"), "при 5° тепла");
    }

    #[test]
    fn square_and_cubic_metres() {
        assert_eq!(n("пятьдесят квадратных метров"), "50 м²");
        assert_eq!(n("три кубических метра"), "3 м³");
        assert_eq!(n("сто кубических метров бетона"), "100 м³ бетона");
        // Without a metre the adjective alone is not a unit.
        assert_eq!(n("три квадратных корня"), "три квадратных корня");
        assert_eq!(n("двадцать квадратных корней"), "20 квадратных корней");
    }

    #[test]
    fn small_numbers_without_unit_stay_words() {
        assert_eq!(n("один из них"), "один из них");
        assert_eq!(n("в два раза больше"), "в два раза больше");
        assert_eq!(n("три дня"), "три дня");
        assert_eq!(n("пять"), "пять");
        assert_eq!(n("ноль"), "ноль");
        assert_eq!(n("девять человек"), "девять человек");
    }

    #[test]
    fn numbers_from_ten_convert_without_unit() {
        assert_eq!(n("десять человек"), "10 человек");
        assert_eq!(n("пришло двенадцать человек"), "пришло 12 человек");
        assert_eq!(n("сорок два"), "42");
        assert_eq!(n("сто"), "100");
    }

    #[test]
    fn compound_numbers() {
        assert_eq!(n("тысяча двести пятьдесят"), "1250");
        assert_eq!(n("два миллиона триста тысяч"), "2300000");
        assert_eq!(n("две тысячи двадцать пять"), "2025");
        assert_eq!(n("тысяча девятьсот девяносто девять"), "1999");
        assert_eq!(n("сто двадцать три"), "123");
        assert_eq!(
            n("девятьсот девяносто девять тысяч девятьсот девяносто девять"),
            "999999"
        );
        assert_eq!(
            n("девятьсот девяносто девять миллионов девятьсот девяносто девять тысяч девятьсот девяносто девять"),
            "999999999"
        );
        assert_eq!(n("пять миллионов"), "5000000");
        assert_eq!(n("один миллион двести тысяч"), "1200000");
        assert_eq!(n("три тысячи рублей"), "3000 ₽");
        assert_eq!(n("два миллиона рублей"), "2000000 ₽");
    }

    #[test]
    fn oblique_cases() {
        assert_eq!(n("до двенадцати миллиметров"), "до 12 мм");
        assert_eq!(n("с двенадцатью миллиметрами"), "с 12 мм");
        assert_eq!(n("от двадцати до тридцати градусов"), "от 20 до 30°");
        assert_eq!(n("около сорока процентов"), "около 40 %");
        assert_eq!(n("больше ста килограммов"), "больше 100 кг");
        assert_eq!(n("свыше двухсот метров"), "свыше 200 м");
        assert_eq!(n("по двумстам рублям"), "по 200 ₽");
        assert_eq!(n("до трёхсот метров"), "до 300 м");
        assert_eq!(n("свыше тысячи метров"), "свыше тысячи метров");
        assert_eq!(n("пять тысяч метров"), "5000 м");
        assert_eq!(n("нет двух миллионов"), "нет 2000000");
        assert_eq!(n("около пятисот тонн"), "около 500 т");
        assert_eq!(n("на девятьсот девяносто девять тысяч"), "на 999000");
    }

    #[test]
    fn yo_spelling_is_accepted() {
        assert_eq!(n("пять метров"), "5 м");
        assert_eq!(n("трёх метров"), "3 м");
        assert_eq!(n("четырёх килограммов"), "4 кг");
        assert_eq!(n("с рублём"), "с рублём");
        assert_eq!(n("пять рублём"), "5 ₽");
    }

    #[test]
    fn case_insensitive_and_keeps_neighbours() {
        assert_eq!(n("Двенадцать миллиметров."), "12 мм.");
        assert_eq!(n("ДВАДЦАТЬ ПЯТЬ ПРОЦЕНТОВ"), "25 %");
        assert_eq!(
            n("Нужно десять Метров, не больше."),
            "Нужно 10 м, не больше."
        );
        assert_eq!(n("Привет, мир!"), "Привет, мир!");
    }

    #[test]
    fn punctuation_splits_sequences() {
        assert_eq!(n("два, три, пять"), "два, три, пять");
        assert_eq!(n("двадцать, пять метров"), "20, 5 м");
        assert_eq!(n("пять; десять"), "пять; 10");
    }

    #[test]
    fn adjacent_numbers_that_do_not_combine() {
        assert_eq!(n("два три"), "два три");
        assert_eq!(n("пять двадцать"), "пять 20");
        assert_eq!(n("двадцать десять"), "20 10");
        assert_eq!(n("сто двести"), "100 200");
        assert_eq!(n("три метра пять метров"), "3 м 5 м");
    }

    #[test]
    fn ordinals_are_not_converted() {
        assert_eq!(n("второй этаж"), "второй этаж");
        assert_eq!(n("пятого числа"), "пятого числа");
        assert_eq!(n("двадцатого июня"), "двадцатого июня");
        assert_eq!(n("сотый"), "сотый");
        assert_eq!(n("двадцать второй"), "20 второй");
    }

    #[test]
    fn units_do_not_match_lookalikes() {
        assert_eq!(n("пять метро"), "пять метро");
        assert_eq!(n("пять метрик"), "пять метрик");
        assert_eq!(n("пять граммофонов"), "пять граммофонов");
        assert_eq!(n("пять штукатуров"), "пять штукатуров");
        assert_eq!(n("пять процентный"), "пять процентный");
        assert_eq!(n("пять градусников"), "пять градусников");
        assert_eq!(n("пять рублевых"), "пять рублевых");
        assert_eq!(n("десять метрополитенов"), "10 метрополитенов");
    }

    #[test]
    fn metre_stem_is_not_part_of_prefixed_units() {
        assert_eq!(n("пять миллиметров"), "5 мм");
        assert_eq!(n("пять сантиметров"), "5 см");
        assert_eq!(n("пять километров"), "5 км");
        assert_eq!(n("пять метров"), "5 м");
        assert_eq!(n("пять килограммов"), "5 кг");
        assert_eq!(n("пять граммов"), "5 г");
    }

    #[test]
    fn all_unit_case_forms() {
        for form in [
            "метр",
            "метра",
            "метров",
            "метрам",
            "метрами",
            "метрах",
            "метру",
            "метром",
            "метре",
            "метры",
        ] {
            assert_eq!(n(&format!("пять {form}")), "5 м", "{form}");
        }
        for form in [
            "рубль",
            "рубля",
            "рублей",
            "рублю",
            "рублем",
            "рубле",
            "рубли",
            "рублям",
            "рублями",
            "рублях",
        ] {
            assert_eq!(n(&format!("пять {form}")), "5 ₽", "{form}");
        }
        for form in ["процент", "процента", "процентов", "процентам", "процентах"]
        {
            assert_eq!(n(&format!("пять {form}")), "5 %", "{form}");
        }
        for form in ["тонна", "тонны", "тонну", "тонн", "тоннах"] {
            assert_eq!(n(&format!("пять {form}")), "5 т", "{form}");
        }
        for form in ["штука", "штуки", "штуку", "штук", "штуками"] {
            assert_eq!(n(&format!("пять {form}")), "5 шт.", "{form}");
        }
        for form in ["градус", "градуса", "градусов", "градусах"] {
            assert_eq!(n(&format!("пять {form}")), "5°", "{form}");
        }
    }

    #[test]
    fn abbreviation_period_is_not_doubled() {
        assert_eq!(n("Нужно десять штук."), "Нужно 10 шт.");
        assert_eq!(n("десять штук, не больше"), "10 шт., не больше");
        assert_eq!(n("десять штук. Потом"), "10 шт. Потом");
    }

    #[test]
    fn idempotent_on_digits() {
        for text in [
            "12 мм",
            "25 %",
            "20°",
            "В 2025 году было 1250 штук",
            "Привет, мир",
            "",
        ] {
            assert_eq!(n(text), text);
            assert_eq!(n(&n(text)), n(text));
        }
        let once = n("двенадцать миллиметров и тысяча двести пятьдесят рублей");
        assert_eq!(once, "12 мм и 1250 ₽");
        assert_eq!(n(&once), once);
    }

    #[test]
    fn digits_before_unit_words_are_left_alone() {
        assert_eq!(n("12 миллиметров"), "12 миллиметров");
        assert_eq!(n("5 метров"), "5 метров");
    }

    #[test]
    fn bare_scale_words_need_a_unit() {
        assert_eq!(n("тысяча рублей"), "1000 ₽");
        assert_eq!(n("миллион рублей"), "1000000 ₽");
        assert_eq!(n("тысяча"), "тысяча");
        assert_eq!(n("миллион"), "миллион");
        assert_eq!(n("тысячи людей"), "тысячи людей");
        assert_eq!(n("тысячи рублей"), "тысячи рублей");
        assert_eq!(n("тысяча и одна ночь"), "тысяча и одна ночь");
        assert_eq!(n("тысяча двести"), "1200");
    }

    #[test]
    fn multiline_and_spacing_are_preserved() {
        assert_eq!(n("пять метров\nдвадцать килограммов"), "5 м\n20 кг");
        assert_eq!(n("двадцать\nпять"), "20\nпять");
        assert_eq!(n("  двадцать   пять  "), "  25  ");
        assert_eq!(n("(двадцать пять процентов)"), "(25 %)");
        assert_eq!(n("«сто рублей»"), "«100 ₽»");
    }

    #[test]
    fn hyphenated_words_are_untouched() {
        assert_eq!(n("пяти-шести метров"), "пяти-шести метров");
        assert_eq!(n("пять-шесть метров"), "пять-шесть метров");
    }

    #[test]
    fn seven_instrumental_is_not_a_number() {
        assert_eq!(n("создал семью"), "создал семью");
        assert_eq!(n("двадцать семь метров"), "27 м");
    }

    #[test]
    fn mixed_sentence() {
        assert_eq!(
            n("Длина двенадцать метров, ширина шесть метров, высота три с половиной метра."),
            "Длина 12 м, ширина 6 м, высота три с половиной метра."
        );
        assert_eq!(
            n("Бетон В25, двести сорок кубических метров, температура плюс пять градусов."),
            "Бетон В25, 240 м³, температура плюс 5°."
        );
    }

    #[test]
    fn unicode_boundaries_do_not_panic() {
        assert_eq!(n("☃ пять метров ☃"), "☃ 5 м ☃");
        assert_eq!(n("пять"), "пять");
        assert_eq!(n("é"), "é");
    }
}
