"""Entry point for GitHub Actions. Never accept a workflow path from the request."""
from __future__ import annotations
import os
import re
import subprocess

ALLOWED = {
    'ttittulares.radar': 'radar-no-d1.yml',
    'ttittulares.images': 'repair-ttittulares-listas.yml',
    'ttendencias.radar': 'ttendencias-refresh.yml',
    'ttendencias.images': 'repair-ttendencias-explicadas.yml',
    'ttactualidad.tests': 'ttactualidad-v8-tests.yml',
    'selorecordamos.health': 'tt-slr-health-verification.yml',
    'selorecordamos.telegram': 'selorecordamos-telegram-delivery-tests.yml',
    'raineta.radar': 'raineta-radar-feasibility.yml',
    'raineta.website': 'rain-static-ci.yml',
}
UUID_RE = re.compile(r'^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',re.I)

def execute(target: str,request_id: str,repo: str,run=subprocess.run):
    if target not in ALLOWED: raise ValueError('Target no autorizado: '+repr(target))
    if not UUID_RE.fullmatch(request_id):raise ValueError('Request ID inválido')
    if repo!='fabricelop/europapress-rss':raise ValueError('Repositorio no esperado')
    filename=ALLOWED[target]
    args=['gh','workflow','run',filename,'--repo',repo,'--ref','main']
    result=run(args,check=True,text=True,capture_output=True,timeout=45)
    print('RC_DISPATCH_ACCEPTED',target,request_id,filename,flush=True)
    print('RC_NOTICE: Dispatch does not prove that the repair workflow succeeded.',flush=True)
    return result

if __name__=='__main__':
    execute(os.environ['RC_TARGET'],os.environ['RC_REQUEST_ID'],os.environ['GITHUB_REPOSITORY'])
