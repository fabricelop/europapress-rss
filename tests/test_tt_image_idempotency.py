"""No-network regressions for TTActualidad one-image-per-revision semantics."""
import json
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import unittest

from shared.tt_image_idempotency import may_enqueue_image_job, is_new_editorial_episode


class ImageIdempotencyTests(unittest.TestCase):
    def test_no_prior_job(self):
        self.assertTrue(may_enqueue_image_job({}, 1))

    def test_queued_and_running_not_replaced_at_any_age(self):
        for state in ("REQUESTED", "RUNNING", "GENERATING", "PERSISTING", "PICKED_UP", "UNCERTAIN"):
            with self.subTest(state=state):
                self.assertFalse(may_enqueue_image_job({"revision": 1, "status": state, "requested_at": "2000-01-01"}, 1, manual_retry_version=99))

    def test_launched_never_replaced_even_manual(self):
        for state in ("LAUNCHED", "DONE", "ERROR", "CANCELLED"):
            with self.subTest(state=state):
                self.assertFalse(may_enqueue_image_job({"revision": 1, "status": state, "pc_launched_at": "2026-10-21T02:00:00Z", "retry_safe_before_submit": True}, 1, manual_retry_version=99))

    def test_uncertain_error_with_generating_true_from_real_incident(self):
        incident = {"revision": 1, "status": "ERROR", "phase": "pc_launch_failed",
                    "auto_repair_attempt": 1, "message": 'No hubo evidencia suficiente; {"submitted":false,"generating":true}'}
        self.assertFalse(may_enqueue_image_job(incident, 1))
        self.assertFalse(may_enqueue_image_job(incident, 1, manual_retry_version=2))

    def test_stale_archive_cancelled_before_chat_can_be_safely_requeued(self):
        job = {
            "revision": 0, "status": "CANCELLED", "phase": "stale_target",
            "message": "Cancelado antes de abrir chat: archived",
            "auto_repair_attempt": 1,
        }
        self.assertTrue(may_enqueue_image_job(job, 0))
        job["auto_repair_attempt"] = 3
        self.assertFalse(may_enqueue_image_job(job, 0))
        job["pc_launched_at"] = "2026-10-26T00:49:00Z"
        self.assertFalse(may_enqueue_image_job(job, 0))
        job.pop("pc_launched_at")
        job["status"] = "ERROR"
        self.assertFalse(may_enqueue_image_job(job, 0))

    def test_today_seven_ready_news_without_composer_can_retry_safely(self):
        job = {
            "revision": 1, "status": "ERROR", "phase": "pc_launch_failed",
            "pc_picked_up_at": "2026-10-29T08:41:18.675Z",
            "message": "No hay compositor visible utilizable para fallback found=1",
            "auto_repair_attempt": 1, "delivery_mode": "launch_only",
        }
        self.assertTrue(may_enqueue_image_job(job, 1))
        job["auto_repair_attempt"] = 3
        self.assertFalse(may_enqueue_image_job(job, 1))
        self.assertTrue(may_enqueue_image_job(job, 1, manual_retry_version=1))
        job["pc_launched_at"] = "2026-10-29T08:41:20Z"
        self.assertFalse(may_enqueue_image_job(job, 1, manual_retry_version=99))
        job.pop("pc_launched_at")
        job["message"] = 'No hubo evidencia suficiente; {"generating":true}'
        self.assertFalse(may_enqueue_image_job(job, 1, manual_retry_version=99))
        job["message"] = "No hay compositor visible utilizable para fallback found=1"
        job.pop("pc_picked_up_at")
        self.assertFalse(may_enqueue_image_job(job, 1))

    def test_ttendencias_missing_target_close_is_prelaunch_safe_retry(self):
        job = {
            "revision": 0, "status": "ERROR", "phase": "pc_launch_failed",
            "message": "closeFixedTargetById is not defined",
            "pc_picked_up_at": "2026-10-29T18:22:42.044Z",
            "delivery_mode": "launch_only", "auto_repair_attempt": 1,
        }
        self.assertTrue(may_enqueue_image_job(job, 0))
        job["auto_repair_attempt"] = 3
        self.assertFalse(may_enqueue_image_job(job, 0))
        for key in ("pc_launched_at", "pc_submitted_at", "image_generated_at"):
            job["auto_repair_attempt"] = 1
            job[key] = "2026-10-29T18:23:00Z"
            self.assertFalse(may_enqueue_image_job(job, 0))
            del job[key]
        job["message"] = "ReferenceError: closeFixedTargetById is not defined"
        self.assertFalse(may_enqueue_image_job(job, 0))
        job["message"] = "closeFixedTargetById is not defined"
        del job["pc_picked_up_at"]
        self.assertFalse(may_enqueue_image_job(job, 0))

    def test_trends_frozen_tab_is_pre_submit_and_bounded(self):
        job = {"project":"ttendencias", "revision":0, "status":"ERROR",
               "delivery_mode":"launch_only", "phase":"pc_launch_failed",
               "pc_picked_up_at":"2026-10-30T21:52:25Z", "auto_repair_attempt":1}
        messages = [
            'La pestaña dedicada no mostró compositor en 60000 ms; {"error":"CDP timeout Runtime.evaluate"}',
            "El target dedicado sigue abierto; no se creará otra pestaña",
            "TTENDENCIAS_PRE_SUBMIT_FAILED CDP timeout Runtime.evaluate",
        ]
        for message in messages:
            candidate = {**job, "message":message}
            self.assertTrue(may_enqueue_image_job(candidate, 0))
            self.assertFalse(may_enqueue_image_job({**candidate,"auto_repair_attempt":3},0,manual_retry_version=99))
            self.assertFalse(may_enqueue_image_job({**candidate,"project":"ttittulares"},0))
            for marker in ["pc_launched_at","pc_submitted_at","pc_image_submitted_at","image_generated_at","upload_sha256"]:
                self.assertFalse(may_enqueue_image_job({**candidate,marker:"evidence"},0))
        self.assertFalse(may_enqueue_image_job({**job,"message":"CDP timeout Runtime.evaluate"},0))
        self.assertFalse(may_enqueue_image_job({**job,"message":"No hubo evidencia suficiente de envío del prompt ImageGen"},0))
        self.assertFalse(may_enqueue_image_job({**job,"message":messages[0],"status":"RUNNING"},0))

    def test_archive_repair_must_keep_automatic_ai_eligible(self):
        root = Path(__file__).resolve().parents[1]
        source = (root / ".github/workflows/repair-ttittulares-listas.yml").read_text(encoding="utf8")
        self.assertNotIn('item["image_mode"]="archive_only"', source)
        self.assertNotIn('item["image_strategy"]="archive_only"', source)
        self.assertIn('item["image_mode"]="ai_plus_fallback"', source)
        self.assertIn('item["image_strategy"]="ai_plus_fallback"', source)
        self.assertIn('if not item.get("disable_ai_image")', source)

    def test_generic_errors_not_automatically_retried(self):
        for phase in ("pc_launch_failed", "expired", "pc_progress", "failed"):
            self.assertFalse(may_enqueue_image_job({"revision": 0, "status": "ERROR", "phase": phase}, 0))

    def test_verified_no_submit_retries_are_bounded(self):
        job = {"revision": 0, "status": "ERROR", "phase": "pc_preflight_failed",
               "retry_safe_before_submit": True, "auto_repair_attempt": 2}
        self.assertTrue(may_enqueue_image_job(job, 0))
        job["auto_repair_attempt"] = 3
        self.assertFalse(may_enqueue_image_job(job, 0))
        self.assertTrue(may_enqueue_image_job(job, 0, manual_retry_version=1))
        job["manual_retry_version"] = 1
        self.assertFalse(may_enqueue_image_job(job, 0, manual_retry_version=1))

    def test_false_verified_flag_not_enough_if_generation_seen(self):
        job = {"revision": 1, "status": "ERROR", "phase": "pc_preflight_failed",
               "retry_safe_before_submit": True, "message": '{"generating": true}'}
        self.assertFalse(may_enqueue_image_job(job, 1))

    def test_new_editorial_revision_allowed(self):
        self.assertTrue(may_enqueue_image_job({"revision": 1, "status": "LAUNCHED"}, 2))
        self.assertTrue(may_enqueue_image_job({"revision": 0, "status": "ERROR"}, 1))

    def test_stale_revision_never_overwrites_newer(self):
        self.assertFalse(may_enqueue_image_job({"revision": 3, "status": "REQUESTED"}, 2))
        self.assertFalse(may_enqueue_image_job({"revision": 1, "status": "LAUNCHED"}, 0))

    def test_zero_revision_is_not_treated_as_missing(self):
        self.assertFalse(may_enqueue_image_job({"revision": 1, "status": "ERROR"}, 0))
        self.assertTrue(may_enqueue_image_job({"revision": 0, "status": "LAUNCHED"}, 1))

    def test_same_trend_new_match_is_a_fresh_image_episode(self):
        old = {"revision": 0, "status": "ERROR", "pc_launched_at": "2026-10-04T21:03:05Z",
               "context_snapshot": {
                   "explained_at": "2026-10-04T22:23:30+02:00",
                   "explanation": "Cancelo marca con Portugal ante Noruega."}}
        new = {"explained_at": "2026-10-26T00:01:19+01:00",
               "explanation": "Cancelo entra sobre Diomande en el Clásico."}
        self.assertFalse(may_enqueue_image_job(old, 0))
        self.assertTrue(is_new_editorial_episode(old, 0, new))
        self.assertTrue(may_enqueue_image_job({} if is_new_editorial_episode(old, 0, new) else old, 0))

    def test_same_match_cannot_duplicate_even_after_launched_error(self):
        old = {"revision": 0, "status": "ERROR", "pc_launched_at": "2026-10-25T21:03:05Z",
               "context_snapshot": {
                   "explained_at": "2026-10-25T21:02:00Z",
                   "explanation": "Explicación revisada."}}
        same = {"explained_at": "2026-10-25T21:02:00Z", "explanation": "Explicación revisada."}
        earlier = {"explained_at": "2026-10-24T21:02:00Z", "explanation": "Otro hecho."}
        just_date = {"explained_at": "2026-10-26T21:02:00Z", "explanation": "Explicación revisada."}
        for candidate in (same, earlier, just_date, {"explanation": "Texto sin fecha"}, {}):
            with self.subTest(candidate=candidate):
                self.assertFalse(is_new_editorial_episode(old, 0, candidate))
        self.assertTrue(is_new_editorial_episode(old, 1, {"explained_at":"2026-10-26T21:02:00Z", "explanation":"Otra"}))
        # New sports match starts at r0, but the old match reached r1.
        old["revision"] = 1
        self.assertTrue(is_new_editorial_episode(old, 0,
            {"explained_at":"2026-10-26T21:02:00Z", "explanation":"Nuevo encuentro."}))
        # The side-effect guard still rejects the old r1 job for r0 if
        # there is no proven separate episode.
        self.assertFalse(may_enqueue_image_job(old, 0))

    def test_workflows_use_same_gate_and_no_rebase(self):
        root = Path(__file__).resolve().parents[1]
        for path in (".github/workflows/repair-ttittulares-listas.yml",
                     ".github/workflows/repair-ttendencias-explicadas.yml"):
            with self.subTest(workflow=path):
                source = (root / path).read_text(encoding="utf-8")
                self.assertIn("may_enqueue_image_job(", source)
                self.assertNotIn('git pull --rebase origin "$CONTROL"', source)
                self.assertIn('git push origin HEAD:"$CONTROL"', source)
                self.assertRegex(source, r"concurrency:[\s\S]*?cancel-in-progress: false")


