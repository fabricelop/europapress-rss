#!/usr/bin/env python3
"""User-requested Listas grouping. Text is written by the editorial runner.

The request snapshots real eligible cards; the result revalidates every member.
Existing explanations/dates/revisions stay untouched. Covered is metadata,
never a publication or deletion. No LLM, image or browser calls live here.
"""
from __future__ import annotations
import copy
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from pilot import trend_maintenance as maintenance
from trends import anticipation
MANUAL = 'trends/telegram-manual-explained.json'
REQUESTS = 'trends/requests.json'
QUEUE = 'trends/editorial-queue.json'
DECISIONS = 'trends/mobile-decisions.json'
DELIVERIES = 'trends/telegram-image-deliveries.json'
RECEIPTS = 'pilot/ttactualidad-action-receipts.json'
CLOSED = {'published', 'deleted', 'dismissed', 'removed', 'delete_pending', 'delete_failed'}
UUID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$', re.I)


def moment(value):
    try:
        d = datetime.fromisoformat(str(value).replace('Z', '+00:00'))
        return d.replace(tzinfo=timezone.utc) if d.tzinfo is None else d.astimezone(timezone.utc)
    except (ValueError, TypeError):
        return None


def digest(text):
    return hashlib.sha256(str(text).encode('utf-8')).hexdigest()


def revision(row):
    return int(row.get('revision') or 0)


def is_covered(row):
    return (row.get('listas_group_role') == 'covered' and bool(row.get('covered_by_id'))
            and int(row.get('covered_source_revision', revision(row))) == revision(row))


def terminal_applies(event, row):
    if str(event.get('status') or '').lower() not in CLOSED:
        return False
    if revision(event) != revision(row):
        return revision(event) > revision(row)
    closed_at = next((parsed for key in ('deleted_at', 'dismissed_at', 'published_at',
                                        'removed_at', 'updated_at', 'delivered_at', 'decided_at')
                      if (parsed := moment(event.get(key)))), None)
    explained_at = moment(row.get('explained_at'))
    return not (closed_at and explained_at and (closed_at-explained_at).total_seconds() < -60)


def latest(rows, key='id'):
    result = {}
    for row in rows:
        ident = str(row.get(key) or '')
        old = result.get(ident)
        if ident and (old is None or (revision(row), str(row.get('updated_at') or row.get('explained_at') or '')) >=
                     (revision(old), str(old.get('updated_at') or old.get('explained_at') or ''))):
            result[ident] = row
    return result


def eligible(state, now, include_covered=False):
    requests = latest(state[REQUESTS]['requests'])
    decisions = latest(state[DECISIONS]['items'])
    deliveries = latest(state[DELIVERIES]['items'], 'event_id')
    result = {}
    for ident, row in latest(state[MANUAL]['items']).items():
        at = moment(row.get('explained_at'))
        rev = revision(row)
        req = requests.get(ident, {})
        if (row.get('anticipation_request') or row.get('status') != 'explained' or not str(row.get('explanation') or '').strip()
                or not at or not -3600 <= (now-at).total_seconds() <= 48*3600
                or str(row.get('group_leader_id') or ident) != ident
                or revision(req) > rev):
            continue
        if not include_covered and is_covered(row):
            continue
        if any(str(x.get('status') or '').lower() in CLOSED or
               str(x.get('telegram_package_status') or '').lower() in CLOSED
               for x in (row, req)):
            continue
        if any(terminal_applies(x, row)
               for x in (decisions.get(ident, {}), deliveries.get(ident, {}))):
            continue
        requested = moment(req.get('requested_at'))
        if req.get('status') in {'preparing', 'update', 'ready'} and requested and (at-requested).total_seconds() < -60:
            continue
        if any(str(x.get('id') or '') == ident and x.get('status') in {'preparing', 'update'}
               and revision(x) > rev for x in state[QUEUE]['items']):
            continue
        result[ident] = row
    return result


def snapshot(row):
    return {'id': row['id'], 'revision': revision(row), 'name': row.get('name') or '',
            'rank': int(row.get('rank') or 0), 'explanation': row['explanation'],
            'explanation_sha256': digest(row['explanation']),
            'explained_at': row.get('explained_at'),
            'verification_sources': row.get('verification_sources') or []}


def receipt(state, payload, status, at, **extra):
    rid = payload['request_id'].lower()
    rows = state[RECEIPTS]['items']
    rows[:] = [x for x in rows if x.get('request_id') != rid]
    rows.append({'request_id': rid, 'project': 'ttendencias',
                 'event_id': 'listas-grouping-'+rid, 'revision': 0,
                 'decision': payload.get('decision') or 'group_listas', 'status': status, 'at': at, **extra})
    state[RECEIPTS]['items'] = rows[-2500:]


