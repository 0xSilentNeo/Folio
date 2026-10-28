#!/usr/bin/env python3
"""Summarise a Time Profiler export (xctrace) of the app's main thread,
window by window, around the OPENCOST marks a UI test printed.

usage: profile_summary.py tp.xml toc.xml test.log [app.log]

- tp.xml:  xctrace export --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'
- toc.xml: xctrace export --toc (for the recording's start time)
- test.log: the xcodebuild log with "OPENCOST HH:mm:ss.SSS what" lines

For each step: how many ms the main thread was busy in the 1.2 s after it
was sent, and in what (inclusive time per function, our module's own
functions listed first). Then the same summed over every step of a kind.
"""
import re
import sys
import datetime as dt
import xml.etree.ElementTree as ET
from collections import defaultdict, Counter

tp_path, toc_path, test_log = sys.argv[1:4]
app_log = sys.argv[4] if len(sys.argv) > 4 else None

# --- recording start (wall clock) ---
toc = open(toc_path, errors="replace").read()
m = re.search(r"<start-date>([^<]+)</start-date>", toc)
start = dt.datetime.fromisoformat(m.group(1).replace("Z", "+00:00"))
print(f"trace start {start.isoformat()}")

def mark_time(hms):
    h, mi, s = hms.split(":")
    sec = float(s)
    t = start.replace(hour=int(h), minute=int(mi), second=int(sec), microsecond=int(round((sec % 1) * 1e6)) % 1000000)
    return (t - start).total_seconds()

marks = []
for line in open(test_log, errors="replace"):
    mm = re.search(r"OPENCOST (\d\d:\d\d:\d\d\.\d+) (.*)", line)
    if mm and not mm.group(2).startswith("layout"):
        marks.append((mark_time(mm.group(1)), mm.group(2).strip()))
# xcodebuild repeats test output: keep the first of each.
seen, uniq = set(), []
for t, w in marks:
    if (round(t, 3), w) in seen:
        continue
    seen.add((round(t, 3), w)); uniq.append((t, w))
marks = sorted(uniq)
print(f"{len(marks)} marks")

# --- samples ---
store = {}

def resolve(el):
    r = el.get("ref")
    return store.get(r) if r else None

samples = []  # (t_seconds, weight_ms, [frames leaf-first])
for ev, el in ET.iterparse(tp_path, events=("end",)):
    tag = el.tag
    if tag == "frame":
        if el.get("ref"):
            continue
        b = el.find("binary")
        bname = None
        if b is not None:
            bname = b.get("name") or (store.get(b.get("ref")) if b.get("ref") else None)
        name = el.get("name") or el.get("addr") or "?"
        store[el.get("id")] = (name, bname or "")
    elif tag == "binary":
        if el.get("id") and el.get("name"):
            store[el.get("id")] = el.get("name")
    elif tag in ("backtrace", "tagged-backtrace"):
        if el.get("ref"):
            continue
        frames = []
        for f in el.findall("frame"):
            fr = store.get(f.get("ref")) if f.get("ref") else store.get(f.get("id"))
            if fr:
                frames.append(fr)
        store[el.get("id")] = frames
    elif tag in ("thread", "sample-time", "weight", "process"):
        if el.get("id"):
            store[el.get("id")] = el.get("fmt") if tag in ("thread", "process") else (el.text or "0")
    elif tag == "row":
        def col(name):
            c = el.find(".//" + name)
            if c is None:
                return None
            return store.get(c.get("ref")) if c.get("ref") else store.get(c.get("id"))
        thread = col("thread") or ""
        # Recorded attached to the app, so every row is the app's.
        if "Main Thread" not in thread:
            el.clear(); continue
        t = int(col("sample-time") or 0) / 1e9
        w = int(col("weight") or 1000000) / 1e6
        bt = col("tagged-backtrace") or col("backtrace") or []
        samples.append((t, w, bt))
        el.clear()
print(f"{len(samples)} main-thread samples")

def ours(frame):
    return frame[1] in ("GlassPlayer", "GlassPlayer.debug.dylib")

def clean(name):
    name = re.sub(r"\(.*", "", name)                 # drop argument lists
    name = re.sub(r"<[^<>]*>", "", name)
    name = re.sub(r"<[^<>]*>", "", name)
    return name[:110]

def window(t0, t1):
    busy = 0.0
    incl_ours, incl_all, leaf = Counter(), Counter(), Counter()
    for t, w, bt in samples:
        if not (t0 <= t < t1):
            continue
        busy += w
        names = set()
        for fr in bt:
            n = clean(fr[0])
            if n in names:
                continue
            names.add(n)
            (incl_ours if ours(fr) else incl_all)[n] += w
        if bt:
            leaf[clean(bt[0][0]) + "  [" + bt[0][1] + "]"] += w
    return busy, incl_ours, incl_all, leaf

def kind(what):
    k = re.sub(r"^[A-Z]\d+ ", "", what)
    return re.sub(r"\b(MobLand|Classroom|Dragon Ball)\b", "<title>", k) if what[:1] == "C" else k

W = 1.2
per_kind = defaultdict(lambda: [0, 0.0, Counter(), Counter(), Counter()])
print("\n== each step: main thread busy in the 1.2 s after it was sent")
for i, (t, what) in enumerate(marks):
    nxt = marks[i + 1][0] if i + 1 < len(marks) else t + W
    t1 = min(t + W, nxt)
    busy, io, ia, lf = window(t, t1)
    print(f"{what:45s} {busy:6.0f} ms busy of {1000 * (t1 - t):5.0f} ms   top ours: " +
          ", ".join(f"{n} {v:.0f}" for n, v in io.most_common(3)))
    if what[:1] in "ABCD":
        k = (what[0], kind(what))
        a = per_kind[k]
        a[0] += 1; a[1] += busy; a[2].update(io); a[3].update(ia); a[4].update(lf)

for (letter, k), (n, busy, io, ia, lf) in sorted(per_kind.items()):
    print(f"\n== {letter}: {k} — {n} times, main thread busy {busy / n:.0f} ms each on average (1.2 s window)")
    print("   our functions (inclusive, ms per time):")
    for name, v in io.most_common(60):
        print(f"     {v / n:7.1f}  {name}")
    print("   system functions (inclusive, ms per time):")
    for name, v in ia.most_common(28):
        print(f"     {v / n:7.1f}  {name}")
    print("   where the time was spent (leaf, ms per time):")
    for name, v in lf.most_common(12):
        print(f"     {v / n:7.1f}  {name}")

# Long stretches with no main-thread samples between busy ones are fine;
# long busy stretches are hitches. List busy runs >= 40 ms.
print("\n== busy runs of 40 ms or more (main thread, contiguous samples)")
run_start = prev = None; acc = 0.0
runs = []
for t, w, bt in sorted(samples, key=lambda s: s[0]):
    if prev is not None and t - prev <= 0.0025:
        acc += w
    else:
        if run_start is not None and acc >= 40:
            runs.append((run_start, acc))
        run_start, acc = t, w
    prev = t
if run_start is not None and acc >= 40:
    runs.append((run_start, acc))
for rs, a in runs:
    label = ""
    for t, what in marks:
        if t <= rs:
            label = f"{what} +{1000 * (rs - t):.0f} ms"
    print(f"   {a:5.0f} ms  starting {label}")
