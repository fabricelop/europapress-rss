# -*- coding: utf-8 -*-
"""TTActualidad Windows — native Qt desktop. No Worker, local server or phone required."""
from __future__ import annotations

import datetime as dt
import html
import json
import os
import pathlib
import re
import threading
import time
import urllib.parse
import urllib.request
import uuid
import webbrowser
from concurrent.futures import ThreadPoolExecutor, as_completed

import keyring
from PySide6.QtCore import QObject, Qt, QTimer, Signal, QSize
from PySide6.QtGui import QPixmap
from PySide6.QtWidgets import (
    QApplication, QWidget, QFrame, QLabel, QPushButton, QLineEdit, QVBoxLayout,
    QHBoxLayout, QGridLayout, QScrollArea, QTextBrowser, QDialog, QDialogButtonBox,
    QMessageBox, QTextEdit, QInputDialog, QSizePolicy, QSplitter, QMenu
)

from TTActualidad import FILES, RAW, API, REPO, KEYRING_SERVICE, normalise, request, text, confirmed_terminals, terminal_applies

SERVICE_KEY = "session"
SECTIONS = [
    ("Todas las Listas", "Todas las Listas", "Resumen de noticias y tendencias"),
    ("Noticias · Listas", "Noticias · Listas", "Noticias listas para publicar"),
    ("Noticias · En elaboración", "Noticias · En elaboración", "Noticias en preparación"),
    ("Noticias · Revisión", "Noticias · Revisión", "Noticias que necesitan atención"),
    ("Noticias · Creciendo", "Noticias · Creciendo", "Historias en desarrollo"),
    ("Noticias · Tremending", "Noticias · Tremending", "Selección de Tremending"),
    ("Tendencias · Listas", "Tendencias · Listas", "Tendencias explicadas"),
    ("Tendencias · En elaboración", "Tendencias · En elaboración", "Explicaciones en curso"),
    ("Tendencias · Top 30", "Tendencias · Top 30", "Clasificación actual"),
]
BG = "#0b1220"
SURFACE = "#101c2e"
CARD = "#18263a"
LINE = "#293b50"
INK = "#eef5ff"
MUTED = "#99adc4"
TEAL = "#65e0c5"
GOLD = "#f0c77a"

STYLE = """
QWidget { background:#0b1220; color:#eef5ff; font-family:'Segoe UI'; font-size:13px; }
QLabel { background:transparent; border:0px; padding:0px; }
QFrame QLabel { background:transparent; }
QScrollArea QWidget#listHost { background:transparent; }
QFrame#sidebar { background:#111d2c; border-right:1px solid #273951; }
QFrame#panel { background:#121f31; border:1px solid #2a4057; border-radius:18px; }
QFrame#metric { background:#172b3e; border:1px solid #31506a; border-radius:16px; }
QFrame#rowCard { background:#1c2d42; border:1px solid #34485f; border-radius:13px; }
QFrame#rowCard:hover { background:#233a50; border-color:#64d8c3; }
QFrame#rowCard[selected="true"] { background:#243d4e; border:1px solid #74dac6; }
QMenu { background:#192a3e; border:1px solid #3a566f; border-radius:10px; padding:6px; }
QMenu::item { padding:9px 18px; color:#eaf2ff; border-radius:6px; }
QMenu::item:selected { background:#2a554e; color:#9bffe7; }
QMenu::item:disabled { color:#64798f; }
QToolTip { background:#243b51; color:white; border:1px solid #57768e; border-radius:6px; padding:7px; }

QLabel#brand { font-size:26px; font-weight:800; color:#83ecd6; }
QLabel#eyebrow { color:#94adc4; font-size:11px; font-weight:700; }
QLabel#pageTitle { font-size:24px; font-weight:750; }
QLabel#metricNumber { font-size:33px; font-weight:800; color:#f4fbff; }
QLabel#cardTitle { font-size:14px; font-weight:650; }
QLabel#detailTitle { font-size:23px; font-weight:750; }
QLabel#small { font-size:12px; color:#9caec1; }
QLabel#body { font-size:14px; color:#d5e2ef; }
QPushButton { border:1px solid #3a516a; border-radius:10px; padding:9px 14px;
  color:#eaf2ff; background:#1b2c43; font-weight:600; }
QPushButton:hover { background:#293e57; border-color:#6397a7; }
QPushButton:pressed { background:#314963; }
QPushButton:disabled { background:#1a2536; color:#708094; border-color:#27384b; }
QPushButton#primary { background:#56cbb1; color:#0c2630; border:1px solid #56cbb1; }
QPushButton#primary:hover { background:#83ead3; }
QPushButton#primary:disabled { background:#1a2536; color:#708094; border-color:#27384b; }
QPushButton#danger { border-color:#915a67; color:#ffd3db; }
QPushButton#danger:hover { background:#4c2a38; }
QPushButton#nav { border:0; background:transparent; padding:11px 14px; text-align:left;
   color:#a8bad0; border-radius:9px; }
QPushButton#nav:hover { background:#1e3247; color:white; }
QPushButton#nav[active="true"] { background:#23453f; color:#78ebd3; font-weight:750; }
QLineEdit, QTextEdit { background:#1b2b40; border:1px solid #385470; border-radius:10px;
  padding:10px 12px; selection-background-color:#276a62; }
QLineEdit:focus, QTextEdit:focus { border:1px solid #6be1c7; }
QTextBrowser { background:#101c2e; color:#dce9f7; border:0; font-size:14px; }
QScrollArea { background:transparent; border:0; }
QScrollBar:vertical { background:#132033; width:8px; border:0; }
QScrollBar::handle:vertical { background:#446078; border-radius:4px; min-height:26px; }
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height:0; }
QSplitter::handle { background:#0b1220; width:12px; }
QDialog { background:#101c2e; }
"""

def label(txt="", name=None, *, selectable=False, wrap=False):
    w = QLabel(str(txt))
    if name:
        w.setObjectName(name)
    w.setWordWrap(wrap)
    if selectable:
        w.setTextInteractionFlags(Qt.TextSelectableByMouse)
    return w

def button(txt, cb, kind=None):
    w=QPushButton(txt)
    if kind: w.setObjectName(kind)
    w.setCursor(Qt.PointingHandCursor)
    w.clicked.connect(cb)
    return w

def frame(name="panel"):
    w=QFrame()
    w.setObjectName(name)
    return w

def row_layout(parent=None, spacing=9, margins=(0,0,0,0)):
    l=QHBoxLayout(parent)
    l.setSpacing(spacing)
    l.setContentsMargins(*margins)
    return l

def col_layout(parent=None, spacing=10, margins=(0,0,0,0)):
    l=QVBoxLayout(parent)
    l.setSpacing(spacing)
    l.setContentsMargins(*margins)
    return l

def clear_layout(layout):
    while layout.count():
        item=layout.takeAt(0)
        if item.widget(): item.widget().deleteLater()
        elif item.layout(): clear_layout(item.layout())

def stamp():
    return dt.datetime.now(dt.timezone.utc).isoformat()

def safe_url(url):
    try:
        o=urllib.parse.urlparse(str(url or ""))
        return o.geturl() if o.scheme=="https" and o.netloc else ""
    except ValueError: return ""

