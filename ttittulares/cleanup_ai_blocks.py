#!/usr/bin/env python3
import json
from pathlib import Path

p = Path(__file__).with_name('prepared.json')
d = json.loads(p.read_text(encoding='utf-8'))
changed = []
for x in d.get('items', []):
    if x.get('tremending_origin') or str(x.get('image_mode', '')).lower() == 'tweet_capture_only':
        continue
    blocked = (
        bool(x.get('disable_ai_image'))
        or str(x.get('image_mode', '')).lower() in {'fallback_only', 'archive_only'}
        or str(x.get('image_strategy', '')).lower() in {'fallback_only', 'archive_only'}
        or str(x.get('ai_image_status', '')).lower() == 'disabled'
    )
    if not blocked:
        continue
    x.pop('disable_ai_image', None)
    x.pop('sensitive_image_reason', None)
    x['image_strategy'] = 'ai_plus_fallback'
    x['image_mode'] = 'ai_plus_fallback'
    if str(x.get('ai_image_status', '')).lower() == 'disabled':
        x['ai_image_status'] = 'none'
    changed.append(str(x.get('event_id', '')))
if changed:
    p.write_text(json.dumps(d, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print('CLEANED', len(changed), ','.join(changed))
