#!/usr/bin/env python3
"""Frame-difference report for a UI lab recording: prints, per 1/30 s frame,
how much the screen changed, and flags transitions as 'snap' (one big jump)
or 'animated' (a run of medium changes). Usage: lab-analyze.py lab.mp4 [fps]"""
import subprocess, sys, numpy as np
path = sys.argv[1]; fps = int(sys.argv[2]) if len(sys.argv) > 2 else 30
W, H = 160, 346  # portrait sim frame downscaled
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-vf", f"fps={fps},scale={W}:{H}", "-f", "rawvideo", "-pix_fmt", "gray", "-"],
                     capture_output=True).stdout
frames = np.frombuffer(raw, np.uint8).reshape(-1, H, W).astype(np.int16)
d = np.abs(np.diff(frames, axis=0)).mean(axis=(1, 2))   # mean abs diff per frame
events = []
i = 0
while i < len(d):
    if d[i] > 1.5:
        j = i
        while j + 1 < len(d) and d[j + 1] > 0.6: j += 1
        run = d[i:j + 1]
        kind = "animated" if len(run) >= 4 else "SNAP"
        events.append((i / fps, len(run), run.max(), kind))
        i = j + 1
    else:
        i += 1
for t, n, mx, kind in events:
    print(f"t={t:6.2f}s  frames={n:3d}  peak={mx:5.1f}  {kind}")
