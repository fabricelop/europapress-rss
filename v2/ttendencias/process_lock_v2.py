#!/usr/bin/env python3
"""Lock de proceso de TTActualidad V2, compartido entre tanda y consumidor.

El sistema operativo libera el bloqueo al morir el proceso; no interpreta
la mera existencia de un fichero como un consumidor vivo. No toca V1.
"""
import contextlib
import os
import pathlib


class AlreadyRunning(RuntimeError):
    pass


@contextlib.contextmanager
def exclusive_v2_lock(path):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    # Un fichero puede sobrevivir a un cierre forzado; el LOCK del SO no.
    with path.open("a+b") as file:
        file.seek(0, os.SEEK_END)
        if file.tell() == 0:
            file.write(b"\0")
            file.flush()
        file.seek(0)
        if os.name == "nt":
            import msvcrt
            try:
                msvcrt.locking(file.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError:
                raise AlreadyRunning("Ya existe consumidor/editorial V2 activo") from None
            try:
                yield
            finally:
                file.seek(0)
                msvcrt.locking(file.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl
            try:
                fcntl.flock(file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                raise AlreadyRunning("Ya existe consumidor/editorial V2 activo") from None
            try:
                yield
            finally:
                fcntl.flock(file.fileno(), fcntl.LOCK_UN)
