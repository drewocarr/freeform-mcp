#!/usr/bin/env python3
"""Create a separate Freeform research copy; never launch it or change the original."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile

SOURCE = Path('/System/Applications/Freeform.app')
ROOT = Path(__file__).resolve().parent
LAB = ROOT / 'lab'


def copy_without_metadata(source: Path, destination: Path) -> None:
    """Copy file contents/modes and relative symlinks, without source xattrs/flags."""
    destination.mkdir(mode=0o755)
    for entry in os.scandir(source):
        src = Path(entry.path)
        dst = destination / entry.name
        if entry.is_symlink():
            target = os.readlink(src)
            # Nested bundle links must remain inside the copied application.
            resolved = src.resolve()
            if os.path.isabs(target) or not resolved.is_relative_to(SOURCE.resolve()):
                raise RuntimeError(f'Refusing external source symlink: {src}')
            dst.symlink_to(target)
        elif entry.is_dir(follow_symlinks=False):
            copy_without_metadata(src, dst)
        elif entry.is_file(follow_symlinks=False):
            shutil.copyfile(src, dst, follow_symlinks=False)
            dst.chmod(stat.S_IMODE(src.stat().st_mode) | stat.S_IWUSR)
        else:
            raise RuntimeError(f'Unexpected source entry: {src}')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--name', default='FreeformLab.app',
                        help='New application basename inside inprocess/lab (must not exist)')
    parser.add_argument('--dry-run', action='store_true', help='Show preparation steps without writing')
    args = parser.parse_args()
    if Path(args.name).name != args.name or not args.name.endswith('.app'):
        parser.error('--name must be a single application basename ending in .app')
    if not SOURCE.is_dir():
        parser.error(f'Installed source is missing: {SOURCE}')
    if LAB.is_symlink() or LAB.resolve() != ROOT / 'lab':
        parser.error('Lab directory must be a real directory within this research folder')
    destination = LAB / args.name
    if destination.exists() or destination.is_symlink():
        parser.error(f'Refusing existing destination: {destination}')
    print(f'Source (read-only): {SOURCE}')
    print(f'Destination: {destination}')
    print('Copy content without extended attributes; set local.freeform.bridge.lab identity;')
    print('remove URL/activity registrations; ad-hoc sign main bundle with empty entitlements and options=0.')
    print('This prepares files only. Use the controlled sandbox launcher for experiments.')
    if args.dry_run:
        return
    LAB.mkdir(parents=True, exist_ok=True)
    # An incomplete copy is retained on error; the next run will refuse it for review.
    copy_without_metadata(SOURCE, destination)
    info = destination / 'Contents/Info.plist'
    data = plistlib.loads(info.read_bytes())
    data.update(CFBundleIdentifier='local.freeform.bridge.lab',
                CFBundleName='Freeform Bridge Lab',
                CFBundleDisplayName='Freeform Bridge Lab')
    data.pop('CFBundleURLTypes', None)
    data.pop('NSUserActivityTypes', None)
    info.write_bytes(plistlib.dumps(data))
    with tempfile.NamedTemporaryFile(dir=LAB, suffix='.plist') as entitlements:
        entitlements.write(plistlib.dumps({}))
        entitlements.flush()
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--options', '0',
                        '--timestamp=none', '--identifier', 'local.freeform.bridge.lab',
                        '--entitlements', entitlements.name, str(destination)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(destination)], check=True)
    subprocess.run(['/usr/bin/codesign', '-dvv', '--entitlements', ':-', str(destination)], check=True)
    print('Prepared and signature-verified. No app was launched.')


if __name__ == '__main__':
    main()
