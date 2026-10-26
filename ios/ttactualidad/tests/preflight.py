"""Preflight: native app, real GitHub Listas, no Cloudflare or home widgets."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
project = (root / "project.yml").read_text(encoding="utf8")
store = (root / "TTActualidad/EditorialStore.swift").read_text(encoding="utf8")
activity = (root / "TTActualidadLive/TTActualidadLive.swift").read_text(encoding="utf8")
shared = (root / "Shared/LiveCountsAttributes.swift").read_text(encoding="utf8")
app = (root / "TTActualidad/TTActualidadApp.swift").read_text(encoding="utf8")

assert "NSSupportsLiveActivities: true" in project
assert "TTActualidadLive:" in project
assert "type: app-extension" in project
assert "WidgetBundle" in activity and "ActivityConfiguration(for: LiveCountsAttributes.self)" in activity
assert "StaticConfiguration" not in activity and "AppIntentConfiguration" not in activity
assert "newsReady" in shared and "trendsReady" in shared
assert "ttactualidad://noticias" in activity and "ttactualidad://tendencias" in activity
assert "Activity<LiveCountsAttributes>.request" in store
assert "Activity<LiveCountsAttributes>.activities.first" in store
assert "staleDate:" in store and "context.isStale" in activity
assert "ttittulares/prepared.json" in store
assert "ttittulares/decisions.json" in store
for name in ("trends/telegram-manual-explained.json", "trends/requests.json",
             "trends/telegram-image-deliveries.json", "trends/mobile-decisions.json",
             "trends/editorial-queue.json", "trends/recent.json"):
    assert name in store, name
for source in (project, store, activity, shared, app):
    assert not re.search(r"workers\.dev|pages\.dev|cloudflare\.com|vercel\.app", source, re.IGNORECASE), "Cloudflare/Vercel dependency"
assert "BGTaskScheduler" not in store
assert "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/" in store
assert "partialData: partial" in store
assert "no Home Screen or Lock Screen widgets" in shared
print("TT_ACTUALIDAD_IOS_PREFLIGHT_OK")
