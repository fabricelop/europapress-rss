#!/usr/bin/env python3
"""Pruebas puras de Listas V2. No navegador, red, token ni publicaciones."""
import base64
import io
import json
import unittest
from unittest.mock import patch

from listas_v2 import (build_listas, classify_cause, classify_x,
                       _decode_contents_json, sync_to_github)

ID = "trv2-38fe784e35097e53eb5a1b13"
SHA = "a" * 64
URL = "https://chatgpt.com/c/6af730c4-69bc-83eb-a7bc-68feb2b6bac8"
TEXT_UNCERTAIN = ("ESTADO_CAUSA: NO_CONFIRMADA\nESTADO_X: INACCESIBLE\n"
                  "El término aparece entre tendencias, pero el motivo concreto "
                  "no se ha podido confirmar con fuentes fiables. "
                  "No deben atribuirse hechos sin pruebas.")

def q(text=TEXT_UNCERTAIN, status="captured_review"):
    return {"step": "04_editorial_queue", "effects_enabled": False,
            "items": {
                ID: {"trend_id": ID, "name": "Junior", "revision": 1,
                     "status": status,
                     "capture": {"revision": 1, "sha256": SHA,
                                 "answer": text, "chat_url": URL,
                                 "verified_complete": True,
                                 "editorial_validated": False}},
                "pending": {"trend_id": "pending", "name": "Pendiente",
                            "revision": 1, "status": "pending"},
            }}

class TestListas(unittest.TestCase):
    @staticmethod
    def blob_response(sha, value):
        raw = json.dumps(value, ensure_ascii=False).encode("utf-8")
        blob = {"sha": sha, "encoding": "base64",
                "content": base64.b64encode(raw).decode("ascii")}
        return io.BytesIO(json.dumps(blob).encode("utf-8"))

    def test_contents_over_one_mib_uses_verified_git_blob(self):
        sha = "b" * 40
        large = {"text": "ñ" * 530000}
        self.assertGreater(len(json.dumps(large, ensure_ascii=False).encode("utf-8")),
                           1024 * 1024)
        item = {"sha": sha, "encoding": "none", "content": ""}
        with patch("listas_v2.urllib.request.urlopen",
                   return_value=self.blob_response(sha, large)) as get:
            self.assertEqual(_decode_contents_json(item, "test-token"), large)
        self.assertTrue(get.call_args.args[0].full_url.endswith("/git/blobs/" + sha))

    def test_blob_with_wrong_sha_is_rejected(self):
        item = {"sha": "a" * 40, "encoding": "none", "content": ""}
        with patch("listas_v2.urllib.request.urlopen",
                   return_value=self.blob_response("b" * 40, {})):
            with self.assertRaisesRegex(RuntimeError, "LISTAS_BLOB_RESPONSE_UNVERIFIED"):
                _decode_contents_json(item, "test-token")

    def test_large_listas_write_and_readback_without_new_chat(self):
        old_sha, new_sha = "a" * 40, "b" * 40
        projected = build_listas(q(), "queue-sha")
        responses = [
            {"sha": old_sha, "encoding": "none", "content": ""},
            {"commit": {"sha": "successful-write"}},
            {"sha": new_sha, "encoding": "none", "content": ""},
        ]
        with (patch("listas_v2._request", side_effect=responses) as request,
              patch("listas_v2.urllib.request.urlopen", side_effect=[
                  self.blob_response(old_sha, {"previous": True}),
                  self.blob_response(new_sha, projected),
              ])):
            actual = sync_to_github(None, "test-token", q(), "queue-sha")
        self.assertEqual(actual, projected)
        self.assertEqual([call.args[0] for call in request.call_args_list],
                         ["GET", "PUT", "GET"])
        self.assertEqual(request.call_args_list[1].args[2]["sha"], old_sha)

    def test_uncertain_enters_listas(self):
        projection = build_listas(q(), "queue-sha")
        self.assertEqual(projection["count"], 1)
        card = projection["items"][ID]
        self.assertTrue(card["uncertain_cause"])
        self.assertEqual(card["label"], "Motivo no confirmado")
        self.assertEqual(card["listas_status"], "pendiente_revision")
        self.assertFalse(card["publication_allowed"])

    def test_uncertainty_explicit(self):
        self.assertEqual(classify_cause("ESTADO_CAUSA: NO_CONFIRMADA"),
                         "no_confirmada")

    def test_legacy_uncertainty(self):
        self.assertEqual(classify_cause("Resultado editorial: NO VERIFICADO"),
                         "no_confirmada")

    def test_explicit_claim_not_independent_verification(self):
        projection = build_listas(q(
            ("ESTADO_CAUSA: CONFIRMADA\nSe menciona un hecho actual. " * 4)), "queue")
        card = projection["items"][ID]
        self.assertEqual(card["cause_status"], "declarada_confirmada")
        self.assertFalse(card["editorial_validated"])
        self.assertFalse(card["publication_allowed"])

    def test_missing_marker_not_automatically_confirmed(self):
        self.assertEqual(classify_cause("Comentario editorial neutro"),
                         "sin_clasificar")

    def test_x_inaccessible(self):
        self.assertEqual(classify_x("ESTADO_X: INACCESIBLE"), ("inaccesible", []))

    def test_x_consulted_without_post_links_is_not_proof(self):
        self.assertEqual(classify_x("ESTADO_X: CONSULTADO"), ("declarado_sin_enlaces", []))

    def test_x_post_links_are_only_declared_evidence(self):
        status, links = classify_x("ESTADO_X: CONSULTADO\n"
            "https://x.com/usuario/status/12345678")
        self.assertEqual(status, "declarado_con_enlaces")
        self.assertEqual(links, ["https://x.com/usuario/status/12345678"])

    def test_pending_not_in_listas(self):
        self.assertNotIn("pending", build_listas(q(), "queue")["items"])

    def test_incomplete_capture_excluded(self):
        x = q()
        x["items"][ID]["capture"]["verified_complete"] = False
        self.assertEqual(build_listas(x, "queue")["count"], 0)

    def test_mismatching_revision_excluded(self):
        x = q()
        x["items"][ID]["revision"] = 2
        self.assertEqual(build_listas(x, "queue")["count"], 0)

    def test_effects_active_rejected(self):
        x = q()
        x["effects_enabled"] = True
        with self.assertRaises(ValueError): build_listas(x, "queue")

    def test_no_queue_sha_rejected(self):
        with self.assertRaises(ValueError): build_listas(q(), "")

    def test_ready_still_not_published(self):
        x = q(status="ready")
        x["items"][ID]["text"] = TEXT_UNCERTAIN
        del x["items"][ID]["capture"]["answer"]
        x["items"][ID]["validated_by"] = "editor"
        card = build_listas(x, "queue")["items"][ID]
        self.assertTrue(card["editorial_validated"])
        self.assertFalse(card["publication_allowed"])
        self.assertEqual(card["cause_status"], "no_confirmada")

if __name__ == "__main__":
    unittest.main()
