#!/usr/bin/env python3
"""Writes a watch history like a phone that's been used for a while into an
app container: the seeded library's watched episodes, one in progress,
entries from an older install (another container path, as after a
reinstall), and streams. ~60 entries.

usage: seed_history.py <app data container> <Media dir>
"""
import json, os, sys, time, uuid

cont, media = sys.argv[1], sys.argv[2]
ref = time.time() - 978307200          # seconds since 2001 (JSONEncoder's default dates)
old_media = "/private/var/mobile/Containers/Data/Application/" + str(uuid.UUID(int=7)).upper() + "/Documents/Media"
entries = []

def add(url, title, pos, dur, ago, source={"local": {}}, key=None):
    item = {"url": url, "title": title, "headers": {}, "subtitles": [], "source": source}
    if key:
        item["historyKey"] = key
    entries.append({"item": item, "position": pos, "duration": dur, "updated": ref - ago})

mob = sorted(os.listdir(os.path.join(media, "Mobland s01")))
cls = sorted(os.listdir(os.path.join(media, "classroom of the elite.")))
ago = 3600
for i, f in enumerate(mob[:4]):
    p = os.path.join(media, "Mobland s01", f)
    add(p, f, 3400 if i < 3 else 1200, 3500, ago, key=p); ago += 5000
for i, f in enumerate(cls[:7]):
    p = os.path.join(media, "classroom of the elite.", f)
    add(p, f, 1400, 1420, ago, key=p); ago += 4000
# the same files from an older install (matched by file name)
for f in mob[:4] + cls[:5]:
    folder = "Mobland s01" if f.startswith("MobLand") else "classroom of the elite."
    p = f"{old_media}/{folder}/{f}"
    add(p, f, 600, 3000, ago, key=p); ago += 9000
# streams: two shows over WebDAV
server = {"webdav": {"serverID": str(uuid.UUID(int=42)).upper()}}
for e in range(1, 16):
    u = f"https://example.invalid/d/X{e:02d}/Daemons.of.the.Shadow.Realm.2026.S01E{e:02d}.1080p.CR.WEB.DL.DUAL.DDP2.0.H.264-AnoZu.mkv"
    add(u, f"Daemons of the Shadow Realm S01E{e:02d}", 1405 if e < 15 else 700, 1405, ago, source=server); ago += 7000
for e in range(1, 9):
    u = f"https://example.invalid/d/G{e:02d}/The.Gentlemen.S01E{e:02d}.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265.mkv"
    add(u, f"The Gentlemen S01E{e:02d}", 3000 if e < 6 else 900, 3200, ago, source=server); ago += 8000
for e in range(1, 9):
    u = f"https://example.invalid/d/A{e:02d}/Attack.on.Titan.S04E{e:02d}.1080p.BluRay.x264.mkv"
    add(u, f"Attack on Titan S04E{e:02d}", 1400, 1440, ago, source=server); ago += 6000

d = os.path.join(cont, "Library", "Application Support")
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, "history.json"), "w") as fh:
    json.dump(entries, fh)
print(f"history: {len(entries)} entries")
