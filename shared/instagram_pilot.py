"""Shared, opt-in preparation of Instagram pilot assets for Telegram senders.
No Telegram or Meta calls. Requires Pillow; no posting happens here.
"""
import hashlib
import io
import os
import pathlib
import re
from PIL import Image, ImageOps

FLAG = "INSTAGRAM_PILOT_ENABLED"
URL_BASE = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/"
EXTENTS = {"ttittulares", "trends"}
EVENT_RE = re.compile(r"^[A-Za-z0-9_-]{5,64}$")


def enabled():
    return os.environ.get(FLAG, "").strip() == "1"


# Tags are selected only when their subject occurs in the approved caption.
# No inference about events, people or places absent from the supplied text.
# Order favors specific subjects before broad categories.
TAG_RULES = (
    # Ground hashtags in explicit names and facts of the approved caption.
    # Important for both editorial projects; never infer an unseen topic.
    (r"\btrump\b", "#DonaldTrump"),
    (r"\beeuu\b|\bestados unidos\b|\bestadounidens\w*", "#EstadosUnidos"),
    (r"\biran\b|\birani\w*", "#Iran"),
    (r"\belecciones?\b|\blegislativas\b|\bcampana electoral\b", "#Elecciones"),
    (r"\bcombustibles?\b|\bgasolina\b|\bcarburantes?\b", "#Combustibles"),
    (r"\bpremio nobel de la paz\b|\bnobel de la paz\b", "#PremioNobelDeLaPaz"),
    (r"\bnavi pillay\b", "#NaviPillay"),
    (r"\bsudafrica\b|\bsudafrican\w*", "#Sudafrica"),
    (r"\bderecho internacional\b", "#DerechoInternacional"),
    (r"\bpromover la paz\b|\bpaloma de la paz\b|\bpaz\b", "#Paz"),
    (r"\brenoir\b", "#Renoir"),
    (r"\bfrancia\b|\bfrances\w*", "#Francia"),
    (r"\barte\b|\bcuadros?\b|\bpinturas?\b|\bmuseos?\b", "#Arte"),
    (r"\bcuadros?\b|\bpinturas?\b", "#Pintura"),
    (r"\bmuseos?\b", "#Museos"),
    (r"\bshakira\b", "#Shakira"),
    (r"\bla revuelta\b", "#LaRevuelta"),
    (r"\bbroncano\b", "#DavidBroncano"),
    (r"\breal madrid\b", "#RealMadrid"),
    (r"\bbar[cç]a\b|\bfc barcelona\b", "#FCBarcelona"),
    (r"\beuroliga\b", "#Euroliga"),
    (r"\bpartizan\b", "#Partizan"),
    (r"\batletico de madrid\b", "#AtleticoDeMadrid"),
    (r"\blamine yamal\b", "#LamineYamal"),
    (r"\balcaraz\b", "#CarlosAlcaraz"),
    (r"\bsinner\b", "#JannikSinner"),
    (r"\bverstappen\b", "#MaxVerstappen"),
    (r"\balonso\b", "#FernandoAlonso"),
    (r"\bformula 1\b|\bf1\b", "#Formula1"),
    (r"\btenis\b", "#Tenis"),
    (r"\bbaloncesto\b|\bcanasta\b|\bpartizan\b|\beuroliga\b", "#Baloncesto"),
    (r"\bfutbol\b|\bgol\b|\bliga de campeones\b", "#Futbol"),
    (r"\bcine\b|\bpelicula\b|\boscar\b", "#Cine"),
    (r"\bconcierto\b|\bcantante\b|\bmusica\b", "#Musica"),
    (r"\bserie\b|\bprograma de television\b|\btelevision\b", "#Television"),
    (r"\bgobierno\b|\bcongreso\b|\belecciones?\b|\bministro\b|\bpolitica\b", "#Politica"),
    (r"\bsanchez\b", "#PedroSanchez"),
    (r"\bfeijoo\b", "#AlbertoNunezFeijoo"),
    (r"\brufian\b", "#GabrielRufian"),
    (r"\bdesahucio\b|\balquiler\b|\bvivienda\b", "#Vivienda"),
    (r"\btribunal\b|\bsentencia\b|\bfiscalia\b", "#Justicia"),
    (r"\binteligencia artificial\b|\btecnologia\b", "#Tecnologia"),
    (r"\bclima\b|\btemperaturas?\b|\bmeteorologia\b", "#Meteorologia"),
    (r"\blluvia\b|\btormenta\b", "#Lluvia"),
    (r"\binmigracion\b|\bmigracion\b|\bice\b", "#Migracion"),
    (r"\beconomia\b|\binflacion\b|\bprecios\b", "#Economia"),
)
TAG_PREFIX_RE = re.compile(r"^(?:@?ttactualidad)\s*[:—–-]?\s*", re.IGNORECASE)
OLD_FOOTER_RE = re.compile(
    r"\s*Ilustraci[oó]n sat[ií]rica generada con IA\.?(?:\s*#TTActualidad)?\s*$",
    re.IGNORECASE,
)
INLINE_TAG_RE = re.compile(r"(?<!\w)#[\w]+", re.UNICODE)


def _fold(value):
    import unicodedata
    return "".join(c for c in unicodedata.normalize("NFKD", value.casefold())
                   if not unicodedata.combining(c))


