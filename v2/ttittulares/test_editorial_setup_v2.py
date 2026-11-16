from pathlib import Path
import tempfile
import unittest

from .editorial_setup_v2 import prepare


class SetupTests(unittest.TestCase):
    def test_only_idle_source_is_copied_into_private_news_seed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'news'
            busy, idle = Path(tmp) / 'busy', Path(tmp) / 'idle'
            for p in (busy, idle):
                p.mkdir(); (p / 'Local State').write_text(p.name)
            result = prepare(root, [busy, idle], Path(tmp) / 'chrome',
                             find_pids=lambda p: [22] if p == busy else [])
            self.assertEqual((root / 'AuthSeed' / 'Local State').read_text(), 'idle')
            self.assertFalse(result['browser_opened'])
            self.assertFalse(result['chatgpt_auth_verified'])
            self.assertTrue((root / 'AuthSeed' / 'news-auth-seed.complete').is_file())

    def test_busy_or_partial_seed_is_not_silently_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'news'
            source = Path(tmp) / 'source'; source.mkdir(); (source / 'Local State').write_text('auth')
            with self.assertRaisesRegex(RuntimeError, 'NO_IDLE'):
                prepare(root, [source], 'chrome', find_pids=lambda p: [44])
            (root / 'AuthSeed').mkdir()
            with self.assertRaisesRegex(RuntimeError, 'INCOMPLETE'):
                prepare(root, [source], 'chrome', find_pids=lambda p: [])

    def test_existing_completed_seed_is_preserved_without_copying_other_credentials(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'news'
            seed = root / 'AuthSeed'; seed.mkdir(parents=True)
            (seed / 'Local State').write_text('news-auth')
            (seed / 'news-auth-seed.complete').write_text('ready')
            result = prepare(root, [], 'chrome', find_pids=lambda p: [])
            self.assertEqual((seed / 'Local State').read_text(), 'news-auth')
            self.assertTrue(result['seed_ready'])


if __name__ == '__main__': unittest.main()
