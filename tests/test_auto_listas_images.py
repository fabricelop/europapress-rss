"""No network, image, or account calls. Validates the one-job enqueue contract."""
import copy
import datetime as dt
import json
import unittest
from ttittulares import auto_listas_images as a

POLICY = {"enabled": True, "automatic_start_at": "2026-11-12T14:35:00Z",
          "max_new_jobs_per_run": 1, "max_active_jobs": 1,
          "one_time_backfill_ids": ["aaa100", "bbb200", "ccc300"]}


def story(target="aaa100", prepared="2026-11-12T13:10:00Z", revision=1):
    return {"event_id": target, "revision": revision, "title": "Titular confirmado",
            "prepared_at": prepared, "with_image": True, "image_mode": "ai_plus_fallback",
            "ai_image_status": "none", "tweet": {"text": "Texto exacto de la noticia", "remate": "🌶️ Remate exacto."}}


class FakeGitHub:
    def __init__(self, data):
        self.data = copy.deepcopy(data)
        self.counts = {}
    def get(self, path, branch=a.BRANCH):
        data = self.data.get((branch, path))
        if data is None:
            return None, None
        return copy.deepcopy(data), "fake-sha"
    def put(self, path, doc, sha=None, branch=a.BRANCH):
        self.counts[path] = self.counts.get(path, 0) + 1
        if (branch, path) in self.data and sha is None:
            raise a.GitHubFailure(422, "already exists")
        self.data[(branch, path)] = copy.deepcopy(doc)
        return {"ok": True}


def fake(items):
    return FakeGitHub({
        ("main", a.SRC_PREPARED): {"items": items},
        ("main", a.SRC_DECISIONS): {"items": []},
        ("main", a.SRC_CATALOG): {"images": []},
        (a.BRANCH, a.INDEX): {"version": 1, "jobs": []}
    })


