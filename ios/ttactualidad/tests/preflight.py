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

# Editorial UX and durable GitHub session contract.
assert "SecureSession" in auth and 'save("session", value: saved)' in auth
assert "refreshTask" in auth and "renewOnForeground()" in dashboard
assert "LazyVGrid" in dashboard and "ScrollView(.horizontal" not in dashboard
assert "case sinRevisar" in store and "unreviewedNews" in store
assert "operationHistory" in store and "pendingOperationsCount" in store
assert "newsWorking" in shared and "trendsWorking" in shared and "pendingActions" in shared
assert "RefreshLiveCountsIntent()" in activity
assert "partialData: partial" in store

# Compact Top 30: exactly eight visible filters in two rows of four.
assert "case movimientos" not in store
assert 'filterChip("↑↓ Cambios"' not in dashboard
assert "count: 4), spacing: 5)" in dashboard
assert dashboard.count('filterChip("') == 14  # 8 trends and 6 news
assert "softCardColor" in dashboard and "colors: [softCardColor, TTTheme.cardInterior]" in dashboard
assert "rankColor, in: RoundedRectangle" in dashboard

# Direct navigation, real radar entrants and durable unread state.
assert 'Abrir noticias en Listas' in dashboard
assert 'Abrir tendencias en Listas' in dashboard
assert 'store.radarNewNames.contains($0.name)' in dashboard
assert 'updateRadarEntrants(' in store and 'TTActualidad.radar.lastVersion.v1' in store
assert 'TTActualidad.unread.news.v1' in store and 'TTActualidad.unread.trends.v1' in store
assert 'quickButton("Preparar novedad"' not in actions
assert 'quickButton("Reelaborar"' not in actions
assert 'quickButton("Elaborar desde cero"' in actions

# Fresh news rewrite keeps 0.4.3 semantics consistent across iOS and backend.
assert 'quickButton("Elaborar desde cero"' in actions
assert 'action.decision == "rework"' in store
assert 'item["rewrite_pending"] as? Bool != true' in store
assert (root.parents[1] / "pilot/rework_ttittulares.py").exists()

# Pending operations stay visible after restarting; no optimistic success.
pending_panel = (root / "TTActualidad" / "PendingOperationsPanel.swift").read_text()
assert "PendingOperationsPanel().environmentObject(store)" in dashboard
assert "TTActualidad.operations.v1" in store and "requestID: String? = nil" in store
assert "reconcileOperationHistory(" in store
assert 'pilot/ttactualidad-action-receipts.json' in store
assert '"Sin confirmar"' in store and '"Esperando GitHub"' in store
assert "Comprobar GitHub ahora" in pending_panel
assert "Pendiente de GitHub" in pending_panel or "Esperando GitHub" in pending_panel
assert "requestID: requestID" in actions and "requestID: requestID" in auth

# A terminal GitHub deletion must remove BOTH canonical and optimistic work.
assert 'closedTrends(manual: manual, requests: requests' in store
assert 'retireClosedTrendOverlays(' in store
assert 'if closedAfterRequest {' in store
assert 'stage = "Retirada"' in store
assert '"deleted_at", "dismissed_at", "updated_at"' in store
assert 'finishedByName[norm(name)]' in store
assert 'operation.id.hasPrefix("ttendencias:")' in store
assert 'case "Confirmada", "En Listas", "Verificada", "Retirada"' in pending_panel
