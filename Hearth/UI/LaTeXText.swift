import Foundation

/// Turns LaTeX math in model replies (\[ … \], \( … \), $$ … $$) into readable plain text:
/// \frac{a}{b} → a/b, \sqrt{n} → √n, n^{2} → n², \times → ×, \leftrightarrow → ↔ …
/// Not a typesetting engine; covers what chat replies commonly use and leaves unknown commands by name.
enum LaTeXText {
    static func plain(_ latex: String) -> String {
        var parser = Parser(Array(latex))
        return parser.parse(until: nil)
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Converts inline \( … \) and \[ … \] spans; leaves the rest of the text alone.
    static func replacingInlineMath(in text: String) -> String {
        guard text.contains("\\(") || text.contains("\\[") else { return text }
        var result = text
        for (open, close) in [("\\(", "\\)"), ("\\[", "\\]")] {
            while let start = result.range(of: open),
                  let end = result.range(of: close, range: start.upperBound..<result.endIndex) {
                let inner = String(result[start.upperBound..<end.lowerBound])
                result.replaceSubrange(start.lowerBound..<end.upperBound, with: plain(inner))
            }
        }
        return result
    }

    // MARK: - Parser

    private struct Parser {
        let chars: [Character]
        var i = 0

        init(_ chars: [Character]) { self.chars = chars }

        /// Reads until `terminator` (or the end of the text)
        mutating func parse(until terminator: Character?) -> String {
            var out = ""
            while i < chars.count {
                let c = chars[i]
                if let terminator, c == terminator { i += 1; return out }
                i += 1
                switch c {
                case "\\": out += command()
                case "{": out += parse(until: "}")
                case "}": break
                case "^": out += script(LaTeXText.superscripts, marker: "^")
                case "_": out += script(LaTeXText.subscripts, marker: "_")
                case "&": out += " "
                case "~": out += " "
                default: out.append(c)
                }
            }
            return out
        }

        /// A {…} group, or a single character/command
        mutating func argument() -> String {
            while i < chars.count, chars[i] == " " { i += 1 }
            guard i < chars.count else { return "" }
            let c = chars[i]
            i += 1
            if c == "{" { return parse(until: "}") }
            if c == "\\" { return command() }
            return String(c)
        }

        mutating func command() -> String {
            guard i < chars.count else { return "" }
            var name = ""
            while i < chars.count, chars[i].isLetter { name.append(chars[i]); i += 1 }
            if name.isEmpty {
                let c = chars[i]
                i += 1
                switch c {
                case " ", ",", ";", ":": return " "
                case "!": return ""
                case "\\": return "\n"
                default: return String(c)   // \{ \} \% \$ \_ \& \#
                }
            }
            switch name {
            case "frac", "dfrac", "tfrac":
                let a = argument(), b = argument()
                return "\(LaTeXText.wrap(a))/\(LaTeXText.wrap(b))"
            case "sqrt":
                var index = ""
                if i < chars.count, chars[i] == "[" { i += 1; index = parse(until: "]") }
                let radicand = LaTeXText.wrap(argument())
                return index.isEmpty ? "√\(radicand)" : "\(LaTeXText.raise(index, marker: "^"))√\(radicand)"
            case "text", "mathrm", "mathbf", "mathit", "mathsf", "mathtt", "textbf", "textit",
                 "operatorname", "boxed", "mbox", "emph":
                return argument()
            case "left", "right", "big", "Big", "bigg", "Bigg", "displaystyle", "limits":
                if i < chars.count, chars[i] == "." { i += 1 }
                return ""
            case "quad", "qquad": return "  "
            case "begin", "end":
                _ = argument()   // environments such as \begin{aligned}
                return ""
            default:
                if let symbol = LaTeXText.symbols[name] { return symbol }
                // Function names (sin, log, max …) and unknown commands stay as written
                return name
            }
        }

        mutating func script(_ map: [Character: Character], marker: String) -> String {
            LaTeXText.raise(argument(), marker: marker, map: map)
        }
    }

    static func raise(_ text: String, marker: String, map: [Character: Character]? = nil) -> String {
        let map = map ?? (marker == "^" ? superscripts : subscripts)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed.allSatisfy({ map[$0] != nil }) {
            return String(trimmed.compactMap { map[$0] })
        }
        return trimmed.count == 1 ? "\(marker)\(trimmed)" : "\(marker)(\(trimmed))"
    }

    /// Wraps in parentheses unless it's a single term: a+b → (a+b)
    static func wrap(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        let simple = t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "," || superscripts.values.contains($0) }
        return simple || (t.hasPrefix("(") && t.hasSuffix(")")) ? t : "(\(t))"
    }

    static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "k": "ᵏ",
    ]

    static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "o": "ₒ", "x": "ₓ",
        "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "n": "ₙ", "m": "ₘ",
    ]

    static let symbols: [String: String] = [
        "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗",
        "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "ne": "≠", "neq": "≠", "approx": "≈",
        "equiv": "≡", "sim": "∼", "propto": "∝", "infty": "∞", "partial": "∂", "nabla": "∇",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔", "implies": "⟹", "iff": "⟺",
        "mapsto": "↦", "sum": "Σ", "prod": "∏", "int": "∫", "in": "∈", "notin": "∉",
        "subset": "⊂", "subseteq": "⊆", "cup": "∪", "cap": "∩", "emptyset": "∅", "forall": "∀",
        "exists": "∃", "neg": "¬", "land": "∧", "lor": "∨", "wedge": "∧", "vee": "∨",
        "ldots": "…", "dots": "…", "cdots": "⋯", "vdots": "⋮", "circ": "∘", "degree": "°",
        "mid": "|", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉", "langle": "⟨", "rangle": "⟩",
        "alpha": "α", "beta": "β", "gamma": "γ", "Gamma": "Γ", "delta": "δ", "Delta": "Δ",
        "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "Theta": "Θ",
        "kappa": "κ", "lambda": "λ", "Lambda": "Λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "Pi": "Π",
        "rho": "ρ", "sigma": "σ", "Sigma": "Σ", "tau": "τ", "phi": "φ", "varphi": "φ", "Phi": "Φ",
        "chi": "χ", "psi": "ψ", "Psi": "Ψ", "omega": "ω", "Omega": "Ω",
    ]
}
