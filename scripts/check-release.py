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
# Signing: Config/Local.xcconfig (git-ignored) overrides Base.xcconfig.
settings = {}
for name in ['Base.xcconfig', 'Local.xcconfig']:
    path = root / 'Config' / name
    if path.exists():
        for line in path.read_text().splitlines():
            key, sep, value = line.partition('=')
            if sep and not key.strip().startswith(('//', '#')):
                settings[key.strip()] = value.split('//')[0].strip()
if settings.get('APP_BUNDLE_ID', '').startswith('com.example.'):
    issues.append('Config/Local.xcconfig: APP_BUNDLE_ID still com.example.snapper')
if not settings.get('DEVELOPMENT_TEAM'):
    issues.append('Config/Local.xcconfig: DEVELOPMENT_TEAM not set')
for path in sorted((root / 'Snapper/Resources/Showcase').glob('showcase-*.jpg')):
    with Image.open(path) as image:
        if max(image.size) < 1600:
            issues.append(f'{path.relative_to(root)}: {image.width}×{image.height}, needs an original >=1600px')
if issues:
    print('Release inputs still needed:\n' + '\n'.join(f'- {item}' for item in issues))
    sys.exit(1)
print('Configuration and image dimensions pass. Complete the manual release checklist before shipping.')
