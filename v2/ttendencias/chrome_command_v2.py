#!/usr/bin/env python3
"""Argumentos comunes de Chrome V2; mismo CDP y perfil, sin alterar V1."""


def command(chrome, profile, port, *, headless=True, url="https://chatgpt.com/"):
    if not isinstance(port, int) or not 1024 <= port <= 65535 or port in (9223, 9234):
        raise ValueError("Puerto V2 no válido o reservado para V1")
    args = [str(chrome), "--user-data-dir=" + str(profile),
            "--remote-debugging-port=" + str(port),
            "--remote-debugging-address=127.0.0.1",
            "--disable-extensions", "--no-first-run", "--no-default-browser-check"]
    if headless:
        args.extend(["--headless=new", "--window-size=1280,900"])
    else:
        args.append("--new-window")
    args.append(url)
    return args
