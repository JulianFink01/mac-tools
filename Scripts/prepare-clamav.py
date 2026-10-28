#!/usr/bin/env python3
"""Prepare pinned official universal ClamAV binaries without installing system software."""
import hashlib
import json
import pathlib
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
CACHE = ROOT / 'build/clamav-cache'
DEST = ROOT / 'Vendor/ClamAV'
VERSION = '1.5.4'
ASSETS = {
    f'clamav-{VERSION}.macos.universal.pkg': 'df7fa753e2f9f67f3bc99b2a40a3be7ef559088c68ad6bdf66b4b5764e965bd6',
    f'clamav-{VERSION}.tar.gz': '1af1117a228f1b5bc7fa91a0dabc37848a99e7d25188e9be8043332ce721dfd3',
}
CACHE.mkdir(parents=True, exist_ok=True)
for name, digest in ASSETS.items():
    path = CACHE / name
    if not path.exists():
        url = f'https://github.com/Cisco-Talos/clamav/releases/download/clamav-{VERSION}/{name}'
        subprocess.run(['curl', '-fL', '--retry', '2', url, '-o', str(path)], check=True)
    hasher = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            hasher.update(block)
    if hasher.hexdigest() != digest:
        raise RuntimeError(f'SHA-256 mismatch: {name}')
expanded = CACHE / 'expanded'
if not expanded.exists():
    subprocess.run(['pkgutil', '--expand-full', str(CACHE / f'clamav-{VERSION}.macos.universal.pkg'), str(expanded)], check=True)
DEST.mkdir(parents=True, exist_ok=True)
for part in ('programs', 'libraries'):
    source = expanded / f'clamav-{VERSION}.macos.universal-{part}.pkg/Payload/usr/local/clamav'
    for folder in ('bin', 'lib', 'etc/certs'):
        if (source / folder).exists():
            # copytree cannot replace existing symlinks on repeated local builds.
            for link in (source / folder).rglob('*'):
                target = DEST / folder / link.relative_to(source / folder)
                if link.is_symlink() and target.is_symlink():
                    target.unlink()
            shutil.copytree(source / folder, DEST / folder, symlinks=True, dirs_exist_ok=True)
# Only ship the scan, database update, and verification tools.
for path in (DEST / 'bin').iterdir():
    if path.name not in ('clamscan', 'freshclam', 'sigtool'):
        path.unlink()
for path in list((DEST / 'bin').iterdir()) + list((DEST / 'lib').glob('*.dylib')):
    if path.is_symlink():
        continue
    load = subprocess.check_output(['otool', '-l', str(path)], text=True)
    if '@executable_path/../lib' not in load:
        subprocess.run(['install_name_tool', '-add_rpath', '@executable_path/../lib', str(path)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True)
notices = DEST / 'Licenses'; notices.mkdir(exist_ok=True)
with tarfile.open(CACHE / f'clamav-{VERSION}.tar.gz') as archive:
    for member in archive.getmembers():
        base = pathlib.PurePosixPath(member.name).name
        if member.isfile() and (base.startswith('COPYING') or base.startswith('LICENSE')):
            data = archive.extractfile(member).read()
            safe = member.name.replace('/', '__')
            (notices / safe).write_bytes(data)
shutil.copyfile(CACHE / f'clamav-{VERSION}.tar.gz', DEST / f'clamav-{VERSION}-source.tar.gz')
(DEST / 'provenance.json').write_text(json.dumps({'version': VERSION, 'upstream': 'https://github.com/Cisco-Talos/clamav', 'sha256': ASSETS, 'changes': 'Added relative runtime library search path and local ad-hoc signatures; engine code unchanged.'}, indent=2))
subprocess.run([str(DEST / 'bin/clamscan'), '--version'], check=True)
print(f'Prepared portable ClamAV: {DEST}')
