import AppKit

@main struct WordmarkChecks {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        var disabledLaunch = GoviLaunchGate()
        check(!disabledLaunch.claim(enabled: false), "Disabled launch must open directly into the workspace")
        check(!disabledLaunch.claim(enabled: true), "Enabling later must wait until the next app launch")
        var enabledLaunch = GoviLaunchGate()
        check(enabledLaunch.claim(enabled: true), "Enabled launch must show the first workspace's splash")
        check(!enabledLaunch.claim(enabled: true), "Restored and newly opened workspaces must not replay the splash")
        var nextLaunch = GoviLaunchGate()
        check(nextLaunch.claim(enabled: true), "A fresh process can show the animation again")

        check(GoviLaunchPreferences.normalized("") == "Govi", "Empty text must restore the original signature")
        check(GoviLaunchPreferences.normalized(" \n\t ") == "Govi", "Whitespace-only text must restore the original signature")
        check(GoviLaunchPreferences.normalized("  Hello\n  World  ") == "Hello World", "Wordmarks must fit on one line")
        check(GoviLaunchPreferences.normalized(String(repeating: "a", count: 100)).count == 40, "Bound long saved preferences")
        let emoji = "👩🏽‍💻"
        check(
            GoviLaunchPreferences.normalized(String(repeating: emoji, count: 41)) == String(repeating: emoji, count: 40),
            "The limit must preserve complete Unicode characters")

        let texts = [
            "Radha", "Hello World", "A", "Agjpqy", "Élodie", "Cafe\u{301}", "مرحبا", "नमस्ते", "你好", String(repeating: "W", count: 40),
        ]
        let frames = [CGRect(x: 0, y: 0, width: 620, height: 140), CGRect(x: 12, y: 7, width: 160, height: 60)]
        for text in texts {
            let outline = GoviWordmarkOutline(text: text)
            check(!outline.path.isEmpty, "Missing shaped glyphs for \(text)")
            check(!outline.requiresTextFallback, "Text outlines should support \(text)")
            for frame in frames {
                let bounds = outline.fittedPath(in: frame).boundingBoxOfPath
                check(bounds.width.isFinite && bounds.height.isFinite && !bounds.isEmpty, "Invalid wordmark bounds for \(text)")
                check(frame.insetBy(dx: -0.01, dy: -0.01).contains(bounds), "Wordmark overflows its preview: \(text)")
                check(
                    abs(bounds.midX - frame.midX) < 0.01 && abs(bounds.midY - frame.midY) < 0.01,
                    "Wordmark is not centered: \(text)")
            }
            check(outline.fittedPath(in: .zero).isEmpty, "An empty preview must not produce invalid geometry")
        }
        for text in ["👋🏽", "Radha 👩🏽‍💻", "你好 🌱"] {
            check(GoviWordmarkOutline(text: text).requiresTextFallback, "Color emoji must render without losing characters: \(text)")
        }
        print("\(checks) wordmark checks passed.")
    }
}