def publication_outcome(choice):
    """Map the user's explicit result to the two distinct terminal outcomes."""
    return {"yes":"published", "no":"deleted", "cancel":None}.get(choice)

def stored_session():
    try: return json.loads(keyring.get_password(KEYRING_SERVICE,SERVICE_KEY) or "{}")
    except Exception: return {}

def session_token():
    data=stored_session()
    token=str(data.get("access_token") or "").strip()
    if data.get("auth_type")=="personal_access_token":
        return token
    expiry=int(data.get("access_expiry") or 0)
    if expiry and expiry<=time.time()+60:
        raise RuntimeError("La sesión GitHub ha caducado. Vuelve a conectarla.")
    return token

def validate_token(token):
    token=token.strip()
    if not token or len(token)<18 or any(c.isspace() for c in token):
        raise ValueError("Introduce un token GitHub válido.")
    _, user = request("https://api.github.com/user",token=token)
    login = str(user.get("login") or "").strip()
    if not login:
        raise ValueError("GitHub no ha reconocido este token.")
    return login

_archive_cache={}
_archive_checked_at=0.0

def load_archive_paths():
    """Fetch the same GitHub archive photo catalog used by iOS (no AI imagery)."""
    global _archive_cache, _archive_checked_at
    if _archive_checked_at and time.time()-_archive_checked_at<600:
        return dict(_archive_cache)
    try:
        _,tree=request("https://api.github.com/repos/"+REPO+"/git/trees/main?recursive=1",timeout=15)
        if tree.get("truncated"):
            raise ValueError("El listado de archivos está truncado")
        found={}
        for node in tree.get("tree",[]):
            path=node.get("path","")
            if node.get("type")!="blob" or not path.startswith(("trends/archive-images/","ttittulares/archive-images/")):
                continue
            match=re.fullmatch(r"(.+)-r([0-9]+)-[^/]+[.](jpg|jpeg|png|webp)",path.rsplit("/",1)[-1],re.I)
            if not match:
                continue
            project="ttendencias" if path.startswith("trends/") else "ttittulares"
            found[project+":"+match.group(1)+":r"+match.group(2)]=RAW+path
        _archive_cache=found
        _archive_checked_at=time.time()
    except Exception:
        # Missing photo catalog must never discard legitimate editorial data.
        pass
    return dict(_archive_cache)

def fetch_editorial():
    """Read all editorial documents from ONE immutable GitHub main commit.

    Reading fourteen independent /main/ RAW files can combine old Listas with
    new decisions, or the reverse. Such a mixed view resurrects closed cards.
    Resolve main once and pin every document to its identical commit SHA.
    Fail closed rather than render partial state from different revisions.
    """
    _,head=request("https://api.github.com/repos/"+REPO+"/commits/main?tt_sync="+str(
        time.time_ns()),token=session_token(),timeout=12)
    sha=str(head.get("sha") or "")
    if len(sha)!=40 or any(c not in "0123456789abcdef" for c in sha.lower()):
        raise RuntimeError("No se pudo identificar una revisión completa de GitHub")
    base="https://raw.githubusercontent.com/"+REPO+"/"+sha+"/"
    result={}
    def one(pair):
        key,path=pair
        _,data=request(base+path,timeout=17)
        if not isinstance(data,dict): raise ValueError(path+" no devolvió JSON válido")
        return key,data
    with ThreadPoolExecutor(max_workers=10) as pool:
        jobs={pool.submit(one,pair):pair[0] for pair in FILES.items()}
        errors=[]
        for future in as_completed(jobs):
            try:
                k,v=future.result()
                result[k]=v
            except Exception as exc:errors.append(jobs[future]+": "+str(exc))
    if errors: raise RuntimeError("Sin actualizar datos incompletos: "+"; ".join(errors[:3]))
    result["_commit_sha"]=sha
    result["archive_photos"]=load_archive_paths()
    return result,normalise(result)

class Events(QObject):
    finished=Signal(str,object,object)

class Worker:
    def __init__(self,signals):
        self.signals=signals
    def run(self,kind,fn):
        def work():
            try:self.signals.finished.emit(kind,fn(),None)
            except Exception as exc:self.signals.finished.emit(kind,None,str(exc))
        threading.Thread(target=work,daemon=True).start()

class ConnectDialog(QDialog):
    def __init__(self,parent=None):
        super().__init__(parent)
        self.setWindowTitle("Conectar GitHub · TTActualidad")
        self.setMinimumSize(520,330)
        self.token=""
        v=col_layout(self,14,(26,24,26,24))
        h=label("Conecta directamente desde Windows","detailTitle")
        v.addWidget(h)
        v.addWidget(label("Sin iPhone, sin Worker y sin contraseñas guardadas en archivos.","small",wrap=True))
        t=label("1. Crea un token de acceso personal de alcance limitado en GitHub.\n"
                "2. Selecciona solo el repositorio fabricelop/europapress-rss.\n"
                "3. Asigna Contents: Read and write para enviar las órdenes.\n"
                "4. Pega el token aquí. Se guardará en el Administrador de credenciales de Windows.",wrap=True)
        t.setStyleSheet("line-height:140%;color:#dce9f7")
        v.addWidget(t)
        v.addWidget(button("Abrir GitHub para crear el token ↗",
            lambda:webbrowser.open("https://github.com/settings/personal-access-tokens/new")))
        self.token_input=QLineEdit()
        self.token_input.setEchoMode(QLineEdit.Password)
        self.token_input.setPlaceholderText("github_pat_…   /   ghp_…")
        v.addWidget(self.token_input)
        self.show_token=button("Mostrar",self.toggle_visibility)
        v.addWidget(self.show_token,alignment=Qt.AlignRight)
        actions=row_layout()
        self.cancel=button("Cancelar",self.reject)
        self.save=button("Verificar y conectar",self.accept_token,"primary")
        actions.addStretch();actions.addWidget(self.cancel);actions.addWidget(self.save)
        v.addLayout(actions)
    def toggle_visibility(self):
        showing=self.token_input.echoMode()==QLineEdit.Password
        self.token_input.setEchoMode(QLineEdit.Normal if showing else QLineEdit.Password)
        self.show_token.setText("Ocultar" if showing else "Mostrar")
    def accept_token(self):
        raw=self.token_input.text().strip()
        if len(raw)<18 or any(ch.isspace() for ch in raw):
            QMessageBox.warning(self,"Token inválido","Introduce el token generado en GitHub.")
            return
        self.token=raw
        self.accept()

