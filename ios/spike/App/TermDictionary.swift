import Foundation

/// Замены терминов после распознавания; применяются ко всем движкам.
enum TermDictionary {
    /// Пары (шаблон, замена). Шаблон — регулярное выражение без учёта регистра;
    /// границы слова (с кириллицей) добавляются автоматически.
    /// Чтобы добавить термин, допишите строку, например:
    /// `("автокад(а|е|у|ом)?", "AutoCAD")` — «автокада» станет «AutoCAD».
    static let replacements: [(pattern: String, replacement: String)] = [
        ("ревит(а|е|у|ом)?", "Revit"),
        ("(рейнг|ренг)(а|е|и|у|ой)?", "Renga"),
    ]

    /// `\b` для кириллицы ненадёжен, поэтому границы заданы через lookaround.
    private static let compiled: [(regex: NSRegularExpression, template: String)] = replacements.compactMap { (item) -> (regex: NSRegularExpression, template: String)? in
        let pattern = "(?<![\\p{L}\\p{N}])(?:\(item.pattern))(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return (regex, NSRegularExpression.escapedTemplate(for: item.replacement))
    }

    static func apply(to text: String) -> String {
        var result = text
        for item in compiled {
            let range = NSRange(result.startIndex..., in: result)
            result = item.regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: item.template)
        }
        return result
    }
}
