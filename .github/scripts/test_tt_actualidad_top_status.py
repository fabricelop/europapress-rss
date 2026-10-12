#!/usr/bin/env python3
"""Checks user-visible Top30 status priority in the real GitHub Pages source."""
from html.parser import HTMLParser
from pathlib import Path

text=Path("docs/index.html").read_text(encoding="utf8")
assert "const closedByName=new Map()" in text
assert "closedById=new Map()" in text
assert "closedByTopic=new Map()" in text
assert "const terminal=manualPending?null:(directClosed||topicClosed)" in text
assert "const editorialState=terminal?terminalLabel[terminal.status]" in text
assert "wasDelivered&&text?" in text
assert "readyText?'EXPLICACIÓN SIN ENTREGAR'" in text
assert ("command('Preparar','prepare')" in text or
        "command('Preparar novedad','prepare')" in text)
assert "Number(x.rank)>=11&&Number(x.rank)<=30" in text
assert "['EN COLA','EN ELABORACIÓN','REVISIÓN','EXPLICADA','BORRADA','PUBLICADA','DESESTIMADA','RETIRADA']" in text
assert "x.rank<=10||x._manualPending" in text
assert "const text=!inExplained&&!working&&!activelyEditing&&(terminal||wasDelivered)?readyText:'';" in text
assert "['hispanidad','feliz dia de la hispanidad','12deoctubre']" in text
print("TT_ACTUALIDAD_STATUS_PRIORITY_SELFTEST_OK")
