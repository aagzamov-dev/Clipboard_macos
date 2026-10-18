#!/usr/bin/env python3
"""Exercise Sparkle's verifier against valid and tampered release artifacts."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
release = root / '.build/release'
info = plistlib.loads((root / 'ClipboardApp/Info.plist').read_bytes())
feed = release / 'appcast.xml'
item = ET.parse(feed).find('./channel/item')
assert item is not None
namespace = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
assert item.findtext(namespace + 'version') == info['CFBundleVersion']
assert item.findtext(namespace + 'shortVersionString') == info['CFBundleShortVersionString']
archive_name = f"Clipboard-v{info['CFBundleShortVersionString']}-universal.zip"
archive = release / archive_name
enclosure = item.find('enclosure')
assert enclosure is not None
assert enclosure.attrib['url'] == f"https://github.com/aagzamov-dev/Clipboard_macos/releases/download/v{info['CFBundleShortVersionString']}/{archive_name}"
assert int(enclosure.attrib['length']) == archive.stat().st_size
signature = enclosure.attrib[namespace + 'edSignature']
key = os.environ.get('SPARKLE_EDDSA_PRIVATE_KEY')
command = [str(root / '.build/sparkle-tools/bin/sign_update'), '--verify']
command += ['--ed-key-file', '-'] if key else ['--account', 'local.clipboard.Clipboard']

def verify(path, signature=None):
    args = command + [str(path)] + ([signature] if signature else [])
    return subprocess.run(args, input=key.encode() if key else None, capture_output=True).returncode == 0

assert verify(feed), 'Feed signature is invalid'
assert verify(archive, signature), 'Archive signature is invalid'
with tempfile.TemporaryDirectory(prefix='update-verification-', dir=root / '.build') as temporary:
    changed_archive = Path(temporary) / archive.name
    changed_archive.write_bytes(archive.read_bytes() + b'changed')
    assert not verify(changed_archive, signature), 'Modified archive was accepted'
    changed_feed = Path(temporary) / feed.name
    changed_feed.write_bytes(feed.read_bytes().replace(b'<title>Clipboard</title>', b'<title>Modified</title>'))
    assert not verify(changed_feed), 'Modified feed was accepted'
print('Release version and URLs match; valid signatures accepted; modified archive and feed rejected.')
