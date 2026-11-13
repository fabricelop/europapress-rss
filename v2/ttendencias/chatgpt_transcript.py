#!/usr/bin/env python3
"""Captura segura de la respuesta en la conversación individual ChatGPT V2.

Soporta los rótulos de interfaz en inglés y español y, cuando la interfaz
expone roles del DOM, lee el mensaje del asistente directamente. No pulsa
Enviar, no crea chats ni toca GitHub.
"""
import re

USER_MARKERS = ("You said:", "Tú dijiste:", "Has dicho:")
ASSISTANT_MARKERS = ("ChatGPT said:", "ChatGPT dijo:", "ChatGPT ha dicho:", "ChatGPT respondió:")
END_MARKERS = ("ChatGPT can make mistakes.", "ChatGPT puede cometer errores.",
               "Latest response", "Última respuesta")
LOAD_ERRORS = ("Could not load this ChatGPT conversation",
               "No se ha podido cargar esta conversación de ChatGPT")


def _marker_positions(text, markers, *, start=0):
    positions = []
    for marker in markers:
        for pattern in ("\n" + marker + "\n", "\n" + marker + "\r\n"):
            position = text.find(pattern, start)
            while position >= 0:
                positions.append((position, len(pattern)))
                position = text.find(pattern, position + 1)
        if text.startswith(marker + "\n", start):
            positions.append((start, len(marker) + 1))
    return sorted(set(positions))


def prompt_matches(prompt, trend_id, revision):
    """La identidad proviene del turno enviado, nunca del texto del asistente."""
    return (isinstance(prompt, str) and trend_id in prompt
            and re.search(r"\brevisi[oó]n\s*[: ]\s*" + re.escape(str(revision)) +
                          r"\b", prompt, re.I) is not None)


def extract_reply(transcript: str, *, trend_id: str, revision: int):
    """Texto vinculado al último prompt y delimitado por el pie de la UI."""
    if not isinstance(transcript, str) or not transcript.strip():
        return "", "empty_document"
    users = _marker_positions(transcript, USER_MARKERS)
    if not users:
        return "", "user_turn_not_found"
    user_pos, user_len = users[-1]
    assistants = _marker_positions(transcript, ASSISTANT_MARKERS, start=user_pos + user_len)
    if not assistants:
        return "", "assistant_turn_not_found"
    assistant_pos, assistant_len = assistants[0]
    prompt = transcript[user_pos + user_len:assistant_pos]
    if not prompt_matches(prompt, trend_id, revision):
        return "", "prompt_identity_mismatch"
    remainder = transcript[assistant_pos + assistant_len:]
    if _marker_positions(remainder, USER_MARKERS):
        return "", "multiple_turns_after_target"
    cuts = [remainder.find(marker) for marker in END_MARKERS if marker in remainder]
    if not cuts:
        return "", "completion_footer_missing"
    answer = remainder[:min(cuts)].strip()
    if len(answer) < 80:
        return "", "short_response"
    return answer, "visible_transcript_bound_to_prompt_and_footer"


def read_status(body: str, *, trend_id: str, revision: int):
    if any(err in body for err in LOAD_ERRORS):
        return {"status": "conversation_load_failed", "answer": "", "reason": "load_error"}
    answer, reason = extract_reply(body, trend_id=trend_id, revision=revision)
    return {"status": "captured" if answer else "waiting", "answer": answer, "reason": reason}


def read_dom_pair(page, *, trend_id, revision):
    """Leer roles DOM solo si hay exactamente UN turno usuario y UNO asistente.

    Se utiliza como alternativa al pie textual localizado, que no siempre
    aparece en el contenido visible de una versión de la interfaz.
    """
    try:
        user = page.locator('[data-message-author-role="user"]')
        assistant = page.locator('[data-message-author-role="assistant"]')
        if user.count() != 1 or assistant.count() != 1:
            return "", "dom_turn_count_ambiguous"
        prompt = user.first.inner_text(timeout=6000)
        if not prompt_matches(prompt, trend_id, revision):
            return "", "dom_prompt_identity_mismatch"
        response_node = assistant.first.locator(".markdown").first
        if response_node.count():
            answer = response_node.inner_text(timeout=6000).strip()
        else:
            answer = assistant.first.inner_text(timeout=6000).strip()
        if len(answer) < 80:
            return "", "dom_response_short"
        return answer, "dom_single_pair_verified"
    except Exception as exc:
        return "", "dom_read_" + type(exc).__name__


def capture_existing_page(page, *, trend_id: str, revision: int, seconds=180,
                          allow_single_reload=True):
    """Lectura únicamente de una conversación ya enviada; nunca reenviar."""
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
        try:
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
                        "reloads": int(reloaded), "url": page.url,
                        "observations": observations[-12:]}
            answer = state["answer"]
            reason = state["reason"]
            if not answer:
                answer, dom_reason = read_dom_pair(page, trend_id=trend_id,
                                                   revision=revision)
                reason = dom_reason if answer else reason + "+" + dom_reason
            busy = page.locator(stop).count() > 0
            stable = stable + 1 if answer and answer == last else 0
            last = answer
            observations.append(reason)
            # Tres comprobaciones consistentes + ausencia de botón Detener.
            if answer and stable >= 3 and not busy:
                return {"status": "captured", "answer": answer, "reason": reason,
                        "reloads": int(reloaded), "url": page.url,
                        "observations": observations[-12:]}
        except Exception as exc:
            observations.append("read_" + type(exc).__name__)
        time.sleep(2)
    return {"status": "timeout", "answer": "",
            "reason": observations[-1] if observations else "no_url",
            "reloads": int(reloaded), "seen_load_error": seen_error,
            "url": page.url, "observations": observations[-12:]}
