#!/usr/bin/env python3
"""Filtros editoriales de bajo valor compartidos por radar y auto-queue.

La regla de astrología es deliberadamente conservadora: bloquea pronósticos
astrológicos/horóscopos editoriales, no noticias que hablen SOBRE astrología.
"""
import re
import unicodedata

HOROSCOPE_WORD_RE = re.compile(r"\b(?:horoscopo|horoscopos|horscopo|horscopos)\b")
ZODIAC_SIGNS = (
    "aries","tauro","geminis","cancer","leo","virgo","libra","escorpio",
    "sagitario","capricornio","acuario","piscis",
)
WEEKDAYS = ("lunes","martes","miercoles","jueves","viernes","sabado","domingo")
MONTHS = ("enero","febrero","marzo","abril","mayo","junio","julio","agosto","septiembre","octubre","noviembre","diciembre")

def norm_text(value):
    text = "".join(
        c for c in unicodedata.normalize("NFKD", str(value or "").lower())
        if not unicodedata.combining(c)
    )
    return re.sub(r"[^a-z0-9]+", " ", text).strip()

def _daily_marker(text):
    padded = f" {text} "
    if any(phrase in padded for phrase in (
        " hoy ", " diario ", " diaria ", " del dia ", " para hoy ",
        " esta semana ", " semanal ", " manana ",
    )):
        return True
    if any(f" {day} " in padded for day in WEEKDAYS):
        return True
    if re.search(r"\b(?:[0-3]?\d)\s+de\s+(?:" + "|".join(MONTHS) + r")\b", text):
        return True
    return False

def content_filter_reason(title, url=""):
    text = norm_text(title)
    if not text:
        return None
    padded = f" {text} "
    url_l = str(url or "").lower()

    if "que te deparan los astros" in text:
        return "astrology_daily"

    has_horoscope = bool(HOROSCOPE_WORD_RE.search(text))
    daily = _daily_marker(text)
    forecast = any(word in padded for word in (
        " prediccion ", " predicciones ", " pronostico ", " pronosticos ",
        " amor ", " dinero ", " salud ", " suerte ",
    ))

    if has_horoscope:
        starts_like_forecast = bool(re.match(
            r"^(?:(?:consulta|mira|descubre|lee)\s+)?(?:tu\s+|el\s+|los\s+)?"
            r"(?:horoscopo|horoscopos|horscopo|horscopos)\b",
            text,
        ))
        direct_daily = bool(re.search(
            r"\b(?:horoscopo|horoscopos|horscopo|horscopos)\s+(?:de|para)\s+hoy\b"
            r"|\b(?:horoscopo|horscopo)\s+diari[oa]\b",
            text,
        ))
        horoscope_section = "/horoscop" in url_l or "/horscop" in url_l
        if (starts_like_forecast and (daily or forecast or direct_daily)) or (
            horoscope_section and (daily or forecast)
        ):
            return "astrology_daily"

    if re.match(r"^predicciones?\s+(?:del\s+)?zodiaco\b", text):
        return "astrology_daily"

    if re.match(r"^(?:los\s+)?signos\s+del\s+zodiaco\b", text) and (daily or forecast):
        return "astrology_daily"
    if "signos del zodiaco" in text and daily and forecast:
        return "astrology_daily"

    sign_hits = sum(1 for sign in ZODIAC_SIGNS if f" {sign} " in padded)
    if sign_hits >= 1 and daily and re.search(r"\bpredicciones?\s+para\b", text):
        return "astrology_daily"
    if sign_hits >= 2 and daily and ("astros" in text or forecast):
        return "astrology_daily"

    return None

def run_filter_regressions():
    positives = [
        ("Horscopo de hoy lunes 5 de octubre de 2026", "https://www.elmundo.es/yodona/horoscopo/2026/10/05/x.html"),
        ("Tu horóscopo diario: lunes 5 de octubre de 2026", "https://example.test/gente/x"),
        ("Predicciones del zodiaco para hoy: qué esperar este lunes", "https://example.test/x"),
        ("Signos del zodiaco: qué te deparan los astros este lunes", "https://example.test/x"),
        ("Predicciones para Aries hoy: amor, dinero y salud", "https://example.test/x"),
        ("Aries y Tauro: predicciones para hoy según los astros", "https://example.test/x"),
    ]
    negatives = [
        ("Un estudio científico analiza por qué creemos en los horóscopos", "https://example.test/ciencia/x"),
        ("El museo dedica una exposición al zodiaco en el arte medieval", "https://example.test/cultura/x"),
        ("La revista elimina su sección de horóscopo diario tras 30 años", "https://example.test/medios/x"),
        ("Horóscopo, el caballo que sorprendió en la carrera de otoño", "https://example.test/deportes/x"),
        ("La NASA explica el origen de las constelaciones del zodiaco", "https://example.test/ciencia/x"),
        ("Una historiadora publica un ensayo sobre astrología renacentista", "https://example.test/cultura/x"),
    ]
    for title, url in positives:
        reason = content_filter_reason(title, url)
        if reason != "astrology_daily":
            raise RuntimeError("Regresión filtro astrología: debía bloquear: " + title)
    for title, url in negatives:
        reason = content_filter_reason(title, url)
        if reason is not None:
            raise RuntimeError("Regresión filtro astrología: falso positivo: " + title)
    return True
