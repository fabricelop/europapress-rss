#!/usr/bin/env python3
"""Localiza el chat nuevo en Chrome V2 sin depender de la pestaña inicial.

La detección de URL y la verificación de identidad son operaciones distintas.
Solo la segunda permite aceptar una respuesta para su persistencia.
"""
import re
import time

CHAT_RE = re.compile(r"^https://chatgpt\.com/c/[A-Za-z0-9-]{16,80}$")


def canonical(url):
    return (url or "").split("?", 1)[0].split("#", 1)[0]


def conversation_urls(browser):
    """Incluye targets CDP que Playwright aún no haya asociado a Page."""
    targets = []
    try:
        cdp = browser.new_browser_cdp_session()
        targets = cdp.send("Target.getTargets").get("targetInfos", [])
        cdp.detach()
    except Exception:
        pass
    urls = {canonical(t.get("url", "")) for t in targets
            if t.get("type") == "page"}
    for ctx in list(browser.contexts):
        for p in list(ctx.pages):
            urls.add(canonical(p.url))
    return sorted(url for url in urls if CHAT_RE.fullmatch(url))


def verify_conversation(page, trend_id, revision):
    """Verifica el turno del usuario; el título no sirve como prueba."""
    try:
        body = page.locator("body").inner_text(timeout=4500)
        user_marker = body.rfind("\nYou said:\n")
        if user_marker < 0:
            user_marker = body.rfind("\nTú dijiste:\n")
        if user_marker < 0:
            return False
        prompt = body[user_marker:]
        assistant = prompt.find("\nChatGPT said:\n")
        if assistant >= 0:
            prompt = prompt[:assistant]
        return (trend_id in prompt and
                re.search(r"\brevisi[oó]n\s*[: ]\s*" + str(revision) + r"\b",
                          prompt, re.I) is not None)
    except Exception:
        return False


def await_conversation(browser, page, trend_id, revision, *, seconds=90,
                       baseline_urls=()):
    """Encuentra URL tras Enter; valida ID antes de adoptar cualquier página.

    Si una URL nueva solo está en los targets CDP, abre una pestaña de
    lectura hacia esa URL. Nunca escribe ni pulsa Enviar.
    """
    baseline = set(baseline_urls)
    inspected = []
    deadline = time.monotonic() + seconds
    probe = None
    while time.monotonic() < deadline:
        urls = conversation_urls(browser)
        # Priorizar URLs no presentes antes del envío; las antiguas no bastan.
        ordered = [u for u in urls if u not in baseline]
        for url in ordered:
            candidates = [p for ctx in browser.contexts
                          for p in ctx.pages if canonical(p.url) == url]
            if not candidates:
                if probe is None:
                    probe = page.context.new_page()
                try:
                    probe.goto(url, wait_until="domcontentloaded", timeout=15000)
                    candidates = [probe]
                except Exception as exc:
                    inspected.append({"url": url, "error": type(exc).__name__})
                    continue
            for candidate in candidates:
                if verify_conversation(candidate, trend_id, revision):
                    return candidate, {"status": "verified", "url": url,
                                       "seen_urls": urls, "inspected": inspected[-15:]}
            inspected.append({"url": url, "status": "identity_not_visible_yet"})
        time.sleep(1)
    return None, {"status": "not_found", "seen_urls": conversation_urls(browser),
                  "inspected": inspected[-20:]}


def check_reply_on_known_chat(browser, url, trend_id, revision):
    """Prueba sin enviar: verificar enlace existente con la sesión V2."""
    if not CHAT_RE.fullmatch(canonical(url)):
        raise ValueError("URL de conversación no válida")
    return None
