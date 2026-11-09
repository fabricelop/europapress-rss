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
# The optimistic UI hides a card before the POST, and restores only when
# the authoritative private service cannot confirm a decision.
assert 'Decisión no confirmada:' in view
assert 'images.removeAll { $0.id == item.id }' in view
assert 'decisionTail = Task {' in view
assert 'await previous?.value' in view
assert 'restore(item)' in view
assert 'model.decide(item, action: "approve", using: github)' in view
assert 'model.decide(item, action: "reject", using: github)' in view
assert 'model.actionID' not in view
assert 'response.appVerified == true' in view and 'response.sitesVerified == true' in view
assert 'ContentUnavailableView' in view
print('TT_IMAGE_INBOX_IOS_STATIC_OK')