def request(state, payload, now):
    """Return a new state; malformed/rejected commands never partially mutate."""
    state = copy.deepcopy(state)
    if (payload.get('project') != 'ttendencias' or not UUID.fullmatch(str(payload.get('request_id') or ''))
            or payload.get('decision') not in {'group_listas', 'remove_covered'}):
        raise ValueError('Orden de agrupación no válida')
    rid = payload['request_id'].lower()
    if any(x.get('request_id') == rid for x in state[RECEIPTS]['items']):
        return state, False
    at = now.isoformat()
    if payload['decision'] == 'remove_covered':
        selected = payload.get('items')
        if not isinstance(selected, list) or not 1 <= len(selected) <= 500:
            raise ValueError('Selecciona las tarjetas agrupadas que deseas retirar')
        current = eligible(state, now, include_covered=True)
        removed = []
        seen = set()
        # Stale selections are reported and skipped, never applied to newer cards.
        for member in selected:
            ident = str(member.get('id') or '')
            if ident in seen:
                continue
            seen.add(ident)
            row = current.get(ident)
            if not row or revision(row) != member.get('revision') or not is_covered(row):
                continue
            for path, field in ((MANUAL, 'items'), (REQUESTS, 'requests')):
                for original in state[path][field]:
                    if original.get('id') == ident and revision(original) == revision(row):
                        original.update(status='deleted', telegram_package_status='deleted',
                                        deleted_at=at, decision_source='listas_grouping_cleanup')
                state[path]['updated_at'] = at
            state[DECISIONS]['items'] = [x for x in state[DECISIONS]['items']
                                         if x.get('id') != ident]
            state[DECISIONS]['items'].append({'id': ident, 'revision': revision(row),
                                              'status': 'deleted', 'updated_at': at,
                                              'source': 'listas_grouping_cleanup'})
            removed.append(ident)
        state[DECISIONS]['updated_at'] = at
        receipt(state, payload, 'applied' if removed else 'rejected', at, removed_ids=removed,
                skipped_count=len(selected)-len(removed),
                **({} if removed else {'error': 'Ninguna tarjeta seleccionada sigue agrupada y vigente; actualiza Listas'}))
        return state, True
    active = next((x for x in state[REQUESTS]['requests'] if x.get('listas_grouping_request')
                   and x.get('status') in {'preparing', 'update'}), None)
    if active:
        receipt(state, payload, 'rejected', at, error='Ya hay una agrupación en curso; espera a que termine antes de enviar tu selección')
        return state, True
    current = eligible(state, now)
    selected = payload.get('items')
    if not isinstance(selected, list) or not 2 <= len(selected) <= 500:
        receipt(state, payload, 'rejected', at, error='Selecciona al menos dos tendencias concretas de Listas')
        return state, True
    ids = [str(x.get('id') or '') for x in selected]
    if len(set(ids)) != len(ids) or any(x['id'] not in current or revision(current[x['id']]) != x.get('revision') for x in selected):
        receipt(state, payload, 'rejected', at, error='La selección ha cambiado; actualiza Listas y selecciona de nuevo')
        return state, True
    current = {ident: current[ident] for ident in ids}
    if len(current) < 2:
        receipt(state, payload, 'rejected', at, error='Se necesitan al menos dos tendencias en Listas sin cubrir')
        return state, True
    if len(current) > 500:
        receipt(state, payload, 'rejected', at, error='Demasiadas tarjetas para una sola revisión; retira primero las antiguas')
        return state, True
    job = {'id': 'listas-grouping-'+rid, 'revision': 0, 'name': 'Agrupar tendencias de Listas',
           'rank': 0, 'status': 'preparing', 'requested_at': at,
           'request_source': 'ttactualidad_group_listas', 'task': 'group_listas',
           'listas_grouping_request': True, 'grouping_state': 'pending',
           'grouping_candidates': [snapshot(x) for x in current.values()],
           'auto_queued': False, 'with_image': False, 'disable_ai_image': True,
           'rewrite_instruction': 'Agrupa exclusivamente las tarjetas seleccionadas en grouping_candidates. Crea UNA ficha conjunta por acontecimiento comprobado. Conserva íntegros los textos de las originales; solo marca su cobertura. No publiques.'}
    state[REQUESTS]['requests'].append(job)
    state[REQUESTS]['updated_at'] = at
    state[QUEUE]['items'].append(copy.deepcopy(job))
    state[QUEUE]['updated_at'] = at
    state[QUEUE]['count'] = len(state[QUEUE]['items'])
    receipt(state, payload, 'applied', at, grouping_job_id=job['id'], candidate_count=len(current))
    return state, True


