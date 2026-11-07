#!/usr/bin/env python3
"""Read-only diagnosis for approved AI image redirects; no Buffer API calls."""
import hashlib
import json
import sys
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ttactualidad_buffer_publish as pub

TARGET = "1edd6ef875e4"
def main():
    source = json.loads((Path(__file__).resolve().parents[1] / "trends/telegram-manual-explained.json").read_text())
    rows = [x for x in source.get("items",[]) if x.get("id")==TARGET and x.get("revision")==0]
    print("episode_count",len(rows))
    if len(rows)!=1:
        return
    row=rows[0]
    candidates = pub.approved_catalog_candidates("ttendencias",TARGET,0,row.get("explanation"),row.get("explained_at"))
    mirror = json.loads((Path(__file__).resolve().parents[1] / "trends/site-ai-images.json").read_text())
    gh = [x for x in mirror.get("images",[]) if x.get("target_id")==TARGET and x.get("revision")==0]
    print("approved_catalog_candidates",len(candidates),"github_mirror_count",len(gh))
    for idx,entry in enumerate(candidates+gh):
        image_url=entry.get("image_url") or ""
        expected=entry.get("sha256") or ""
        try:
            verified=pub.check_image(image_url,expected,"ttendencias",TARGET,0)
            print("actual_publisher_IA_preflight","PASS","canonical_host",urlparse(verified).hostname)
        except Exception as exc:
            print("actual_publisher_IA_preflight","FAILED",type(exc).__name__,str(exc)[:95])
            raise
        try:
            original=urlparse(image_url)
            with urlopen(Request(image_url,headers={"User-Agent":"TTActualidad-BufferPublisher/1"}),timeout=25) as response:
                final=urlparse(response.geturl())
                data=response.read(12*1024*1024+1)
                print(json.dumps({
                    "candidate_index":idx,
                    "origin_host":original.hostname,
                    "final_scheme":final.scheme,
                    "final_host":final.hostname,
                    "redirected":final.geturl()!=image_url,
                    "path_matches_exact_episode":final.path.startswith("/images/ttendencias/"+TARGET+"-r0-"),
                    "final_path_has_extension":final.path.endswith(".png"),
                    "final_has_query":bool(final.query),
                    "mime":response.headers.get_content_type(),
                    "sha_match":hashlib.sha256(data).hexdigest()==expected.lower(),
                    "byte_count":len(data),
                    "oversize":len(data)>12*1024*1024,
                }))
        except Exception as exc:
            print("candidate",idx,"error",type(exc).__name__,str(exc)[:80].split("?")[0])
if __name__=="__main__":
    main()
