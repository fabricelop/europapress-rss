#!/usr/bin/env python3
"""Offline contract tests for concurrent editorial/image V2 workers."""
import copy
import inspect
import os
import pathlib
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

os.environ.setdefault("LOCALAPPDATA", tempfile.gettempdir())
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import editorial_run_v2 as editorial
import image_same_chat_v2 as same_chat
import image_worker_v2 as image
import image_target_tracker_v2 as tracker
import image_job_v2 as image_jobs
from auto_editorial_policy_v2 import eligible_plan
from image_intake_v2 import fingerprint, validate_job


def fixture():
    date = datetime.now(timezone.utc).isoformat()
    names = ["#FelizDomingo"] + ["Explicada %02d" % r for r in range(2, 17)]
    names += ["Bolivia"] + ["Explicada %02d" % r for r in range(18, 31)]
    topics = {}
    rows = {}
    for rank, name in enumerate(names, 1):
        tid = "trv2-%024x" % rank
        answer = "Ficha editorial de %s" % name
        status = "pending" if rank == 17 else "captured_review"
        capture = ({"revision": 1, "answer": answer,
                    "sha256": fingerprint(answer), "image": {}}
                   if rank != 17 else None)
        rows[tid] = {"trend_id": tid, "name": name, "revision": 1,
                     "status": status, "capture": capture}
        topics[tid] = {"trend_id": tid, "name": name, "rank": rank, "active": True}
    queue = {"step": "04_editorial_queue", "effects_enabled": False,
             "source_observed_at": date, "items": rows}
    history = {"step": "03_movement", "country": "ES",
               "observed_at": date, "top30": names, "topics": topics}
    return queue, history