def weighted_length(value):
    # X's configured single-weight Unicode ranges, URLs occupy 23 characters.
    value = re.sub(r'https?://\S+', 'x'*23, value)
    return sum(1 if ord(c) <= 0x10ff or 0x2000 <= ord(c) <= 0x200d or
               0x2010 <= ord(c) <= 0x201f or 0x2032 <= ord(c) <= 0x2037 else 2 for c in value)


def apply_result(state, command, now):
    state = copy.deepcopy(state)
    job_id = str(command.get('job_id') or '')
    job = next((x for x in state[REQUESTS]['requests'] if x.get('id') == job_id
                and x.get('listas_grouping_request')), None)
    if not job:
        raise ValueError('Solicitud de agrupación inexistente')
    result_digest = digest(json.dumps(command, sort_keys=True, ensure_ascii=False))
    if job.get('grouping_result_digest') == result_digest:
        return state, False
    if job.get('status') not in {'preparing', 'update'}:
        raise ValueError('Esta solicitud ya terminó o fue cancelada')
    groups = command.get('groups')
    if not isinstance(groups, list):
        raise ValueError('Falta groups (puede ser [] si no hay coincidencias)')
    candidates = {x['id']: x for x in job['grouping_candidates']}
    current = eligible(state, now)
    used = set()
    planned = []
    skipped = []
    for group in groups:
        members = group.get('members')
        text = str(group.get('explanation') or '').strip()
        closer = str(group.get('closer_text') or '').strip()
        name = str(group.get('name') or '').strip()
        sources = group.get('verification_sources')
        if not isinstance(members, list) or len(members) < 2:
            raise ValueError('Cada grupo debe cubrir al menos dos tarjetas')
        if not name or not text.startswith('TT#') or weighted_length(text) >= 280:
            raise ValueError('Explicación conjunta vacía, sin TT# o demasiado larga')
        if closer and (not closer.startswith('🌶️ ') or not text.endswith(closer) or text.count(closer) != 1):
            raise ValueError('Remate conjunto no válido')
        if not str(group.get('reason') or '').strip() or not isinstance(sources, list) or not sources or not all(
                isinstance(x, dict) and str(x.get('url') or '').startswith('https://') for x in sources):
            raise ValueError('El acontecimiento común requiere motivo y fuentes verificadas')
        refs = []
        stale = False
        for member in members:
            ident = str(member.get('id') or '')
            if ident in used or ident not in candidates or member.get('revision') != candidates[ident]['revision']:
                raise ValueError('Miembro repetido, inventado o revisión fuera de la solicitud')
            used.add(ident)
            old = candidates[ident]
            row = current.get(ident)
            if (not row or revision(row) != old['revision'] or row.get('explained_at') != old.get('explained_at')
                    or digest(row['explanation']) != old['explanation_sha256']):
                stale = True
            refs.append(old)
        if stale:
            skipped.append([x['id'] for x in refs])
            continue  # Never partially cover a group after a deletion/rework.
        planned.append((group, refs))
    coverage = []
    published = {x['id']: x for x in maintenance.published_context(state, now, grouping_api())} if job.get('automatic_grouping') else {}
    historical = {x['id']: x for x in job.get('published_context', [])}
    for link in command.get('covered_by_existing', []):
        member = link.get('member') or {}
        ident = member.get('id')
        target = str(link.get('published_id') or '')
        if ident in used or ident not in candidates or member.get('revision') != candidates[ident]['revision']:
            raise ValueError('Cobertura publicada fuera de la solicitud o repetida')
        if (target not in published or target not in historical
                or published[target]['revision'] != historical[target]['revision']
                or published[target].get('explained_at') != historical[target].get('explained_at')
                or published[target]['explanation_sha256'] != historical[target]['explanation_sha256']):
            raise ValueError('Publicación de cobertura obsoleta o inexistente')
        if not str(link.get('reason') or '').strip() or link.get('no_material_changes') is not True:
            raise ValueError('La cobertura previa requiere motivo y ausencia explícita de novedades')
        row = current.get(ident)
        if (row and revision(row) == member['revision'] and row.get('explained_at') == candidates[ident].get('explained_at')
                and digest(row['explanation']) == candidates[ident]['explanation_sha256']):
            coverage.append((row, published[target]))
        used.add(ident)
    at = now.isoformat()
    created = []
    for group, refs in planned:
        ident = 'listas-joint-'+digest(job_id+'|'+ '|'.join(sorted(x['id']+':'+str(x['revision']) for x in refs)))[:16]
        if ident in latest(state[MANUAL]['items']) or ident in latest(state[REQUESTS]['requests']):
            raise ValueError('La ficha conjunta ya existe con otra solicitud')
        positive_ranks = [x['rank'] for x in refs if x['rank'] > 0]
        text = str(group['explanation']).strip()
        row = {'id': ident, 'revision': 0, 'name': group['name'].strip(),
               'rank': min(positive_ranks) if positive_ranks else 0, 'status': 'explained',
               'explanation': text, 'closer_text': str(group.get('closer_text') or '').strip(),
               'explained_at': at, 'requested_at': at, 'updated_at': at,
               'listas_group_role': 'joint', 'listas_group_members': [{'id': x['id'], 'revision': x['revision']} for x in refs],
               'trend_names': [x['name'] for x in refs], 'group_title': group['name'].strip(),
               'verification_sources': group['verification_sources'], 'grouping_reason': group['reason'],
               'grouping_request_id': job_id, 'source': 'listas_grouping_editorial',
               'auto_queued': False, 'with_image': True, 'disable_ai_image': False,
               'image_strategy': 'ai_plus_fallback', 'ai_image_status': 'pending'}
        maintenance.clear({MANUAL: {'items': [row]}, REQUESTS: {'requests': []}}, row, at)
        direct_ids = {x['id'] for x in refs}
        for path, field in ((MANUAL, 'items'), (REQUESTS, 'requests')):
            for original in state[path][field]:
                direct = any(original.get('id') == x['id'] and revision(original) == x['revision'] for x in refs)
                descendant = is_covered(original) and original.get('covered_by_id') in direct_ids
                if (direct or descendant) and original.get('status') == 'explained':
                    original.update(listas_group_role='covered', covered_by_id=ident,
                                    covered_by_revision=0, covered_by_name=row['name'],
                                    covered_source_revision=revision(original), covered_at=at, grouping_request_id=job_id)
            state[path][field].append(copy.deepcopy(row))
            state[path]['updated_at'] = at
        created.append(ident)
    for row, target in coverage:
        maintenance.stamp_rows(state, row, listas_group_role='covered', covered_by_id=target['id'],
                               covered_by_name=target['name'], covered_by_revision=target['revision'],
                               covered_source_revision=revision(row), covered_at=at,
                               coverage_reason='already_published_same_event', grouping_request_id=job_id)
    # Release only unchanged snapshot rows. New arrivals wait for the next pass.
    for ident, old in candidates.items():
        row = current.get(ident)
        if (row and revision(row) == old['revision'] and row.get('explained_at') == old.get('explained_at')
                and digest(row['explanation']) == old['explanation_sha256']):
            maintenance.clear(state, row, at)
    # No changes to source explanations, dates, revision, publication history.
    job.update(status='grouping_completed', grouping_state='completed', completed_at=at,
               grouping_created_ids=created, grouping_skipped_stale=skipped,
               grouping_result_digest=result_digest)
    state[REQUESTS]['updated_at'] = at
    state[QUEUE]['items'] = [x for x in state[QUEUE]['items'] if not (x.get('id') == job_id and revision(x) == revision(job))]
    state[QUEUE]['count'] = len(state[QUEUE]['items'])
    state[QUEUE]['updated_at'] = at
    return state, True


