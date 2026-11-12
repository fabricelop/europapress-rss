"""Static guard until a real macOS/iPhone build verifies the Swift source."""
from pathlib import Path
p = Path(__file__).resolve().parents[1]
view = (p / 'TTActualidad/ImageApprovalInbox.swift').read_text()
gh = (p / 'TTActualidad/GitHubEditor.swift').read_text()
dash = (p / 'TTActualidad/TTDashboard.swift').read_text()
config = (p / 'project.yml').read_text()
assert 'ImageApprovalInbox(github: github)' in dash
assert 'privateImageInboxRequest' in gh and 'authorizedToken()' in gh
assert 'TTImageApprovalAPIBaseURL' in config and 'TTImageApprovalAPIBaseURL' in gh
assert 'Button("Aprobar")' in view and 'Button("Rechazar")' in view
assert 'approved_awaiting_publication' in view and 'expectedIdentity' in view
assert 'SHA256.hash(data: data)' in view
assert not __import__('re').search(r'\bAsyncImage\s*\(', view)  # ignore comment; reject an actual call
assert 'URLSession' not in view  # auth always remains in GitHubEditor
# Keep each card visible while POST is in progress; a definitive 409/401
# must be shown inline without an optimistic remove/reinsert animation.
assert 'holdUnconfirmed(item, action: action' in view
assert 'Section("Decisiones sin confirmación (" +' in view
assert 'images.removeAll { $0.id == item.id }' in view  # only accepted/held records
assert 'decisionTail = Task {' in view
assert 'await previous?.value' in view
assert 'restoreRejected(item)' in view
assert 'model.decide(item, action: "approve", using: github)' in view
assert 'model.decide(item, action: "reject", using: github)' in view
assert 'model.actionID' not in view
assert 'response.appVerified == true' in view and 'response.sitesVerified == true' in view
assert 'ContentUnavailableView' in view
print('TT_IMAGE_INBOX_IOS_STATIC_OK')
# Exact image decisions survive app termination and do not repeat after
# a successful authenticated server acceptance with a delayed X mirror.
assert 'AcceptedReceipt: Codable' in view
assert 'UserDefaults.standard.data(forKey: acceptedKey)' in view
assert 'UserDefaults.standard.set(data, forKey: acceptedKey)' in view
assert 'private func accepted(_ item: PendingImage)' in view
assert 'accepted($0)' in view
assert 'markAccepted(item, state: response.state)' in view
assert 'markAccepted(item, state: "published_unverified")' in view
assert 'Aprobación aceptada por el servidor' in view
assert 'response.appVerified == true' in view and 'response.sitesVerified == true' in view
assert 'No se repetirá la aprobación' in view
assert 'associateVerifiedOriginalInGitHub(item, using: github)' in view
assert 'restoreRejected(item)' in view
print("TT_IMAGE_APPROVAL_PERSISTENT_IDEMPOTENCY_BUILD98_OK")

# A regenerated receipt ID for the same PNG/episode must not reopen approval.
assert 'acceptedReceipts.values.contains' in view
assert 'unconfirmedDecisions.values.contains' in view
assert 'return $0.id > $1.id' in view
print("TT_IMAGE_INBOX_RECEIPT_ID_CHANGE_DEDUP_OK")

# Build99: many images must not arbitrarily evict an on-screen preview.
assert 'private let previewLimit = 64' in view
assert 'kCGImageSourceThumbnailMaxPixelSize: 640' in view
assert 'previewOrder.append(item.id)' in view
assert 'previews.keys.first' not in view
print("TT_IMAGE_INBOX_THUMBNAIL_CACHE_STABLE_BUILD99_OK")

# Build100: server rejection remains visible on the same row without
# optimistic disappearance, even if a reload starts during POST.
decide = view[view.index('func decide(_ item: PendingImage'):
              view.index('private func persistDecision(_ item: PendingImage')]
assert 'images.removeAll { $0.id == item.id }' in decide
assert 'decisionFailures.removeValue(forKey: item.id)' in decide
assert 'decisionFailures[item.id] = "DECISIÓN NO APLICADA: "' in view
assert 'if let failure = model.decisionFailures[item.id]' in view
assert 'let ready = items.filter {' in view
assert 'images = ready' in view
assert 'restoreRejected(item)' in view
print("TT_IMAGE_INBOX_BUILD100_NO_BOUNCE_OK")

# Exact rollback: the tap is immediate, POST is asynchronous, a confirmed
# 4xx rejection restores only the same PNG and leaves an inline diagnosis.
assert 'images.removeAll { $0.id == item.id }' in decide
assert 'optimisticPositions[item.id] = images.firstIndex' in decide
assert 'restoreRejected(item)' in view
assert 'decisionFailures[item.id] = "DECISIÓN NO APLICADA: "' in view
assert 'let keys = Set(images.map(\\.id)).union(processingIDs)' in view
print("TT_IMAGE_INBOX_BUILD101_OPTIMISTIC_WITH_ERROR_DETAILS_OK")