class StoryDialog(QDialog):
    def __init__(self,parent=None):
        super().__init__(parent)
        self.setWindowTitle("Nueva noticia")
        self.setMinimumWidth(550)
        v=col_layout(self,14,(24,24,24,24))
        v.addWidget(label("Añadir noticia","detailTitle"))
        v.addWidget(label("Titular o descripción"))
        self.heading=QLineEdit();self.heading.setPlaceholderText("¿Qué ha ocurrido?")
        v.addWidget(self.heading)
        v.addWidget(label("Enlace de la fuente (opcional)"))
        self.source=QLineEdit();self.source.setPlaceholderText("https://…")
        v.addWidget(self.source)
        v.addWidget(label("Indicaciones editoriales (opcional)"))
        self.instructions=QTextEdit();self.instructions.setFixedHeight(100)
        v.addWidget(self.instructions)
        buttons=row_layout()
        buttons.addStretch()
        buttons.addWidget(button("Cancelar",self.reject))
        buttons.addWidget(button("Enviar a elaboración",self.accept,"primary"))
        v.addLayout(buttons)
    def payload(self):
        title=self.heading.text().strip()
        url=self.source.text().strip()
        if not title and not url: raise ValueError("Indica un titular o una URL.")
        if title and len(title)<5:raise ValueError("El titular debe tener al menos cinco caracteres.")
        if url and not safe_url(url):raise ValueError("La fuente debe ser HTTPS.")
        return {"project":"ttittulares","request_id":str(uuid.uuid4()),
                "title":title[:240],"url":url[:2000],
                "instructions":self.instructions.toPlainText().strip()[:1000]}

