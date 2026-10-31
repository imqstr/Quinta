#!/usr/bin/env python3
"""Run the experimental Intel macOS Studio build through CiderDarling."""
import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
PROJECT = ROOT.parents[1]
sys.path.insert(0, str(PROJECT / 'launcher'))
from quinta import core
from quinta.dns import DnsForwarder


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, default=ROOT / 'RobloxStudio.app')
    args = parser.parse_args()
    app = args.bundle.resolve() / 'Contents/MacOS'
    if not (app / 'RobloxStudio').is_file():
        parser.error('Intel macOS Studio bundle is missing; provide --bundle /path/to/RobloxStudio.app')
    if core.roblox_pids():
        parser.error('Close the running Player before testing Studio in the same Darling prefix')
    if not core.SHIM.is_file():
        parser.error('Build the Quinta shim with bash scripts/build-native.sh first')
    subprocess.run(['bash', str(ROOT / 'build.sh')], check=True)
    settings = core.load_settings()
    settings.update(display_backend='x11', diagnostic_signals=True)
    session = core.RobloxSession(settings)
    session.dns = DnsForwarder('quad9')
    environment = session.environment()
    core.ensure_x11(environment)
    script = '''cd "$1" || exit 1
compat=$2; shim=$3; shift 3
for kv in "$@"; do export "$kv"; done
export DYLD_FORCE_FLAT_NAMESPACE=1
export DYLD_INSERT_LIBRARIES="$compat:$shim/libQuintaShims.dylib"
export DYLD_LIBRARY_PATH="$shim"
exec ./RobloxStudio
'''
    try:
        with (ROOT / 'launch.log').open('w') as log:
            print(f'Studio startup log: {ROOT / "launch.log"}', flush=True)
            process = subprocess.run([
                core.DARLING_EXECUTABLE, 'shell', '/bin/bash', '-c', script, 'quinta-studio',
                '/Volumes/SystemRoot' + str(app),
                '/Volumes/SystemRoot' + str(ROOT / 'libStudioCompat.dylib'),
                '/Volumes/SystemRoot' + str(core.SHIM_DIR), *session.shim_variables()
            ], env=environment, stdout=log, stderr=subprocess.STDOUT)
            return process.returncode
    finally:
        session.dns.stop()


if __name__ == '__main__':
    sys.exit(main())
