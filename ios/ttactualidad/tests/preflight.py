"""Preflight: native app, real GitHub Listas, no Cloudflare or home widgets."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
project = (root / "project.yml").read_text(encoding="utf8")
store = (root / "TTActualidad/EditorialStore.swift").read_text(encoding="utf8")
activity = (root / "TTActualidadLive/TTActualidadLive.swift").read_text(encoding="utf8")
shared = (root / "Shared/LiveCountsAttributes.swift").read_text(encoding="utf8")
app = (root / "TTActualidad/TTActualidadApp.swift").read_text(encoding="utf8")
dashboard = (root / "TTActualidad/TTDashboard.swift").read_text(encoding="utf8")
actions = (root / "TTActualidad/EditorialActionPanels.swift").read_text(encoding="utf8")
auth = (root / "TTActualidad/GitHubEditor.swift").read_text(encoding="utf8")

assert "NSSupportsLiveActivities: true" in project
assert "ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon" in project
assert (root / "art/AppIcon.svg").is_file()
assert "TTDashboard()" in app
assert "NewsSubmissionSheet" in dashboard and "EditorialActions" in dashboard
assert "ttactualidad_manual_news_v1" in auth and "ttactualidad_action_v1" in auth
assert "kSecClassGenericPassword" in auth and "https://api.github.com/" in auth
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

# Gallery is explicitly archive-only: no AI retrieval or generated-image fallback.
catalog = (root / "TTActualidad/ArchivePhotoCatalog.swift").read_text(encoding="utf8")
gallery = (root / "TTActualidad/ArchivePhotoGallery.swift").read_text(encoding="utf8")
assert 'trends/archive-images/' in catalog and 'ttittulares/archive-images/' in catalog
assert 'generated-images' in catalog and '!image.path.lowercased().contains("generated-images")' in catalog
assert 'ArchivePhotoCatalog.resolved(' in store
# A dedicated photo-gallery filter was intentionally removed from the UI.
# Archive-photo support inside each expanded editorial card remains available.
assert 'chip("Fotos archivo"' not in dashboard
assert 'ArchivePhotoGallery' not in dashboard
assert 'Foto archivo' in actions
assert 'lineLimit(expanded ? nil : 2)' in dashboard
assert 'movementLabel' in dashboard and 'rankColor' in dashboard
assert 'Copiar foto de archivo' in gallery
assert 'ChatGPT Images' in actions