class EnqueueTests(unittest.TestCase):
    def test_one_job_idempotent_and_one_backfill(self):
        gh = fake([story(), story("bbb200"), story("ccc300")])
        result = a.execute(gh, POLICY)
        self.assertEqual(result["actions"][-1]["result"], "new_job_enqueued")
        self.assertEqual(gh.counts[a.INDEX], 1)
        self.assertEqual(len(gh.data[(a.BRANCH, a.INDEX)]["jobs"]), 1)
        job = gh.data[(a.BRANCH, f"{a.JOB_DIR}/aaa100.json")]
        self.assertEqual(job["delivery_mode"], "launch_only")
        self.assertEqual(job["mode"], "automatic_ready_repair")
        self.assertIn("guindillas", job["context_snapshot"]["image_style"])
        again = a.execute(gh, POLICY)
        self.assertNotIn("new_job_enqueued", [x["result"] for x in again["actions"]])
    def test_status_launched_terminal_and_no_duplicate(self):
        gh = fake([story(), story("bbb200")])
        a.execute(gh, POLICY)
        path = f"{a.JOB_DIR}/aaa100.json"
        gh.data[(a.BRANCH, path)]["status"] = "LAUNCHED"
        result = a.execute(gh, POLICY)
        self.assertEqual(result["actions"][-1]["id"], "bbb200")
        self.assertEqual(len(gh.data[(a.BRANCH,a.INDEX)]["jobs"]), 2)
    def test_new_story_after_cutover_without_backfill(self):
        gh = fake([story("fresh999", "2026-11-12T15:15:00Z")])
        result = a.execute(gh, POLICY)
        self.assertEqual(result["actions"][-1]["result"], "new_job_enqueued")
    def test_no_old_backlog_and_closed_or_assigned(self):
        gh = fake([story("old999"), story()])
        gh.data[("main", a.SRC_DECISIONS)]["items"] = [{"event_id": "aaa100", "status": "published"}]
        self.assertEqual(a.execute(gh, POLICY)["eligible"], 0)
        gh.data[("main", a.SRC_DECISIONS)]["items"] = []
        gh.data[("main", a.SRC_CATALOG)]["images"] = [{"target_id": "aaa100", "revision": 1, "image_url": "https://example.test/existing.png"}]
        self.assertEqual(a.execute(gh, POLICY)["eligible"], 0)
    def test_sensitivity_and_fallback_rules(self):
        for name, value in [("ai_image_status", "failed"),
                             ("ai_image_tool_called_at", "2026-11-12T14:00:00Z")]:
            row = story(); row[name] = value
            self.assertFalse(a.main_story(row, set(), set(), POLICY)[0], (name, value))
        # Legacy topic restrictions must not stop any READY story.
        for name, value in [("disable_ai_image", True), ("image_mode", "fallback_only"),
                            ("with_image", False), ("ai_image_status", "disabled"),
                            ("sensitive_editorial", True), ("image_mode", "tweet_capture_only")]:
            row = story(); row[name] = value
            self.assertTrue(a.main_story(row, set(), set(), POLICY)[0], (name, value))
        row = story(); row["fallback_image_status"] = "ready"
        self.assertTrue(a.main_story(row, set(), set(), POLICY)[0])
        row["sensitive_editorial"] = True
        self.assertTrue(a.main_story(row, set(), set(), POLICY)[0])
        job, _ = a.make_job(row)
        self.assertIn("víctimas", job["instructions"]["sensitivity"])
    def test_pending_job_blocks_other(self):
        gh = fake([story(), story("bbb200")]); a.execute(gh, POLICY)
        outcome = a.execute(gh, POLICY)
        self.assertNotIn("new_job_enqueued", [x["result"] for x in outcome["actions"]])
    def test_orphan_index_repaired_without_new_job(self):
        gh = fake([story()]); job, item = a.make_job(story())
        gh.data[(a.BRANCH, f"{a.JOB_DIR}/aaa100.json")] = job
        result = a.execute(gh, POLICY)
        self.assertEqual(result["actions"][0]["result"], "prior_job_reused_or_index_repaired")
        self.assertEqual(len(gh.data[(a.BRANCH,a.INDEX)]["jobs"]), 1)
        self.assertEqual(gh.counts.get(f"{a.JOB_DIR}/aaa100.json", 0), 0)
    def test_new_revision_only_after_prior_terminal(self):
        newer = story("aaa100", revision=2)
        gh = fake([newer])
        old_job, old_index = a.make_job(story("aaa100", revision=1))
        old_job["status"] = "LAUNCHED"
        old_job["pc_launched_at"] = old_job["requested_at"]
        gh.data[(a.BRANCH, f"{a.JOB_DIR}/aaa100.json")] = old_job
        gh.data[(a.BRANCH, a.INDEX)]["jobs"] = [old_index]
        out = a.execute(gh, POLICY)
        self.assertEqual(out["actions"][-1]["result"], "new_job_enqueued")
        current = gh.data[(a.BRANCH, f"{a.JOB_DIR}/aaa100.json")]
        self.assertEqual(current["revision"], 2)
        self.assertEqual(len(gh.data[(a.BRANCH, a.INDEX)]["jobs"]), 1)
        self.assertEqual(gh.data[(a.BRANCH, a.INDEX)]["jobs"][0]["revision"], 2)
        again = a.execute(gh, POLICY)
        self.assertNotIn("new_job_enqueued", [x["result"] for x in again["actions"]])

    def test_new_revision_never_overwrites_running_old_job(self):
        gh = fake([story("aaa100", revision=2)])
        old_job, old_index = a.make_job(story("aaa100", revision=1))
        old_job["status"] = "RUNNING"
        gh.data[(a.BRANCH, f"{a.JOB_DIR}/aaa100.json")] = old_job
        gh.data[(a.BRANCH, a.INDEX)]["jobs"] = [old_index]
        outcome = a.execute(gh, POLICY)
        self.assertNotIn("new_job_enqueued", [x["result"] for x in outcome["actions"]])
        self.assertEqual(gh.data[(a.BRANCH, f"{a.JOB_DIR}/aaa100.json")]["revision"], 1)

    def test_revision_and_exact_text_required(self):
        row = story(); row["revision"] = "1"; self.assertFalse(a.main_story(row,set(),set(),POLICY)[0])
        row = story(); row["tweet"]["remate"] = ""; self.assertFalse(a.main_story(row,set(),set(),POLICY)[0])
    def test_wrong_policy_fails_closed(self):
        gh = fake([story()]); p = {**POLICY, "max_active_jobs": 10}
        with self.assertRaises(RuntimeError): a.execute(gh, p)

if __name__ == "__main__":
    unittest.main()