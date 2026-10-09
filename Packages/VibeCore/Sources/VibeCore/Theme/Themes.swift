import Foundation

/// Built-in color schemes.
public enum Themes {
    public static let vibeNight = Theme(id: "vibe-night", name: "Vibe Night", dark: true, Palette(
        background: "#16171D", foreground: "#D5D8E0", selection: "#33395A", cursor: "#8C9EFF",
        lineHighlight: "#FFFFFF0B", gutter: "#4A4F63", gutterActive: "#B4BBD6", accent: "#8C9EFF",
        comment: "#6B7089", keyword: "#C49BFF", type: "#6CD4FF", function: "#82AAFF", string: "#A8E07A",
        number: "#FFB86B", constant: "#FF9D7A", variable: "#7FE0D0", property: "#FF8CA8", operator: "#89DDFF",
        punctuation: "#9AA3BF", tag: "#FF7A93", attribute: "#FFD580", meta: "#FFD580", escape: "#89DDFF",
        regex: "#7FE0D0", heading: "#82AAFF", link: "#6CD4FF", code: "#A8E07A", quote: "#9AA3BF",
        strong: "#FFB86B", markup: "#5C6380", inserted: "#9FE07A", deleted: "#FF6E86", changed: "#FFC66B",
        invalid: "#FF5370", italicComments: true))

    public static let vibeDay = Theme(id: "vibe-day", name: "Vibe Day", dark: false, Palette(
        background: "#FBFBFC", foreground: "#2A2E37", selection: "#D3E2FF", cursor: "#5856D6",
        lineHighlight: "#0000000A", gutter: "#AEB3BF", gutterActive: "#4B5160", accent: "#5856D6",
        comment: "#8E95A3", keyword: "#9B3FD0", type: "#0E7C9A", function: "#2F64D6", string: "#2F8A2E",
        number: "#C25E00", constant: "#B24F12", variable: "#0E8A7A", property: "#C93A5B", operator: "#0F86A8",
        punctuation: "#6B7280", tag: "#C93A5B", attribute: "#A35E00", meta: "#A35E00", escape: "#0F86A8",
        regex: "#0E8A6E", heading: "#2F64D6", link: "#1F6FD1", code: "#2F8A2E", quote: "#6B7280",
        strong: "#C25E00", markup: "#A6ABB8", inserted: "#2E8B3E", deleted: "#D1344D", changed: "#B7791F",
        invalid: "#E0244A", italicComments: true))

    public static let mariana = Theme(id: "mariana", name: "Mariana", dark: true, Palette(
        background: "#303841", foreground: "#D8DEE9", selection: "#4E5A65", cursor: "#F9AE58",
        lineHighlight: "#FFFFFF0A", gutter: "#6B7682", gutterActive: "#D8DEE9", accent: "#6699CC",
        comment: "#A6ACB9", keyword: "#C695C6", type: "#FAC761", function: "#6699CC", string: "#99C794",
        number: "#F9AE58", constant: "#F97B58", variable: "#5FB4B4", property: "#EC5F66", operator: "#F97B58",
        punctuation: "#A6ACB9", tag: "#EC5F66", attribute: "#C695C6", meta: "#5FB4B4", escape: "#5FB4B4",
        regex: "#5FB4B4", heading: "#6699CC", link: "#6699CC", code: "#99C794", quote: "#A6ACB9",
        strong: "#F9AE58", markup: "#65737E", inserted: "#99C794", deleted: "#EC5F66", changed: "#F9AE58",
        invalid: "#EC5F66"))

