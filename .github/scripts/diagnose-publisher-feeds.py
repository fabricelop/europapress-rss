"""Diagnostic-only: publisher feeds vs Google News fallback (no state writes)."""
import concurrent.futures, urllib.request, urllib.error, re, json, sys
from datetime import datetime, timezone
from html.parser import HTMLParser
sys.path.insert(0,"telegram")
from source_publication import feed_publication, article_publication

URLS={
 "COPE":[
  "https://www.cope.es/rss/home.xml",
  "https://www.cope.es/",
  "https://www.cope.es/actualidad/",
 ],
 "EFE":[
  "https://efe.com/espana/feed/","https://efe.com/feed/","https://efe.com/espana/","https://efe.com/"
 ],
 "EFE Deportes":[
  "https://efe.com/deportes/feed/","https://efe.com/deportes/"
 ],
 "HuffPost":[
  "https://www.huffingtonpost.es/feeds/index.xml","https://www.huffingtonpost.es/"
 ],
 "Telecinco":[
  "https://www.telecinco.es/noticias/","https://www.telecinco.es/rss/","https://www.telecinco.es/rss.xml"
 ],
 "Cuatro":[
  "https://www.cuatro.com/noticias/","https://www.cuatro.com/rss/","https://www.cuatro.com/rss.xml"
 ],
 "AS":[
  "https://as.com/ultimas-noticias/","https://as.com/rss/","https://as.com/rss-de-ascom-n/","https://as.com/rss/portada.xml","https://feeds.as.com/mrss-s/pages/as/site/as.com/section/futbol/portada/",
 ],
 "Reuters":[
  "https://www.reuters.com/arc/outboundfeeds/rss/",
 ],
 "AP":[
  "https://apnews.com/",
 ],
 "Público Tremending":[
  "https://www.publico.es/tremending/",
 ],
}
class Links(HTMLParser):
 def __init__(self):super().__init__();self.urls=[]
 def handle_starttag(self,tag,attrs):
  if tag=="a":
   a=dict(attrs)
   if a.get("href"):self.urls.append(a["href"])
def probe(label,url):
 try:
  q=urllib.request.Request(url,headers={
   "User-Agent":"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/151 Safari/537.36",
   "Accept":"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
   "Accept-Language":"es-ES,es;q=0.9,en;q=0.7",
  })
  with urllib.request.urlopen(q,timeout=9) as f:
   body=f.read(900000).decode("utf-8","ignore");final=f.geturl();type=f.headers.get("content-type","")
  blocks=re.findall(r"<(?:item|entry)\b[\s\S]*?</(?:item|entry)>",body,re.I)
  dates=[feed_publication(b) for b in blocks[:5]]
  news=[(feed_publication(b),re.search(r"<link[^>]*>([\s\S]*?)</link>",b,re.I).group(1).strip())
        for b in blocks if re.search(r"<link[^>]*>([\s\S]*?)</link>",b,re.I)
        and "/noticias/" in re.search(r"<link[^>]*>([\s\S]*?)</link>",b,re.I).group(1)]
  news=[x for x in news if x[0]]
  links=Links();links.feed(body)
  from urllib.parse import urljoin,urlparse
  host=urlparse(final).hostname
  own=[urljoin(final,x) for x in links.urls if urlparse(urljoin(final,x)).hostname in [host,"www."+host if host else ""]]
  sample=[x for x in own if len(urlparse(x).path.split("/"))>=4][:5]
  result={"source":label,"requested":url,"final":final,"http":"OK","type":type[:50],"bytes":len(body),"items":len(blocks),"feed_dates":dates,"links":len(links.urls),"sample_links":sample[:3],"page_own_meta":article_publication(body),"first_item":blocks[0][:380] if blocks else None,"news_articles":len(news),"latest_news":sorted(news,reverse=True)[:2],"rss_links":[x for x in links.urls if (".xml" in x or "rss" in x or "/feed" in x)][:18]}
  return result
 except Exception as e:
  return {"source":label,"requested":url,"error":str(e)[:180]}
queries=[(n,u) for n,urls in URLS.items() for u in urls]
with concurrent.futures.ThreadPoolExecutor(max_workers=10) as ex:
 for result in ex.map(lambda a:probe(*a),queries):
  print("SOURCE_PROBE",json.dumps(result,ensure_ascii=False))