class MainWindow(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("TTActualidad · Escritorio")
        self.resize(1460,880)
        self.setMinimumSize(1040,660)
        self.docs={}
        self.news=[];self.trends=[];self.top30=[];self.published={"ttittulares":0,"ttendencias":0}
        self.selected=None;self.section="Todas las Listas"
        self.refreshing=False;self.sending=False
        self.pending_actions={}  # keyed by GitHub request_id
        self.optimistic_hides={}  # (project, id, revision) -> pending/confirmed closure
        self.verified_terminals={}  # receipt/decision-backed, never speculative
        self.verified_revision=None
        self.refresh_again=False
        self.loaded_image=QPixmap()
        self.events=Events()
        self.events.finished.connect(self.on_finished)
        self.worker=Worker(self.events)
        self.nav={}
        self.card_widgets={}
        self.draw()
        self.timer=QTimer(self)
        self.timer.timeout.connect(self.refresh)
        # Anonymous REST API is limited; a connected GitHub account permits
        # faster polling while retaining the same write permissions.
        self.timer.start(45000 if session_token() else 120000)
        QTimer.singleShot(200,self.refresh)

    def draw(self):
        root=row_layout(self,0)
        side=frame("sidebar")
        side.setFixedWidth(245)
        root.addWidget(side)
        nav=col_layout(side,6,(19,29,19,18))
        nav.addWidget(label("TTActualidad","brand"))
        nav.addWidget(label("REDACCIÓN  /  WINDOWS","eyebrow"))
        nav.addSpacing(21)
        nav.addWidget(label("BANDEJAS","eyebrow"))
        for title,_,_ in SECTIONS:
            if title=="Noticias · Listas":
                nav.addSpacing(16)
                nav.addWidget(label("NOTICIAS","eyebrow"))
            if title=="Tendencias · Listas":
                nav.addSpacing(12)
                nav.addWidget(label("TENDENCIAS","eyebrow"))
            caption="Resumen general" if title=="Todas las Listas" else title.split(" · ")[-1]
            b=button("  "+caption,lambda checked=False,n=title:self.change_section(n),"nav")
            b.setProperty("active",title==self.section)
            b.style().unpolish(b);b.style().polish(b)
            self.nav[title]=b
            nav.addWidget(b)
        nav.addStretch()
        nav.addWidget(label("CONEXIÓN SEGURA","eyebrow"))
        self.auth_label=label("GitHub · sin conectar","small",wrap=True)
        nav.addWidget(self.auth_label)
        nav.addWidget(button("Cambiar conexión",self.connect))
        nav.addWidget(button("Cerrar sesión",self.logout))
        content=QWidget()
        content.setSizePolicy(QSizePolicy.Expanding,QSizePolicy.Expanding)
        root.addWidget(content,1)
        page=col_layout(content,18,(27,27,27,19))
        head=row_layout(spacing=18)
        titles=col_layout(spacing=4)
        self.heading=label("Todas las listas","pageTitle")
        self.subtitle=label("Noticias y tendencias listas para gestionar","small")
        titles.addWidget(label("PANEL EDITORIAL   ·   GITHUB","eyebrow"))
        titles.addWidget(self.heading);titles.addWidget(self.subtitle)
        head.addLayout(titles,1)
        head.addWidget(button("ChatGPT Images ↗",lambda:webbrowser.open("https://chatgpt.com/images")))
        head.addWidget(button("+  Nueva noticia",self.new_story,"primary"))
        self.reload=button("Actualizar",self.refresh)
        head.addWidget(self.reload)
        page.addLayout(head)
        metric_row=row_layout(spacing=12)
        self.metric_labels={}
        self.metric_subtitles={}
        for title,key in [
            ("NOTICIAS EN LISTAS","news_ready"),
            ("TENDENCIAS EN LISTAS","trends_ready"),
            ("EN ELABORACIÓN","working"),
            ("NOTICIAS PUBLICADAS · 24 H","published_news"),
            ("TENDENCIAS PUBLICADAS · 24 H","published_trends")
        ]:
            card=frame("metric")
            vv=col_layout(card,5,(14,12,14,10))
            vv.addWidget(label(title,"eyebrow",wrap=True))
            value=label("—","metricNumber")
            vv.addWidget(value)
            self.metric_labels[key]=value
            pending=label("","small")
            pending.setStyleSheet("color:#f0c77a;")
            vv.addWidget(pending)
            self.metric_subtitles[key]=pending
            metric_row.addWidget(card,1)
        page.addLayout(metric_row)
        splitter=QSplitter(Qt.Horizontal)
        splitter.setChildrenCollapsible(False)
        page.addWidget(splitter,1)

        left=frame("panel")
        ll=col_layout(left,12,(18,20,18,18))
        lhead=row_layout()
        lhead.addWidget(label("Bandeja editorial","cardTitle"))
        self.list_count=label("0 elementos","small")
        lhead.addStretch();lhead.addWidget(self.list_count)
        ll.addLayout(lhead)
        grouping=row_layout(spacing=7)
        self.group_listas_button=button("Agrupar",lambda:self.group_listas(False),"primary")
        self.remove_grouped_button=button("Retirar agrupadas",lambda:self.group_listas(True))
        grouping.addWidget(self.group_listas_button)
        grouping.addWidget(self.remove_grouped_button)
        ll.addLayout(grouping)
        self.grouping_request_ids={}
        self.search=QLineEdit()
        self.search.setPlaceholderText("Buscar por titular, tema o texto…")
        self.search.textChanged.connect(self.render_list)
        ll.addWidget(self.search)
        self.scroll=QScrollArea();self.scroll.setWidgetResizable(True)
        self.list_host=QWidget()
        self.list_host.setObjectName("listHost")
        self.list_layout=col_layout(self.list_host,8,(2,4,2,6))
        self.scroll.setWidget(self.list_host)
        ll.addWidget(self.scroll,1)
        splitter.addWidget(left)

        right=frame("panel")
        rl=col_layout(right,12,(24,21,24,21))
        self.state_tag=label("SELECCIONA UN ELEMENTO","eyebrow")
        rl.addWidget(self.state_tag)
        self.detail_title=label("Tu bandeja editorial","detailTitle",wrap=True)
        self.detail_title.setMaximumHeight(112)
        rl.addWidget(self.detail_title)
        self.detail_meta=label("Selecciona una tarjeta para leerla y gestionar sus acciones.","small",wrap=True)
        rl.addWidget(self.detail_meta)

        # Text and photographic preview SHARE one row. Photos can no longer
        # push the action buttons below the bottom of the window.
        preview=row_layout(spacing=14)
        self.body=QTextBrowser()
        self.body.setMinimumHeight(115)
        self.body.setOpenExternalLinks(False)
        self.body.anchorClicked.connect(self.open_link)
        self.body.setHtml("<p style='color:#99adc4'>Las noticias y tendencias aparecerán aquí.</p>")
        preview.addWidget(self.body,1)
        self.image_label=label()
        self.image_label.setAlignment(Qt.AlignCenter)
        self.image_label.setFixedSize(180,132)
        self.image_label.setStyleSheet("background:#22354a;border:1px solid #36516b;border-radius:12px;")
        self.image_label.hide()
        preview.addWidget(self.image_label,0,Qt.AlignTop)
        rl.addLayout(preview,1)

        # Primary actions remain in the visible, STICKY action dock; secondary
        # actions are available in a genuine menu without nine tiny rows.
        self.actions={}
        rl.addWidget(label("HERRAMIENTAS DE PUBLICACIÓN","eyebrow"))
        quick=row_layout(spacing=8)
        quick_items=[
            ("Copiar texto","copy",self.copy_text,None),
            ("Copiar GAG","gag",self.copy_gag,None),
            ("ChatGPT Images ↗","chatgpt",lambda:webbrowser.open("https://chatgpt.com/images"),None),
            ("Publicar en X ↗","x",self.publish_x,"primary"),
        ]
        for caption,key,fn,kind in quick_items:
            btn=button(caption,fn,kind)
            btn.setMinimumHeight(40)
            self.actions[key]=btn
            quick.addWidget(btn,1)
        rl.addLayout(quick)

        rl.addWidget(label("GESTIÓN EDITORIAL","eyebrow"))
        editorial=row_layout(spacing=8)
        primary_decisions=[
            ("Preparar / Reelaborar","rework",self.prepare_or_rework,None),
            ("Quitar de Listas","deleted",lambda:self.editorial_action("deleted"),"danger"),
            ("Cerrar · Sí / No","published",self.ask_publication_outcome,"primary")
        ]
        for caption,key,fn,kind in primary_decisions:
            btn=button(caption,fn,kind)
            btn.setMinimumHeight(42)
            self.actions[key]=btn
            editorial.addWidget(btn,1)
        self.more_menu=QMenu(right)
        extra=[
            ("Buscar en X ↗","searchx",self.search_x),
            ("TTImages ↗","ttimages",lambda:webbrowser.open("https://t.me/TTImages_bot")),
            ("Abrir fuente ↗","source",self.open_source),
            ("Ver foto de archivo ↗","image",self.open_image),
            ("Copiar foto de archivo","photo_copy",self.copy_photo),
            ("Añadir pistas a la tendencia","hints",self.add_hints),
            ("Desestimar","discard",lambda:self.editorial_action("discard")),
        ]
        for caption,key,fn in extra:
            action=self.more_menu.addAction(caption)
            action.triggered.connect(lambda checked=False,callback=fn:callback())
            self.actions[key]=action
        self.more_button=button("Más  ···",lambda:self.more_menu.exec(
            self.more_button.mapToGlobal(self.more_button.rect().bottomLeft())))
        self.more_button.setMinimumHeight(42)
        editorial.addWidget(self.more_button)
        rl.addLayout(editorial)
        splitter.addWidget(right)
        splitter.setSizes([475,720])
        self.notice=label("GitHub es la autoridad editorial · las órdenes se verifican antes de confirmarse.","small",wrap=True)
        page.addWidget(self.notice)
        self.update_auth_badge()
        self.update_actions()

    def change_section(self,section):
        self.section=section
        self.heading.setText(section)
        info=next((x[2] for x in SECTIONS if x[0]==section),"Bandeja editorial")
        self.subtitle.setText(info)
        for title,b in self.nav.items():
            b.setProperty("active",title==section)
            b.style().unpolish(b);b.style().polish(b)
        self.render_list()

    def update_auth_badge(self):
        session=stored_session()
        name=session.get("login")
        self.auth_label.setText("Conectado: @"+str(name) if name else "GitHub · sin conectar")

    def connect(self):
        dlg=ConnectDialog(self)
        if dlg.exec()!=QDialog.Accepted:return
        token=dlg.token
        self.notice.setText("Verificando identidad con GitHub…")
        self.worker.run("auth",lambda: (validate_token(token),token))

    def logout(self):
        answer=QMessageBox.question(self,"Cerrar sesión","¿Desconectar GitHub de este ordenador?")
        if answer!=QMessageBox.Yes:return
        try:keyring.delete_password(KEYRING_SERVICE,SERVICE_KEY)
        except keyring.errors.PasswordDeleteError:pass
        self.update_auth_badge()
        self.timer.start(120000)
        self.notice.setText("Sesión cerrada. La lectura pública sigue disponible.")

    def refresh(self):
        if self.refreshing:
            self.refresh_again=True
            return
        self.refreshing=True
        self.reload.setEnabled(False)
        self.notice.setText("Sincronizando el estado editorial desde GitHub…")
        self.worker.run("refresh",fetch_editorial)

    def _finish_refresh_if_requested(self):
        if self.refresh_again and not self.refreshing:
            self.refresh_again=False
            QTimer.singleShot(200,self.refresh)

    def on_finished(self,kind,value,error):
        if kind=="auth":
            if error:
                self.notice.setText("No se pudo conectar: "+error)
                QMessageBox.warning(self,"GitHub",error)
                return
            login,token=value
            try:
                keyring.set_password(KEYRING_SERVICE,SERVICE_KEY,json.dumps({
                    "auth_type":"personal_access_token","access_token":token,
                    "login":login}))
            except Exception as exc:
                QMessageBox.warning(self,"Credenciales",str(exc));return
            self.update_auth_badge()
            self.timer.start(45000)
            self.notice.setText("Conexión verificada con GitHub · @"+login)
        elif kind=="refresh":
            self.refreshing=False;self.reload.setEnabled(True)
            if error:
                self.notice.setText("No se han sustituido los datos anteriores: "+error)
                self._finish_refresh_if_requested()
                return
            self.docs,processed=value
            self.news,self.trends,self.top30,self.published=processed
            # A confirmed closure from the phone or Windows must remain known
            # even if GitHub briefly serves an older snapshot later. Never
            # infer closure solely from an absent card or a 204 dispatch.
            for key,mark in confirmed_terminals(self.docs).items():
                earlier=self.verified_terminals.get(key)
                if earlier is None or mark["revision"]>earlier["revision"] or (
                        mark["revision"]==earlier["revision"] and
                        (mark["at"] or dt.datetime.min.replace(tzinfo=dt.timezone.utc)) >
                        (earlier["at"] or dt.datetime.min.replace(tzinfo=dt.timezone.utc))):
                    self.verified_terminals[key]=mark
            self.verified_revision=self.docs.get("_commit_sha")
            # Resolve receipts before rendering; a stale CDN snapshot must not
            # briefly resurrect a card the person has just closed.
            had_pending=bool(self.pending_actions)
            self.confirm_pending()
            self.reconcile_optimistic_closures()
            self.render_list()
            if not had_pending:
                self.notice.setText("GitHub · revisión "+str(self.verified_revision or "")[:8]+
                                    " sincronizada · "+dt.datetime.now().strftime("%H:%M:%S"))
            self._finish_refresh_if_requested()
        elif kind=="submit":
            # Every worker carries its own request_id so multiple cards may
            # be closed without blocking on one another's GitHub workflow.
            if error:
                self.notice.setText("Error inesperado al enviar: "+error)
                return
            request_id,send_error=value
            pending=self.pending_actions.get(request_id)
            if send_error:
                if pending:
                    self.pending_actions.pop(request_id,None)
                    self.optimistic_hides.pop(pending.get("hide_key"),None)
                self.sending=False
                self.render_list()
                self.notice.setText("No se pudo enviar la orden. Tarjeta restaurada: "+send_error)
                QMessageBox.warning(self,"Acción no enviada",send_error)
                return
            if pending:
                if pending["decision"] in {"group_listas","remove_covered"}:
                    self.sending=False
                pending["dispatched"]=True
                self.notice.setText("GitHub comprueba la solicitud de agrupación…" if pending["decision"] in {"group_listas","remove_covered"} else "Tarjeta apartada al instante · GitHub comprueba la orden…")
                for delay in (1800,4500,9000,16000,28000,45000,70000):
                    QTimer.singleShot(delay,self.refresh)
                QTimer.singleShot(605000,self.expire_pending)
            else:
                self.sending=False
                self.notice.setText("Solicitud enviada a GitHub · "+request_id[:8])
                QTimer.singleShot(5000,self.refresh)
            self.update_actions()
        elif kind=="image":
            rowkey,data=value if not error else (None,None)
            if error or not data or not self.selected or rowkey!=(self.selected["project"],self.selected["id"]):
                return
            pix=QPixmap()
            if not pix.loadFromData(data):return
            self.loaded_image=pix
            self.image_label.setPixmap(pix.scaled(QSize(172,124),Qt.KeepAspectRatio,Qt.SmoothTransformation))
            self.image_label.show()
            self.update_actions()

    def list_data(self):
        if self.section=="Todas las Listas":
            return [x for x in self.news+self.trends if x["state"]=="Listas"]
        if self.section=="Tendencias · Top 30":return self.top30
        if self.section.startswith("Noticias · "):
            state=self.section.split(" · ",1)[1]
            return [x for x in self.news if x["state"]==state]
        state=self.section.split(" · ",1)[1]
        return [x for x in self.trends if x["state"]==state]

    def render_list(self):
        chosen=self.visible_rows(self.list_data())
        query=self.search.text().casefold().strip()
        if query:
            chosen=[x for x in chosen if query in (x.get("title","")+" "+x.get("body","")).casefold()]
        self.list_count.setText(str(len(chosen))+" elementos")
        news_ready=sum(x["state"]=="Listas" for x in self.visible_rows(self.news))
        trend_ready=sum(x["state"]=="Listas" for x in self.visible_rows(self.trends))
        working=sum(x["state"]=="En elaboración" for x in self.news+self.trends)
        self.metric_labels["news_ready"].setText(str(news_ready))
        self.metric_labels["trends_ready"].setText(str(trend_ready))
        self.metric_labels["working"].setText(str(working))
        pending_published={"ttittulares":0,"ttendencias":0}
        for entry in self.pending_actions.values():
            if entry["decision"]=="published" and entry.get("hide_key"):
                pending_published[entry["project"]]+=1
        self.metric_labels["published_news"].setText(str(self.published["ttittulares"]))
        self.metric_labels["published_trends"].setText(str(self.published["ttendencias"]))
        for project,key in (("ttittulares","published_news"),("ttendencias","published_trends")):
            count=pending_published[project]
            self.metric_subtitles[key].setText(
                ("+"+str(count)+" pendiente" if count else "Confirmadas en GitHub"))
        clear_layout(self.list_layout)
        self.card_widgets={}
        if not chosen:
            msg=label("No hay elementos en esta sección.","small",wrap=True)
            self.list_layout.addWidget(msg)
        for item in chosen[:180]:
            card=frame("rowCard")
            is_selected=(self.selected and item["id"]==self.selected["id"]
                         and item["project"]==self.selected["project"])
            card.setProperty("selected",bool(is_selected))
            self.card_widgets[(item["project"],item["id"])]=card
            card.setCursor(Qt.PointingHandCursor)
            cc=col_layout(card,7,(13,12,13,11))
            line=row_layout(spacing=8)
            kind="NOTICIA" if item["project"]=="ttittulares" else "TENDENCIA"
            group_badge=(" · AGRUPADA EN: "+item.get("covered_by_name", "")) if item.get("covered_by_id") else (" · PUBLICACIÓN CONJUNTA" if item.get("is_joint_group") else "")
            cap=label(kind+"  ·  "+item["state"].upper()+group_badge,"eyebrow",wrap=True)
            line.addWidget(cap)
            line.addStretch()
            if item.get("rank"):line.addWidget(label("#"+str(item["rank"]),"eyebrow"))
            cc.addLayout(line)
            ttl=label(item.get("title") or "Sin titular","cardTitle",wrap=True)
            cc.addWidget(ttl)
            snippet=(item.get("body") or "Pendiente de texto.").replace("\n"," ")
            if len(snippet)>115:snippet=snippet[:112].rstrip()+"…"
            cc.addWidget(label(snippet,"small",wrap=True))
            # QWidget event filter is not needed: a transparent, full-card
            # QPushButton makes the entire row keyboard and pointer accessible.
            select=button("Ver y gestionar  ›",lambda checked=False,r=item:self.select_item(r))
            select.setMinimumHeight(28)
            select.setStyleSheet("text-align:left;border:0;background:transparent;color:#77e9d0;padding:2px;font-weight:700;")
            cc.addWidget(select)
            self.list_layout.addWidget(card)
        self.list_layout.addStretch()
        if self.selected:
            visible=any(x["id"]==self.selected["id"] and x["project"]==self.selected["project"] for x in chosen)
            if not visible:self.clear_detail()
            else:
                fresh=next(x for x in chosen if x["id"]==self.selected["id"] and x["project"]==self.selected["project"])
                self.select_item(fresh,load_image=False)
        self.update_actions()

    def clear_detail(self):
        self.selected=None
        self.detail_title.setText("Elige una noticia o tendencia")
        self.detail_meta.setText("Verás aquí el texto, las fuentes y las acciones disponibles.")
        self.state_tag.setText("SELECCIONA UNA TARJETA")
        self.body.setHtml("<p style='color:#99adc4'>Selecciona un elemento de la bandeja.</p>")
        self.loaded_image=QPixmap()
        self.image_label.setPixmap(QPixmap())
        self.image_label.hide()
        self.update_actions()

    def select_item(self,item,load_image=True):
        self.selected=item
        for key,card in self.card_widgets.items():
            card.setProperty("selected",key==(item["project"],item["id"]))
            card.style().unpolish(card)
            card.style().polish(card)
        self.state_tag.setText(item["category"].upper()+"   /   "+item["state"].upper())
        if item.get("covered_by_id"):
            self.state_tag.setText("AGRUPADA EN: "+item.get("covered_by_name", ""))
        elif item.get("is_joint_group"):
            self.state_tag.setText("PUBLICACIÓN CONJUNTA")
        self.detail_title.setText(item.get("title") or "Sin título")
        self.detail_meta.setText("ID "+item["id"]+"  ·  Rev. "+str(item["revision"])+("  ·  #"+str(item.get("rank")) if item.get("rank") else "")+("  ·  "+item.get("trend_status","") if item["state"]=="Top 30" else ""))
        body=html.escape(item.get("body") or "Pendiente de texto.").replace("\n","<br>")
        meta=("<p style='font-size:12px;color:#8fa9bf;margin-top:20px'>"
              "Fuente: "+("disponible" if safe_url(item.get("source")) else "no disponible")+
              " · Foto de archivo: "+("disponible" if safe_url(item.get("image")) else "no disponible")+"</p>")
        self.body.setHtml("<div style='font-family:Segoe UI;font-size:15px;"
                          "line-height:155%;color:#e2edf8'>"+body+"</div>"+meta)
        self.loaded_image=QPixmap()
        self.image_label.setPixmap(QPixmap());self.image_label.hide()
        self.update_actions()
        url=safe_url(item.get("image"))
        if load_image and url:
            key=(item["project"],item["id"])
            def getimage():
                req=urllib.request.Request(url,headers={"User-Agent":"TTActualidad-Windows/1.0"})
                with urllib.request.urlopen(req,timeout=9) as response:
                    typ=response.headers.get("Content-Type","")
                    if not typ.startswith("image/"):raise ValueError("La URL no devuelve una imagen")
                    data=response.read(3_000_001)
                    if len(data)>3_000_000:raise ValueError("Imagen demasiado grande")
                return key,data
            self.worker.run("image",getimage)

    @staticmethod
    def item_key(item):
        return (str(item.get("project") or ""),str(item.get("id") or ""),
                int(item.get("revision") or 0))

    def visible_rows(self,items):
        # Both the Windows and iPhone actions feed the same verified terminal
        # journal. Never re-display a closed revision because one RAW edge
        # temporarily returns an older Listas document.
        return [item for item in items
                if (item.get("state") not in ("Listas","Tremending","En elaboración","Revisión","Creciendo")
                    or not terminal_applies(self.verified_terminals,
                        item.get("project"),item.get("id"),item.get("revision"),
                        item.get("explained_at")))
                and (item.get("state") not in ("Listas","Tremending")
                     or self.item_key(item) not in self.optimistic_hides)]

    def reconcile_optimistic_closures(self):
        # A successful, receipt-backed closure may remain hidden briefly while
        # the GitHub raw CDN catches up. Drop the local overlay as soon as the
        # authoritative list no longer contains the same revision.
        existing={self.item_key(x) for x in self.news+self.trends
                  if x.get("state") in ("Listas","Tremending")}
        active={p.get("hide_key") for p in self.pending_actions.values()}
        for key in list(self.optimistic_hides):
            if key not in existing and key not in active:
                self.optimistic_hides.pop(key,None)

    def update_actions(self):
        row=self.selected
        ready=bool(row and row["state"]=="Listas")
        working=bool(row and row["state"]=="En elaboración")
        top=bool(row and row["state"]=="Top 30")
        tremending=bool(row and row["state"]=="Tremending")
        review=bool(row and row["state"] in ("Revisión","Creciendo"))
        has=bool(row)
        covered=bool(row and row.get("covered_by_id"))
        listas_view=self.section in {"Todas las Listas","Tendencias · Listas"}
        self.group_listas_button.setVisible(listas_view)
        self.remove_grouped_button.setVisible(listas_view)
        grouping_pending=any(x["decision"] in {"group_listas","remove_covered"} for x in self.pending_actions.values())
        self.group_listas_button.setEnabled(not self.sending and not grouping_pending)
        self.remove_grouped_button.setEnabled(not self.sending and not grouping_pending and any(x.get("covered_by_id") for x in self.trends))
        pending_key=self.item_key(row) if has else None
        action_pending=any(p["project"]==row["project"] and p["event_id"]==row["id"] and
                           p["revision"]==int(row.get("revision") or 0)
                           for p in self.pending_actions.values()) if has else False
        enable={
            "copy":has,"gag":has and (ready or top) and bool(row.get("body")),
            "chatgpt":True,"x":has and bool(row.get("body")) and (ready or top),
            "searchx":has,"ttimages":True,
            "source":has and bool(safe_url(row.get("source"))),
            "image":has and bool(safe_url(row.get("image"))),
            "photo_copy":has and not self.loaded_image.isNull(),
            "rework":has and (ready or review or top),
            "hints":has and row["project"]=="ttendencias" and ready,
            "deleted":has and (ready or tremending),
            "discard":has and (working or (review and row["project"]=="ttittulares")),
            "published":has and ready
        }
        if covered:
            for key in ("x","published","rework","hints","gag"):
                enable[key]=False
        for k,b in self.actions.items():
            allowed=enable.get(k,False)
            if (action_pending or self.sending) and k in {"rework","hints","deleted","discard","published"}:
                allowed=False
            b.setEnabled(bool(allowed))
        if row:
            self.actions["deleted"].setText("Retirar agrupada" if covered else "Quitar de Listas")
            self.actions["rework"].setText(
                "Preparar" if row["state"] in ("Revisión","Creciendo")
                or (top and not row.get("body") and row.get("rank",0)>10)
                else "Reelaborar")
            self.actions["published"].setToolTip(
                "Elegir Cancelar / Sí publicada (+1) / No sin publicar (+0).")

    def group_listas(self, cleanup=False):
        if not session_token():
            QMessageBox.warning(self,"Conectar GitHub","Conecta GitHub antes de agrupar.")
            return
        covered=[x for x in self.trends if x.get("state")=="Listas" and x.get("covered_by_id")]
        candidates=[x for x in self.trends if x.get("state")=="Listas" and not x.get("covered_by_id")]
        if (cleanup and not covered) or (not cleanup and len(candidates)<2):
            self.notice.setText("No hay agrupadas para retirar." if cleanup else "Se necesitan dos tendencias en Listas sin cubrir.")
            return
        message=("Retirar las "+str(len(covered))+" tarjetas cubiertas, sin publicar ni borrar sus fichas conjuntas?" if cleanup else
                 "Revisar todas las tendencias de Listas y preparar una ficha conjunta por acontecimiento? Las explicaciones originales se conservarán y quedarán marcadas como agrupadas.")
        if QMessageBox.question(self,"Retirar agrupadas" if cleanup else "Agrupar Listas",message)!=QMessageBox.Yes:
            return
        decision="remove_covered" if cleanup else "group_listas"
        rid=self.grouping_request_ids.setdefault(decision,str(uuid.uuid4()))
        payload={"project":"ttendencias","event_id":"listas-grouping","request_id":rid,"decision":decision}
        if cleanup:payload["items"]=[{"id":x["id"],"revision":x["revision"]} for x in covered]
        self.pending_actions[rid]={"request_id":rid,"project":"ttendencias","event_id":"listas-grouping",
            "revision":0,"decision":decision,"since":time.time(),"hide_key":None,"dispatched":False}
        self.submit("ttactualidad_group_listas_v1",payload)

    def confirm_pending(self):
        if not self.pending_actions:
            return
        receipts=(self.docs.get("action_receipts") or {}).get("items") or []
        by_id={str(x.get("request_id") or ""):x for x in receipts}
        for request_id,pending in list(self.pending_actions.items()):
            receipt=by_id.get(request_id)
            if receipt:
                status=str(receipt.get("status") or "").lower()
                if status in {"applied","already_applied"}:
                    # Never count optimistic publications as confirmed; counts
                    # are calculated only from publication-events.json.
                    if pending.get("hide_key"):
                        self.optimistic_hides[pending["hide_key"]]="confirmed"
                    self.pending_actions.pop(request_id,None)
                    if pending["decision"] in self.grouping_request_ids:
                        self.grouping_request_ids.pop(pending["decision"],None)
                    self.notice.setText("GitHub confirmó «"+pending["decision"]+
                                        "» · "+pending["event_id"])
                elif status in {"rejected","failed","error","invalid"}:
                    if pending.get("hide_key"):
                        self.optimistic_hides.pop(pending["hide_key"],None)
                    self.pending_actions.pop(request_id,None)
                    self.notice.setText("GitHub rechazó la orden: "+str(receipt.get("error") or status)+
                                        " · tarjeta restaurada")
                # queued/processing is NOT a rejection or a confirmed deletion.
                continue
            if time.time()-pending["since"]>=600:
                # A delayed GitHub Actions receipt must not cause a card to
                # reappear 80 seconds after the user removed it. Ten minutes
                # without proof is UNCERTAIN, not published or deleted.
                self.pending_actions.pop(request_id,None)
                if pending.get("hide_key"):
                    self.optimistic_hides.pop(pending["hide_key"],None)
                self.notice.setText("Orden SIN CONFIRMAR tras 10 min: verifica GitHub antes de repetirla.")
        self.update_actions()

    def expire_pending(self):
        if any(time.time()-p["since"]>=600 for p in self.pending_actions.values()):
            self.confirm_pending()
            self.render_list()

    def copy_gag(self):
        """GAG_VISUAL_NATIVE_V2: hechos y remate solo como contexto, no como texto gráfico."""
        row=self.selected
        if not row or not row.get("body"):return
        full=str(row["body"])
        title=str(row.get("title") or "")
        closer=next((p.strip() for p in reversed(full.splitlines()) if p.strip().startswith("🌶")),"")
        factual="\n".join(p.strip() for p in full.splitlines()
                          if p.strip() and not p.strip().startswith(("🌶","#")))
        kind="TTendencias" if row["project"]=="ttendencias" else "TTiTTulares"
        styles=[
            "Caricatura editorial contemporánea de alta calidad, línea de tinta expresiva y acuarela controlada, gestos muy trabajados y fondo ligero.",
            "Cómic europeo contemporáneo, entintado preciso, volumen sólido y expresiones fuertes.",
            "Póster gráfico editorial sofisticado, formas contundentes y textura de impresión, SIN tipografía.",
            "Escena absurda semirrealista, iluminación natural y situación imposible tratada con precisión visual.",
            "Diorama editorial tipo stop-motion/clay, miniaturas artesanales y detalle selectivo.",
            "Ilustración publicitaria retro de los años 60 reinterpretada con dibujo elegante e ironía visual.",
            "Grabado/linograbado moderno, textura rica y un único foco narrativo.",
            "Pop art editorial refinado, serigrafía y energía gráfica sin saturación.",
            "Cartoon 3D editorial estilizado, modelado cuidado y expresiones claras.",
            "Novela gráfica satírica, dibujo detallado y composición sobria."
        ]
        low=(title+" "+factual).lower()
        sensitive=any(w in low for w in (
            "víctim","victim","fallec","muert","murió","murio","traged","accident",
            "agresión sexual","agresion sexual","violaci","asesinat","atentad",
            "desaparecid","herid","catástrof","suicid"))
        key=kind+"|"+str(row.get("id") or title)+"|r"+str(row.get("revision") or 0)
        index=0
        for b in key.encode("utf-8"):index=(index*33+b)%len(styles)
        visual=("ILUSTRACIÓN PERIODÍSTICA RIGUROSA Y RESPETUOSA, sin humor ni caricatura de las víctimas, sin escenas gráficas ni datos inventados."
                if sensitive else "GAG EDITORIAL VISUAL: "+styles[index]+
                " Más gag, menos barroquismo: una sola idea fuerte, lectura en 1–2 segundos, uno a tres protagonistas y fondo mínimo. "
                "El gag nace de la IDEA del remate, nunca de reproducir el titular.")
        prompt="\n\n".join([
            "Genera AHORA UNA SOLA imagen "+("EDITORIAL PERIODÍSTICA" if sensitive else "GAG IA")+
            " para "+kind+". Formato horizontal 16:9; ilustración a sangre, de borde a borde.",
            "REGLA ABSOLUTA: SOLO IMAGEN, SIN NINGÚN TEXTO. No dibujar titular, explicación, remate, hashtags, cifras, "
            "nombres, números, letras, bocadillos, carteles, etiquetas, logotipos, créditos ni pie de foto. "
            "NO crear una tarjeta de noticia, publicación maquetada, infografía, collage o interfaz. "
            "PROHIBIDA la franja inferior blanca o negra, panel, banda, marco, cabecera o espacio para escribir. "
            "La ilustración ocupa TODO el lienzo.",
            "Los hechos siguientes son CONTEXTO NO VISIBLE. No escribir, copiar ni rotular su contenido.",
            "ASUNTO (SOLO CONTEXTO):\n"+("#"+str(row["rank"])+" " if row.get("rank") else "")+title,
            "HECHOS EDITORIALES (SOLO CONTEXTO):\n"+factual,
            "REMATE (SOLO INSPIRACIÓN VISUAL, NUNCA TEXTO EN LA IMAGEN):\n"+(
                closer or "Sin remate separado; no inventar uno."),
            "DIRECCIÓN ARTÍSTICA DE ELABORACIÓN EDITORIAL:\n"+visual,
            "No inventar hechos, declaraciones, culpabilidades ni daños. El emoji 🌶️ solo marca el remate: "
            "PROHIBIDO dibujar guindillas, chiles, pimientos o sus iconos. "+
            ("Tratar con respeto a las víctimas y familiares." if sensitive else
             "Metáfora visual ingeniosa, no representación literal del titular."),
            "ENTREGAR EXACTAMENTE UNA ILUSTRACIÓN LIMPIA, SIN TEXTO, SIN FRANJA INFERIOR NI TARJETA."
        ])
        QApplication.clipboard().setText(prompt)
        self.notice.setText("Prompt de imagen pura copiado · abre ChatGPT Images para pegarlo.")

    def search_x(self):
        if not self.selected:return
        terms=self.selected["title"]
        url="https://x.com/search?q="+urllib.parse.quote(terms)+"&f=live"
        webbrowser.open(url)

    def copy_photo(self):
        if not self.loaded_image.isNull():
            QApplication.clipboard().setPixmap(self.loaded_image)
            self.notice.setText("Foto de archivo copiada al portapapeles.")

    def prepare_or_rework(self):
        row=self.selected
        if not row:return
        if row["state"] in ("Revisión","Creciendo"):
            self.editorial_action("prepare")
        elif row["state"]=="Top 30" and not row.get("body") and row.get("rank",0)>10:
            if not row.get("id","").startswith("manual-"):
                QMessageBox.warning(self,"Top 30","Actualiza: no se puede verificar el identificador manual.")
                return
            self.editorial_action("prepare")
        else:
            self.editorial_action("rework")

    def add_hints(self):
        row=self.selected
        if not row or row["project"]!="ttendencias" or row["state"]!="Listas":return
        hint,ok=QInputDialog.getMultiLineText(self,"Pistas para la tendencia",
            "Fuentes, contexto y qué debe cambiar en la explicación de "+row["title"]+":")
        if not ok:return
        hint=hint.strip()
        if not 8<=len(hint)<=6000:
            QMessageBox.warning(self,"Pistas","Introduce entre 8 y 6000 caracteres.")
            return
        self.editorial_action("hints",hint=hint)

    def open_link(self,url):
        parsed=safe_url(url.toString())
        if parsed:webbrowser.open(parsed)

    def copy_text(self):
        if self.selected:
            QApplication.clipboard().setText(self.selected.get("body") or self.selected.get("title",""))
            self.notice.setText("Texto copiado al portapapeles.")

    def open_source(self):
        if self.selected and safe_url(self.selected.get("source")):
            webbrowser.open(self.selected["source"])

    def open_image(self):
        if self.selected and safe_url(self.selected.get("image")):
            webbrowser.open(self.selected["image"])

    def publish_x(self):
        row=self.selected
        if not row or not row.get("body"):return
        if self.sending:
            self.notice.setText("La solicitud anterior sigue enviándose.")
            return
        tweet=row["body"][:280]
        opened=webbrowser.open("https://twitter.com/intent/tweet?text="+urllib.parse.quote(tweet))
        if not opened:
            self.notice.setText("No se pudo abrir X. Ningún estado editorial ha cambiado.")
            return
        # We cannot inspect the X browser. Only the person can confirm the
        # outcome. Show all THREE choices, and never equate opening X to posting.
        self.ask_publication_outcome(row)

    def ask_publication_outcome(self,row=None):
        row=row or self.selected
        if not row or row.get("state")!="Listas" or self.sending:
            return
        if not row.get("id"):
            self.notice.setText("Falta ID editorial. Actualiza GitHub antes de cerrar.")
            return
        dlg=QMessageBox(self)
        dlg.setWindowTitle("¿Has publicado en X?")
        dlg.setIcon(QMessageBox.Question)
        dlg.setText("¿Se ha publicado realmente este contenido en X?")
        dlg.setInformativeText(row["title"]+"\n\n"
            "Sí: retirar de Listas y sumar 1 a Publicadas 24 h.\n"
            "No: retirar de Listas SIN sumar al contador.\n"
            "Cancelar: no modificar nada.")
        yes=dlg.addButton("Sí · publicada",QMessageBox.AcceptRole)
        no=dlg.addButton("No · retirar",QMessageBox.DestructiveRole)
        cancel=dlg.addButton("Cancelar",QMessageBox.RejectRole)
        dlg.setDefaultButton(cancel)
        dlg.exec()
        chosen=dlg.clickedButton()
        choice="yes" if chosen is yes else "no" if chosen is no else "cancel"
        decision=publication_outcome(choice)
        if decision is not None:
            self.editorial_action(decision,confirmed=True)
        # Cancel deliberately sends no GitHub event.


    def submit(self,event,payload):
        action_event=event=="ttactualidad_action_v1"
        key=(payload["project"],payload.get("event_id",""),int(payload.get("revision") or 0))
        if not action_event and self.sending:
            self.notice.setText("Ya hay una nueva noticia en proceso de envío.")
            return
        if action_event and any(
            p["project"]==key[0] and p["event_id"]==key[1] and p["revision"]==key[2]
            for p in self.pending_actions.values()):
            self.notice.setText("Esta tarjeta ya tiene una orden pendiente.")
            return
        request_id=payload["request_id"]
        if action_event:
            hide_key=key if (payload.get("decision") in {"published","deleted"}
                             and self.selected and
                             self.selected.get("state") in {"Listas","Tremending"}) else None
            self.pending_actions[request_id]={
                "request_id":request_id,"project":key[0],"event_id":key[1],
                "revision":key[2],"decision":payload.get("decision"),
                "since":time.time(),"hide_key":hide_key,"dispatched":False
            }
            if hide_key:
                self.optimistic_hides[hide_key]="pending"
                # This is a UI-only overlay. Never write terminal state into
                # the local authoritative JSON or the confirmed 24h counter.
                self.render_list()
                self.notice.setText("Tarjeta apartada · confirmación de GitHub pendiente…")
        else:
            self.sending=True
            self.notice.setText("Enviando la nueva noticia a GitHub…")
        self.update_actions()
        def perform():
            try:
                token=session_token()
                if not token:
                    raise ValueError("Conecta GitHub antes de enviar órdenes.")
                status,_=request(API,method="POST",token=token,timeout=25,
                    data={"event_type":event,"client_payload":payload})
                if status!=204:
                    raise RuntimeError("GitHub no aceptó la orden (HTTP "+str(status)+")")
                return request_id,None
            except Exception as exc:
                return request_id,str(exc)
        self.worker.run("submit",perform)

    def editorial_action(self,action,hint="",confirmed=False):
        r=self.selected
        if not r:return
        if not r.get("id"):
            QMessageBox.warning(self,"No verificable","Esta tarjeta aún no tiene ID editorial. Actualiza.")
            return
        if action in ("published","deleted","discard") and not confirmed:
            prompt={
                "published":"¿Ya la has publicado en X? Esta orden SOLO registrará la publicación en GitHub; no enviará ningún tuit.",
                "deleted":"¿Quitar esta tarjeta de Listas?",
                "discard":"¿Desestimar esta tarjeta en elaboración?"
            }[action]
            if QMessageBox.question(self,"Confirmación editorial",prompt+"\n\n"+r["title"]+
                "\n\nEl resultado se verificará automáticamente en GitHub.")!=QMessageBox.Yes:
                return
        payload={"project":r["project"],"event_id":r["id"],"revision":r["revision"],
            "decision":action,"request_id":str(uuid.uuid4()),"received_at":stamp(),
            "trend_name":r.get("title"),"trend_rank":r.get("rank",0)}
        if action=="hints":
            payload["hints"]=hint
        self.submit("ttactualidad_action_v1",payload)

    def new_story(self):
        dlg=StoryDialog(self)
        if dlg.exec()!=QDialog.Accepted:return
        try:payload=dlg.payload()
        except ValueError as exc:
            QMessageBox.warning(self,"Nueva noticia",str(exc));return
        self.submit("ttactualidad_manual_news_v1",payload)

def main():
    app=QApplication([])
    app.setStyle("Fusion")
    app.setStyleSheet(STYLE)
    win=MainWindow()
    win.show()
    app.exec()

if __name__=="__main__":
    main()

