#!/usr/bin/env python3
"""Conservative V1 editorial exclusions, ported as pure V2 functions."""
from __future__ import annotations
import re
import unicodedata

HOROSCOPE_WORD_RE = re.compile(r"\b(?:horoscopo|horoscopos|horscopo|horscopos)\b")
ZODIAC_SIGNS = ("aries","tauro","geminis","cancer","leo","virgo","libra","escorpio",
                "sagitario","capricornio","acuario","piscis")
WEEKDAYS = ("lunes","martes","miercoles","jueves","viernes","sabado","domingo")
MONTHS = ("enero","febrero","marzo","abril","mayo","junio","julio","agosto","septiembre",
          "octubre","noviembre","diciembre")

LOTTERY_GAMES = ("bonoloto","euromillones","la primitiva","gordo de la primitiva",
                 "eurojackpot","eurodreams","loteria nacional","loteria de navidad",
                 "loteria del nino","cupon once","cupon diario","cuponazo","sueldazo",
                 "super once","triplex","mi dia","lototurf","quinigol","quiniela")
ROUTINE_DRAW = ("comprobar","resultado","resultados","combinacion ganadora","numero premiado",
                "numeros premiados","numeros ganadores","sorteo de hoy","sorteo hoy",
                "sorteo del","sorteo de la","combinacion del","premios de hoy")
MATERIAL_LOTTERY = ("acertante","un ganador","una ganadora","reparte","repartido","vendido en",
                    "cae en","premio record","fraude","estafa","detenido","detenida",
                    "investiga","investigacion","error","fallo","cancelado","suspendido",
                    "cambio de reglas","cambio normativo","nueva norma","nuevo sistema")

SPORT_IMPORTANT = (
 "mundial","eurocopa","champions","europa league","conference league","laliga","liga de campeones",
 "copa del rey","supercopa","seleccion espanola","espana","real madrid","barcelona","atletico de madrid",
 "alcaraz","sinner","djokovic","nadal","wimbledon","roland garros","us open","australian open","masters 1000",
 "formula 1","f1","motogp","marquez","alonso","sainz","ciclismo","tour de france","giro","vuelta a espana",
 "pogacar","vingegaard","evenepoel","juegos olimpicos","olimpicos","mundial de atletismo","record mundial",
 "nba","euroliga","acb","real madrid baloncesto","barcelona baloncesto","copa davis","billie jean king",
 "fallece","muere","lesion grave","retirada","sancion","dopaje","record","campeon","campeona","titulo mundial"
)
SPORT_MINOR = (
 "segunda division","laliga hypertmotion","primera rfef","segunda rfef","tercera rfef","juvenil","cadete",
 "grupo 1","grupo 2","grupo 3","grupo 4","grupo 5","resultados, partidos y clasificacion","resultados y clasificacion"
)


def norm_text(value):
    text = "".join(c for c in unicodedata.normalize("NFKD", str(value or "").lower())
                   if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]+", " ", text).strip()


def _daily_marker(text):
    padded = f" {text} "
    if any(phrase in padded for phrase in (" hoy "," diario "," diaria "," del dia ",
                                           " para hoy "," esta semana "," semanal "," manana ")):
        return True
    if any(f" {day} " in padded for day in WEEKDAYS):
        return True
    return bool(re.search(r"\b(?:[0-3]?\d)\s+de\s+(?:" + "|".join(MONTHS) + r")\b", text))


def content_filter_reason(title, url=""):
    text = norm_text(title)
    if not text:
        return "empty_title"
    padded = f" {text} "
    url_l = str(url or "").lower()
    if "que te deparan los astros" in text:
        return "astrology_daily"
    has_horoscope = bool(HOROSCOPE_WORD_RE.search(text))
    daily = _daily_marker(text)
    forecast = any(word in padded for word in (
        " prediccion "," predicciones "," pronostico "," pronosticos "," amor "," dinero "," salud "," suerte "
    ))
    if has_horoscope:
        starts_like_forecast = bool(re.match(
            r"^(?:(?:consulta|mira|descubre|lee)\s+)?(?:tu\s+|el\s+|los\s+)?"
            r"(?:horoscopo|horoscopos|horscopo|horscopos)\b", text))
        direct_daily = bool(re.search(
            r"\b(?:horoscopo|horoscopos|horscopo|horscopos)\s+(?:de|para)\s+hoy\b"
            r"|\b(?:horoscopo|horscopo)\s+diari[oa]\b", text))
        horoscope_section = "/horoscop" in url_l or "/horscop" in url_l
        if ((starts_like_forecast and (daily or forecast or direct_daily)) or
                (horoscope_section and (daily or forecast))):
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


def routine_lottery_result(title):
    text = norm_text(title)
    if not text or not any(term in text for term in LOTTERY_GAMES):
        return False
    if any(term in text for term in MATERIAL_LOTTERY):
        return False
    return any(term in text for term in ROUTINE_DRAW)


def sport_important(title):
    text = norm_text(title)
    if any(term in text for term in SPORT_MINOR):
        return False
    return any(term in text for term in SPORT_IMPORTANT)


def filter_row(title, url="", source_type="general"):
    reason = content_filter_reason(title, url)
    if reason:
        return reason
    if routine_lottery_result(title):
        return "routine_lottery_result"
    if source_type == "sport" and not sport_important(title):
        return "sport_not_in_priority_scope"
    return None
