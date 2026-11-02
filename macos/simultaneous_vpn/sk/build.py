#!/usr/bin/env python3
"""Copy OpenConnect and relocate its libraries before privileged installation."""
import argparse
import base64
import os
from pathlib import Path
import re
import shutil
import subprocess

here = Path(__file__).resolve().parent
build = here.parent / 'build' / 'sk'
runtime = build / 'runtime'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--openconnect', type=Path, help='Override the Homebrew OpenConnect path')
args = parser.parse_args()
if os.geteuid() == 0:
    parser.error('Build as your normal user.')
config = here / 'openconnect.conf'
if not config.is_file():
    parser.error('Copy sk/openconnect.conf.example to sk/openconnect.conf and edit it first.')
text = config.read_text()
accounts = re.findall(r'^user=([A-Za-z0-9_.@-]+)$', text, re.M)
pins = re.findall(r'^servercert=pin-sha256:([A-Za-z0-9+/=]+)$', text, re.M)
try:
    valid_pins = bool(pins) and all(len(base64.b64decode(pin, validate=True)) == 32 for pin in pins)
except ValueError:
    valid_pins = False
if len(accounts) != 1 or accounts[0] == 'YOUR_LOGIN' or not valid_pins:
    parser.error('Set one user=LOGIN and a valid servercert=pin-sha256:... in sk/openconnect.conf.')
if re.search(r'^\s*(?:passwd|password)\s*=', text, re.M):
    parser.error('Keep the password in Keychain, not in openconnect.conf.')


def run(*args):
    return subprocess.check_output(args, text=True)


def dependencies(path):
    return [line.strip().split(' (compatibility version', 1)[0]
            for line in run('/usr/bin/otool', '-L', str(path)).splitlines()[1:]]


candidates = [args.openconnect] if args.openconnect else [Path('/opt/homebrew/bin/openconnect'), Path('/usr/local/bin/openconnect')]
binary = next((p.resolve() for p in candidates if p.is_file()), None)
if binary is None:
    raise SystemExit('Install OpenConnect with Homebrew first.')
if build.exists():
    shutil.rmtree(build)
runtime.mkdir(parents=True)
prefixes = ('/opt/homebrew/', '/usr/local/')
pending = [binary]
sources = set()
while pending:
    source = pending.pop()
    if source in sources:
        continue
    sources.add(source)
    for library in dependencies(source):
        if library.startswith(prefixes):
            pending.append(Path(library).resolve())
        elif not library.startswith(('/usr/lib/', '/System/Library/')):
            raise SystemExit(f'Unsupported dependency: {library}')
def runtime_name(path):
    return 'openconnect' if path == binary else path.name


if len({runtime_name(p) for p in sources}) != len(sources):
    raise SystemExit('Library filename collision.')

for source in sorted(sources):
    shutil.copyfile(source, runtime / runtime_name(source))
    (runtime / runtime_name(source)).chmod(0o755)
for source in sorted(sources):
    target = runtime / runtime_name(source)
    changes = []
    for library in dependencies(source):
        if library.startswith(prefixes) and Path(library).resolve() != source:
            changes += ['-change', library, '@loader_path/' + Path(library).resolve().name]
    if source.suffix == '.dylib':
        changes += ['-id', '@loader_path/' + source.name]
    for rpath in re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset',
                            run('/usr/bin/otool', '-l', str(source))):
        changes += ['-delete_rpath', rpath]
    if changes:
        run('/usr/bin/install_name_tool', *changes, str(target))
    run('/usr/bin/codesign', '--force', '--sign', '-', str(target))
    run('/usr/bin/codesign', '--verify', '--strict', str(target))
    for library in dependencies(target):
        if library.startswith('@loader_path/'):
            if not (runtime / library.removeprefix('@loader_path/')).is_file():
                raise SystemExit(f'Missing library: {library}')
        elif not library.startswith(('/usr/lib/', '/System/Library/')):
            raise SystemExit(f'Unprotected dependency: {library}')

hook = runtime / 'vpnc-script'
if hook.exists():
    hook.unlink()
run('python3', str(here / 'prepare-vpnc.py'), '--output', str(hook))
(runtime / 'gnutls.conf').write_text('# Bundled GnuTLS defaults; fixed certificate pin.\n')
shutil.copyfile(config, build / 'openconnect.conf')
run('/usr/bin/clang', '-Wall', '-Wextra', '-Werror', '-O2',
    str(here / 'connect.c'), '-o', str(build / 'connect'))
run('/usr/bin/codesign', '--force', '--sign', '-', str(build / 'connect'))
run('/usr/bin/codesign', '--verify', '--strict', str(build / 'connect'))
print(run(str(runtime / 'openconnect'), '--version').splitlines()[0])
print(f'Prepared OpenConnect and {len(sources) - 1} libraries in {build}.')
