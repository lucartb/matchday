#!/usr/bin/env python3
"""Erzeugt cal/<team>.ics und cal/highlights.ics aus data.js (Kalender-Abos).
Aufruf im Repo-Ordner: python3 tools/build_ics.py"""
import json, re, os, hashlib, unicodedata
from datetime import datetime, timedelta, date
from zoneinfo import ZoneInfo

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BER = ZoneInfo("Europe/Berlin")
DUR = {"Wintersport": 90, "American Football": 200, "Leichtathletik": 180, "Schwimmen": 150,
       "Beachvolleyball": 60, "Radsport": 90, "Fußball": 115, "Darts": 210, "Rugby": 110,
       "Handball": 100, "Motorsport": 120}

def slug(x):
    x = x.lower().replace("ä", "ae").replace("ö", "oe").replace("ü", "ue").replace("ß", "ss")
    x = "".join(c for c in unicodedata.normalize("NFD", x) if unicodedata.category(c) != "Mn")
    return re.sub(r"[^a-z0-9]+", "-", x).strip("-")

def esc(t):
    return str(t).replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\n", "\\n")

def fold(line):
    b = line.encode("utf-8"); out = []
    while len(b) > 74:
        cut = 74
        while (b[cut] & 0xC0) == 0x80: cut -= 1
        out.append(b[:cut].decode()); b = b[cut:]
    out.append(b.decode())
    return "\r\n ".join(out)

def vevent(e, stamp):
    uid = hashlib.sha1((e["d"] + (e.get("t") or "") + e["ti"]).encode()).hexdigest()[:20] + "@matchday"
    tv = " · ".join(e.get("tv") or []) or "Sender offen"
    desc = f'{e.get("c","")} · {tv}' + (f' · {e["n"]}' if e.get("n") else "")
    L = ["BEGIN:VEVENT", f"UID:{uid}", f"DTSTAMP:{stamp}"]
    if e.get("t"):
        st = datetime.fromisoformat(f'{e["d"]}T{e["t"]}').replace(tzinfo=BER).astimezone(ZoneInfo("UTC"))
        en = st + timedelta(minutes=DUR.get(e["s"], 120))
        L += [f"DTSTART:{st:%Y%m%dT%H%M%SZ}", f"DTEND:{en:%Y%m%dT%H%M%SZ}"]
    else:
        d = date.fromisoformat(e["d"])
        L += [f"DTSTART;VALUE=DATE:{d:%Y%m%d}", f"DTEND;VALUE=DATE:{d + timedelta(days=1):%Y%m%d}"]
    L += [f"SUMMARY:{esc(e['ti'])}", f"DESCRIPTION:{esc(desc)}", f"LOCATION:{esc(tv)}", "END:VEVENT"]
    return L

def write(name, title, evs, stamp):
    L = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Matchday//DE", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
         f"X-WR-CALNAME:{esc('Matchday – ' + title)}", "X-WR-TIMEZONE:Europe/Berlin",
         "REFRESH-INTERVAL;VALUE=DURATION:PT6H", "X-PUBLISHED-TTL:PT6H"]
    for e in evs: L += vevent(e, stamp)
    L.append("END:VCALENDAR")
    with open(os.path.join(ROOT, "cal", name + ".ics"), "w", encoding="utf-8", newline="") as f:
        f.write("\r\n".join(fold(x) for x in L) + "\r\n")

def main():
    s = open(os.path.join(ROOT, "data.js"), encoding="utf-8").read()
    data = json.loads(s[s.index("{"):s.rindex("}") + 1])
    html = open(os.path.join(ROOT, "index.html"), encoding="utf-8").read()
    tb = html[html.index("const TEAMS={"):html.index("};", html.index("const TEAMS={"))]
    names = set(re.findall(r'"([^"]+)":\{', tb))
    ab = html[html.index("const ALIAS={"):html.index("};", html.index("const ALIAS={"))]
    alias = dict(re.findall(r'"([^"]+)":"([^"]+)"', ab))
    for e in data["events"]:
        p = e["ti"].split(" – ")
        if len(p) == 2 and "," not in e["ti"] and "(" not in e["ti"]:
            names.update(x.strip() for x in p)
    os.makedirs(os.path.join(ROOT, "cal"), exist_ok=True)
    stamp = datetime.now(ZoneInfo("UTC")).strftime("%Y%m%dT%H%M%SZ")
    evs = sorted(data["events"], key=lambda e: (e["d"], e.get("t") or "99"))
    for nm in sorted(names):
        keys = [nm] + [k for k, v in alias.items() if v == nm]
        write(slug(nm), nm, [e for e in evs if any(k in e["ti"] for k in keys)], stamp)
    write("highlights", "Highlights", [e for e in evs if e.get("hl")], stamp)
    print(f"{len(names) + 1} Kalender geschrieben")

if __name__ == "__main__":
    main()