class SplitTest(unittest.TestCase):
    def test_image_target_accepts_new_separate_chat_and_not_assistant_echo(self):
        command = "v2-img-trv2-15fbf166ba6a2f83c7a45b75-r1-a2-testnonce"
        class Locator:
            def __init__(self, text):
                self.text = text
                self.last = self
            def count(self):
                return 1 if self.text else 0
            def inner_text(self, timeout=None):
                return self.text
        class Page:
            def __init__(self, user_text, body=""):
                self.user_text = user_text
                self.body = body
            def locator(self, selector):
                return Locator(self.body if selector == "body" else self.user_text)
        self.assertTrue(tracker.verify_image_turn(Page(command), command))
        self.assertFalse(tracker.verify_image_turn(Page("", "El asistente repitió " + command), command))

    def test_image_user_command_in_collapsed_dom_text(self):
        command = "v2-img-trv2-15fbf166ba6a2f83c7a45b75-r2-a1-testnonce"
        class Messages:
            last = None
            def count(self):
                return 1
            def all_text_contents(self):
                return ["TT_V2_IMAGE_JOB_V1 " + command + " explicación de revisión 2"]
            def inner_text(self, timeout=None):
                return "Show more"
        messages = Messages()
        messages.last = messages
        class Page:
            def locator(self, selector):
                return messages
        self.assertTrue(tracker.verify_image_turn(Page(), command))

    def test_image_existing_starting_tab_url_can_be_verified(self):
        """Do not reject a revisited URL solely because it was in baseline."""
        command = "v2-img-trv2-15fbf166ba6a2f83c7a45b75-r2-a1-testnonce"
        url = "https://chatgpt.com/c/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        class Node:
            last = None
            def count(self):
                return 1
            def all_text_contents(self):
                return [command]
            def inner_text(self, timeout=None):
                return command
        node = Node()
        node.last = node
        class Page:
            def __init__(self):
                self.url = url
                self.context = None
            def locator(self, selector):
                return node
        page = Page()
        context = type("Context", (), {"pages": [page]})()
        page.context = context
        class Cdp:
            def send(self, _):
                return {"targetInfos": [{"type": "page", "url": url}]}
            def detach(self):
                pass
        class Browser:
            contexts = [context]
            def new_browser_cdp_session(self):
                return Cdp()
        match, receipt = tracker.await_image_conversation(
            Browser(), page, command, seconds=1, baseline_urls=(url,))
        self.assertIs(match, page)
        self.assertEqual(receipt["status"], "verified")

    def test_target_discovery_in_another_chrome_tab(self):
        command = "v2-img-trv2-15fbf166ba6a2f83c7a45b75-r1-a2-testnonce"
        target = "https://chatgpt.com/g/imagegen/c/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        class Node:
            def __init__(self, text):
                self.text = text
                self.last = self
            def count(self):
                return int(bool(self.text))
            def inner_text(self, timeout=None):
                return self.text
        class Page:
            def __init__(self, url, user):
                self.url = url
                self.user = user
                self.context = None
            def locator(self, selector):
                return Node(self.user if selector != "body" else self.user)
        root, chat = Page("https://chatgpt.com/", ""), Page(target, command)
        context = type("Context", (), {"pages": [root, chat]})()
        root.context = chat.context = context
        class Cdp:
            def send(self, _):
                return {"targetInfos": [{"type": "page", "url": target}]}
            def detach(self):
                pass
        class Browser:
            contexts = [context]
            def new_browser_cdp_session(self):
                return Cdp()
        match, evidence = tracker.await_image_conversation(
            Browser(), root, command, seconds=1, baseline_urls=())
        self.assertIs(match, chat)
        self.assertEqual(evidence["url"], target)

    def test_first_editorial_is_bolivia_while_image_is_felizdomingo(self):
        queue, history = fixture()
        with tempfile.TemporaryDirectory() as folder:
            row, _, _ = eligible_plan(queue, history, directory=folder)
            self.assertEqual(row["name"], "Bolivia")
            with patch.object(image, "JOURNALS", pathlib.Path(folder)):
                image_row, _ = image.pick_next(queue, history)
                self.assertEqual(image_row["name"], "#FelizDomingo")

    def test_new_image_job_never_depends_on_editorial_chat(self):
        queue, _ = fixture()
        row = queue["items"]["trv2-%024x" % 1]
        self.assertNotIn("chat_url", row["capture"])
        job = image_jobs.proposed_job(row, nonce="isolated123456")
        self.assertNotIn("conversation_url", job)
        validate_job(job)
        self.assertIn(row["capture"]["answer"], job["prompt"])
        self.assertIn("escena narrativa única", job["prompt"])
        self.assertIn("no dibujes guindillas", job["prompt"])
        self.assertIn("Identificador: " + row["trend_id"], job["prompt"])
        job["conversation_url"] = "https://chatgpt.com/c/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        validate_job(job)

    def test_source_editorial_chat_url_is_not_copied_to_image_request(self):
        queue, _ = fixture()
        row = queue["items"]["trv2-%024x" % 1]
        editorial_chat = "https://chatgpt.com/c/bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
        row["capture"]["chat_url"] = editorial_chat
        job = image_jobs.proposed_job(row, nonce="separate123456")
        self.assertNotIn(editorial_chat, str(job))
        self.assertNotIn("conversation_url", job)

    def test_first_image_is_rank_one_even_with_pending_editorial_at_17(self):
        queue, history = fixture()
        with patch.object(image, "JOURNALS", pathlib.Path(tempfile.mkdtemp())):
            row, attempt = image.pick_next(queue, history)
        self.assertEqual((row["name"], attempt), ("#FelizDomingo", 1))

    def test_skip_saved_and_unexplained(self):
        queue, history = fixture()
        first = queue["items"]["trv2-%024x" % 1]
        first["capture"]["image"] = {"status": "saved", "path": "x", "sha256": "a" * 64}
        with patch.object(image, "JOURNALS", pathlib.Path(tempfile.mkdtemp())):
            row, attempt = image.pick_next(queue, history)
        self.assertEqual((row["name"], attempt), ("Explicada 02", 1))
        self.assertFalse(image.eligible(queue["items"]["trv2-%024x" % 17]))

    def test_rex_revision_is_as_eligible_as_initial_explanation(self):
        queue, history = fixture()
        first = queue["items"]["trv2-%024x" % 1]
        updated_answer = "Reexplicación confirmada desde X: detalle nuevo"
        first.update(revision=2, review_mode="x", reason="user_reexplanation")
        first["capture"] = {"revision": 2, "answer": updated_answer,
                            "sha256": fingerprint(updated_answer), "image": {}}
        self.assertTrue(image.eligible(first))
        with tempfile.TemporaryDirectory() as folder:
            with patch.object(image, "JOURNALS", pathlib.Path(folder)):
                row, attempt = image.pick_next(queue, history)
        self.assertEqual((row["trend_id"], row["revision"], attempt),
                         (first["trend_id"], 2, 1))

    def test_retry_cooldown_does_not_stop_other_ranks(self):
        queue, history = fixture()
        with tempfile.TemporaryDirectory() as folder:
            with patch.object(image, "JOURNALS", pathlib.Path(folder)):
                row, attempt = image.pick_next(queue, history)
                image.JOURNALS.mkdir(exist_ok=True)
                editorial.store(image.journal_path(row["trend_id"], 1, attempt),
                                {"at": datetime.now(timezone.utc).isoformat(),
                                 "status": "failed"})
                next_row, next_attempt = image.pick_next(queue, history)
                self.assertEqual((next_row["name"], next_attempt), ("Explicada 02", 1))
                later = datetime.now(timezone.utc) + timedelta(minutes=5)
                retry_row, retry_attempt = image.pick_next(queue, history, now=later)
                self.assertEqual((retry_row["name"], retry_attempt), ("#FelizDomingo", 2))

    def test_first_saved_receipt_is_immutable(self):
        queue, _ = fixture()
        tid = "trv2-%024x" % 1
        row = queue["items"][tid]
        row["capture"]["image"] = {"status": "saved", "path": "original"}
        latest = copy.deepcopy(queue)
        class Api:
            def request(self, *args, **kwargs):
                raise AssertionError("Should not contact GitHub when simulated")
        with patch.object(editorial, "queue_read", return_value=(latest, "blob")):
            with patch.object(editorial, "queue_write") as writer:
                editorial.update_image_receipt(Api(), "authtoken", tid, 1,
                                               row["capture"]["sha256"],
                                               {"status": "saved", "path": "duplicate"})
                writer.assert_not_called()

    def test_image_generation_progress_is_revision_safe_and_cleared(self):
        queue, _ = fixture()
        tid = "trv2-%024x" % 1
        row = queue["items"][tid]
        job = image_jobs.proposed_job(row, nonce="progress123456789")
        current = copy.deepcopy(queue)
        class Api:
            pass
        with patch.object(editorial, "queue_read", return_value=(current, "blob")):
            with patch.object(editorial, "queue_write") as writer:
                self.assertTrue(image.update_image_progress(Api(), "auth", job, active=True))
                writer.assert_called_once()
                marker = current["items"][tid]["image_progress"]
                self.assertEqual(marker["command_id"], job["command_id"])
                self.assertEqual(marker["revision"], 1)
                self.assertTrue(image.update_image_progress(Api(), "auth", job, active=False))
                self.assertNotIn("image_progress", current["items"][tid])
                self.assertEqual(writer.call_count, 2)
        current["items"][tid]["revision"] = 2
        with patch.object(editorial, "queue_read", return_value=(current, "blob")):
            with patch.object(editorial, "queue_write") as writer:
                self.assertFalse(image.update_image_progress(Api(), "auth", job, active=True))
                writer.assert_not_called()

    def test_independent_profiles_and_loops(self):
        self.assertNotEqual(image.PROFILE, editorial.PROFILE)
        self.assertEqual(image.PROFILE.name, "ChromeProfileImages")
        self.assertIn("image_profile_pids", inspect.getsource(image.run_one))
        self.assertNotIn("image_same_chat_v2", inspect.getsource(editorial.run_one))
        self.assertIn("images.sort(", same_chat.probe("v2-img-test"))
        self.assertNotIn("images.length!==1", same_chat.probe("v2-img-test"))


if __name__ == "__main__":
    unittest.main()

