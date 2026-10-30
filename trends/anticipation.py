"""Bounded, text-only preparation of emerging signals using existing sources.

Drafts never become Listas or image jobs. Top-30 research may reuse a fresh
draft, with a final factual check, only after the normal selector accepts it.
"""
import copy
import hashlib
import re
import unicodedata
from datetime import datetime, timedelta, timezone

ACTIVE = {'preparing', 'update'}
CLOSED = {'published', 'deleted', 'dismissed', 'removed', 'delete_pending', 'delete_failed'}
MAX_DRAFTS = 2
WINDOW = timedelta(minutes=15)
DRAFT_TTL = timedelta(hours=1)


def moment(value):
    try:
        at = datetime.fromisoformat(str(value).replace('Z', '+00:00'))
        return at.replace(tzinfo=timezone.utc) if at.tzinfo is None else at.astimezone(timezone.utc)
    except (TypeError, ValueError):
        return None


def key(value):
    return ''.join(c for c in unicodedata.normalize('NFD', str(value or '').casefold())
                   if unicodedata.category(c) != 'Mn').strip().lstrip('#')


def digest(value):
    return hashlib.sha256(str(value).encode()).hexdigest()


def captured(recent, now):
    at = moment(recent.get('captured_at'))
    return bool(at and -60 <= (now-at).total_seconds() <= 20*60
                and recent.get('selection_method') not in {'hold-last-good', 'stale-fallback', 'none'}
                and recent.get('safe_to_auto_queue') is not False)


def source_support(signal, recent):
    """Near-identical rankings count once; require at least one dated fresh list."""
    representatives = []
    fresh = False
    for name in signal.get('social_sources') or []:
        source = (recent.get('sources') or {}).get(name, {})
        if not source.get('ok') or source.get('freshness') in {'stale', 'invalid', 'error'}:
            continue
        terms = {key(x) for x in (source.get('trends') or [])[:50] if x}
        if key(signal.get('name')) not in terms:
            continue
        age = source.get('age_minutes')
        if source.get('freshness') == 'fresh' and isinstance(age, (float, int)) and 0 <= age <= 45:
            fresh = True
        if any(len(terms & old)/max(1, len(terms | old)) >= .85 for old in representatives):
            continue
        representatives.append(terms)
    return len(representatives), fresh


def strong_signals(recent, now):
    if not captured(recent, now):
        return []
    top = {key(x.get('name')) for x in recent.get('items', []) if 1 <= int(x.get('rank') or 999) <= 30}
    selected = []
    for signal in recent.get('upcoming') or []:
        name = key(signal.get('name'))
        first = moment(signal.get('first_detected_at'))
        history = signal.get('rank_history') or []
        if (not name or name in top or not first or not 0 <= (now-first).total_seconds() <= 45*60
                or signal.get('movement') not in {'new', 'up'} or len(history) < 2):
            continue
        previous, current = history[-2:]
        prev_at, at = moment(previous.get('captured_at')), moment(current.get('captured_at'))
        if (not prev_at or not at or not 0 < (at-prev_at).total_seconds() <= 30*60
                or not 0 <= (now-at).total_seconds() <= 15*60):
            continue
        rank = int(current.get('best_rank') or 999)
        jump = int(previous.get('best_rank') or 999)-rank
        growth = int(current.get('source_count') or 0)-int(previous.get('source_count') or 0)
        support, fresh = source_support(signal, recent)
        if not 1 <= rank <= 50 or support < 2 or not fresh or jump < 8 and growth < 1:
            continue
        selected.append((-(jump+growth*8), -support, rank, name, signal))
    return [x[-1] for x in sorted(selected, key=lambda x: x[:-1])]