    public static let monokai = Theme(id: "monokai", name: "Monokai", dark: true, Palette(
        background: "#272822", foreground: "#F8F8F2", selection: "#49483E", cursor: "#F8F8F0",
        lineHighlight: "#3E3D3299", gutter: "#90908A", gutterActive: "#F8F8F2", accent: "#A6E22E",
        comment: "#75715E", keyword: "#F92672", type: "#66D9EF", function: "#A6E22E", string: "#E6DB74",
        number: "#AE81FF", constant: "#AE81FF", variable: "#FD971F", property: "#66D9EF", operator: "#F92672",
        punctuation: "#F8F8F2", tag: "#F92672", attribute: "#A6E22E", meta: "#66D9EF", escape: "#AE81FF",
        regex: "#E6DB74", heading: "#A6E22E", link: "#66D9EF", code: "#E6DB74", quote: "#CFCFC2",
        strong: "#FD971F", markup: "#75715E", inserted: "#A6E22E", deleted: "#F92672", changed: "#E6DB74",
        invalid: "#F92672", italicTypes: true))

    public static let dracula = Theme(id: "dracula", name: "Dracula", dark: true, Palette(
        background: "#282A36", foreground: "#F8F8F2", selection: "#44475A", cursor: "#F8F8F2",
        lineHighlight: "#FFFFFF0A", gutter: "#6272A4", gutterActive: "#F8F8F2", accent: "#BD93F9",
        comment: "#6272A4", keyword: "#FF79C6", type: "#8BE9FD", function: "#50FA7B", string: "#F1FA8C",
        number: "#BD93F9", constant: "#BD93F9", variable: "#FFB86C", property: "#8BE9FD", operator: "#FF79C6",
        punctuation: "#F8F8F2", tag: "#FF79C6", attribute: "#50FA7B", meta: "#FFB86C", escape: "#FF79C6",
        regex: "#FF5555", heading: "#BD93F9", link: "#8BE9FD", code: "#50FA7B", quote: "#F1FA8C",
        strong: "#FFB86C", markup: "#6272A4", inserted: "#50FA7B", deleted: "#FF5555", changed: "#FFB86C",
        invalid: "#FF5555", italicTypes: true))

    public static let oneDark = Theme(id: "one-dark", name: "One Dark", dark: true, Palette(
        background: "#282C34", foreground: "#ABB2BF", selection: "#3E4451", cursor: "#528BFF",
        lineHighlight: "#2C313C", gutter: "#4B5263", gutterActive: "#ABB2BF", accent: "#61AFEF",
        comment: "#5C6370", keyword: "#C678DD", type: "#E5C07B", function: "#61AFEF", string: "#98C379",
        number: "#D19A66", constant: "#D19A66", variable: "#56B6C2", property: "#E06C75", operator: "#56B6C2",
        punctuation: "#ABB2BF", tag: "#E06C75", attribute: "#D19A66", meta: "#56B6C2", escape: "#56B6C2",
        regex: "#56B6C2", heading: "#E06C75", link: "#61AFEF", code: "#98C379", quote: "#7F848E",
        strong: "#D19A66", markup: "#5C6370", inserted: "#98C379", deleted: "#E06C75", changed: "#D19A66",
        invalid: "#E06C75", italicComments: true))

    public static let oneLight = Theme(id: "one-light", name: "One Light", dark: false, Palette(
        background: "#FAFAFA", foreground: "#383A42", selection: "#DCE3F5", cursor: "#526FFF",
        lineHighlight: "#0000000A", gutter: "#9D9D9F", gutterActive: "#383A42", accent: "#4078F2",
        comment: "#A0A1A7", keyword: "#A626A4", type: "#C18401", function: "#4078F2", string: "#50A14F",
        number: "#986801", constant: "#986801", variable: "#0184BC", property: "#E45649", operator: "#0184BC",
        punctuation: "#383A42", tag: "#E45649", attribute: "#986801", meta: "#0184BC", escape: "#0184BC",
        regex: "#0184BC", heading: "#E45649", link: "#4078F2", code: "#50A14F", quote: "#A0A1A7",
        strong: "#986801", markup: "#A0A1A7", inserted: "#50A14F", deleted: "#E45649", changed: "#986801",
        invalid: "#CA1243", italicComments: true))

