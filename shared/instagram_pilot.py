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


def caption(text):
    value = str(text or "").strip()
    if not value:
        raise ValueError("Missing approved text")
    note = "\n\nIlustración satírica generada con IA.\n#TTActualidad"
    if len(value + note) > 2200:
        raise ValueError("Instagram caption too long")
    return value + note


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
