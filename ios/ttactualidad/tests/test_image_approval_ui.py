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
assert 'AsyncImage' not in view
assert 'URLSession' not in view  # auth always remains in GitHubEditor
assert 'No se ha confirmado la decisión' in view
assert 'ContentUnavailableView' in view
print('TT_IMAGE_INBOX_IOS_STATIC_OK')