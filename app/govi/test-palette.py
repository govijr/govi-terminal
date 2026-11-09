#!/usr/bin/env python3
"""Compile and exercise the production Swift palette math against bundled themes."""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parent.parent
source = (root / 'macos/Sources/Features/Terminal/GoviAppearance.swift').read_text()
math = source.split('// BEGIN CHROME MATH')[1].split('// END CHROME MATH')[0]
cases = [(0xffffff, 0x222222), (0x121212, 0xeeeeee), (0xf0d9ee, 0xaca0ac),
         (0xff00ff, 0x00ff00), (0x777777, 0x787878), (0x0000ff, 0x000099)]
for path in (root / 'dist/Govi.app/Contents/Resources/ghostty/themes').iterdir():
    colors = {}
    for line in path.read_text().splitlines():
        pair = line.split('=', 1)
        if len(pair) == 2 and pair[0].strip() in ('background', 'foreground'):
            try: colors[pair[0].strip()] = int(pair[1].strip().lstrip('#'), 16)
            except ValueError: pass
    if len(colors) == 2: cases.append((colors['background'], colors['foreground']))
checks = '''
var count = 0
for (background, foreground) in cases {
    for mode in ["follow", "light", "dark"] {
        for increased in [false, true] {
            let p = GoviChromePalette(background: background, text: foreground, mode: mode, increased: increased)
            for surface in [p.canvas, p.surface, p.hover, p.selection] {
                for text in [p.foreground, p.secondary] {
                    precondition(GoviChromePalette.contrast(text, surface) >= (increased ? 7 : 4.5), "Contrast failed: \\(background), \\(mode), \\(increased)")
                    count += 1
                }
            }
            if mode == "light" { precondition(!p.dark) }
            if mode == "dark" { precondition(p.dark) }
        }
    }
}
print("Passed \\(count) contrast checks across \\(cases.count) palettes, three appearance modes and both contrast settings.")
'''
out = root / '.build/palette-tests'
out.mkdir(parents=True, exist_ok=True)
swift = out / 'main.swift'
swift.write_text('import Foundation\n' + math + '\nlet cases: [(UInt32, UInt32)] = [' + ','.join(f'({a},{b})' for a,b in cases) + ']\n' + checks)
subprocess.run(['swiftc', '-module-cache-path', str(out/'modules'), str(swift), '-o', str(out/'check')], check=True)
subprocess.run([str(out/'check')], check=True)
