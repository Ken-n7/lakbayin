"""The booth's QR sheet: a page with the codes a visitor scans, opened in the
browser on this laptop. Run from the repo root:

  server/.venv/bin/python -m server.booth
  server/.venv/bin/python -m server.booth --wifi "VenueWifi" "its password"
  server/.venv/bin/python -m server.booth --link https://.../Lakbayin.apk

Codes: the install page (this server's public address, or --link for a
download hosted elsewhere), and with --wifi the network to join first.
"""
import argparse
import html
import io
import webbrowser
from pathlib import Path

import qrcode
import qrcode.image.svg

ROOT = Path(__file__).resolve().parents[1]
PUBLIC = "https://server.lakbayin.space"


def code(text):
    out = io.BytesIO()
    qrcode.make(text, image_factory=qrcode.image.svg.SvgPathImage, box_size=12).save(out)
    return out.getvalue().decode().split("?>", 1)[-1]


def wifi(ssid, password):
    esc = lambda v: "".join(chr(92) + c if c in chr(92) + ';,:"' else c for c in v)
    return f"WIFI:T:WPA;S:{esc(ssid)};P:{esc(password)};;"


def sheet(cards):
    body = "".join(f"<section><h2>{html.escape(t)}</h2>{code(v)}<p>{html.escape(n)}</p></section>" for t, v, n in cards)
    return ("<!doctype html><meta charset=utf-8><title>Lakbayin booth</title><style>"
            "body{font:20px sans-serif;text-align:center;margin:1em}main{display:flex;flex-wrap:wrap;justify-content:center;gap:2em}"
            "section{width:20em}svg{width:100%;height:auto}h1{margin:.2em}p{color:#444;word-break:break-all}</style>"
            f"<h1>Lakbayin</h1><p>Android only</p><main>{body}</main>")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--wifi", nargs=2, metavar=("NAME", "PASSWORD"), help="a network to join first")
    p.add_argument("--link", help="a download hosted elsewhere (a GitHub release), instead of this server's page")
    p.add_argument("--no-open", action="store_true")
    a = p.parse_args()
    cards = []
    if a.wifi:
        cards.append((f"1. Join the WiFi “{a.wifi[0]}”", wifi(*a.wifi), "Scan with the camera, then tap Join."))
    page = a.link or PUBLIC + "/get"
    cards.append((f"{len(cards) + 1}. Install the game", page, page))
    out = ROOT / "build/booth/index.html"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(sheet(cards))
    assert wifi('a;b', 'p:1') == 'WIFI:T:WPA;S:a' + chr(92) + ';b;P:p' + chr(92) + ':1;;'
    print(f"Install page: {page}\nQR sheet:     {out}")
    if not (ROOT / "build/Lakbayin-release.apk").exists():
        print("No build/Lakbayin-release.apk yet: game/tools/device.sh release")
    if not a.no_open:
        webbrowser.open(out.as_uri())
