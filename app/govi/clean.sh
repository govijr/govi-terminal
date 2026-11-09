#!/bin/zsh
# Remove generated project files. The source and finished app are always kept.
set -euo pipefail
cd "${0:A:h}/.."
python3 - "$PWD" "$@" <<'PY'
import json, shutil, subprocess, sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
args = sys.argv[2:]
if args not in ([], ['--deep']):
    raise SystemExit('Usage: ./govi/clean.sh [--deep]')
deep = bool(args)
# A running build or app can still need resources from its bundle. Skip it.
try:
    commands = subprocess.check_output(['ps', '-A', '-o', 'comm='], text=True).splitlines()
except (OSError, subprocess.CalledProcessError):
    raise SystemExit('Could not inspect running builds; no files were removed.')
active = [line.strip() for line in commands if line.strip().startswith(str(root) + '/')]
if any(Path(command).name in {'zig', 'build', 'clang', 'clang++', 'swiftc', 'swift-frontend'} for command in active):
    raise SystemExit('A Govi build is running. Finish it before clearing generated files.')

def size():
    return int(subprocess.check_output(['du', '-sk', str(root)], text=True).split()[0]) * 1024

before = size()
removed, skipped = [], []

def remove(path):
    if not path.exists() and not path.is_symlink():
        return
    if path == root or root not in path.parents or path == root / 'dist':
        raise SystemExit(f'Refusing to remove {path}')
    if any(command == str(path) or command.startswith(str(path) + '/') for command in active):
        skipped.append(str(path.relative_to(root)))
        return
    if path.is_symlink() or path.is_file():
        path.unlink()
    else:
        shutil.rmtree(path)
    removed.append(str(path.relative_to(root)))

for item in ['.zig-cache', 'zig-out', 'macos/build', 'macos/GhosttyKit.xcframework']:
    remove(root / item)
build = root / '.build'
if build.exists():
    for child in list(build.iterdir()):
        if child.name == 'zig-cache' and not deep:
            for cache in list(child.iterdir()):
                if cache.name != 'p':
                    remove(cache)
        elif child.is_dir() or child.is_symlink():
            remove(child)
if deep:
    remove(root / '.tools')
else:
    for archive in (root / '.tools').glob('*.tar.xz'):
        remove(archive)

build.mkdir(exist_ok=True)
after = size()
report = {'bytes_before': before, 'bytes_after': after, 'removed': removed, 'kept_running': skipped, 'deep': deep}
(build / 'last-cleanup.json').write_text(json.dumps(report, indent=2) + '\n')
print(f'Reclaimed {(before - after) / 1024**3:.2f} GB. Kept dist/Govi.app and all source files.')
if deep:
    print('The next build will download its compiler and dependencies again.')
if skipped:
    print('Kept artifacts used by a running process: ' + ', '.join(skipped))
PY
