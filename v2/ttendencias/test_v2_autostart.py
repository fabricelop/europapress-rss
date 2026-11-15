"""V2 Top30 autostart contract: isolated Windows task and no console popups."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parent


class Top30TaskAutostartTests(unittest.TestCase):
    def test_starts_when_user_logs_on_and_keeps_15_minute_schedule(self):
        script = (ROOT / "Install-V2-Top30-15min.ps1").read_text(encoding="utf-8")
        self.assertIn("New-ScheduledTaskTrigger -AtLogOn -User $account", script)
        self.assertIn("-RepetitionInterval (New-TimeSpan -Minutes 15)", script)
        self.assertIn("-StartWhenAvailable", script)
        self.assertIn("-MultipleInstances IgnoreNew", script)
        self.assertIn("$existing.State -eq 'Running'", script)
        self.assertIn("TT_V2_TOP30_AT_LOGON=YES", script)
        self.assertIn("TTActualidadV2-Top30-15m", script)
        self.assertNotIn("TTendencias Local", script)

    def test_uses_hidden_powershell_and_hidden_python(self):
        installer = (ROOT / "Install-V2-Top30-15min.ps1").read_text(encoding="utf-8")
        runner = (ROOT / "Run-V2-Top30-Tick.ps1").read_text(encoding="utf-8")
        self.assertIn("-WindowStyle Hidden -File", installer)
        self.assertIn("-WindowStyle Hidden", runner)
        self.assertNotIn("-NoNewWindow", runner)

    def test_recovers_missing_modules_without_overwriting_existing_installation(self):
        installer = (ROOT / "Install-V2-Top30-15min.ps1").read_text(encoding="utf-8")
        self.assertIn("Ensure-V2File 'top30_tick_v2.py'", installer)
        self.assertIn("Ensure-V2File 'persist_capture_github.py'", installer)
        self.assertIn("Ensure-V2File 'Run-V2-Top30-Tick.ps1'", installer)
        self.assertIn("if (Test-Path -LiteralPath $destination) { return }", installer)
        self.assertIn("Select-String -LiteralPath $download -Pattern $marker", installer)
        self.assertIn("feature/ttactualidad-v2-clean/v2/ttendencias/", installer)


if __name__ == "__main__":
    unittest.main()