def sync(recent, requests_doc, manual_doc, decisions_doc, now):
    """Reconcile promotions/expiry before opening at most two draft slots."""
    requests = requests_doc.setdefault('requests', [])
    jobs = [x for x in requests if x.get('anticipation_request')]
    safe = captured(recent, now)
    top = {key(x.get('name')): x for x in recent.get('items', []) if 1 <= int(x.get('rank') or 999) <= 30} if safe else {}
    ordinary = {key(x.get('name')): x for x in requests if not x.get('anticipation_request')}
    at = now.isoformat()
    for job in jobs:
        name = key(job.get('anticipated_name'))
        started = moment(job.get('requested_at'))
        if started and now-started > DRAFT_TTL and job.get('status') in ACTIVE | {'anticipation_prepared'}:
            job.update(status='anticipation_expired', updated_at=at, anticipation_reason='draft_window_elapsed')
        if name in top and not job.get('anticipated_entered_top30_at'):
            entered = moment(recent.get('captured_at')) or now
            job['anticipated_entered_top30_at'] = entered.isoformat()
            prepared = moment(job.get('anticipation_prepared_at'))
            detected = moment(job.get('anticipated_at'))
            job['detection_lead_minutes'] = max(0, round((entered-detected).total_seconds()/60, 1)) if detected else None
            job['prepared_before_top30'] = bool(prepared and timedelta(0) <= entered-prepared <= DRAFT_TTL
                                                   and job.get('status') == 'anticipation_prepared')
            job['preparation_lead_minutes'] = round((entered-prepared).total_seconds()/60, 1) if prepared else None
        if name in top and job.get('status') in ACTIVE | {'anticipation_prepared'}:
            target = ordinary.get(name)
            prepared = moment(job.get('anticipation_prepared_at'))
            # A manual investigation or terminal decision is never overwritten.
            if (target and target.get('status') in ACTIVE and target.get('auto_queued') is True
                    and prepared and timedelta(0) <= now-prepared <= DRAFT_TTL):
                if not target.get('anticipation_origin_id'):
                    target.update(anticipation_origin_id=job['id'], anticipation_draft=copy.deepcopy(job['anticipation_draft']))
                    target['rewrite_instruction'] = (str(target.get('rewrite_instruction') or '')+
                        '\nHa entrado en Top 30. Reutiliza anticipation_draft solo tras comprobar actualidad, fuentes y detonante; usa el puesto real y el formato habitual. No des por verificado lo antiguo.').strip()
                job['promotion_request_id'] = target['id']
                job['status'] = 'anticipation_promoted'
            else:
                job['status'] = 'anticipation_superseded'
                job['promotion_reason'] = 'ordinary_request_takes_priority_or_no_fresh_draft'
            job['updated_at'] = at
    busy = sum(x.get('status') in ACTIVE | {'anticipation_prepared'} for x in jobs)
    recent_jobs = sum(timedelta(0) <= now-started < WINDOW for x in jobs if (started := moment(x.get('requested_at'))))
    budget = min(MAX_DRAFTS-busy, MAX_DRAFTS-recent_jobs)
    # Preserve the new/manual Top30 workload before speculative preparation.
    if any(x.get('status') in ACTIVE and not any(x.get(flag) for flag in
               ['anticipation_request', 'listas_grouping_request', 'red_review_request']) for x in requests):
        budget = 0
    known = set()
    for row in requests + manual_doc.get('items', []) + decisions_doc.get('items', []):
        known.update(key(n) for n in [row.get('anticipated_name') or row.get('name')] + (row.get('trend_names') or []) if n)
    if safe and budget > 0:
        for signal in strong_signals(recent, now):
            if budget <= 0:
                break
            name = str(signal['name'])
            if key(name) in known:
                continue
            ident = 'radar-prepare-'+digest(key(name)+'|'+str(signal.get('first_detected_at')))[:20]
            job = dict(id=ident, revision=0, name='Radar · '+name, rank=0, status='preparing', requested_at=at,
                       task='anticipate', anticipation_request=True, anticipated_name=name,
                       anticipated_at=signal.get('first_detected_at'), anticipation_signal=copy.deepcopy(signal),
                       anticipated_best_rank=signal.get('best_observed_rank'),
                       with_image=False, disable_ai_image=True, auto_queued=False,
                       request_source='emerging_radar',
                       rewrite_instruction='Prepara un borrador factual de esta señal emergente, no una ficha de Top30. Verifica el detonante actual con fuentes. Guarda anticipation-outbox, sin publicar ni crear imágenes ni tocar Listas.')
            requests.append(job)
            jobs.append(job)
            known.add(key(name))
            budget -= 1
    return metrics(jobs)


def apply_result(requests_doc, command, now):
    requests_doc = copy.deepcopy(requests_doc)
    job = next((x for x in requests_doc['requests'] if x.get('id') == command.get('job_id') and x.get('anticipation_request')), None)
    if not job:
        raise ValueError('Solicitud de anticipación inexistente')
    if job.get('status') not in ACTIVE:
        return requests_doc, False
    if command.get('revision') != int(job.get('revision') or 0):
        raise ValueError('Revisión anticipada obsoleta')
    started = moment(job.get('requested_at'))
    if not started or now-started > DRAFT_TTL:
        job.update(status='anticipation_expired', updated_at=now.isoformat())
        return requests_doc, True
    outcome = command.get('outcome')
    reason = str(command.get('reason') or '').strip()
    if outcome not in {'prepared', 'unverified'} or not reason:
        raise ValueError('Anticipación requiere outcome prepared/unverified y motivo')
    if outcome == 'prepared':
        body = str(command.get('explanation_body') or '').strip()
        closer = str(command.get('closer_text') or '').strip()
        sources = command.get('verification_sources') or []
        weighted = sum(1 if ord(c) <= 0x10ff or 0x2000 <= ord(c) <= 0x200d or 0x2010 <= ord(c) <= 0x201f or 0x2032 <= ord(c) <= 0x2037 else 2 for c in re.sub(r'https?://\S+', 'x'*23, body))
        if (not body or body.startswith('TT#') or weighted+6 >= 280
                or len(re.findall(r'(?<!\w)#\w+', body)) < 2
                or closer and (not closer.startswith('🌶️ ') or not body.endswith(closer) or body.count(closer) != 1)
                or not sources or not all(isinstance(x, dict) and str(x.get('url') or '').startswith('https://') for x in sources)):
            raise ValueError('Borrador sin fuentes, etiquetas, longitud o estructura válidas')
        job['anticipation_draft'] = dict(explanation_body=body, closer_text=closer,
                                         verification_sources=copy.deepcopy(sources), verified_at=now.isoformat())
        job['anticipation_prepared_at'] = now.isoformat()
    job.update(status='anticipation_'+outcome, anticipation_reason=reason, updated_at=now.isoformat())
    requests_doc['updated_at'] = now.isoformat()
    return requests_doc, True


def metrics(jobs):
    rows = [{k: job.get(k) for k in ('id', 'anticipated_name', 'status', 'anticipated_at', 'requested_at',
             'anticipation_prepared_at', 'anticipated_entered_top30_at', 'detection_lead_minutes',
             'preparation_lead_minutes', 'prepared_before_top30', 'promotion_request_id')} for job in jobs[-200:]]
    promoted = [x for x in rows if x['prepared_before_top30'] is True]
    return dict(version=1, budget_eur=0, max_drafts=MAX_DRAFTS, evaluated=len(rows),
                entered_top30=sum(bool(x['anticipated_entered_top30_at']) for x in rows),
                prepared_before_top30=len(promoted),
                mean_preparation_lead_minutes=round(sum(x['preparation_lead_minutes'] for x in promoted)/len(promoted), 1) if promoted else None,
                items=rows)
