#!/usr/bin/env python3
"""Concrete preflight for known release placeholders; never writes user data."""
from pathlib import Path
import re
import sys
from PIL import Image

root = Path(__file__).resolve().parents[1]
issues = []
for path in [root / 'Snapper/App/AppConfig.swift', *sorted((root / 'docs').glob('*.html'))]:
    text = path.read_text()
    for marker in ['Your Name or Company', 'support@example.com', 'class="placeholder"']:
        if marker in text:
            issues.append(f'{path.relative_to(root)}: unresolved {marker}')
config = (root / 'Snapper/App/AppConfig.swift').read_text()
if re.search(r'appStoreID:\s*String\?\s*=\s*nil', config):
    issues.append('AppConfig.swift: App Store ID not configured')
for path in sorted((root / 'Snapper/Resources/Showcase').glob('showcase-*.jpg')):
    with Image.open(path) as image:
        if max(image.size) < 1600:
            issues.append(f'{path.relative_to(root)}: {image.width}×{image.height}, needs an original >=1600px')
if issues:
    print('Release inputs still needed:\n' + '\n'.join(f'- {item}' for item in issues))
    sys.exit(1)
print('Configuration and image dimensions pass. Complete the manual release checklist before shipping.')
