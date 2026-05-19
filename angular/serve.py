#!/usr/bin/env python3
# Minimaler statischer SPA-Server: unbekannte Pfade -> index.html
# (damit /callback Deep-Links der Angular-Routen funktionieren).
import http.server, os, socketserver

ROOT = "/site"

class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=ROOT, **k)
    def do_GET(self):
        p = self.path.split("?", 1)[0]
        fp = os.path.join(ROOT, p.lstrip("/"))
        # SPA-Fallback NUR für Routen (kein Dateiname mit Endung). Fehlende
        # Assets/config.json liefern ehrliches 404 statt index.html.
        if p != "/" and not os.path.isfile(fp) and "." not in os.path.basename(p):
            self.path = "/index.html"
        return super().do_GET()

with socketserver.TCPServer(("", 8080), H) as s:
    s.allow_reuse_address = True
    s.serve_forever()
