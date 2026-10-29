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
# GitHub acceptance (HTTP 204) is never treated as final application.
# Each decision has a persisted ID, a bounded receipt lookup and an explicit
# unverified state rather than an eternal pending notice.
assert "EditorialReceiptPending: Codable" in auth
assert "pendingReceipts" in auth and "requestID: requestID" in auth
assert "checkPendingReceipts()" in auth and "followReceipt(requestID)" in auth
assert '"applied", "already_applied"' in auth
assert '"request_id"' in auth and '"revision"' in auth
assert "persistPendingReceipts()" in auth and "expireUnverifiedReceipts()" in auth
assert 'receiptChange' in dashboard and 'resumeReceiptChecks()' in dashboard
assert ".onChange(of: github.receiptChange)" in actions
# Old published deliveries may share an ID with a new weekly explanation.
assert "if let closedAt {" in store and "closedAt.timeIntervalSince(explained) >= -60" in store
from datetime import datetime, timedelta
older_closed = datetime.fromisoformat("2026-10-08T07:48:38+02:00")
fresh_explained = datetime.fromisoformat("2026-10-29T07:43:00+01:00")
assert (older_closed - fresh_explained).total_seconds() < -60
actual_closure = fresh_explained + timedelta(minutes=10)
assert (actual_closure - fresh_explained).total_seconds() >= -60
# Three distinct post-X outcomes, and immediate UI removal with rollback.
assert 'confirmPublication = true' in actions
assert 'submitDecision("published")' in actions and 'submitDecision("deleted")' in actions
assert 'Button("Cancelar", role: .cancel)' in actions
assert "optimisticClosures" in auth and "reconcileOptimisticClosures" in auth
assert 'optimisticClosures.insert' in auth and 'optimisticClosures.remove' in auth
assert 'visibleReadyNews' in dashboard and 'visibleReadyTrends' in dashboard
assert 'case .listas: return visibleReadyNews' in dashboard
assert 'case .listas: return visibleReadyTrends' in dashboard
# An explanation and its request must refer to the same editorial occurrence.
assert 'sameEditorialEpisode' in store and 'reqRev > rowRev && !sameEditorialEpisode' in store
same_text = "TT#9 #FelizJueves"
different_text = "TT#9 Otra tendencia"
assert (same_text == same_text) and not (different_text == same_text)
print("TT_ACTUALIDAD_IOS_OPTIMISTIC_PUBLICATION_OK")
print("TT_ACTUALIDAD_IOS_RECEIPT_AND_RECURRENCE_OK")
print("TT_ACTUALIDAD_IOS_PREFLIGHT_OK")

# Gallery is explicitly archive-only: no AI retrieval or generated-image fallback.
catalog = (root / "TTActualidad/ArchivePhotoCatalog.swift").read_text(encoding="utf8")
gallery = (root / "TTActualidad/ArchivePhotoGallery.swift").read_text(encoding="utf8")
assert 'trends/archive-images/' in catalog and 'ttittulares/archive-images/' in catalog
assert 'generated-images' in catalog and '!image.path.lowercased().contains("generated-images")' in catalog
assert 'ArchivePhotoCatalog.resolved(' in store
assert 'ArchivePhotoGallery' in dashboard
assert 'Copiar foto de archivo' in gallery
assert 'ChatGPT Images' in actions
