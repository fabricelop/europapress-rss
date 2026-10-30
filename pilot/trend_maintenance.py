"""Conditional trend research and the text-before-images grouping gate.

Research is performed by the existing editorial chat, never by this scheduler.
All result application is on a fresh state with exact revision/text guards.
"""
import copy
import hashlib
import json
import re
import unicodedata
from datetime import timedelta

MANUAL = 'trends/telegram-manual-explained.json'
REQUESTS = 'trends/requests.json'
QUEUE = 'trends/editorial-queue.json'
RECENT = 'trends/recent.json'
ACTIVE = {'preparing', 'update'}
TERMINAL = {'published', 'deleted', 'dismissed', 'removed', 'delete_pending', 'delete_failed'}
REVIEW_PERIOD = timedelta(minutes=15)
REVIEWS_PER_PERIOD = 2
REVIEW_COOLDOWN = timedelta(hours=1)


def key(value):
    return ''.join(c for c in unicodedata.normalize('NFD', str(value or '').casefold())
                   if unicodedata.category(c) != 'Mn').strip().lstrip('#')


def fingerprint(row):
    content = [str(row.get('id')), int(row.get('revision') or 0),
               row.get('explained_at'), row.get('explanation')]
    return hashlib.sha256(json.dumps(content, ensure_ascii=False).encode()).hexdigest()


def image_allowed(row):
    """A changed text invalidates clearance even if a producer reused revision 0."""
    if row.get('listas_group_role') == 'covered':
        return False
    return (row.get('editorial_grouping_state') == 'cleared'
            and row.get('editorial_grouping_fingerprint') == fingerprint(row))


def stamp_rows(state, row, **fields):
    for path, field in ((MANUAL, 'items'), (REQUESTS, 'requests')):
        for target in state[path][field]:
            if (target.get('id') == row.get('id')
                    and int(target.get('revision') or 0) == int(row.get('revision') or 0)
                    and target.get('explanation') == row.get('explanation')):
                target.update(fields)


def clear(state, row, at):
    stamp_rows(state, row, editorial_grouping_state='cleared',
               editorial_grouping_fingerprint=fingerprint(row), editorial_grouping_checked_at=at)


def add_job(state, job, at):
    state[REQUESTS]['requests'].append(job)
    state[REQUESTS]['updated_at'] = at
    state[QUEUE]['items'].append(copy.deepcopy(job))
    state[QUEUE].update(count=len(state[QUEUE]['items']), updated_at=at)


def schedule(state, now, grouping):
    """Call after applying results. New explanations, grouping, then reviews."""
    at = now.isoformat()
    if state[QUEUE].get('maintenance_pause'):
        return
    reqs = state[REQUESTS]['requests']
    live = [x for x in reqs if x.get('status') in ACTIVE]
    current = grouping.eligible(state, now)
    unchecked = [x for x in current.values() if not image_allowed(x)]
    for row in unchecked:
        stamp_rows(state, row, editorial_grouping_state='pending')
    # Normal editorial requests (including manual reworks) always take priority.
    if any(not x.get('listas_grouping_request') and not x.get('red_review_request') for x in live):
        return
    if not any(x.get('listas_grouping_request') for x in live) and unchecked:
        signature = '|'.join(sorted(fingerprint(x) for x in current.values()))
        ident = 'listas-auto-'+hashlib.sha256(signature.encode()).hexdigest()[:20]
        # Retrying a stale result must use a new snapshot, not reopen a closed job.
        if any(x.get('id') == ident for x in reqs):
            ident += '-'+str(int(now.timestamp()))
        history = published_context(state, now, grouping)
        job = dict(id=ident, revision=0, name='Agrupación automática de Listas', rank=0,
                   status='preparing', requested_at=at, task='group_listas',
                   listas_grouping_request=True, automatic_grouping=True,
                   grouping_state='pending', grouping_candidates=[grouping.snapshot(x) for x in current.values()],
                   published_context=history, with_image=False, disable_ai_image=True,
                   auto_queued=False, request_source='editorial_maintenance',
                   rewrite_instruction='Comprueba el mismo acontecimiento; agrupa solo coincidencias verificadas. Compara también las publicaciones previas. Conserva originales. No publiques.')
        add_job(state, job, at)
    schedule_reviews(state, now, grouping)


def published_context(state, now, grouping):
    requests = grouping.latest(state[REQUESTS]['requests'])
    decisions = grouping.latest(state.get('trends/mobile-decisions.json', {}).get('items', []))
    deliveries = grouping.latest(state.get('trends/telegram-image-deliveries.json', {}).get('items', []), 'event_id')
    rows = []
    for row in grouping.latest(state[MANUAL]['items']).values():
        at = grouping.moment(row.get('explained_at'))
        if not at or not -3600 <= (now-at).total_seconds() <= 48*3600 or not row.get('explanation'):
            continue
        events = [row, requests.get(row['id'], {}), decisions.get(row['id'], {}), deliveries.get(row['id'], {})]
        if (grouping.revision(requests.get(row['id'], {})) > grouping.revision(row)
                or any(x.get('status') in TERMINAL-{'published'} and grouping.terminal_applies(x, row) for x in events)):
            continue
        if any(x.get('status') == 'published' and grouping.revision(x) == grouping.revision(row) for x in events):
            rows.append(grouping.snapshot(row))
    return rows


