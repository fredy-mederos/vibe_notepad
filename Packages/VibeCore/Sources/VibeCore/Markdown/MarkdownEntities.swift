import Foundation

// MARK: - Character references

/// Entity and backslash-escape handling.
///
/// In body text, syntactically valid character references are passed through verbatim (the web view
/// decodes the full HTML5 table). Where text must be decoded (URLs, titles, alt text, heading text),
/// numeric references and the common named references below are decoded; unknown names stay literal.
enum MDText {
    /// End index of a syntactically valid entity / numeric character reference starting at `pos` (`&`).
    static func entityEnd(_ s: [UInt8], _ pos: Int, _ end: Int) -> Int? {
        var i = pos + 1
        guard i < end else { return nil }
        if s[i] == MDByte.hash {
            i += 1
            guard i < end else { return nil }
            if s[i] == 0x78 || s[i] == 0x58 { // x X
                i += 1
                let start = i
                while i < end && MDChar.isHexDigit(s[i]) && i - start < 7 { i += 1 }
                let digits = i - start
                guard digits >= 1 && digits <= 6, i < end, s[i] == MDByte.semicolon else { return nil }
                return i + 1
            }
            let start = i
            while i < end && MDChar.isDigit(s[i]) && i - start < 8 { i += 1 }
            let digits = i - start
            guard digits >= 1 && digits <= 7, i < end, s[i] == MDByte.semicolon else { return nil }
            return i + 1
        }
        guard MDChar.isLetter(s[i]) else { return nil }
        let start = i
        while i < end && MDChar.isAlphanumeric(s[i]) && i - start < 33 { i += 1 }
        let length = i - start
        guard length >= 2 && length <= 32, i < end, s[i] == MDByte.semicolon else { return nil }
        return i + 1
    }

    /// Decodes the reference `s[pos..<end]` (`&...;`). Returns nil for unknown named references.
    static func decodeEntity(_ s: [UInt8], _ pos: Int, _ end: Int) -> [UInt8]? {
        guard end - pos >= 3 else { return nil }
        if s[pos + 1] == MDByte.hash {
            var value: UInt32 = 0
            if s[pos + 2] == 0x78 || s[pos + 2] == 0x58 {
                for k in (pos + 3)..<(end - 1) { value = value &* 16 &+ MDChar.hexValue(s[k]) }
            } else {
                for k in (pos + 2)..<(end - 1) { value = value &* 10 &+ UInt32(s[k] - 0x30) }
            }
            let scalar = (value == 0 ? nil : Unicode.Scalar(value)) ?? "\u{FFFD}"
            return Array(String(Character(scalar)).utf8)
        }
        let name = String(decoding: s[(pos + 1)..<(end - 1)], as: UTF8.self)
        guard let decoded = MDEntities.named[name] else { return nil }
        return Array(decoded.utf8)
    }

    /// Processes backslash escapes and character references in `s[lo..<hi]`.
    static func unescape(_ s: [UInt8], _ lo: Int, _ hi: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(hi - lo)
        var i = lo
        while i < hi {
            let c = s[i]
            if c == MDByte.backslash && i + 1 < hi && MDChar.isPunctuation(s[i + 1]) {
                out.append(s[i + 1])
                i += 2
            } else if c == MDByte.ampersand, let e = entityEnd(s, i, hi), let decoded = decodeEntity(s, i, e) {
                out.append(contentsOf: decoded)
                i = e
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }

    /// Decodes character references only (used for plain text built from already-tokenized nodes).
    static func decodeEntities(_ s: [UInt8], _ lo: Int, _ hi: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(hi - lo)
        var i = lo
        while i < hi {
            if s[i] == MDByte.ampersand, let e = entityEnd(s, i, hi), let decoded = decodeEntity(s, i, e) {
                out.append(contentsOf: decoded)
                i = e
            } else {
                out.append(s[i])
                i += 1
            }
        }
        return out
    }
}

// MARK: - Named entities

/// The most commonly used HTML named character references.
enum MDEntities {
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
        "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›", "bull": "•", "middot": "·",
        "deg": "°", "plusmn": "±", "times": "×", "divide": "÷", "para": "¶", "sect": "§",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "curren": "¤", "dagger": "†", "Dagger": "‡",
        "permil": "‰", "prime": "′", "Prime": "″", "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓",
        "harr": "↔", "lArr": "⇐", "rArr": "⇒", "hArr": "⇔", "le": "≤", "ge": "≥", "ne": "≠",
        "asymp": "≈", "equiv": "≡", "infin": "∞", "minus": "−", "sum": "∑", "prod": "∏", "radic": "√",
        "part": "∂", "nabla": "∇", "isin": "∈", "notin": "∉", "cap": "∩", "cup": "∪", "and": "∧",
        "or": "∨", "forall": "∀", "exist": "∃", "empty": "∅", "frac12": "½", "frac14": "¼",
        "frac34": "¾", "sup1": "¹", "sup2": "²", "sup3": "³", "micro": "µ", "iexcl": "¡",
        "iquest": "¿", "shy": "\u{00AD}", "acute": "´", "cedil": "¸", "uml": "¨", "macr": "¯",
        "ordf": "ª", "ordm": "º", "not": "¬", "brvbar": "¦", "szlig": "ß", "check": "✓", "cross": "✗",
        "hearts": "♥", "spades": "♠", "clubs": "♣", "diams": "♦", "star": "☆", "starf": "★",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}", "zwj": "\u{200D}",
        "lrm": "\u{200E}", "rlm": "\u{200F}",
        "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä", "Aring": "Å", "AElig": "Æ",
        "Ccedil": "Ç", "Egrave": "È", "Eacute": "É", "Ecirc": "Ê", "Euml": "Ë", "Igrave": "Ì", "Iacute": "Í",
        "Icirc": "Î", "Iuml": "Ï", "Ntilde": "Ñ", "Ograve": "Ò", "Oacute": "Ó", "Ocirc": "Ô", "Otilde": "Õ",
        "Ouml": "Ö", "Oslash": "Ø", "Ugrave": "Ù", "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü", "Yacute": "Ý",
        "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã", "auml": "ä", "aring": "å", "aelig": "æ",
        "ccedil": "ç", "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë", "igrave": "ì", "iacute": "í",
        "icirc": "î", "iuml": "ï", "ntilde": "ñ", "ograve": "ò", "oacute": "ó", "ocirc": "ô", "otilde": "õ",
        "ouml": "ö", "oslash": "ø", "ugrave": "ù", "uacute": "ú", "ucirc": "û", "uuml": "ü", "yacute": "ý",
        "yuml": "ÿ", "Alpha": "Α", "Beta": "Β", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω", "alpha": "α", "beta": "β",
        "gamma": "γ", "delta": "δ", "epsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "iota": "ι",
        "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο", "pi": "π",
        "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "chi": "χ", "psi": "ψ",
        "omega": "ω", "Tab": "\t", "NewLine": "\n", "excl": "!", "num": "#", "dollar": "$",
        "percnt": "%", "lpar": "(", "rpar": ")", "ast": "*", "plus": "+", "comma": ",", "period": ".",
        "sol": "/", "colon": ":", "semi": ";", "equals": "=", "quest": "?", "commat": "@", "lsqb": "[",
        "lbrack": "[", "rsqb": "]", "rbrack": "]", "bsol": "\\", "lowbar": "_", "grave": "`", "lcub": "{",
        "lbrace": "{", "rcub": "}", "rbrace": "}", "verbar": "|", "vert": "|", "Hat": "^", "tilde": "˜",
    ]
}