    public static let githubLight = Theme(id: "github-light", name: "GitHub Light", dark: false, Palette(
        background: "#FFFFFF", foreground: "#1F2328", selection: "#CCE5FF", cursor: "#0969DA",
        lineHighlight: "#F6F8FA", gutter: "#8C959F", gutterActive: "#1F2328", accent: "#0969DA",
        comment: "#6E7781", keyword: "#CF222E", type: "#953800", function: "#8250DF", string: "#0A3069",
        number: "#0550AE", constant: "#0550AE", variable: "#953800", property: "#0550AE", operator: "#CF222E",
        punctuation: "#1F2328", tag: "#116329", attribute: "#0550AE", meta: "#8250DF", escape: "#116329",
        regex: "#116329", heading: "#0550AE", link: "#0969DA", code: "#0A3069", quote: "#57606A",
        strong: "#1F2328", markup: "#8C959F", inserted: "#116329", deleted: "#82071E", changed: "#953800",
        invalid: "#82071E"))

    public static let githubDark = Theme(id: "github-dark", name: "GitHub Dark", dark: true, Palette(
        background: "#0D1117", foreground: "#E6EDF3", selection: "#1F3A5F", cursor: "#2F81F7",
        lineHighlight: "#161B22", gutter: "#6E7681", gutterActive: "#E6EDF3", accent: "#2F81F7",
        comment: "#8B949E", keyword: "#FF7B72", type: "#FFA657", function: "#D2A8FF", string: "#A5D6FF",
        number: "#79C0FF", constant: "#79C0FF", variable: "#FFA657", property: "#79C0FF", operator: "#FF7B72",
        punctuation: "#E6EDF3", tag: "#7EE787", attribute: "#79C0FF", meta: "#D2A8FF", escape: "#79C0FF",
        regex: "#7EE787", heading: "#79C0FF", link: "#58A6FF", code: "#A5D6FF", quote: "#8B949E",
        strong: "#E6EDF3", markup: "#6E7681", inserted: "#3FB950", deleted: "#F85149", changed: "#FFA657",
        invalid: "#F85149"))

    public static let solarizedDark = Theme(id: "solarized-dark", name: "Solarized Dark", dark: true, Palette(
        background: "#002B36", foreground: "#93A1A1", selection: "#0A4A5A", cursor: "#93A1A1",
        lineHighlight: "#073642", gutter: "#586E75", gutterActive: "#93A1A1", accent: "#268BD2",
        comment: "#586E75", keyword: "#859900", type: "#B58900", function: "#268BD2", string: "#2AA198",
        number: "#D33682", constant: "#D33682", variable: "#CB4B16", property: "#268BD2", operator: "#859900",
        punctuation: "#839496", tag: "#268BD2", attribute: "#B58900", meta: "#CB4B16", escape: "#DC322F",
        regex: "#DC322F", heading: "#CB4B16", link: "#268BD2", code: "#2AA198", quote: "#657B83",
        strong: "#CB4B16", markup: "#586E75", inserted: "#859900", deleted: "#DC322F", changed: "#B58900",
        invalid: "#DC322F", italicComments: true))

    public static let solarizedLight = Theme(id: "solarized-light", name: "Solarized Light", dark: false, Palette(
        background: "#FDF6E3", foreground: "#586E75", selection: "#EEE8D5", cursor: "#586E75",
        lineHighlight: "#EEE8D5", gutter: "#93A1A1", gutterActive: "#586E75", accent: "#268BD2",
        comment: "#93A1A1", keyword: "#859900", type: "#B58900", function: "#268BD2", string: "#2AA198",
        number: "#D33682", constant: "#D33682", variable: "#CB4B16", property: "#268BD2", operator: "#859900",
        punctuation: "#657B83", tag: "#268BD2", attribute: "#B58900", meta: "#CB4B16", escape: "#DC322F",
        regex: "#DC322F", heading: "#CB4B16", link: "#268BD2", code: "#2AA198", quote: "#839496",
        strong: "#CB4B16", markup: "#93A1A1", inserted: "#859900", deleted: "#DC322F", changed: "#B58900",
        invalid: "#DC322F", italicComments: true))

