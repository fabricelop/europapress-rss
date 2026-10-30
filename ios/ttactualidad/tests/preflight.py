"""Preflight: native iPhone editor and PlumeImpactor Live Activity (no Home widgets)."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
project = (root / "project.yml").read_text(encoding="utf8")
store = (root / "TTActualidad/EditorialStore.swift").read_text(encoding="utf8")
activity = (root / "TTActualidadLive/TTActualidadLive.swift").read_text(encoding="utf8")
widget_source = (root / "Shared/RefreshLiveCountsIntent.swift").read_text(encoding="utf8")
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
assert "recentHeadline" in shared and "latestHeadline" in widget_source
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

# Urgent/manual editor must open the already signed-in ChatGPT iOS app,
# never the unauthenticated browser homepage. Keep Images unchanged.
assert 'quickButton("URGENTE · Elaborar ya"' in actions
assert actions.count('quickButton("Abrir ChatGPT"') == 2
assert 'URL(string: "chatgpt://")' in actions
assert 'URL(string: "com.openai.chat://")' in actions
assert 'UIApplication.shared.open(primary, options: [:])' in actions
assert 'openChatGPTApp()' in actions
assert 'URL(string: "https://chatgpt.com/")' not in actions
assert 'https://chatgpt.com/images' in actions

# Editorial UX and durable GitHub session contract.
assert "SecureSession" in auth and 'save("session", value: saved)' in auth
assert "refreshTask" in auth and "renewOnForeground()" in dashboard
assert "LazyVGrid" in dashboard and "ScrollView(.horizontal" not in dashboard
assert "case sinRevisar" not in store
assert 'filterChip("Sin revisar"' not in dashboard
assert "operationHistory" in store and "pendingOperationsCount" in store
assert "newsWorking" in shared and "trendsWorking" in shared and "pendingActions" in shared
assert "RefreshLiveCountsIntent()" in activity
assert "partialData: partial" in store

# Top 30: six trend filters in two rows of three; Nuevas removed.
assert "case movimientos" not in store
assert 'filterChip("↑↓ Cambios"' not in dashboard
assert "count: 3), spacing: 5)" in dashboard
assert dashboard.count('filterChip("') == 11  # 6 trends and 5 news
assert "softCardColor" in dashboard and "colors: [softCardColor, TTTheme.cardInterior]" in dashboard
assert "rankColor, in: RoundedRectangle" in dashboard

# Direct navigation, real radar entrants and durable unread state.
assert 'Abrir noticias en Listas' in dashboard
assert 'Abrir tendencias en Listas' in dashboard
assert 'store.radarNewNames.contains(item.name)' in dashboard
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
assert "Órdenes por confirmar" in pending_panel
assert "requestID: requestID" in actions and "requestID: requestID" in auth

# A terminal GitHub deletion must remove BOTH canonical and optimistic work.
assert 'closedTrends(manual: manual, requests: requests' in store
assert 'retireClosedTrendOverlays(' in store
assert 'if closedAfterRequest || newsTerminal {' in store
assert 'stage = "Retirada"' in store
assert '"deleted_at", "dismissed_at", "updated_at"' in store
assert 'finishedByName[norm(name)]' in store
assert 'private func operationIdentity(_ operation: EditorialOperation)' in store
assert '["ttittulares", "ttendencias"].contains(project)' in store
assert 'case "Confirmada", "En Listas", "Verificada", "Retirada"' in pending_panel

# Legacy unconfirmed operations from pre-0.4.4 lack request IDs.
# They must reconcile using stable project, event ID, revision, action and time.
assert 'private func operationIdentity(_ operation: EditorialOperation)' in store
assert 'let receipt = remote' in store
assert 'Self.str(row, "event_id") == id' in store
assert 'Self.str(row, "decision") == operation.kind' in store
assert 'Self.int(row, "revision") == identity.revision' in store
assert 'operation.createdAt.addingTimeInterval(-180)' in store
assert '"ttittulares/decisions.json"' in store
assert 'freshReceipts || freshNewsDecisions || freshTrendClosures' in store
assert 'stage = "Confirmada"' in store

# A successful Github deletion must be durable across stale/cached snapshots.
assert "struct EditorialTombstone: Codable" in store
assert '"TTActualidad.confirmed-terminals.v1"' in store
assert "accumulateConfirmedTerminals(docs, downloaded)" in store
assert "applyConfirmedTerminals(EditorialSnapshot(" in store
assert "snapshot = applyConfirmedTerminals(updated)" in store
assert '"pilot/ttactualidad-action-receipts.json"' in store
assert '"ttittulares/decisions.json"' in store
assert '"trends/mobile-decisions.json"' in store
assert "revision <= tombstone.revision" in store
assert "persistTerminals()" in store
assert "case .verified:" in store and "markTerminal(project: project" in store
assert "news: canonicalSnapshot.news," in store

# Every Tremending story retains its real Público URL and exposes an external link.
assert 'sourceURL: URL(string: Self.str(item, "url"))' in store
assert 'news.status == "TREMENDING"' in actions
assert 'quickButton("Ver en Público", "arrow.up.right.square")' in actions
assert 'openURL(original)' in actions
assert 'url.path.hasPrefix("/tremending/")' in actions
assert 'url.scheme?.lowercased() == "https"' in actions

# Publish/non-publish is a deliberate two-button confirmation on ready Lists.
assert 'Button("Publicado · Quitar de Listas")' in actions
assert '"No publicado · Quitar de Listas"' in actions
covered_actions = actions.split('if let trend, trend.isCovered {', 1)[1].split('} else if let news', 1)[0]
assert 'quickButton("Quitar de Listas"' in covered_actions
assert 'trend?.isCovered != true' not in actions
assert 'submit("published")' in actions and 'submit("deleted")' in actions
assert '"pilot/ttactualidad-publication-events.json"' in store
assert "func publicationsLast24h(project: String, now: Date = Date()) -> Int?" in store
assert "now.addingTimeInterval(-86_400)" in store
assert "$0.confirmedAt > lowerBound && $0.confirmedAt <= now" in store
assert 'publicationLedgerAvailable = false' in store
assert 'Self.str(row, "decision") == "published"' in store
assert 'TimelineView(.periodic(from: .now, by: 60))' in dashboard
assert 'published24hChip("TTiT", project: "ttittulares"' in dashboard
assert 'published24hChip("TTen", project: "ttendencias"' in dashboard
assert '"published" : "deleted"' not in store or 'action.decision == "published"' in store

# Publication badge must observe every verified receipt and never stall full UI.
assert '@Published private var publicationEvents: [PublicationEvent]' in store
assert 'func refreshPublicationCounters(' in store
assert 'expectedProject: project, expectedID: id' in store
assert 'async let ledger = fetchPublicationJSON(' in store
assert 'async let receipts = fetchPublicationJSON(' in store
assert 'publicationEvents = Array(unique.values)' in store
assert 'guard !isLoading else { return }' in store
assert 'lastCompletedRefresh' in store
assert 'refreshIfStale(minInterval: TimeInterval = 120)' in store
assert 'refreshRequested' not in store
assert 'isManuallyRefreshing' in dashboard
assert '.refreshable {' not in dashboard
assert '.onChange(of: scenePhase)' not in dashboard
assert 'refreshIfStale(minInterval: 120)' in app
assert 'refresh(manual: true)' in dashboard

# 0.4.11: Chronological 24h audit, no redundant editorial hub or swipe-refresh copy.
history = (root / "TTActualidad/PublishedHistorySheet.swift").read_text()
assert "struct ConfirmedPublication: Identifiable" in store
assert "func publicationsHistoryLast24h(" in store
assert "if $0.confirmedAt != $1.confirmedAt" in store
assert 'publicationSheet = PublicationSheetRoute(project: project)' in dashboard
assert '.sheet(item: $publicationSheet)' in dashboard
assert 'PublishedHistorySheet(project: selection.project)' in dashboard
assert 'history.count - index' in history and 'history.enumerated()' in history
assert 'item.confirmedAt, format: .dateTime.day()' in history
assert 'showEditorialHub' not in dashboard
assert 'GitHub directo · Sin Cloudflare' not in dashboard
assert 'Última actualización' in dashboard
assert 'Desliza para actualizar' not in dashboard
assert 'Pulsa el botón de actualizar arriba' in dashboard

# 0.4.12 editor hints: request provenance + old investigations remain visible.
hints_sheet = (root / "TTActualidad" / "TrendHintsSheet.swift").read_text()
assert 'TextEditor(text: $hints)' in hints_sheet
assert 'submitTrendHints(' in hints_sheet and 'requestID: requestID' in hints_sheet
assert 'decision: "hints"' in hints_sheet
assert 'quickButton("Aportar pistas"' in actions
assert 'case "hints": return "Aportar pistas e investigar"' in store
assert 'var unexplainedTrends: [TrendItem]' in store
assert 'buildUnexplainedTrends(' in store
assert 'SIN EXPLICACIÓN' in store and 'SIN EXPLICACIÓN' in dashboard
assert 'store.snapshot.unexplainedTrends' in dashboard
assert 'case "SIN EXPLICACIÓN": return "PISTAS"' in dashboard
assert 'decision == "hints"' in store
assert '"hints": text' in auth
assert 'await store.refreshIfStale(minInterval: 45)' in dashboard
assert 'MARKETING_VERSION: "0.4.29"' in project
assert 'CURRENT_PROJECT_VERSION: "35"' in project
print("TT_ACTUALIDAD_IOS_HINTS_PREFLIGHT_OK")

# 0.4.17: an editorial trend may trigger independent news investigation.
assert 'quickButton("Enviar a TTiTTulares"' in actions
assert 'sendTrendToNews(_ trend: TrendItem)' in actions
assert 'originTrend: trend' in actions
assert 'beginManualNews(requestID: requestID, title: headline,' in actions
assert 'fromTrend: true' in actions
assert 'originTrend: TrendItem? = nil' in auth
assert 'payload["origin_trend"]' in auth
assert 'case "De tendencia a noticia": return "Tendencia → TTiTTulares"' in store
assert 'operation.kind == "De tendencia a noticia"' not in store or 'De tendencia a noticia' in store
assert '["Nueva noticia", "De tendencia a noticia"].contains(operation.kind)' in store
print("TT_ACTUALIDAD_IOS_TREND_TO_NEWS_PREFLIGHT_OK")

# 0.4.17: stale GitHub-inactive orders recover and the verified publish counter
# increments without blocking the rest of the interface.
assert "retireAbandonedTrendOperations(" in store
assert "await store.refreshIfStale(minInterval: 0)" in hints_sheet
assert '["inactive", "problem", "failed"].contains(' in store
assert 'publicationEvents.append(PublicationEvent(' in store
assert 'func requestEditorialRun(project: String)' in auth
assert '"control/ttendencias-run-trigger"' in auth
assert 'headName.hasPrefix("control/ttittulares-run-trigger")' in auth
assert 'requestEditorialRun(project: project)' in dashboard
assert 'Solicitar procesamiento de' in dashboard
assert 'CURRENT_PROJECT_VERSION: "35"' in project
print("TT_ACTUALIDAD_IOS_0414_EDITORIAL_RUN_PREFLIGHT_OK")

# 0.4.17: cancel PROCESSING without adding to Listas, and separate
# unacknowledged GitHub commands from already registered editorial work.
assert 'quickButton("Suprimir · No pasar a Listas"' in actions
assert '"¿Suprimir esta noticia en elaboración?"' in actions
assert 'intent == "discard" && news?.status == "EN ELABORACIÓN"' in actions
assert '["Enviando", "Esperando GitHub", "Pendiente de GitHub",\n         "Sin confirmar"].contains(status)' in store
assert 'operationHistory.filter(\\.isOutstanding).count' in store
assert 'Text("Órdenes por confirmar")' in pending_panel
assert 'terminalMarks["ttittulares:" + draft.id] != nil' in store
assert 'CURRENT_PROJECT_VERSION: "35"' in project
print("TT_ACTUALIDAD_IOS_0415_SUPPRESS_PREFLIGHT_OK")

# 0.4.17: no Home Screen widgets; the same .appex serves a real Live Activity.
assert not (root / "TTActualidadLive/TTActualidadHomeWidgets.swift").exists()
assert "TTActualidadHomeWidget()" not in activity
assert "StaticConfiguration" not in activity and "AppIntentConfiguration" not in activity
assert "WidgetCenter.shared" not in store
assert 'recentHeadline' in shared and 'recentHeadline: source.latestHeadline' in widget_source
assert "ÚLTIMA NOTICIA LISTA" in activity
assert "PUBLICADAS · ÚLTIMAS 24 H" in activity
assert "newsPublished24h" in activity and "trendsPublished24h" in activity
assert 'publishedCountsAvailable' in shared
assert 'pilot/ttactualidad-publication-events.json' in widget_source
assert "retireAbandonedNewsOperations(" in store
assert 'requestID: requestID' in actions and 'requestID: requestID' in hints_sheet
assert 'MARKETING_VERSION: "0.4.29"' in project
assert 'CURRENT_PROJECT_VERSION: "35"' in project
print("TT_ACTUALIDAD_IOS_0417_LIVE_NO_WIDGETS_PREFLIGHT_OK")


# 0.4.20: navigation must not block on large GitHub JSON or archive trees.
assert 'EditorialDocumentLoader.load(paths: paths)' in store
assert 'private enum EditorialDocumentLoader' in store
assert 'private struct EditorialDocumentLoad: @unchecked Sendable' in store
assert 'private static let fractionalISO:' in store
assert 'private static let standardISO:' in store
assert 'terminalMarksNeedSave' in store
catalog = (root / "TTActualidad/ArchivePhotoCatalog.swift").read_text(encoding="utf8")
assert 'private actor ArchivePhotoMemory' in catalog
assert 'if let fresh = await memory.fresh()' in catalog
assert 'Date().timeIntervalSince(modified) < 600' in catalog
assert 'TimelineView(.periodic(from: .now, by: 60))' in dashboard
assert 'TimelineView(.periodic(from: .now, by: 1))' not in dashboard
# Keep urgent/manual ChatGPT and ChatGPT Images navigation unchanged.
assert 'launchUrgentEditorial()' in actions
assert 'openChatGPTApp()' in actions
assert 'TTActualidad.chatGPTProjectLink.v1' not in actions
assert 'openEditorialChat()' not in actions
assert 'quickLink("ChatGPT Images", "photo.artframe", "https://chatgpt.com/images")' in actions
print("TT_ACTUALIDAD_IOS_0420_PERFORMANCE_PREFLIGHT_OK")


# 0.4.21: the compact Dynamic Island itself exposes all six verified metrics.
# +working is not a GitHub write receipt; it counts editorial work in progress.
assert 'private func compactCounts(' in activity
assert 'prefix: "N", ready: context.state.newsReady' in activity
assert 'working: context.state.newsWorking' in activity
assert 'published24h: context.state.newsPublished24h' in activity
assert 'prefix: "T", ready: context.state.trendsReady' in activity
assert 'working: context.state.trendsWorking' in activity
assert 'published24h: context.state.trendsPublished24h' in activity
assert 'publishedAvailable: context.state.publishedCountsAvailable' in activity
assert 'Text("24h")' in activity
assert 'publishedAvailable ? String(published24h) : "—"' in activity
assert 'context.isStale || context.state.partialData' in activity
assert 'Text(context.state.checkedAt, format: .dateTime.hour().minute())' in activity
assert 'openChatGPTApp()' in actions and 'openEditorialChat()' not in actions
print("TT_ACTUALIDAD_IOS_0421_COMPACT_ISLAND_PREFLIGHT_OK")

# Copiar GAG real del iPhone: ilustración pura, no tarjeta de noticia.
assert 'GAG_VISUAL_NATIVE_V2' in actions
for token in ('SOLO IMAGEN', 'SIN NINGÚN TEXTO', 'franja inferior', 'SIN BANDA INFERIOR', 'Más gag, menos barroquismo', 'PROHIBIDO dibujar guindillas'):
    assert token in actions, token
assert 'quickButton("Copiar GAG", "sparkles") { copy(gagPrompt) }' in actions
print("TT_ACTUALIDAD_IOS_GAG_NATIVE_V2_OK")


assert 'filterChip("Nuevas"' not in dashboard
assert 'case nuevas = "Nuevas"' not in store
