#!/usr/bin/env python3
"""Vendor pinned offline chat libraries; verify npm package integrity before reading files."""
import base64
import hashlib
import io
import json
from pathlib import Path
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent / 'Vendor' / 'ChatRenderer'
PACKAGES = [
    ('katex', '0.19.1', 'jG8uKntjSEcm2EpQOh0XturpPuuC9r3Sq5HLHdsFdWZT27E672SF19QEi+of0/YeOy15lDgRhKvr5614uRrEfA==', {'dist/katex.min.js': 'katex.min.js', 'dist/katex.min.css': 'katex.min.css', 'LICENSE': 'LICENSE-katex'}),
    ('marked', '18.1.2', 'DfOnvLAQ6WYeWxWO1u4RyFOeqyHup6dks5PPqnoFiooU7ipRvidO/2j8plhAHIiZg574E9ZlzSjUiPMLAzFkgg==', {'lib/marked.umd.js': 'marked.js', 'LICENSE': 'LICENSE-marked'}),
    ('dompurify', '3.4.17', 'B/pSlYVHQ58kqISD/yDjuJ1yfzI34m1gF4lAod2bwSRhiN4K5Cl3H8Af7hqB2PmTL911tdEudnnXn5FnhRoz0w==', {'dist/purify.min.js': 'purify.min.js', 'LICENSE': 'LICENSE-dompurify'}),
    ('plotly.js-dist-min', '4.1.2', 'VSmS9KVNun16S8qFYYp9LlL/XBby4ueeGqB+K9AqRCVsup8dSpGULap4UyR1f2mz4pV3qjWp1sR5chwLgIKPoQ==', {'plotly.min.js': 'plotly.min.js', 'LICENSE': 'LICENSE-plotly'}),
    ('vega', '6.4.0', 'rHXCq2LpEWCLMjXBEj7hocY9G0/i5TGYRayGGSj06VTF4+l2IG2Z7oeZKCjWbUh/7hTE/mVhbaOPB72wCElh6g==', {'build/vega.min.js': 'vega.min.js', 'LICENSE': 'LICENSE-vega'}),
    ('vega-lite', '6.5.0', 'fMXF6s0MrIg0UTWnLIfeFtgSLzVhyzSKobzGrh5rhS+mL6FOYFG3m7ouJ4U23gj65EK+gl9FIIT5w7wLNaAzkA==', {'build/vega-lite.min.js': 'vega-lite.min.js', 'LICENSE': 'LICENSE-vega-lite'}),
    ('vega-embed', '7.3.0', 'wQ8s5GaSzqoKgmRfbRolgBrjE2CP7ZKHXqH7NijxMqPjpdWxSs4Dn8tvp9g0giQvh2cK+3p56sxjWWM0wNngGw==', {'build/vega-embed.min.js': 'vega-embed.min.js', 'LICENSE': 'LICENSE-vega-embed'}),
]

def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    manifest = {'packages': {}, 'files': {}}
    for name, version, integrity, files in PACKAGES:
        url = f'https://registry.npmjs.org/{name}/-/{name}-{version}.tgz'
        data = urllib.request.urlopen(url, timeout=60).read()
        assert base64.b64encode(hashlib.sha512(data).digest()).decode() == integrity, f'Integrity mismatch: {name}'
        manifest['packages'][name] = {'version': version, 'url': url, 'integrity': 'sha512-' + integrity}
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
            mapping = dict(files)
            if name == 'katex':
                mapping.update({m.name.removeprefix('package/'): 'fonts/' + Path(m.name).name for m in archive.getmembers() if m.name.startswith('package/dist/fonts/') and m.name.endswith('.woff2')})
            for source, target in mapping.items():
                content = archive.extractfile('package/' + source).read()
                path = ROOT / target
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
                manifest['files'][target] = hashlib.sha256(content).hexdigest()
        print(f'{name} {version}')
    (ROOT / 'versions.json').write_text(json.dumps(manifest, indent=2) + '\n')

if __name__ == '__main__':
    main()
