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
