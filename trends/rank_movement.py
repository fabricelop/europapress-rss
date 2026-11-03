"""Persistent last effective position change for the complete Top 30."""
import unicodedata
from datetime import datetime, timedelta

NEW_WINDOW = timedelta(hours=1)

def name_key(value):
    folded = unicodedata.normalize('NFD', ' '.join(str(value).casefold().split()).lstrip('#'))
    return ''.join(c for c in folded if unicodedata.category(c) != 'Mn')

def parsed(value):
    try:
        date = datetime.fromisoformat(str(value).replace('Z', '+00:00'))
        return date if date.tzinfo else None
    except (TypeError, ValueError):
        return None

def rank_items(names, previous, now, key=name_key):
    """Repeated ranks preserve direction, origin rank and change time.

    The first known full ranking is a baseline, never thirty invented entries.
    A return after absence is a new episode. Labels expire; history does not.
    """
    if now.tzinfo is None:
        raise ValueError('Timezone-aware observation required')
    old = {}
    for i, name in enumerate(previous.get('top30') or []):
        if isinstance(name, str) and name.strip():
            old[key(name)] = {'name': name, 'rank': i + 1}
    for row in previous.get('items') or []:
        if isinstance(row, dict) and isinstance(row.get('rank'), int) and 1 <= row['rank'] <= 30 and row.get('name'):
            old[key(row['name'])] = row
    # Partial rankings cannot prove absence from the Top 30.
    full_previous = len({r['rank'] for r in old.values()}) == 30
    at = now.isoformat(timespec='seconds')
    result = []
    for rank, name in enumerate(names[:30], 1):
        prior = old.get(key(name))
        current = {'rank': rank, 'name': name, 'movement_version': 2,
                   'movement': 'flat', 'previous_rank': None, 'rank_delta': None,
                   'last_changed_at': None, 'entered_top30_at': None}
        if prior is None:
            if full_previous:
                current.update(movement='new', last_changed_at=at, entered_top30_at=at)
        elif rank != prior['rank']:
            delta = prior['rank'] - rank
            current.update(movement='up' if delta > 0 else 'down', previous_rank=prior['rank'],
                           rank_delta=delta, last_changed_at=at,
                           entered_top30_at=prior.get('entered_top30_at'))
        elif prior.get('movement_version') == 2:
            # Copy only movement fields, never old editorial content or rank.
            for field in ('movement', 'previous_rank', 'rank_delta', 'last_changed_at', 'entered_top30_at'):
                current[field] = prior.get(field)
            if current['movement'] == 'new':
                entered = parsed(current['entered_top30_at'])
                if entered is None or not timedelta(0) <= now - entered < NEW_WINDOW:
                    current.update(movement='flat', previous_rank=None, rank_delta=None)
            elif current['movement'] in ('up', 'down'):
                previous_rank = current['previous_rank']
                valid = isinstance(previous_rank, int) and 1 <= previous_rank <= 30 and current['rank_delta'] == previous_rank - rank
                if not valid or not ((current['movement'] == 'up' and current['rank_delta'] > 0) or (current['movement'] == 'down' and current['rank_delta'] < 0)):
                    current.update(movement='flat', previous_rank=None, rank_delta=None)
            else:
                current.update(movement='flat', previous_rank=None, rank_delta=None)
        result.append(current)
    return result