    public static let nord = Theme(id: "nord", name: "Nord", dark: true, Palette(
        background: "#2E3440", foreground: "#D8DEE9", selection: "#434C5E", cursor: "#D8DEE9",
        lineHighlight: "#3B4252", gutter: "#4C566A", gutterActive: "#D8DEE9", accent: "#88C0D0",
        comment: "#616E88", keyword: "#81A1C1", type: "#8FBCBB", function: "#88C0D0", string: "#A3BE8C",
        number: "#B48EAD", constant: "#B48EAD", variable: "#EBCB8B", property: "#8FBCBB", operator: "#81A1C1",
        punctuation: "#ECEFF4", tag: "#81A1C1", attribute: "#8FBCBB", meta: "#5E81AC", escape: "#EBCB8B",
        regex: "#EBCB8B", heading: "#88C0D0", link: "#88C0D0", code: "#A3BE8C", quote: "#7B88A1",
        strong: "#D08770", markup: "#4C566A", inserted: "#A3BE8C", deleted: "#BF616A", changed: "#EBCB8B",
        invalid: "#BF616A", italicComments: true))

    public static let catppuccinMocha = Theme(id: "catppuccin-mocha", name: "Catppuccin Mocha", dark: true, Palette(
        background: "#1E1E2E", foreground: "#CDD6F4", selection: "#45475A", cursor: "#F5E0DC",
        lineHighlight: "#FFFFFF08", gutter: "#6C7086", gutterActive: "#B4BEFE", accent: "#CBA6F7",
        comment: "#7F849C", keyword: "#CBA6F7", type: "#F9E2AF", function: "#89B4FA", string: "#A6E3A1",
        number: "#FAB387", constant: "#FAB387", variable: "#F5C2E7", property: "#B4BEFE", operator: "#89DCEB",
        punctuation: "#9399B2", tag: "#89B4FA", attribute: "#F9E2AF", meta: "#F5C2E7", escape: "#F5C2E7",
        regex: "#F5C2E7", heading: "#89B4FA", link: "#89B4FA", code: "#A6E3A1", quote: "#9399B2",
        strong: "#FAB387", markup: "#6C7086", inserted: "#A6E3A1", deleted: "#F38BA8", changed: "#F9E2AF",
        invalid: "#F38BA8", italicComments: true))

    public static let catppuccinLatte = Theme(id: "catppuccin-latte", name: "Catppuccin Latte", dark: false, Palette(
        background: "#EFF1F5", foreground: "#4C4F69", selection: "#CCD0DA", cursor: "#DC8A78",
        lineHighlight: "#0000000A", gutter: "#8C8FA1", gutterActive: "#4C4F69", accent: "#8839EF",
        comment: "#9CA0B0", keyword: "#8839EF", type: "#DF8E1D", function: "#1E66F5", string: "#40A02B",
        number: "#FE640B", constant: "#FE640B", variable: "#EA76CB", property: "#7287FD", operator: "#04A5E5",
        punctuation: "#7C7F93", tag: "#1E66F5", attribute: "#DF8E1D", meta: "#EA76CB", escape: "#EA76CB",
        regex: "#EA76CB", heading: "#D20F39", link: "#1E66F5", code: "#40A02B", quote: "#7C7F93",
        strong: "#FE640B", markup: "#9CA0B0", inserted: "#40A02B", deleted: "#D20F39", changed: "#DF8E1D",
        invalid: "#D20F39", italicComments: true))

    public static let all: [Theme] = [
        vibeNight, vibeDay, mariana, monokai, dracula, oneDark, oneLight, githubLight, githubDark,
        solarizedDark, solarizedLight, nord, catppuccinMocha, catppuccinLatte,
    ]

    public static var dark: [Theme] { all.filter(\.isDark) }
    public static var light: [Theme] { all.filter { !$0.isDark } }

    public static func theme(id: String) -> Theme? { all.first { $0.id == id } }
}
