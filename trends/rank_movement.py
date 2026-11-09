"""Last effective rank change with seven-day topic memory, not snapshot entrants."""
import unicodedata
from datetime import datetime, timedelta
NEW_WINDOW = timedelta(hours=1)
HISTORY_WINDOW = timedelta(days=7)
REENTRY_GAP = timedelta(minutes=30)  # Distinguish a new observed Top30 stay from short collection gaps.

def name_key(value):
    folded = unicodedata.normalize('NFD', ' '.join(str(value).casefold().split()).lstrip('#'))
    return ''.join(c for c in folded if unicodedata.category(c) != 'Mn')

def parsed(value):
    try:
        date = datetime.fromisoformat(str(value).replace('Z', '+00:00'))
        return date if date.tzinfo else None
    except (TypeError, ValueError):
        return None

def remembered(previous, now, key):
    result = {}
    for row in (previous.get('rank_movement_history') or {}).values():
        seen = parsed(row.get('last_seen_at')) if isinstance(row,dict) else None
        if seen and timedelta(0) <= now-seen <= HISTORY_WINDOW and row.get('name') and (row.get('rank') is None or isinstance(row.get('rank'),int) and 1 <= row['rank'] <= 30):
            result[key(row['name'])] = row
    return result

def rank_items(names, previous, now, key=name_key):
    if now.tzinfo is None:
        raise ValueError('Timezone-aware observation required')
    old = remembered(previous, now, key)
    if not previous.get('rank_movement_history'):
        # Bootstrap known topics conservatively, without inventing an old rank.
        for row in (previous.get('radar_history') or {}).values():
            if not isinstance(row,dict) or not row.get('name'):
                continue
            seen = parsed(row.get('last_seen_at'))
            if seen and timedelta(0) <= now-seen <= HISTORY_WINDOW:
                old[key(row['name'])] = {'name':row['name'],'rank':None,
                    'first_seen_at':row.get('first_detected_at') or now.isoformat(timespec='seconds'),
                    'last_seen_at':row['last_seen_at']}
    initialized = bool(previous.get('rank_movement_history'))
    prior_top30 = {key(row.get('name')) for row in (previous.get('items') or [])[:30]
                   if isinstance(row,dict) and row.get('name')}
    prior_top30.update(key(name) for name in (previous.get('top30') or [])[:30]
                       if isinstance(name,str) and name.strip())
    for i,name in enumerate((previous.get('top30') or [])[:30]):
        if isinstance(name,str) and name.strip():
            old.setdefault(key(name),{'name':name,'rank':i+1})
    for row in previous.get('items') or []:
        if isinstance(row,dict) and isinstance(row.get('rank'),int) and 1 <= row['rank'] <= 30 and row.get('name'):
            old[key(row['name'])] = {**old.get(key(row['name']),{}),**row}
    at = now.isoformat(timespec='seconds')
    result = []
    for rank,name in enumerate(names[:30],1):
        prior = old.get(key(name))
        current = {'rank':rank,'name':name,'movement_version':3,'movement':'flat',
                   'previous_rank':None,'rank_delta':None,'last_changed_at':None,
                   'entered_top30_at':prior.get('entered_top30_at') if prior else None,
                   'first_seen_at':prior.get('first_seen_at',at) if prior else at}
        last_seen = parsed(prior.get('last_seen_at')) if prior else None
        departed = (initialized and key(name) not in prior_top30 and last_seen is not None
                    and REENTRY_GAP <= now-last_seen <= HISTORY_WINDOW and len(names)>=30)
        if departed:
            # Stable identity for this new visit; a changed rank alone is not
            # evidence of a new episode, but a real 30-minute absence is.
            current.update(movement='new',last_changed_at=at,entered_top30_at=at)
        elif prior is None:
            # Migration establishes a baseline; untrusted legacy 'new' is not history.
            if initialized and len(names)>=30:
                current.update(movement='new',last_changed_at=at,entered_top30_at=at)
        elif isinstance(prior.get('rank'),int) and rank != prior['rank']:
            delta = prior['rank']-rank
            current.update(movement='up' if delta>0 else 'down',previous_rank=prior['rank'],rank_delta=delta,last_changed_at=at)
        elif prior.get('movement_version') in (2,3):
            kind=prior.get('movement')
            origin=prior.get('previous_rank')
            delta=origin-rank if isinstance(origin,int) and 1 <= origin <= 30 else None
            if kind in ('up','down') and delta == prior.get('rank_delta') and delta and ((kind=='up' and delta>0) or (kind=='down' and delta<0)):
                current.update(movement=kind,previous_rank=origin,rank_delta=delta,last_changed_at=prior.get('last_changed_at'))
            elif kind=='new' and prior.get('movement_version')==3:
                entered=parsed(prior.get('entered_top30_at'))
                if entered and timedelta(0) <= now-entered < NEW_WINDOW:
                    current.update(movement='new',last_changed_at=prior.get('last_changed_at'))
        result.append(current)
    return result

def movement_history(previous, items, now, key=name_key):
    history=remembered(previous,now,key)
    if not previous.get('rank_movement_history'):
        for row in (previous.get('radar_history') or {}).values():
            if isinstance(row,dict) and row.get('name') and parsed(row.get('last_seen_at')):
                history[key(row['name'])] = {'name':row['name'],'rank':None,
                    'first_seen_at':row.get('first_detected_at') or now.isoformat(timespec='seconds'),
                    'last_seen_at':row['last_seen_at']}
    at=now.isoformat(timespec='seconds')
    for row in items:
        history[key(row['name'])] = {**row,'last_seen_at':at}
    return dict(sorted(history.items(),key=lambda pair:pair[1]['last_seen_at'],reverse=True)[:1000])
