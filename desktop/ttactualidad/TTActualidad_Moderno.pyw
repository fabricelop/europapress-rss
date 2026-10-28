# -*- coding: utf-8 -*-
"""TTActualidad Windows — native Qt desktop. No Worker, local server or phone required."""
from __future__ import annotations

import datetime as dt
import html
import json
import os
import pathlib
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
    QMessageBox, QTextEdit, QInputDialog, QSizePolicy, QSplitter
)

from TTActualidad import FILES, RAW, API, REPO, KEYRING_SERVICE, normalise, request, text

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

def fetch_editorial():
    result={}
    def one(pair):
        key,path=pair
        _,data=request(RAW+path+"?cache="+str(int(time.time())),timeout=17)
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
        self.resize(1460,920)
        self.setMinimumSize(1050,670)
        self.docs={}
        self.news=[];self.trends=[];self.top30=[];self.published={"ttittulares":0,"ttendencias":0}
        self.selected=None;self.section="Todas las Listas"
        self.refreshing=False;self.sending=False
        self.events=Events()
        self.events.finished.connect(self.on_finished)
        self.worker=Worker(self.events)
        self.nav={}
        self.draw()
        self.timer=QTimer(self)
        self.timer.timeout.connect(self.refresh)
        self.timer.start(120000)
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
        for title,key in [("NOTICIAS EN LISTAS","news_ready"),("TENDENCIAS EN LISTAS","trends_ready"),
                          ("EN ELABORACIÓN","working"),("PUBLICADAS · 24 H","published")]:
            card=frame("metric")
            vv=col_layout(card,7,(17,14,17,14))
            vv.addWidget(label(title,"eyebrow"))
            value=label("—","metricNumber")
            vv.addWidget(value)
            self.metric_labels[key]=value
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
        rl=col_layout(right,13,(24,22,24,22))
        self.state_tag=label("SELECCIONA UNA TARJETA","eyebrow")
        rl.addWidget(self.state_tag)
        self.detail_title=label("Elige una noticia o tendencia","detailTitle",wrap=True)
        rl.addWidget(self.detail_title)
        self.detail_meta=label("Verás aquí el texto, las fuentes y las acciones disponibles.","small",wrap=True)
        rl.addWidget(self.detail_meta)
        self.image_label=label()
        self.image_label.setFixedHeight(0)
        self.image_label.setAlignment(Qt.AlignCenter)
        self.image_label.setStyleSheet("border-radius:12px;background:#17283a;")
        rl.addWidget(self.image_label)
        self.body=QTextBrowser()
        self.body.setOpenExternalLinks(False)
        self.body.anchorClicked.connect(self.open_link)
        self.body.setHtml("<p style='color:#99adc4'>Selecciona un elemento de la bandeja.</p>")
        rl.addWidget(self.body,1)
        self.actions={}
        rl.addWidget(label("CREACIÓN Y PUBLICACIÓN","eyebrow"))
        tool_actions=QGridLayout()
        tool_actions.setHorizontalSpacing(8);tool_actions.setVerticalSpacing(8)
        tools=[
            ("Copiar texto","copy",self.copy_text,None),
            ("Copiar GAG","gag",self.copy_gag,None),
            ("ChatGPT Images ↗","chatgpt",lambda:webbrowser.open("https://chatgpt.com/images"),None),
            ("Publicar en X ↗","x",self.publish_x,"primary"),
            ("Buscar en X ↗","searchx",self.search_x,None),
            ("TTImages ↗","ttimages",lambda:webbrowser.open("https://t.me/TTImages_bot"),None),
            ("Abrir fuente ↗","source",self.open_source,None),
            ("Ver foto archivo ↗","image",self.open_image,None),
            ("Copiar foto","photo_copy",self.copy_photo,None)
        ]
        for i,(caption,key,fn,kind) in enumerate(tools):
            btn=button(caption,fn,kind);self.actions[key]=btn
            tool_actions.addWidget(btn,i//3,i%3)
        rl.addLayout(tool_actions)
        rl.addWidget(label("ACCIONES EDITORIALES","eyebrow"))
        edit_actions=QGridLayout()
        edit_actions.setHorizontalSpacing(8);edit_actions.setVerticalSpacing(8)
        decisions=[
            ("Preparar / Reelaborar","rework",self.prepare_or_rework,None),
            ("Añadir pistas","hints",self.add_hints,None),
            ("Quitar de Listas","deleted",lambda:self.editorial_action("deleted"),"danger"),
            ("Desestimar","discard",lambda:self.editorial_action("discard"),"danger"),
            ("Confirmar publicada","published",lambda:self.editorial_action("published"),None)
        ]
        for i,(caption,key,fn,kind) in enumerate(decisions):
            btn=button(caption,fn,kind);self.actions[key]=btn
            edit_actions.addWidget(btn,i//3,i%3)
        rl.addLayout(edit_actions)
        splitter.addWidget(right)
        splitter.setSizes([475,720])
        self.notice=label("La información proviene directamente de GitHub. Ninguna acción se confirma antes de verificarse.","small",wrap=True)
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
        self.notice.setText("Sesión cerrada. La lectura pública sigue disponible.")

    def refresh(self):
        if self.refreshing:return
        self.refreshing=True
        self.reload.setEnabled(False)
        self.notice.setText("Sincronizando el estado editorial desde GitHub…")
        self.worker.run("refresh",fetch_editorial)

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
            self.notice.setText("Conexión verificada con GitHub · @"+login)
        elif kind=="refresh":
            self.refreshing=False;self.reload.setEnabled(True)
            if error:
                self.notice.setText("No se han sustituido los datos anteriores: "+error)
                return
            self.docs,processed=value
            self.news,self.trends,self.top30,self.published=processed
            self.render_list()
            self.notice.setText("GitHub actualizado · "+dt.datetime.now().strftime("%H:%M:%S"))
        elif kind=="submit":
            self.sending=False
            if error:
                self.notice.setText("Acción no enviada: "+error)
                QMessageBox.warning(self,"Acción no enviada",error)
                return
            self.notice.setText("GitHub ha recibido la orden · "+value[:8]+
                                " · pendiente de confirmación en los archivos editoriales.")
            QTimer.singleShot(6000,self.refresh)
            QTimer.singleShot(15000,self.refresh)
        elif kind=="image":
            rowkey,data=value if not error else (None,None)
            if error or not data or not self.selected or rowkey!=(self.selected["project"],self.selected["id"]):
                return
            pix=QPixmap()
            if not pix.loadFromData(data):return
            self.image_label.setPixmap(pix.scaled(QSize(820,180),Qt.KeepAspectRatio,Qt.SmoothTransformation))
            self.image_label.setFixedHeight(180)

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
        chosen=self.list_data()
        query=self.search.text().casefold().strip()
        if query:
            chosen=[x for x in chosen if query in (x.get("title","")+" "+x.get("body","")).casefold()]
        self.list_count.setText(str(len(chosen))+" elementos")
        news_ready=sum(x["state"]=="Listas" for x in self.news)
        trend_ready=sum(x["state"]=="Listas" for x in self.trends)
        working=sum(x["state"]=="En elaboración" for x in self.news+self.trends)
        self.metric_labels["news_ready"].setText(str(news_ready))
        self.metric_labels["trends_ready"].setText(str(trend_ready))
        self.metric_labels["working"].setText(str(working))
        self.metric_labels["published"].setText(str(sum(self.published.values())))
        clear_layout(self.list_layout)
        if not chosen:
            msg=label("No hay elementos en esta sección.","small",wrap=True)
            self.list_layout.addWidget(msg)
        for item in chosen[:180]:
            card=frame("rowCard")
            card.setCursor(Qt.PointingHandCursor)
            cc=col_layout(card,7,(13,12,13,11))
            line=row_layout(spacing=8)
            kind="NOTICIA" if item["project"]=="ttittulares" else "TENDENCIA"
            cap=label(kind+"  ·  "+item["state"].upper(),"eyebrow")
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
        self.image_label.setPixmap(QPixmap())
        self.image_label.setFixedHeight(0)
        self.update_actions()

    def select_item(self,item,load_image=True):
        self.selected=item
        self.state_tag.setText(item["category"].upper()+"   /   "+item["state"].upper())
        self.detail_title.setText(item.get("title") or "Sin título")
        self.detail_meta.setText("ID "+item["id"]+"  ·  Revisión "+str(item["revision"]))
        body=html.escape(item.get("body") or "Pendiente de texto.").replace("\n","<br>")
        meta=("<p style='font-size:12px;color:#8fa9bf;margin-top:20px'>"
              "Fuente: "+("disponible" if safe_url(item.get("source")) else "no disponible")+
              " · Foto de archivo: "+("disponible" if safe_url(item.get("image")) else "no disponible")+"</p>")
        self.body.setHtml("<div style='font-family:Segoe UI;font-size:15px;"
                          "line-height:155%;color:#e2edf8'>"+body+"</div>"+meta)
        self.image_label.setPixmap(QPixmap());self.image_label.setFixedHeight(0)
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

    def update_actions(self):
        row=self.selected
        has=bool(row)
        ready=has and row["state"]=="Listas"
        working=has and row["state"]=="En elaboración"
        for k in ("copy","x","source","image","rework","discard","deleted","published"):
            self.actions[k].setEnabled(bool(has))
        if not has:return
        self.actions["source"].setEnabled(bool(safe_url(row.get("source"))))
        self.actions["image"].setEnabled(bool(safe_url(row.get("image"))))
        self.actions["published"].setEnabled(bool(ready))
        self.actions["deleted"].setEnabled(bool(ready))
        self.actions["discard"].setEnabled(bool(working))
        self.actions["rework"].setEnabled(bool(ready or row["state"]=="Top 30"))

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
        if self.selected:
            tweet=(self.selected.get("body") or self.selected.get("title",""))[:280]
            webbrowser.open("https://twitter.com/intent/tweet?text="+urllib.parse.quote(tweet))

    def submit(self,event,payload):
        if self.sending:return
        self.sending=True
        self.notice.setText("Enviando la orden a GitHub…")
        def perform():
            token=session_token()
            if not token:raise ValueError("Conecta GitHub antes de enviar órdenes.")
            status,_=request(API,method="POST",token=token,timeout=25,
                data={"event_type":event,"client_payload":payload})
            if status!=204:raise RuntimeError("GitHub no aceptó la orden (HTTP "+str(status)+")")
            return payload["request_id"]
        self.worker.run("submit",perform)

    def editorial_action(self,action):
        r=self.selected
        if not r:return
        if action in ("published","deleted","discard"):
            msg={"published":"Marcar como publicada","deleted":"Quitar de Listas","discard":"Desestimar"}[action]
            if QMessageBox.question(self,msg,"¿"+msg+"?\n\n"+r["title"]+
                "\n\nGitHub volverá a verificar la revisión y el estado editorial.")!=QMessageBox.Yes:
                return
        payload={"project":r["project"],"event_id":r["id"],"revision":r["revision"],
            "decision":action,"request_id":str(uuid.uuid4()),"received_at":stamp(),
            "trend_name":r.get("title"),"trend_rank":r.get("rank",0)}
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
