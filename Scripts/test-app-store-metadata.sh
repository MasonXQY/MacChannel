#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$#" == 1 && "$1" == --text-only ]] || { echo 'metadata BLOCKED: final screenshots and TestFlight evidence not verified'; exit 2; }
python3 - <<'PY'
from pathlib import Path
limits = {'name': 30, 'subtitle': 30, 'description': 4000, 'keywords': 100,
          'promotional_text': 170, 'release_notes': 4000}
for locale in ('zh-Hans', 'en-US'):
    for field, limit in limits.items():
        path = Path('AppStore/metadata') / locale / (field + '.txt')
        assert path.is_file(), f'missing metadata: {locale}/{field}'
        text = path.read_text(encoding='utf-8').strip()
        assert 0 < len(text) <= limit, f'invalid length: {locale}/{field}'
        assert not any(word in text for word in ('Windows', 'zensys-tech.com', '100% secure', '零数据收集', 'zero data collection')), f'unapproved claim: {locale}/{field}'
        if field == 'name':
            assert text == 'DropMesh'
print('metadata text PASS: 12 fields; not submission approval')
PY
