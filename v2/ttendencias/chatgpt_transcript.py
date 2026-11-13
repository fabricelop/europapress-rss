#!/usr/bin/env python3
"""Captura de transcripción ChatGPT en la interfaz actual, aislada de Chrome.

Inspirado en el control de estabilidad de V1 (TT-Editorial-Tab-Watch.js),
pero extrae texto. No interactúa con el editor ni toca GitHub.
"""
import re

PROMPT_MARKER = "You said:"
ASSISTANT_MARKER = "ChatGPT said:"
END_MARKERS = ("ChatGPT can make mistakes.", "Latest response")


def extract_reply(transcript: str, *, trend_id: str, revision: int):
    """Devuelve (texto, diagnóstico). Fail-closed ante conversación ambigua."""
    if not isinstance(transcript, str) or not transcript.strip():
        return "", "empty_document"
    # Solo considerar turnos del diálogo, nunca coincidencias aisladas del menú.
    user_pos = transcript.rfind("\n" + PROMPT_MARKER + "\n")
    if user_pos < 0:
        return "", "user_turn_not_found"
    following = transcript[user_pos + len(PROMPT_MARKER) + 2:]
    assistant_pos = following.find("\n" + ASSISTANT_MARKER + "\n")
    if assistant_pos < 0:
        return "", "assistant_turn_not_found"
    prompt = following[:assistant_pos]
    expected_revision = rf"\brevisi[oó]n\s*[: ]\s*{revision}\b"
    if trend_id not in prompt or not re.search(expected_revision, prompt, re.I):
        return "", "prompt_identity_mismatch"
    remainder = following[assistant_pos + len(ASSISTANT_MARKER) + 2:]
    if "\n" + PROMPT_MARKER + "\n" in remainder:
        return "", "multiple_turns_after_target"
    cuts = [remainder.find(m) for m in END_MARKERS if m in remainder]
    if not cuts:
        return "", "completion_footer_missing"
    response = remainder[:min(cuts)].strip()
    if len(response) < 80:
        return "", "short_response"
    # La respuesta puede no repetir el ID: la identidad proviene del turno
    # de usuario enlazado, no de una coincidencia accidental en la respuesta.
    return response, "visible_transcript_bound_to_prompt_and_footer"

def read_status(body: str, *, trend_id: str, revision: int):
    """Clasificar el contenido visible sin suponer que un chat está listo."""
    if "Could not load this ChatGPT conversation" in body:
        return {"status": "conversation_load_failed", "answer": "", "reason": "load_error"}
    answer, reason = extract_reply(body, trend_id=trend_id, revision=revision)
    return {"status": "captured" if answer else "waiting", "answer": answer, "reason": reason}


def capture_existing_page(page, *, trend_id: str, revision: int, seconds=180,
                          allow_single_reload=True):
    """Lectura únicamente: no escribir, clicar ni reenviar. Misma sesión Chrome."""
    import time
    last = ""
    stable = 0
    reloaded = False
    seen_error = False
    deadline = time.monotonic() + seconds
    stop = ("[data-testid='stop-button'],button[aria-label*='Stop'],"
            "button[aria-label*='Detener']")
    observations = []
    while time.monotonic() < deadline:
        if not page.url.startswith("https://chatgpt.com/c/"):
            observations.append("await_chat_url")
            time.sleep(2)
            continue
        body = page.locator("body").inner_text(timeout=8000)
        state = read_status(body, trend_id=trend_id, revision=revision)
        if state["status"] == "conversation_load_failed":
            seen_error = True
            if allow_single_reload and not reloaded:
                reloaded = True
                page.reload(wait_until="domcontentloaded", timeout=45000)
                time.sleep(3)
                continue
            return {"status": "load_failed", "answer": "", "reason": state["reason"],
                    "reloads": int(reloaded), "url": page.url, "observations": observations[-12:]}
        answer = state["answer"]
        busy = page.locator(stop).count() > 0
        stable = stable + 1 if answer and answer == last else 0
        last = answer
        observations.append(state["reason"])
        if answer and stable >= 3 and not busy:
            return {"status": "captured", "answer": answer, "reason": state["reason"],
                    "reloads": int(reloaded), "url": page.url, "observations": observations[-12:]}
        time.sleep(2)
    return {"status": "timeout", "answer": "", "reason": observations[-1] if observations else "no_url",
            "reloads": int(reloaded), "seen_load_error": seen_error, "url": page.url,
            "observations": observations[-12:]}
