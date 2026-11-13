import AppKit
import CoreText

enum GoviLaunchPreferences {
    static let enabledKey = "GoviLaunchAnimation"
    static let textKey = "GoviLaunchWordmarkText"
    static let defaultText = "Govi"
    static let maximumLength = 40

    static var text: String { normalized(UserDefaults.standard.string(forKey: textKey) ?? "") }

    static func normalized(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? defaultText : String(line.prefix(maximumLength))
    }
}

/// Consume the launch once, even when disabled, so enabling it in Settings only
/// takes effect on the next launch rather than when another workspace opens.
struct GoviLaunchGate {
    private var claimed = false

    mutating func claim(enabled: Bool) -> Bool {
        guard !claimed else { return false }
        claimed = true
        return enabled
    }
}

/// Core Text shapes the whole line before extracting outlines, preserving
/// ligatures, combining marks, right-to-left scripts and font fallback.
struct GoviWordmarkOutline {
    static var font: NSFont {
        NSFont(name: "SnellRoundhand-Bold", size: 160) ?? NSFont.systemFont(ofSize: 160, weight: .medium)
    }

    let path: CGPath
    let requiresTextFallback: Bool

    init(text: String) {
        let attributed = NSAttributedString(string: GoviLaunchPreferences.normalized(text), attributes: [.font: Self.font])
        let line = CTLineCreateWithAttributedString(attributed)
        let combined = CGMutablePath()
        var fallback = false
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = attributes[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for i in 0..<count {
                if let glyphPath = CTFontCreatePathForGlyph(font, glyphs[i], nil) {
                    combined.addPath(glyphPath, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
                } else {
                    var glyph = glyphs[i]
                    if !CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, nil, 1).isEmpty { fallback = true }
                }
            }
        }
        path = combined
        // Color emoji have no vector outline. Render the complete text normally
        // in that case, rather than dropping characters from the wordmark.
        requiresTextFallback = fallback || combined.isEmpty
    }

    func fittedPath(in rect: CGRect) -> CGPath {
        let bounds = path.boundingBoxOfPath
        guard !bounds.isEmpty, !rect.isEmpty else { return CGMutablePath() }
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        var transform = CGAffineTransform(
            a: scale, b: 0, c: 0, d: -scale,
            tx: rect.midX - bounds.midX * scale, ty: rect.midY + bounds.midY * scale)
        return path.copy(using: &transform) ?? path
    }
}