def schedule_reviews(state, now, grouping):
    recent = state.get(RECENT, {})
    captured = grouping.moment(recent.get('updated_at') or recent.get('captured_at') or recent.get('generated_at'))
    # Stale or explicitly unsafe radar must not initiate background research.
    if (not captured or not -3600 <= (now-captured).total_seconds() <= 3600
            or recent.get('safe_to_auto_queue') is False
            or recent.get('selection_method') in {'hold-last-good', 'stale-fallback', 'none'}
            or recent.get('non_stale_source_count') == 0):
        return
    top = {key(x.get('name')): x for x in recent.get('items', [])
           if 1 <= int(x.get('rank') or 999) <= 30}
    latest = {}
    for row in state[MANUAL]['items']:
        if not row.get('explanation') or row.get('status') not in {'explained', 'published'}:
            continue
        for name in [row.get('name')] + (row.get('trend_names') or []):
            if key(name) not in top:
                continue
            old = latest.get(key(name))
            if old is None or str(row.get('explained_at') or '') > str(old.get('explained_at') or ''):
                latest[key(name)] = row
    reqs = grouping.latest(state[REQUESTS]['requests'])
    active_reviews = {x.get('review_source', {}).get('id') for x in reqs.values()
                      if x.get('red_review_request') and x.get('status') in ACTIVE}
    review_jobs = [x for x in reqs.values() if x.get('red_review_request')]
    active_count = sum(x.get('status') in ACTIVE for x in review_jobs)
    # A rolling window prevents every five-minute tick (or a quick completion)
    # from refilling the batch. Pending work also occupies the two global slots.
    recent_count = sum(0 <= (now-at).total_seconds() < REVIEW_PERIOD.total_seconds()
                       for x in review_jobs if (at := grouping.moment(x.get('requested_at'))))
    budget = min(REVIEWS_PER_PERIOD-active_count, REVIEWS_PER_PERIOD-recent_count)
    if budget <= 0:
        return
    seen = set()
    candidates = []
    for name, row in latest.items():
        ident = row['id']
        if ident in seen or ident in active_reviews or grouping.is_covered(row):
            continue
        seen.add(ident)
        source_req = reqs.get(ident, {})
        if grouping.revision(source_req) > grouping.revision(row) or source_req.get('status') in ACTIVE:
            continue
        if any(x.get('status') in TERMINAL-{'published'} for x in (row, source_req)):
            continue
        closed = grouping.latest(state.get('trends/mobile-decisions.json', {}).get('items', [])).get(ident, {})
        if closed.get('status') in TERMINAL-{'published'} and grouping.terminal_applies(closed, row):
            continue
        explained = grouping.moment(row.get('explained_at'))
        checked = grouping.moment(row.get('red_review_checked_at'))
        if not explained or now < explained or checked and now-checked < REVIEW_COOLDOWN:
            continue
        age = now-explained
        priority, color = ((0, 'roja') if age > timedelta(hours=24) else
                           (1, 'amarilla') if age >= timedelta(hours=12) else (2, 'verde'))
        # Within each color prefer those least recently checked, then the
        # oldest explanation, using IDs for deterministic ordering.
        candidates.append((priority, checked is not None, checked or explained, explained, ident, name, row, color))
    for priority, _, _, _, ident, name, row, color in sorted(candidates, key=lambda x: x[:5]):
        if budget <= 0:
            break
        review_id = 'red-review-'+hashlib.sha256((fingerprint(row)+'|'+str(int(now.timestamp())//3600)).encode()).hexdigest()[:20]
        if review_id in reqs:
            continue
        job = dict(id=review_id, revision=0, name='Revisar novedades: '+str(row.get('name')), rank=int(top[name]['rank']),
                   status='preparing', requested_at=now.isoformat(), task='review_red', red_review_request=True,
                   review_color=color, review_priority=priority,
                   review_source={**grouping.snapshot(row), 'fingerprint': fingerprint(row)},
                   with_image=False, disable_ai_image=True, auto_queued=False,
                   rewrite_instruction='Busca novedades sustanciales verificables. Sin novedades, conserva texto y fecha. Continuidad: sigue siendo tendencia por; episodio distinto comprobado: es tendencia por. No publiques.')
        add_job(state, job, now.isoformat())
        budget -= 1


def apply_review(state, command, now, grouping):
    state = copy.deepcopy(state)
    job = next((x for x in state[REQUESTS]['requests'] if x.get('id') == command.get('job_id') and x.get('red_review_request')), None)
    if not job:
        raise ValueError('Revisión de tendencia inexistente')
    if job.get('status') not in ACTIVE:
        return state, False
    snap = job['review_source']
    source = grouping.latest(state[MANUAL]['items']).get(snap['id'])
    request = grouping.latest(state[REQUESTS]['requests']).get(snap['id'], {})
    source_names = {key(source.get('name'))} | {key(x) for x in source.get('trend_names', [])} if source else set()
    superseded = any(x.get('id') != snap['id'] and x.get('status') in {'explained', 'published'}
                     and str(x.get('explained_at') or '') > str(snap.get('explained_at') or '')
                     and source_names.intersection({key(x.get('name'))} | {key(n) for n in x.get('trend_names', [])})
                     for x in state[MANUAL]['items'])
    top_names = {key(x.get('name')) for x in state.get(RECENT, {}).get('items', [])
                 if 1 <= int(x.get('rank') or 999) <= 30}
    closures = [x for p, field in [('trends/mobile-decisions.json', 'id'), ('trends/telegram-image-deliveries.json', 'event_id')]
                for x in state.get(p, {}).get('items', []) if x.get(field) == snap['id']]
    stale = (not source or superseded or not source_names.intersection(top_names)
             or fingerprint(source) != snap['fingerprint']
             or grouping.revision(request) > snap['revision'] or request.get('status') in ACTIVE
             or any(x.get('status') in TERMINAL-{'published'} and grouping.terminal_applies(x, source or {}) for x in [source or {}, request]+closures))
    at = now.isoformat()
    outcome = command.get('outcome')
    if outcome not in {'unchanged', 'updated', 'unverified'}:
        raise ValueError('outcome debe ser unchanged, updated o unverified')
    reason = str(command.get('reason') or '').strip()
    sources = command.get('verification_sources') or []
    if not reason or outcome != 'unverified' and (not sources or not all(isinstance(x, dict) and str(x.get('url') or '').startswith('https://') for x in sources)):
        raise ValueError('La revisión requiere motivo y fuentes verificadas; unverified requiere motivo del bloqueo')
    if not stale:
        stamp_rows(state, source, red_review_checked_at=at, red_review_outcome=outcome,
                   red_review_reason=reason, red_review_sources=sources)
        if outcome == 'updated':
            text = str(command.get('explanation') or '').strip()
            closer = str(command.get('closer_text') or '').strip()
            separate = command.get('distinct_episode') is True
            expected = r'\bes tendencia (?:por|porque)\b' if separate else r'\bsigue[n]? siendo tendencia (?:por|porque)\b'
            if (not str(command.get('new_facts') or '').strip() or not re.search(expected, text, re.I)
                    or not text.startswith('TT#') or grouping.weighted_length(text) >= 280
                    or text == snap['explanation'] or closer and (not closer.startswith('🌶️ ') or not text.endswith(closer) or text.count(closer) != 1)):
                raise ValueError('Actualización sin novedades, formato de continuidad/episodio o longitud válidos')
            # New publication identity: never revive a published or dismissed source.
            ident = 'trend-update-'+grouping.digest(job['id'])[:20]
            row = dict(id=ident, revision=0, name=source.get('name'), rank=job['rank'], status='explained',
                       requested_at=at, explained_at=at, updated_at=at, explanation=text, closer_text=closer,
                       verification_sources=sources, originated_from_prior_id=source['id'],
                       trend_names=source.get('trend_names') or [source.get('name')],
                       red_review_job_id=job['id'], continuity_update=not separate, distinct_episode=separate,
                       new_facts=command['new_facts'], with_image=True, disable_ai_image=False,
                       editorial_grouping_state='pending', image_strategy='ai_plus_fallback', ai_image_status='pending')
            for path, field in ((MANUAL, 'items'), (REQUESTS, 'requests')):
                state[path][field].append(copy.deepcopy(row))
            # An unpublished older card is visibly covered, with its text intact.
            published = any(x.get('status') == 'published' and grouping.revision(x) == grouping.revision(source)
                            for x in [source, request]+closures)
            if not published and source['id'] in grouping.eligible(state, now):
                stamp_rows(state, source, listas_group_role='covered', covered_by_id=ident,
                           covered_by_name=row['name'], covered_by_revision=0,
                           covered_source_revision=grouping.revision(source), covered_at=at)
            job['review_created_id'] = ident
    job.update(status='review_completed', review_outcome='stale' if stale else outcome,
               completed_at=at, review_reason=reason)
    state[QUEUE]['items'] = [x for x in state[QUEUE]['items'] if x.get('id') != job['id']]
    state[QUEUE].update(count=len(state[QUEUE]['items']), updated_at=at)
    state[REQUESTS]['updated_at'] = at
    state[MANUAL]['updated_at'] = at
    return state, True
