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

/// Consume the first workspace even with playback off. Enabling playback later
/// applies on the next app launch, rather than when another workspace opens.
struct GoviLaunchGate {
    private var claimed = false

    mutating func claim(enabled: Bool) -> Bool {
        guard !claimed else { return false }
        claimed = true
        return enabled
    }
}

/// Load the supplied font from its file, without looking up an installed font
/// by family name or allowing a system typeface to replace missing characters.
struct GoviSignatureFont {
    static let fileName = "GiviSignature-Medium.ttf"
    static let postScriptName = "GiviSignature-Medium"
    let font: CTFont

    init?(url: URL) {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
            let descriptor = descriptors.first
        else { return nil }
        let font = CTFontCreateWithFontDescriptor(descriptor, 160, nil)
        guard CTFontCopyPostScriptName(font) as String == Self.postScriptName else { return nil }
        self.font = font
    }

    func unsupportedCharacters(in text: String) -> [String] {
        var missing: [String] = []
        for character in text {
            let value = String(character)
            var characters = Array(value.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            let supported = CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
            if (!supported || glyphs.contains(0)) && !missing.contains(value) { missing.append(value) }
        }
        return missing
    }
}

struct GoviSignatureOutline {
    let path: CGPath
    private let penWidth: CGFloat

    init?(text: String, font signature: GoviSignatureFont) {
        let text = GoviLaunchPreferences.normalized(text)
        guard signature.unsupportedCharacters(in: text).isEmpty else { return nil }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: signature.font]))
        let combined = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = attributes[kCTFontAttributeName] as! CTFont
            guard CTFontCopyPostScriptName(font) as String == GoviSignatureFont.postScriptName else { return nil }
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for i in 0..<count {
                if let outline = CTFontCreatePathForGlyph(font, glyphs[i], nil) {
                    combined.addPath(outline, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
                }
            }
        }
        guard !combined.isEmpty else { return nil }
        path = combined
        penWidth = CTFontGetSize(signature.font) * 0.15
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

    func revealWidth(in rect: CGRect) -> CGFloat {
        let bounds = path.boundingBoxOfPath
        guard !bounds.isEmpty, !rect.isEmpty else { return 0 }
        return max(1, penWidth * min(rect.width / bounds.width, rect.height / bounds.height))
    }
}
