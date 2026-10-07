"""Side-effect-free cross-account story matcher.

This module is intentionally NOT wired into TTiTTulares or TTendencias.
It only classifies a pair of texts as same_story, same_topic or independent.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import asdict, dataclass
from difflib import SequenceMatcher

STOPWORDS = {
    "de","la","el","los","las","un","una","unos","unas","y","o","e","en","a","al",
    "del","por","para","con","sin","sobre","que","se","es","son","ha","han","su","sus",
    "este","esta","estos","estas","como","mas","tras","entre","desde","hasta","ya","le",
    "les","lo","si","no","fue","ser","muy","pero","porque","durante","frente","cada",
    "todo","toda","todos","todas","tendencia"
}


@dataclass(frozen=True)
class MatchResult:
    classification: str
    score: float
    jaccard: float
    containment: float
    sequence_ratio: float
    subject_match: bool
    shared_anchors: tuple[str, ...]

    def to_dict(self) -> dict:
        return asdict(self)


def _normalize(text: str) -> str:
    text = unicodedata.normalize("NFKD", (text or "").lower())
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = re.sub(r"https?://\\S+", " ", text)
    text = re.sub(r"[^a-z0-9ñ]+", " ", text)
    return " ".join(text.split())


def _tokens(text: str) -> list[str]:
    return [
        token for token in _normalize(text).split()
        if token not in STOPWORDS and len(token) > 2
    ]


def classify_story_pair(
    left_text: str,
    right_text: str,
    *,
    subject: str = "",
    same_story_threshold: float = 0.55,
    same_topic_threshold: float = 0.34,
) -> MatchResult:
    left = set(_tokens(left_text))
    right = set(_tokens(right_text))
    union = left | right
    shared = left & right

    jaccard = len(shared) / len(union) if union else 0.0
    containment = (
        len(shared) / min(len(left), len(right))
        if left and right else 0.0
    )
    sequence_ratio = SequenceMatcher(
        None, _normalize(left_text), _normalize(right_text)
    ).ratio()

    anchors = tuple(sorted(
        token for token in shared
        if len(token) >= 6 or token.isdigit()
    ))

    subject_tokens = set(_tokens(subject))
    subject_match = False
    if subject_tokens:
        needed = max(1, len(subject_tokens) - 1)
        subject_match = (
            len(subject_tokens & left) >= needed
            and len(subject_tokens & right) >= needed
        )

    score = (
        0.45 * containment
        + 0.25 * jaccard
        + 0.15 * min(len(anchors) / 4.0, 1.0)
        + 0.15 * sequence_ratio
        + (0.12 if subject_match else 0.0)
    )
    score = min(score, 1.0)

    if score >= same_story_threshold:
        classification = "same_story"
    elif score >= same_topic_threshold or (subject_match and len(shared) >= 2):
        classification = "same_topic"
    else:
        classification = "independent"

    return MatchResult(
        classification=classification,
        score=round(score, 6),
        jaccard=round(jaccard, 6),
        containment=round(containment, 6),
        sequence_ratio=round(sequence_ratio, 6),
        subject_match=subject_match,
        shared_anchors=anchors,
    )
