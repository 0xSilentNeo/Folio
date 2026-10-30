import Foundation

extension String {
    /// HTML character references decoded: numeric (`&#39;`, `&#x27;`) and the
    /// common named ones (`&amp;`, `&quot;`, `&nbsp;`, `&rsquo;`…). IMDb's
    /// plots and some addons' descriptions carry them (30 Oct screenshot:
    /// "O&#39;Hara", "Alice&#39;s"). Applied once where metadata text enters
    /// the app (IMDbSource, the addon models, the saved metadata), never
    /// while drawing.
    var decodingHTMLEntities: String {
        guard contains("&"), let re = HTMLText.pattern else { return self }
        let ns = self as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let body = ns.substring(with: m.range(at: 1))
            out += HTMLText.character(body) ?? ns.substring(with: m.range)
            last = NSMaxRange(m.range)
        }
        out += ns.substring(from: last)
        return out
    }
}

enum HTMLText {
    fileprivate static let pattern = try? NSRegularExpression(pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,9});")

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "laquo": "«", "raquo": "»", "copy": "©", "reg": "®", "trade": "™", "deg": "°", "middot": "·", "bull": "•",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "aacute": "á", "agrave": "à", "acirc": "â", "iacute": "í", "oacute": "ó",
        "uacute": "ú", "ntilde": "ñ", "ccedil": "ç", "auml": "ä", "ouml": "ö", "uuml": "ü", "szlig": "ß",
    ]

    /// The character a reference's body ("#39", "#x27", "amp") stands for, or nil.
    fileprivate static func character(_ body: String) -> String? {
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            return UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if body.hasPrefix("#") {
            return UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return named[body]
    }
}