def caption(text):
    """Use editorial text intact apart from account prefix; add up to 5 topical tags.

    The existing Telegram/X caption is not changed. This only affects new
    Instagram snapshots; already-delivered Instagram rows stay immutable.
    """
    value = TAG_PREFIX_RE.sub("", str(text or "").strip())
    value = OLD_FOOTER_RE.sub("", value).strip()
    # Do not place the author handle inside the description: IG displays it.
    # The platform shows @ttactualidad as author. Drop historical generic tags
    # from new Instagram captions; prefer specific evidence-based topics.
    value = re.sub(r"(?<!\w)#(?:TTActualidad|Actualidad)\b", "", value, flags=re.IGNORECASE).strip()
    if not value:
        raise ValueError("Missing approved text")

    present = {t.casefold() for t in INLINE_TAG_RE.findall(value)}
    topics = _fold(value)
    tags = []
    slots = max(0, 5 - len(present))
    for pattern, tag in TAG_RULES:
        if not slots:
            break
        if tag.casefold() in present:
            continue
        if re.search(pattern, topics):
            tags.append(tag)
            present.add(tag.casefold())
            slots -= 1
    # Unknown topics remain untagged. Never manufacture generic #Actualidad.
    result = value + ("\n\n" + " ".join(tags) if tags else "")
    if len(result) > 2200:
        # Tags are optional; never truncate the approved factual text or the gag.
        result = value
    if len(result) > 2200:
        raise ValueError("Instagram caption too long")
    return result


def materialize(root, project, event_id, revision, raw):
    """Create an RGB JPEG image from verified AI bytes, without touching its original."""
    if project not in EXTENTS or not EVENT_RE.fullmatch(str(event_id)):
        raise ValueError("Invalid source identity")
    if not isinstance(revision, int) or revision < 0 or revision > 99999:
        raise ValueError("Invalid revision")
    if not isinstance(raw, bytes) or not (3000 <= len(raw) <= 16 * 1024 * 1024):
        raise ValueError("Invalid AI image bytes")
    with Image.open(io.BytesIO(raw)) as im:
        im.verify()
    with Image.open(io.BytesIO(raw)) as im:
        im = ImageOps.exif_transpose(im)
        if im.width < 320 or im.height < 320 or im.width * im.height > 24_000_000:
            raise ValueError("AI image dimensions not valid for Instagram")
        if im.mode in ("RGBA", "LA") or "transparency" in im.info:
            rgba = im.convert("RGBA")
            result = Image.new("RGB", rgba.size, (255, 255, 255))
            result.paste(rgba, mask=rgba.getchannel("A"))
            im = result
        else:
            im = im.convert("RGB")
        ratio = im.width / im.height
        # Letterbox unusually tall/wide AI images; never distort the gag.
        if ratio < 4 / 5:
            new_width = round(im.height * 4 / 5)
            canvas = Image.new("RGB", (new_width, im.height), (255, 255, 255))
            canvas.paste(im, ((new_width - im.width) // 2, 0))
            im = canvas
        elif ratio > 1.91:
            new_height = round(im.width / 1.91)
            canvas = Image.new("RGB", (im.width, new_height), (255, 255, 255))
            canvas.paste(im, (0, (new_height - im.height) // 2))
            im = canvas
        if max(im.size) > 1440:
            im.thumbnail((1440, 1440), Image.Resampling.LANCZOS)
        buf = io.BytesIO()
        im.save(buf, format="JPEG", quality=88, optimize=True, progressive=False)
        jpeg = buf.getvalue()
    if not jpeg.startswith(b"\xff\xd8\xff") or len(jpeg) > 8 * 1024 * 1024:
        raise ValueError("Instagram JPEG invalid")
    sha = hashlib.sha256(jpeg).hexdigest()
    rel = pathlib.Path(project) / "instagram-images" / f"ig-{event_id}-r{revision}-{sha[:12]}.jpg"
    target = pathlib.Path(root) / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.is_file():
        target.write_bytes(jpeg)
    return {"image_url": URL_BASE + rel.as_posix(), "image_sha256": sha, "image_local_path": rel.as_posix()}


def payload(root, project, event_id, revision, text, raw):
    obj = materialize(root, project, event_id, revision, raw)
    obj["caption"] = caption(text)
    return obj


def attach_button(keyboard, callback_data, post):
    """Append Instagram control without changing existing X / editorial actions."""
    if not enabled() or not post:
        return keyboard
    if not (isinstance(post, dict) and str(post.get("image_url", "")).endswith(".jpg")):
        return keyboard
    if not (str(callback_data).startswith("tt:i:") or str(callback_data).startswith("tx:i:")):
        raise ValueError("Invalid Instagram callback identity")
    if len(callback_data.encode("utf-8")) > 64:
        raise ValueError("Telegram callback_data too long")
    kb = {"inline_keyboard": [list(row) for row in keyboard.get("inline_keyboard", [])]}
    insert_at = len(kb["inline_keyboard"])
    if insert_at and any(x.get("callback_data", "").startswith(("tt:p:","tt:d:","tx:p:","tx:d:")) for x in kb["inline_keyboard"][-1]):
        insert_at -= 1
    kb["inline_keyboard"].insert(insert_at, [{"text": "📸 Publicar en Instagram", "callback_data": callback_data}])
    return kb