class GitRefConcurrencyTests(unittest.TestCase):
    """Real local Git ref CAS: two writers cannot commit the same claim."""
    def test_concurrent_control_branch_claims_have_single_winner(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            bare = base / "remote.git"
            subprocess.run(["git", "init", "--bare", "-q", str(bare)], check=True)
            init = base / "initial"
            subprocess.run(["git", "clone", "-q", str(bare), str(init)], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(init), "config", "user.email", "ci@example.test"], check=True)
            subprocess.run(["git", "-C", str(init), "config", "user.name", "CI"], check=True)
            (init / "jobs").mkdir()
            (init / "jobs" / "item.json").write_text("{}\n")
            subprocess.run(["git", "-C", str(init), "add", "."], check=True)
            subprocess.run(["git", "-C", str(init), "commit", "-qm", "baseline"], check=True)
            subprocess.run(["git", "-C", str(init), "push", "-q", "origin", "HEAD:refs/heads/control"], check=True)
            barrier = threading.Barrier(2)
            results = []
            def claim(number):
                clone = base / f"claim{number}"
                subprocess.run(["git", "clone", "-q", "-b", "control", str(bare), str(clone)], check=True)
                subprocess.run(["git", "-C", str(clone), "config", "user.email", "ci@example.test"], check=True)
                subprocess.run(["git", "-C", str(clone), "config", "user.name", "CI"], check=True)
                (clone / "jobs" / "item.json").write_text(json.dumps({"revision": 1, "status": "REQUESTED", "command_id": f"one-{number}"}) + "\n")
                subprocess.run(["git", "-C", str(clone), "add", "."], check=True)
                subprocess.run(["git", "-C", str(clone), "commit", "-qm", "claim"], check=True)
                barrier.wait(timeout=10)
                result = subprocess.run(["git", "-C", str(clone), "push", "origin", "HEAD:refs/heads/control"], capture_output=True)
                results.append(result.returncode)
            threads = [threading.Thread(target=claim, args=(n,)) for n in (1, 2)]
            for t in threads: t.start()
            for t in threads: t.join(timeout=20)
            self.assertEqual(sorted(results), [0, 1])
            checkout = base / "verify"
            subprocess.run(["git", "clone", "-q", "-b", "control", str(bare), str(checkout)], check=True)
            job = json.loads((checkout / "jobs" / "item.json").read_text())
            self.assertFalse(may_enqueue_image_job(job, 1))
            self.assertTrue(may_enqueue_image_job(job, 2))


if __name__ == "__main__":
    unittest.main()
