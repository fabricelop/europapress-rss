# TTActualidad Desktop for Windows. GitHub is the only editorial authority.
# No Cloudflare, local web server, Telegram or continuously running service.
from __future__ import annotations
import concurrent.futures, datetime as dt, hashlib, json, os, pathlib, threading, time, unicodedata, urllib.error, urllib.parse, urllib.request, uuid, webbrowser
import tkinter as tk
from tkinter import ttk, messagebox, simpledialog
import keyring

REPO = "fabricelop/europapress-rss"
RAW = "https://raw.githubusercontent.com/" + REPO + "/main/"
API = "https://api.github.com/repos/" + REPO + "/dispatches"
STORE = pathlib.Path(os.environ.get("APPDATA") or pathlib.Path.home()) / "TTActualidad"
CONFIG = STORE / "desktop.json"
KEYRING_SERVICE = "TTActualidad.Windows.GitHub"
FILES = {
    "prepared":"ttittulares/prepared.json",
    "decisions":"ttittulares/decisions.json",
    "status":"ttittulares/status.json",
    "news_queue":"ttittulares/editorial-queue.json",
    "tremending":"ttittulares/tremending/items.json",
    "recent":"trends/recent.json",
    "manual":"trends/telegram-manual-explained.json",
    "trend_prepared":"trends/prepared.json",
    "requests":"trends/requests.json",
    "deliveries":"trends/telegram-image-deliveries.json",
    "trend_decisions":"trends/mobile-decisions.json",
    "trend_queue":"trends/editorial-queue.json",
    "pub_events":"pilot/ttactualidad-publication-events.json",
    "action_receipts":"pilot/ttactualidad-action-receipts.json",
    "explained":"trends/explained.json",
}
TERMINAL = {"published","deleted","dismissed","removed","delete_pending"}
NEWS_ACTIVE = {"PROCESSING","UPDATE_PROCESSING"}
TREND_ACTIVE = {"preparing","update"}

