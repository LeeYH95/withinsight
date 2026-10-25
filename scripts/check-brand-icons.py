#!/usr/bin/env python3
"""Check the built app's modern icon catalog and legacy fallback."""
import json
import plistlib
import subprocess
import sys
from pathlib import Path


def main():
    app = Path(sys.argv[1])
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIconName') != 'ShipianLight':
        raise ValueError('Missing primary compiled icon: ShipianLight')
    resources = app / 'Contents/Resources'
    fallback = resources / (info['CFBundleIconFile'].removesuffix('.icns') + '.icns')
    if not fallback.is_file():
        raise ValueError('Missing ICNS fallback for macOS 14/15')
    assets = json.loads(subprocess.check_output(
        ['xcrun', 'assetutil', '--info', str(resources / 'Assets.car')]))
    for name in ('ShipianLight', 'ShipianDark'):
        stacks = {a.get('Appearance') for a in assets
                  if a.get('Name') == name and a.get('AssetType') == 'IconImageStack'}
        if not {'NSAppearanceNameAqua', 'NSAppearanceNameDarkAqua'} <= stacks:
            raise ValueError(f'Missing native light/dark icon stacks: {name}')
        if not any(a.get('Name') == name and a.get('AssetType') == 'MultiSized Image'
                   for a in assets):
            raise ValueError(f'Missing legacy runtime rendition: {name}')
    print('Icon packaging check passed: two native icon stacks and legacy fallbacks.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f'FAIL icon packaging: {error}', file=sys.stderr)
        sys.exit(1)