def grouping_api():
    from types import SimpleNamespace
    return SimpleNamespace(**{name: globals()[name] for name in (
        'eligible', 'latest', 'moment', 'snapshot', 'revision', 'is_covered',
        'terminal_applies', 'digest', 'weighted_length')})


def load_state():
    result = {}
    for path in (MANUAL, REQUESTS, QUEUE, DECISIONS, DELIVERIES, RECEIPTS):
        result[path] = json.loads((ROOT/path).read_text(encoding='utf-8'))
        field = 'requests' if path == REQUESTS else 'items'
        if not isinstance(result[path].get(field), list):
            raise ValueError('Estado obligatorio no válido: '+path)
    result[maintenance.RECENT] = json.loads((ROOT/maintenance.RECENT).read_text(encoding='utf-8'))
    return result


def main():
    state = load_state()
    before = copy.deepcopy(state)

    # One-shot editorial consistency repair: remove an insensitive closer from
    # the already-applied DANA maintenance update. Exact id/revision/text
    # guards make this idempotent and prevent touching any later edit.
    correction_id = 'trend-update-07dc8165892e5d9a6b62'
    correction_rev = 0
    old_closer = '🌶️ Dos años después, el recuento aún se mueve.'
    wrong_text = ('TT#12 Dana sigue siendo tendencia por el segundo aniversario en Valencia: '
                  'la jueza elevó a 234 las víctimas mortales tras reconocer el fallecimiento '
                  'de un vecino de Paiporta.\\\\n#DANA #Valencia')
    clean_text = ('TT#12 Dana sigue siendo tendencia por el segundo aniversario en Valencia: '
                  'la jueza elevó a 234 las víctimas mortales tras reconocer el fallecimiento '
                  'de un vecino de Paiporta.\\n#DANA #Valencia')
    for path, field in ((REQUESTS, 'requests'), (maintenance.MANUAL, 'items')):
        for row in state[path][field]:
            if (row.get('id') == correction_id
                    and int(row.get('revision') or 0) == correction_rev
                    and (row.get('closer_text') == old_closer
                         or row.get('explanation') == wrong_text)):
                row['explanation'] = clean_text
                row['closer_text'] = ''
                row['editorial_grouping_state'] = 'cleared'
                row['editorial_grouping_fingerprint'] = maintenance.fingerprint(row)
    now = datetime.now(timezone.utc)
    payload = json.loads(os.environ.get('TT_LISTAS_GROUP_JSON') or '{}')
    if payload:
        try:
            state, _ = request(state, payload, now)
        except ValueError as error:
            if not UUID.fullmatch(str(payload.get('request_id') or '')):
                raise
            receipt(state, payload, 'rejected', now.isoformat(), error=str(error))
    for path in sorted((ROOT/'trends/listas-grouping-outbox').glob('*.json')):
        command = json.loads(path.read_text(encoding='utf-8'))
        job = next((x for x in state[REQUESTS]['requests'] if x.get('id') == command.get('job_id')), {})
        if job.get('status') not in {'preparing', 'update'}:
            continue
        command_digest = digest(json.dumps(command, sort_keys=True, ensure_ascii=False))
        if job.get('grouping_error_digest') == command_digest:
            continue
        try:
            state, _ = apply_result(state, command, now)
        except ValueError as error:
            # Persist the failure under the exact input. Other actions still
            # receive their ACK; the editor may correct this SAME outbox.
            job['grouping_state'] = 'needs_correction'
            job['grouping_error'] = str(error)
            job['grouping_error_digest'] = command_digest
    for path in sorted((ROOT/'trends/maintenance-outbox').glob('*.json')):
        command = json.loads(path.read_text(encoding='utf-8'))
        job = next((x for x in state[REQUESTS]['requests'] if x.get('id') == command.get('job_id')), {})
        if job.get('status') not in {'preparing', 'update'}:
            continue
        try:
            state, _ = maintenance.apply_review(state, command, now, grouping_api())
        except ValueError as error:
            job['review_error'] = str(error)
    for path in sorted((ROOT/'trends/anticipation-outbox').glob('*.json')):
        command = json.loads(path.read_text(encoding='utf-8'))
        job = next((x for x in state[REQUESTS]['requests'] if x.get('id') == command.get('job_id')), {})
        if job.get('status') not in {'preparing', 'update'} or not job.get('anticipation_request'):
            continue
        try:
            state[REQUESTS], _ = anticipation.apply_result(state[REQUESTS], command, now)
        except ValueError as error:
            job['anticipation_error'] = str(error)
    completed_early = {x['id'] for x in state[REQUESTS]['requests']
                       if x.get('anticipation_request') and x.get('status') not in {'preparing', 'update'}}
    previous_count = len(state[QUEUE]['items'])
    state[QUEUE]['items'] = [x for x in state[QUEUE]['items'] if x.get('id') not in completed_early]
    if len(state[QUEUE]['items']) != previous_count:
        state[QUEUE]['updated_at'] = now.isoformat()
    state[QUEUE]['count'] = len(state[QUEUE]['items'])
    maintenance.schedule(state, now, grouping_api())
    changed = []
    for path, doc in state.items():
        if doc != before[path]:
            (ROOT/path).write_text(json.dumps(doc, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
            changed.append(path)
    print('TT_LISTAS_GROUPING', json.dumps({'changed': changed, 'request_id': payload.get('request_id')}, ensure_ascii=False))


if __name__ == '__main__':
    main()