def request(url, method="GET", data=None, token="", form=False, timeout=17):
    headers = {"Accept":"application/json", "User-Agent":"TTActualidad-Windows/0.1"}
    if token:
        headers["Authorization"] = "Bearer " + token
    if data is not None:
        if form:
            payload = urllib.parse.urlencode(data).encode("utf-8")
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            payload = json.dumps(data, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
    else:
        payload = None
    req = urllib.request.Request(url, data=payload, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as response:
        content = response.read()
        return response.status, (json.loads(content.decode("utf-8")) if content else {})

def date(value):
    try:
        parsed = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=dt.timezone.utc)
    except (ValueError, TypeError):
        return None

def text(v):
    return str(v or "").strip()

def norm(value):
    value=unicodedata.normalize("NFD", text(value).casefold())
    value="".join(c for c in value if unicodedata.category(c)!="Mn")
    return " ".join(value.split())

def archive_url(docs,project,event_id,revision,raw):
    url=(docs.get("archive_photos") or {}).get(
        project+":"+text(event_id)+":r"+str(revision))
    if url:
        return url
    raw=text(raw)
    if not raw.startswith("https://"):
        return ""
    path=raw.lower()
    if ("chatgpt.com" in path or "generated-images" in path
            or "ai-image" in path or "/images/ai/" in path):
        return ""
    return raw

def latest_rows(items, key):
    latest = {}
    for item in items or []:
        if not isinstance(item, dict):
            continue
        ident = text(item.get(key))
        if not ident:
            continue
        other = latest.get(ident)
        if other is None or (int(item.get("revision") or 0), str(item.get("updated_at") or item.get("explained_at") or "")) >= (int(other.get("revision") or 0), str(other.get("updated_at") or other.get("explained_at") or "")):
            latest[ident] = item
    return latest

def rows(d, key="items"):
    data = d.get(key, []) if isinstance(d, dict) else []
    return data if isinstance(data, list) else []

def confirmed_terminals(docs):
    """Only GitHub-confirmed terminal outcomes, never local optimistic actions.

    Receipts cover the brief interval between Actions accepting an operation
    and the editorial decision ledger being visible. The revision matters:
    an older closure must never hide a new editorial revision.
    """
    marks = {}
    def add(project, identifier, revision, state, at):
        if state not in {"published", "deleted", "dismissed", "discard"}:
            return
        if project not in {"ttittulares", "ttendencias"}:
            return
        identifier = text(identifier)
        if not identifier:
            return
        try:
            rev = int(revision or 0)
        except (TypeError, ValueError):
            return
        key = (project, identifier)
        current = marks.get(key)
        stamp = date(at)
        if current is None or rev > current["revision"] or (
                rev == current["revision"] and (stamp or dt.datetime.min.replace(
                    tzinfo=dt.timezone.utc)) > (current["at"] or dt.datetime.min.replace(
                        tzinfo=dt.timezone.utc))):
            marks[key] = {"revision": rev, "at": stamp}
    for row in rows(docs.get("decisions", {})):
        add("ttittulares", row.get("event_id"), row.get("revision"),
            text(row.get("status")).lower(),
            row.get("published_at") or row.get("deleted_at") or row.get("updated_at"))
    for row in rows(docs.get("trend_decisions", {})):
        add("ttendencias", row.get("id") or row.get("event_id"),
            row.get("revision"), text(row.get("status")).lower(),
            row.get("published_at") or row.get("deleted_at") or row.get("updated_at"))
    for doc, list_key in (("manual", "items"), ("requests", "requests")):
        for row in rows(docs.get(doc, {}), list_key):
            add("ttendencias", row.get("id"), row.get("revision"),
                text(row.get("status")).lower(),
                row.get("published_at") or row.get("deleted_at") or row.get("updated_at"))
    for row in rows(docs.get("action_receipts", {})):
        if text(row.get("status")).lower() not in {"applied", "already_applied"}:
            continue
        add(text(row.get("project")), row.get("event_id"),
            row.get("revision"), text(row.get("decision")).lower(), row.get("at"))
    return marks


def terminal_applies(marks, project, identifier, revision, episode_at=None):
    mark = marks.get((project, text(identifier)))
    if not mark:
        return False
    rev = int(revision or 0)
    if rev > mark["revision"]:
        return False
    # A trend ID/revision may be reused in a new editorial episode.
    if project == "ttendencias" and rev == mark["revision"]:
        episode = date(episode_at)
        if episode and mark["at"] and episode > mark["at"] + dt.timedelta(seconds=60):
            return False
    return True


def is_listas_covered(row):
    return (row.get("listas_group_role")=="covered" and bool(row.get("covered_by_id"))
            and int(row.get("covered_source_revision",row.get("revision") or 0))==int(row.get("revision") or 0))


def normalise(docs):
    prepared = rows(docs["prepared"])
    marks = confirmed_terminals(docs)
    def is_news_closed(item):
        return terminal_applies(marks, "ttittulares",
                                item.get("event_id") or item.get("id"),
                                item.get("revision"))
    ready_news = []
    for item in prepared:
        ident = text(item.get("event_id"))
        if not ident or is_news_closed(item) or item.get("rewrite_pending") is True:
            continue
        tweet = item.get("tweet") or {}
        archive = item.get("archive_image") or item.get("fallback_image") or {}
        ready_news.append({"project":"ttittulares","id":ident,"revision":int(item.get("revision") or 0),
            "title":text(item.get("title")), "body":text(tweet.get("text")) or text(item.get("explanation") or item.get("factual_summary")),
            "state":"Listas", "category":"Noticias", "source":text(item.get("url")),
            "image":archive_url(docs,"ttittulares",ident,item.get("revision") or 0,archive.get("url"))})
    active = [x for x in rows(docs["news_queue"]) if text(x.get("status")).upper() in NEWS_ACTIVE]
    if not active:
        active = rows(docs["status"], "processing_items")
    active_ids = {text(x.get("event_id")) for x in active}
    def news_section(items, label):
        output = []
        for x in items:
            ident = text(x.get("event_id") or x.get("id"))
            if not ident or is_news_closed(x) or text(x.get("status")).lower() in TERMINAL or (label!="En elaboración" and ident in active_ids):
                continue
            output.append({"project":"ttittulares","id":ident,"revision":int(x.get("revision") or 0),
                "title":text(x.get("title") or x.get("name")), "body":text(x.get("explanation") or x.get("factual_summary")),
                "state":label, "category":"Noticias", "source":text(x.get("url")), "image":""})
        return output
    news = ready_news + news_section(active,"En elaboración")
    news += news_section(rows(docs["status"],"problematic_items"),"Revisión")
    news += news_section(rows(docs["status"],"three_source_items"),"Creciendo")
    news += news_section(rows(docs["tremending"]),"Tremending")

    requests = latest_rows(rows(docs["requests"],"requests"),"id")
    manual = latest_rows(rows(docs["manual"]),"id")
    delivered = latest_rows(rows(docs["deliveries"]),"event_id")
    staged = latest_rows(rows(docs["trend_prepared"]),"id")
    closures = latest_rows(rows(docs["trend_decisions"]),"id")
    trend_queue = rows(docs["trend_queue"])
    now = dt.datetime.now(dt.timezone.utc)
    trend_ready = []
    for ident,x in manual.items():
        if text(x.get("status")).lower() != "explained" or not text(x.get("explanation")):
            continue
        leader = text(x.get("group_leader_id"))
        if leader and leader != ident:
            continue
        rev = int(x.get("revision") or 0)
        if terminal_applies(marks, "ttendencias", ident, rev, x.get("explained_at")):
            continue
        explained = date(x.get("explained_at"))
        if not explained or not -3600 <= (now - explained).total_seconds() <= 48*3600:
            continue
        req = requests.get(ident,{})
        if int(req.get("revision") or 0) > rev:
            continue
        # The iPhone checks BOTH the explanation and the request. A terminal
        # request takes precedence over the older explained snapshot.
        if any(text(z.get("status")).lower() in TERMINAL or
               text(z.get("telegram_package_status")).lower() in TERMINAL
               for z in (x,req)):
            continue
        requested=date(req.get("requested_at"))
        if (text(req.get("status")).lower() in {"preparing","update","ready"}
                and requested and explained < requested - dt.timedelta(seconds=60)):
            continue
        newer_work = any(text(q.get("id"))==ident and text(q.get("status")).lower() in TREND_ACTIVE
                         and int(q.get("revision") or 0)>rev for q in trend_queue)
        if newer_work:
            continue
        removal = closures.get(ident,{})
        delivery = delivered.get(ident,{})
        if any(text(k.get("status")).lower() in TERMINAL and int(k.get("revision") or 0)>=rev for k in (removal,delivery)):
            continue
        trend_ready.append({"project":"ttendencias","id":ident,"revision":rev,"title":text(x.get("name") or req.get("name")),
            "body":text(x.get("explanation")), "state":"Listas","category":"Tendencias",
            "explained_at":x.get("explained_at"),
            "source":text(x.get("source_url")),
            "image":archive_url(docs,"ttendencias",ident,rev,
                                (x.get("archive_image") or x.get("fallback_image") or {}).get("url")
                                or x.get("archive_image_url")),
            "rank":int(x.get("rank") or req.get("rank") or 0),
            "covered_by_id":text(x.get("covered_by_id")) if is_listas_covered(x) else "",
            "covered_by_name":text(x.get("covered_by_name")) if is_listas_covered(x) else "",
            "is_joint_group":x.get("listas_group_role")=="joint"})
    trend_ready.sort(key=lambda row: (
        row['rank'] if row['rank'] > 0 else float('inf'),
        bool(row.get('covered_by_id')),
        -(date(row.get('explained_at')) or now).timestamp(), row['id']))
    # Listas uses the SAME authoritative manual ledger as iPhone.
    # Staged-only prepared snapshots are intentionally not promoted to Listas.
    readyIDs = {x["id"] for x in trend_ready}
    # iOS: both requests and the queue can contain a live preparing/update.
    work_by_id={}
    for x in rows(docs["requests"],"requests")+trend_queue:
        ident=text(x.get("id"))
        if not ident or text(x.get("status")).lower() not in TREND_ACTIVE:
            continue
        rev=int(x.get("revision") or 0)
        if ident in readyIDs and any(y["id"]==ident and y["revision"]>=rev for y in trend_ready):
            continue
        if text(closures.get(ident,{}).get("status")).lower() in TERMINAL:
            continue
        old=work_by_id.get(ident)
        if old is None or rev>int(old.get("revision") or 0):
            work_by_id[ident]=x
    working=[]
    for ident,x in work_by_id.items():
        req=requests.get(ident,{})
        working.append({"project":"ttendencias","id":ident,"revision":int(x.get("revision") or req.get("revision") or 0),
            "title":text(x.get("name") or req.get("name") or ident),
            "body":text(x.get("explanation") or x.get("problem_reason")),
            "state":"En elaboración","category":"Tendencias","source":text(x.get("source_url")),
            "image":"","rank":int(x.get("rank") or req.get("rank") or 0)})
    # Exact Top30 ranking from the iOS radar, with editorial explanations
    # matched by normalized name (not by unverified radar id).
    recent=rows(docs["recent"])
    rank_by_number={}
    for i,x in enumerate(recent):
        rank=int(x.get("rank") or i+1)
        if 1<=rank<=30 and text(x.get("name")):
            rank_by_number[rank]=text(x["name"])
    for i,name in enumerate(docs["recent"].get("top30",[])[:30]):
        rank_by_number.setdefault(i+1,text(name))
    histories=(rows(docs["manual"])+rows(docs["explained"])+rows(docs["requests"],"requests"))
    explanations={}
    for record in histories:
        if not text(record.get("explanation")):
            continue
        names=[record.get("name"),record.get("display_name")]
        if record.get("listas_group_role") != "joint":
            names+=(record.get("trend_names") or [])
            names +=[x.get("name") for x in (record.get("trend_context") or []) if isinstance(x,dict)]
        for name in names:
            key=norm(name)
            if key:
                old=explanations.get(key)
                if old is None or str(record.get("updated_at") or record.get("explained_at") or "")>=str(old.get("updated_at") or old.get("explained_at") or ""):
                    explanations[key]=record
    request_by_name={}
    for record in rows(docs["requests"],"requests"):
        key=norm(record.get("name"))
        if key:
            old=request_by_name.get(key)
            if old is None or int(record.get("revision") or 0)>int(old.get("revision") or 0) or (
                int(record.get("revision") or 0)==int(old.get("revision") or 0)
                and str(record.get("updated_at") or record.get("requested_at") or "")>=str(old.get("updated_at") or old.get("requested_at") or "")):
                request_by_name[key]=record
    ready_names={norm(x["title"]) for x in trend_ready}
    trending=[]
    for rank in range(1,31):
        name=rank_by_number.get(rank)
        if not name:
            continue
        key=norm(name)
        exp=explanations.get(key,{})
        req=request_by_name.get(key,{})
        explanation=text(exp.get("explanation"))
        req_status=text(req.get("status")).lower()
        if req_status in {"preparing","update","ready"}:
            status="EN ELABORACIÓN"
        elif explanation:
            status="EXPLICADA"
        else:
            status="PENDIENTE" if rank<=10 else "PREPARACIÓN MANUAL"
        # When there is no editorial request, Top 11-30 uses the valid
        # server-side manual-{sha256(NFC(name))[:32]} identifier for prepare.
        ident=text(req.get("id") or exp.get("id"))
        if not ident and rank>10:
            ident="manual-"+hashlib.sha256(unicodedata.normalize("NFC",name).encode("utf-8")).hexdigest()[:32]
        archive=exp.get("archive_image") or exp.get("fallback_image") or {}
        trending.append({"project":"ttendencias","id":ident,"revision":int(req.get("revision") or exp.get("revision") or 0),
            "title":name,"body":explanation,"state":"Top 30","category":"Top 30","rank":rank,
            "source":text(req.get("source_url") or exp.get("source_url")),
            "image":archive_url(docs,"ttendencias",ident,int(req.get("revision") or exp.get("revision") or 0),archive.get("url")),
            "trend_status":status,"inListas":key in ready_names,
            "covered_by_id":text(req.get("covered_by_id")) if is_listas_covered(req) else "",
            "covered_by_name":text(req.get("covered_by_name")) if is_listas_covered(req) else ""})
    lb = now - dt.timedelta(hours=24)
    published = set()
    totals = {"ttittulares":0,"ttendencias":0}
    for x in rows(docs["pub_events"]):
        t = date(x.get("at"))
        project = text(x.get("project"))
        key = (project,text(x.get("event_id")),int(x.get("revision") or 0))
        if t and lb < t <= now and project in totals and key not in published and key[1]:
            published.add(key)
            totals[project]+=1
    return news,trend_ready+working,trending,totals

class TTActualidad(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("TTActualidad · Windows")
        self.geometry("1240x830")
        self.minsize(870,600)
        self.configure(bg="#111b2b")
        STORE.mkdir(parents=True, exist_ok=True)
        try: self.config_data=json.loads(CONFIG.read_text(encoding="utf-8"))
        except Exception: self.config_data={}
        self.docs={}
        self.items={}
        self.selected=None
        self.refreshing=False
        self.sending=False
        self.pending=set()
        self._make_ui()
        self.after(200,self.refresh)
        self.after(120000,self.refresh_timer)

    def _make_ui(self):
        top=tk.Frame(self,bg="#111b2b")
        top.pack(fill="x",padx=18,pady=(16,8))
        tk.Label(top,text="TTActualidad",font=("Segoe UI",23,"bold"),fg="#8ce2c9",bg="#111b2b").pack(side="left")
        ttk.Button(top,text="Actualizar desde GitHub",command=self.refresh).pack(side="right",padx=4)
        ttk.Button(top,text="Conectar GitHub",command=self.connect).pack(side="right",padx=4)
        ttk.Button(top,text="+ Noticia",command=self.new_story).pack(side="right",padx=4)
        self.counters=tk.StringVar(value="Sin sincronizar")
        tk.Label(self,textvariable=self.counters,bg="#172338",fg="#dbecff",font=("Segoe UI",11,"bold"),anchor="w",padx=15,pady=11).pack(fill="x",padx=16,pady=6)
        bar=tk.Frame(self,bg="#111b2b")
        bar.pack(fill="x",padx=16,pady=(4,10))
        tk.Label(bar,text="Sección",bg="#111b2b",fg="white").pack(side="left")
        self.section=tk.StringVar(value="Noticias · Listas")
        self.selector=ttk.Combobox(bar,textvariable=self.section,state="readonly",width=25,
          values=["Noticias · Listas","Noticias · En elaboración","Noticias · Revisión","Noticias · Creciendo","Noticias · Tremending",
                  "Tendencias · Top 30","Tendencias · Listas","Tendencias · En elaboración","Todas las Listas"])
        self.selector.pack(side="left",padx=8)
        self.selector.bind("<<ComboboxSelected>>",lambda _:self.render())
        self.query=tk.StringVar()
        ttk.Entry(bar,textvariable=self.query,width=45).pack(side="right",fill="x",expand=True,padx=8)
        tk.Label(bar,text="Buscar",bg="#111b2b",fg="white").pack(side="right")
        self.query.trace_add("write",lambda *_:self.render())
        content=tk.PanedWindow(self,orient="horizontal",bg="#111b2b",sashwidth=6)
        content.pack(fill="both",expand=True,padx=16,pady=4)
        left=tk.Frame(content,bg="#172338")
        right=tk.Frame(content,bg="#172338")
        content.add(left,minsize=360,width=510);content.add(right,minsize=370)
        self.table=ttk.Treeview(left,columns=("status","title"),show="headings",selectmode="browse")
        self.table.heading("status",text="Estado");self.table.heading("title",text="Titular / Tendencia")
        self.table.column("status",width=124,stretch=False);self.table.column("title",width=405,stretch=True)
        sb=ttk.Scrollbar(left,orient="vertical",command=self.table.yview)
        self.table.configure(yscrollcommand=sb.set)
        sb.pack(side="right",fill="y");self.table.pack(side="left",fill="both",expand=True)
        self.table.bind("<<TreeviewSelect>>",self.select_row)
        self.title_var=tk.StringVar(value="Selecciona una tarjeta")
        tk.Label(right,textvariable=self.title_var,font=("Segoe UI",14,"bold"),fg="#e7f1ff",
                 bg="#172338",wraplength=580,justify="left",anchor="w").pack(fill="x",padx=14,pady=12)
        self.detail=tk.Text(right,wrap="word",font=("Segoe UI",11),bg="#172338",fg="#e7f1ff",
             borderwidth=0,relief="flat",padx=12,pady=9)
        self.detail.pack(fill="both",expand=True,padx=4)
        self.detail.config(state="disabled")
        buttons=tk.Frame(right,bg="#172338")
        buttons.pack(fill="x",padx=8,pady=9)
        actions=[("Copiar texto",self.copy_text),("Abrir fuente",self.open_source),("Publicar en X",self.publish_x),
                 ("Abrir imágenes",lambda:webbrowser.open("https://chatgpt.com/images")),
                 ("Elaborar / Reelaborar",lambda:self.editorial_action("rework")),
                 ("Desestimar",lambda:self.editorial_action("discard")),
                 ("Quitar de Listas",lambda:self.editorial_action("deleted")),
                 ("Marcar publicada",lambda:self.editorial_action("published"))]
        for i,(label,fn) in enumerate(actions):
            ttk.Button(buttons,text=label,command=fn).grid(row=i//4,column=i%4,padx=2,pady=3,sticky="ew")
        for i in range(4):buttons.columnconfigure(i,weight=1)
        self.notice=tk.StringVar(value="GitHub es el estado autoritativo. Las acciones se verifican tras refrescar.")
        tk.Label(self,textvariable=self.notice,bg="#111b2b",fg="#f6ce88",anchor="w",pady=9).pack(fill="x",padx=16)

    def ui(self,fn):
        self.after(0,fn)

    def refresh_timer(self):
        if self.winfo_exists():
            if not self.refreshing: self.refresh()
            self.after(120000,self.refresh_timer)

    def refresh(self):
        if self.refreshing:return
        self.refreshing=True
        self.notice.set("Consultando las fuentes editoriales de GitHub…")
        def work():
            docs={};errors=[]
            def fetch_pair(item):
                key,path=item
                _,data=request(RAW+path+"?t="+str(int(time.time())),timeout=15)
                if not isinstance(data,dict):raise ValueError("JSON inválido: "+path)
                return key,data
            with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:
                futures={pool.submit(fetch_pair,item):item[0] for item in FILES.items()}
                for f in concurrent.futures.as_completed(futures):
                    try:k,v=f.result();docs[k]=v
                    except Exception as exc:errors.append(futures[f]+": "+str(exc))
            def done():
                self.refreshing=False
                if errors:
                    self.notice.set("Actualización parcial; no se aplican datos incompletos: "+", ".join(errors[:2]))
                    return
                try:
                    self.docs=docs
                    self.news,self.trends,self.top30,self.published=normalise(docs)
                    self.render()
                    self.notice.set("Datos comprobados en GitHub · "+dt.datetime.now().strftime("%H:%M:%S"))
                except Exception as exc:
                    self.notice.set("Error al interpretar los datos: "+str(exc))
            self.ui(done)
        threading.Thread(target=work,daemon=True).start()

    def render(self):
        if not hasattr(self,"news"):return
        sec=self.section.get();search=self.query.get().casefold()
        if sec=="Todas las Listas":
            chosen=[x for x in self.news+self.trends if x["state"]=="Listas"]
        elif sec.startswith("Noticias"):
            label=sec.split(" · ",1)[1]
            chosen=[x for x in self.news if x["state"]==label]
        elif sec=="Tendencias · Top 30":
            chosen=self.top30
        else:
            label=sec.split(" · ",1)[1]
            chosen=[x for x in self.trends if x["state"]==label]
        chosen=[x for x in chosen if search in (x["title"]+" "+x["body"]).casefold()]
        old=(self.selected or {}).get("project"),(self.selected or {}).get("id")
        self.table.delete(*self.table.get_children());self.items={}
        for n,row in enumerate(chosen[:1000]):
            rid=str(n);self.items[rid]=row
            self.table.insert("", "end",iid=rid,values=(row["state"],(("#"+str(row.get("rank"))+" ") if row.get("rank") else "")+row["title"]))
            if (row["project"],row["id"])==old:self.table.selection_set(rid)
        nc=sum(x["state"]=="Listas" for x in self.news)
        nw=sum(x["state"]=="En elaboración" for x in self.news)
        tc=sum(x["state"]=="Listas" for x in self.trends)
        tw=sum(x["state"]=="En elaboración" for x in self.trends)
        self.counters.set(f"NOTICIAS  Listas {nc}  ·  Elaboración {nw}   |   TENDENCIAS  Listas {tc}  ·  Elaboración {tw}"
                          f"   |   Publicadas 24 h: N {self.published['ttittulares']} · T {self.published['ttendencias']}")

    def select_row(self,event=None):
        selected=self.table.selection()
        if not selected:return
        row=self.items.get(selected[0])
        if not row:return
        self.selected=row;self.title_var.set(row["title"])
        self.detail.config(state="normal");self.detail.delete("1.0","end")
        self.detail.insert("1.0",f"{row['category']} · {row['state']}\nID: {row['id']} · Revisión: {row['revision']}\n\n{row['body'] or 'Sin texto todavía.'}\n\nFuente: {row['source'] or '—'}\nFoto archivo: {row['image'] or '—'}")
        self.detail.config(state="disabled")

    def current(self):
        if not self.selected:
            messagebox.showinfo("TTActualidad","Selecciona una noticia o tendencia primero.")
        return self.selected

    def copy_text(self):
        r=self.current()
        if r:
            self.clipboard_clear();self.clipboard_append(r["body"] or r["title"])
            self.notice.set("Texto copiado al portapapeles.")

    def open_source(self):
        r=self.current()
        if r and r["source"].startswith("https://"):webbrowser.open(r["source"])

    def publish_x(self):
        r=self.current()
        if r:webbrowser.open("https://twitter.com/intent/tweet?text="+urllib.parse.quote((r["body"] or r["title"])[:280]))

    def get_creds(self):
        try:return json.loads(keyring.get_password(KEYRING_SERVICE,"session") or "{}")
        except Exception:return {}

    def save_creds(self,creds):
        keyring.set_password(KEYRING_SERVICE,"session",json.dumps(creds))

    def authorized_token(self):
        creds=self.get_creds()
        token=text(creds.get("access_token"))
        expiry=int(creds.get("access_expiry") or 0)
        if token and (not expiry or expiry-time.time()>90):return token
        refresh=text(creds.get("refresh_token"))
        client=text(self.config_data.get("client_id"))
        if not refresh or not client:return token
        _,new=request("https://github.com/login/oauth/access_token",method="POST",form=True,
           data={"client_id":client,"grant_type":"refresh_token","refresh_token":refresh})
        if not new.get("access_token"):raise ValueError(new.get("error_description") or "La autorización GitHub ha caducado.")
        creds.update(new);creds["access_expiry"]=int(time.time())+int(new.get("expires_in") or 28800)
        self.save_creds(creds)
        return creds["access_token"]

    def connect(self):
        client=simpledialog.askstring("Conectar GitHub","Client ID público de la GitHub App utilizada en el iPhone:",initialvalue=self.config_data.get("client_id",""),parent=self)
        if client is None:return
        client=client.strip()
        if not client.startswith("Iv") or not (12<=len(client)<=80) or not all(ch.isascii() and (ch.isalnum() or ch==".") for ch in client):
            messagebox.showerror("GitHub","Client ID de GitHub App no válido.");return
        self.config_data["client_id"]=client
        CONFIG.write_text(json.dumps(self.config_data),encoding="utf-8")
        self.notice.set("Solicitando código de autorización de GitHub…")
        def work():
            try:
                _,auth=request("https://github.com/login/device/code",method="POST",form=True,data={"client_id":client})
                secret=auth["device_code"];code=auth["user_code"]
                self.ui(lambda: self.notice.set("GitHub: abre github.com/login/device e introduce "+code))
                self.ui(lambda: webbrowser.open("https://github.com/login/device"))
                interval=max(5,int(auth.get("interval") or 5));deadline=time.time()+int(auth.get("expires_in") or 900)
                while time.time()<deadline:
                    time.sleep(interval)
                    _,result=request("https://github.com/login/oauth/access_token",method="POST",form=True,
                       data={"client_id":client,"device_code":secret,"grant_type":"urn:ietf:params:oauth:grant-type:device_code"})
                    if result.get("access_token"):
                        result["access_expiry"]=int(time.time())+int(result.get("expires_in") or 28800)
                        self.save_creds(result)
                        self.ui(lambda:self.notice.set("GitHub conectado · las órdenes podrán enviarse sin Cloudflare."))
                        return
                    if result.get("error")=="slow_down":interval+=5
                    elif result.get("error") not in ("authorization_pending","slow_down"):
                        raise ValueError(result.get("error_description") or "Autorización rechazada.")
                raise TimeoutError("El código de GitHub ha caducado.")
            except Exception as exc:
                err = str(exc)
                self.ui(lambda:self.notice.set("Conexión GitHub: "+err))
        threading.Thread(target=work,daemon=True).start()

    def submit(self,event,payload,detail):
        if self.sending:return
        rid=payload["request_id"]
        self.sending=True;self.notice.set("Enviando orden a GitHub…")
        def work():
            try:
                token=self.authorized_token()
                if not token:raise RuntimeError("Primero conecta GitHub con su Client ID.")
                status,_=request(API,method="POST",token=token,data={"event_type":event,"client_payload":payload},timeout=25)
                if status!=204:raise RuntimeError("GitHub no confirmó el dispatch (HTTP "+str(status)+").")
                self.pending.add(rid)
                self.ui(lambda:self.notice.set("GitHub recibió la solicitud "+rid[:8]+" · pendiente de verificación; no se marca como completada."))
                self.ui(lambda:self.after(7000,self.refresh))
            except Exception as exc:
                err = str(exc)
                self.ui(lambda:self.notice.set(detail+": "+err))
            finally:
                self.ui(lambda:setattr(self,"sending",False))
        threading.Thread(target=work,daemon=True).start()

    def editorial_action(self,decision):
        r=self.current()
        if not r:return
        if not r["id"] or r["revision"]<0:
            messagebox.showerror("TTActualidad","No consta el ID/revisión editorial.");return
        if decision in ("published","deleted","discard"):
            if not messagebox.askyesno("Confirmar",f"¿Aplicar «{decision}» a:\n{r['title']}?\n\nSe comprobará en GitHub."):
                return
        payload={"project":r["project"],"event_id":r["id"],"revision":r["revision"],
          "decision":decision,"request_id":str(uuid.uuid4()),"received_at":dt.datetime.now(dt.timezone.utc).isoformat(),
          "trend_name":r["title"],"trend_rank":r.get("rank",0)}
        self.submit("ttactualidad_action_v1",payload,"Acción "+decision)

    def new_story(self):
        title=simpledialog.askstring("Nueva noticia","Titular o descripción:",parent=self)
        if title is None:return
        url=simpledialog.askstring("Nueva noticia","URL de la noticia (opcional, HTTPS):",parent=self)
        if url is None:return
        instructions=simpledialog.askstring("Nueva noticia","Indicaciones editoriales (opcional):",parent=self)
        if instructions is None:return
        title=title.strip();url=url.strip()
        if not title and not url:
            messagebox.showerror("TTActualidad","Indica un titular o URL.");return
        if title and len(title)<5:
            messagebox.showerror("TTActualidad","El titular debe tener al menos 5 caracteres.");return
        if url and not url.startswith("https://"):
            messagebox.showerror("TTActualidad","La URL debe empezar por https://");return
        payload={"project":"ttittulares","request_id":str(uuid.uuid4()),
                 "title":title[:240],"url":url[:2000],"instructions":instructions[:1000]}
        self.submit("ttactualidad_manual_news_v1",payload,"Nueva noticia")

if __name__=="__main__":
    TTActualidad().mainloop()

