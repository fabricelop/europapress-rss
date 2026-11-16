"""Provision a private news-only auth seed from an idle authenticated V2 profile.

This copies credentials locally on the same Windows account. No browser opens;
no cookies/tokens are written to GitHub. A running source is never copied.
"""
import argparse
import json
import os
from pathlib import Path

from .editorial_browser_v2 import clone_job_profile, common, write_private


def prepare(root, sources, chrome, *, find_pids=None):
    root = Path(root).resolve()
    root.mkdir(parents=True, exist_ok=True)
    seed = root / 'AuthSeed'
    marker = seed / 'news-auth-seed.complete'
    finder = find_pids or common('chrome_profile_process_v2').exact_chrome_profile_pids
    if seed.exists() and not marker.is_file():
        raise RuntimeError('NEWS_SEED_INCOMPLETE_REVIEW_LOCAL_COPY')
    if not seed.exists():
        eligible = [Path(p) for p in sources if (Path(p) / 'Local State').is_file() and not finder(Path(p))]
        if not eligible:
            raise RuntimeError('NEWS_NO_IDLE_V2_AUTH_PROFILE_USE_SEED_SOURCE')
        clone_job_profile(eligible[0], seed, find_pids=finder)
        marker.write_text('TTN2_LOCAL_AUTH_SEED_COMPLETE\n', encoding='utf-8')
    write_private(root / 'settings.json', {'project': 'ttittulares-v2', 'workers': 3,
                                         'seed_profile': str(seed), 'chrome': str(Path(chrome))})
    return {'project': 'ttittulares-v2', 'seed_ready': True, 'browser_opened': False,
            'chatgpt_auth_verified': False}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--seed-source', type=Path)
    parser.add_argument('--chrome', type=Path, required=True)
    args = parser.parse_args()
    trends = Path(os.environ['LOCALAPPDATA']) / 'TTActualidadV2'
    sources = [args.seed_source] if args.seed_source else [trends / 'ChromeProfile'] + [
        trends / ('ChromeProfile-Parallel-%02d' % i) for i in range(1, 6)]
    print(json.dumps(prepare(args.root, sources, args.chrome)))


if __name__ == '__main__': main()
