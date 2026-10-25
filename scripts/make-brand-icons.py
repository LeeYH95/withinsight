#!/usr/bin/env python3
"""Compile native macOS icon stacks and preserve approved in-app artwork."""
import argparse
import json
import pathlib
import shutil
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--source', required=True)
p.add_argument('--output', required=True)
a = p.parse_args()
source, output = pathlib.Path(a.source), pathlib.Path(a.output)
output.mkdir(parents=True, exist_ok=True)
icons = []
for appearance in ('Light', 'Dark'):
    original = source / f'ShipianIcon{appearance}.png'
    if not original.is_file():
        raise SystemExit(f'Missing approved artwork: {original}')
    system = output / f'ShipianSystemIcon{appearance}.png'
    subprocess.run(['swift', str(pathlib.Path(__file__).with_name('export-system-icon.swift')),
                    str(original), str(system)], check=True)
    # Settings uses the original art, not the full-bleed system export.
    subprocess.run(['sips', '-z', '1024', '1024', str(original), '--out',
                    str(output / f'ShipianIcon{appearance}.png')], check=True, stdout=subprocess.DEVNULL)
    icon = output / f'Shipian{appearance}.icon'
    (icon / 'Assets').mkdir(parents=True, exist_ok=True)
    shutil.copy2(system, icon / 'Assets/Artwork.png')
    # The approved artwork is already opaque and shaded. Disable additional
    # material effects; Icon Composer owns only the system shape and rendition.
    model = {
        'fill': {'solid': 'srgb:1,1,1,1'},
        'groups': [{
            'layers': [{'image-name': 'Artwork.png', 'name': 'Approved artwork'}],
            'shadow': {'kind': 'neutral', 'opacity': 0},
            'specular': False,
            'translucency': {'enabled': False, 'value': 0},
        }],
        'supported-platforms': {'squares': ['macOS']},
    }
    (icon / 'icon.json').write_text(json.dumps(model, indent=2) + '\n')
    icons.append(str(icon))

# Modern macOS reads icon-stack metadata from Assets.car; loose ICNS/PNG
# resources can be wrapped in a compatibility tile. actool also emits the
# correctly masked ICNS fallback used on macOS 14/15.
subprocess.run([
    'xcrun', 'actool', *icons, '--compile', str(output),
    '--platform', 'macosx', '--minimum-deployment-target', '14.0',
    '--app-icon', 'ShipianLight', '--include-all-app-icons',
    '--output-partial-info-plist', str(output / 'icon-info.plist'),
], check=True)
