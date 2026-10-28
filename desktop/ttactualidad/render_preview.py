# Offline visual regression snapshot: only fabricated editorial data, no GitHub credentials.
import importlib.machinery
import importlib.util
import os
import pathlib
import sys
from unittest.mock import patch

os.environ["QT_QPA_PLATFORM"]="offscreen"
root=pathlib.Path(__file__).resolve().parent
sys.path.insert(0,str(root))
loader=importlib.machinery.SourceFileLoader("TTActualidad_Moderno",str(root/"TTActualidad_Moderno.pyw"))
spec=importlib.util.spec_from_loader(loader.name,loader)
m=importlib.util.module_from_spec(spec)
loader.exec_module(m)
app=m.QApplication([])
app.setStyle("Fusion")
app.setStyleSheet(m.STYLE)
with patch.object(m.MainWindow,"refresh",lambda self:None):
    w=m.MainWindow()
    w.resize(1420,840)
    w.news=[
        {"project":"ttittulares","id":"sample-1","revision":1,"state":"Listas",
         "title":"La coordinación ferroviaria y las medidas de seguridad, a debate",
         "body":"Las autoridades revisan los protocolos ferroviarios y anuncian nuevas comprobaciones de infraestructura.\n\n#Ferrocarril #Transporte",
         "category":"Noticias","source":"https://example.org/article","image":""},
        {"project":"ttittulares","id":"sample-2","revision":1,"state":"Listas",
         "title":"Nuevas medidas de movilidad en las principales ciudades",
         "body":"Se presentan medidas de movilidad para mejorar la conexión de los barrios.\n\n#Movilidad",
         "category":"Noticias","source":"","image":""},
    ]
    w.trends=[
        {"project":"ttendencias","id":"sample-t","revision":0,"state":"Listas",
         "title":"Movilidad urbana","body":"TT#3 Movilidad urbana es tendencia por los nuevos planes metropolitanos.",
         "category":"Tendencias","source":"","image":"","rank":3},
    ]
    w.published={"ttittulares":26,"ttendencias":18}
    w.change_section("Todas las Listas")
    w.show()
    app.processEvents()
    w.select_item(w.news[0],load_image=False)
    app.processEvents()
    target=root/"dist"/"TTActualidad-preview.png"
    target.parent.mkdir(parents=True,exist_ok=True)
    ok=w.grab().save(str(target))
    if not ok or target.stat().st_size<20000:
        raise RuntimeError("Windows UI snapshot missing or too small")
    print("Offline preview saved",target, target.stat().st_size)
    w.close()
