"""Strict, offline second phase for TTendencias Sites image deletions.

This module DOES NOT delete a hosted Sites file or publish the website.
The Site must first attest to deleting the exact stored file and to reading
back both the missing storage object and the missing editorial image link.
The caller is responsible for serializing GitHub updates with blob-SHA CAS.
"""

from __future__ import annotations

import copy
import re
from urllib.parse import urlsplit

PROJECT_ID = "appgprj_6ae4dcf7d7488191a574e5b649e67370"
SITE_HOST = "ttactualidad-tendencias.rainyraven22.chatgpt.site"
SHA256_RE = re.compile(r"[a-f0-9]{64}\Z")
IDENTITY_RE = re.compile(r"[-a-zA-Z0-9_]{3,160}\Z")


class DeletionGuardError(ValueError):
    """A requested deletion is not proven safe to reconcile."""


def _require_identity(value):
    if not isinstance(value, str) or not IDENTITY_RE.fullmatch(value):
        raise DeletionGuardError("invalid_target_id")


def _require_sha(value):
    if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
        raise DeletionGuardError("invalid_sha256")


def _require_hosted_url(value):
    if not isinstance(value, str):
        raise DeletionGuardError("invalid_image_url")
    u = urlsplit(value)
    if (u.scheme != "https" or u.hostname != SITE_HOST or u.port is not None
            or u.username or u.password or u.query or u.fragment
            or not u.path.startswith("/images/ttendencias/")
            or not u.path.endswith(".png")):
        raise DeletionGuardError("foreign_or_invalid_site_image_url")


def reconcile_after_site_deletion(manifest: dict, request: dict, site_receipt: dict) -> dict:
    """Return a new catalog with *one* exact image removed, otherwise raise.

    The receipt must be produced by the authenticated Site implementation,
    not by client-controlled JSON. A 404 from a CDN alone is insufficient.
    This routine never mutates its inputs and never performs HTTP requests.
    """
    if not all(isinstance(v, dict) for v in (manifest, request, site_receipt)):
        raise DeletionGuardError("invalid_document")
    if manifest.get("schema_version") != 1 or manifest.get("project_id") != PROJECT_ID:
        raise DeletionGuardError("wrong_manifest")
    if not isinstance(manifest.get("images"), list):
        raise DeletionGuardError("invalid_images")
    if request.get("project_id") != PROJECT_ID:
        raise DeletionGuardError("wrong_project")
    _require_identity(request.get("target_id"))
    _require_sha(request.get("sha256"))
    revision = request.get("revision")
    if type(revision) is not int or revision < 0:
        raise DeletionGuardError("invalid_revision")
    _require_hosted_url(request.get("image_url"))
    if not isinstance(request.get("explanation"), str) or not request["explanation"]:
        raise DeletionGuardError("missing_explanation")
    if not isinstance(request.get("explained_at"), str) or not request["explained_at"]:
        raise DeletionGuardError("missing_explained_at")

    identity = (request["target_id"], revision)
    matches = [i for i, image in enumerate(manifest["images"])
               if isinstance(image, dict)
               and (image.get("target_id"), image.get("revision")) == identity]
    if len(matches) != 1:
        raise DeletionGuardError("not_one_exact_catalog_record")
    record = manifest["images"][matches[0]]
    for key in ("target_id", "revision", "sha256", "image_url", "explained_at", "explanation"):
        if record.get(key) != request[key]:
            raise DeletionGuardError("stale_or_mismatched_" + key)

    # Site-side deletion MUST have happened first, including its own readback.
    # Treat all unrecognized/partial/error states as pending, not success.
    if (site_receipt.get("status") != "deleted"
            or site_receipt.get("storage_missing") is not True
            or site_receipt.get("editorial_link_missing") is not True):
        raise DeletionGuardError("site_deletion_not_verified")
    for key in ("project_id", "target_id", "revision", "sha256", "image_url"):
        if site_receipt.get(key) != request.get(key):
            raise DeletionGuardError("site_receipt_mismatch_" + key)

    result = copy.deepcopy(manifest)
    del result["images"][matches[0]]
    return result
