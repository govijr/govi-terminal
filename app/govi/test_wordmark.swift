import AppKit
import CoreText

@main struct WordmarkChecks {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        let resources = URL(fileURLWithPath: "govi/Govi")
        guard let font = GoviSignatureFont(url: resources.appendingPathComponent("Fonts/\(GoviSignatureFont.fileName)")) else {
            preconditionFailure("The bundled Givi Signature font must load")
        }
        check(CTFontCopyPostScriptName(font.font) as String == "GiviSignature-Medium", "Use the supplied font exactly")
        check(
            GoviSignatureFont(url: resources.appendingPathComponent("Fonts/Geist-Regular.ttf")) == nil,
            "Never substitute a system or other bundled font")
        check(GoviSignatureFont(url: resources.appendingPathComponent("Fonts/missing.ttf")) == nil, "Handle missing font resources")
        check(
            FileManager.default.fileExists(atPath: resources.appendingPathComponent("Licenses/GiviSignature-OFL.txt").path),
            "Ship the font's license")

        var disabled = GoviLaunchGate()
        check(!disabled.claim(enabled: false), "Disabled launch must go straight to the workspace")
        check(!disabled.claim(enabled: true), "Enabling playback later must wait for the next app launch")
        var enabled = GoviLaunchGate()
        check(enabled.claim(enabled: true), "Show the first launch animation")
        check(!enabled.claim(enabled: true), "Opening more workspaces must not replay it")
        var relaunched = GoviLaunchGate()
        check(relaunched.claim(enabled: true), "A new app launch can play again")

        check(GoviLaunchPreferences.normalized("") == "Govi", "Empty text restores the original signature")
        check(GoviLaunchPreferences.normalized(" \n\t ") == "Govi", "Whitespace-only text restores the original signature")
        check(GoviLaunchPreferences.normalized("  MY\n  NAME  ") == "MY NAME", "Normalize the wordmark onto one line")
        check(GoviLaunchPreferences.normalized(String(repeating: "W", count: 100)).count == 40, "Bound long preferences")
        let emoji = "👩🏽‍💻"
        check(
            GoviLaunchPreferences.normalized(String(repeating: emoji, count: 41)) == String(repeating: emoji, count: 40),
            "The length limit must preserve complete characters")

        for code in 32...126 {
            let character = String(UnicodeScalar(code)!)
            check(font.unsupportedCharacters(in: character).isEmpty, "The supplied font covers printable ASCII: \(character)")
        }
        for text in ["👋🏽", "RADHA 👩🏽‍💻", "你好"] {
            check(!font.unsupportedCharacters(in: text).isEmpty, "Detect characters absent from the supplied font")
            check(GoviSignatureOutline(text: text, font: font) == nil, "Do not render absent characters in a fallback typeface")
        }
        check(font.unsupportedCharacters(in: "👋👋") == ["👋"], "Do not repeat unsupported characters in validation")

        let texts = [
            "Govi", "GOVI", "RADHA", "Radha", "Alex-42", "MY WORKSPACE", "A", "!?", "0123456789", String(repeating: "W", count: 40),
        ]
        let frames = [CGRect(x: 0, y: 0, width: 620, height: 140), CGRect(x: 12, y: 7, width: 160, height: 60)]
        for text in texts {
            guard let outline = GoviSignatureOutline(text: text, font: font) else { preconditionFailure("Missing wordmark for \(text)") }
            check(!outline.path.isEmpty, "Empty letter outlines for \(text)")
            for frame in frames {
                let bounds = outline.fittedPath(in: frame).boundingBoxOfPath
                check(bounds.width.isFinite && bounds.height.isFinite && !bounds.isEmpty, "Invalid geometry for \(text)")
                check(frame.insetBy(dx: -0.01, dy: -0.01).contains(bounds), "Wordmark overflows the preview")
                check(abs(bounds.midX - frame.midX) < 0.01 && abs(bounds.midY - frame.midY) < 0.01, "Keep the wordmark centered")
                check(outline.revealWidth(in: frame).isFinite && outline.revealWidth(in: frame) >= 1, "Keep the pen reveal visible")
            }
            check(outline.fittedPath(in: .zero).isEmpty && outline.revealWidth(in: .zero) == 0, "Handle zero-sized views")
        }
        print("\(checks) signature wordmark checks passed.")
    }
}
