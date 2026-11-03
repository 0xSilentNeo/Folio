mpv shaders
===========

GLSL shaders that change the picture while it's drawn: upscaling
(Anime4K, FSRCNNX, ravu), sharpening (adaptive-sharpen, CAS), chroma
upscaling (KrigBilateral), denoising, colour tweaks.

Put *.glsl or *.hook files here, then turn them on in Folio → Settings →
mpv → Shaders, or in the player's Shaders menu. They run in the order you
turn them on. Anime4K is built in: the player's Anime4K menu picks a mode,
and "Remember per show" keeps it for each show.

Where they run
- Metal renderer (the default): every kind, compute shaders
  (//!COMPUTE) too.
- OpenGL renderer (Settings → mpv → Renderer): fragment shaders only;
  compute shaders are skipped. Anime4K, FSRCNNX, KrigBilateral,
  SSimSuperRes and adaptive-sharpen are fragment shaders and work.
- Picture in Picture: with Metal, shaders pause while PiP is on (PiP
  draws with a simpler path) and come back when you return; with OpenGL
  they keep running in PiP.

Good to know
- Heavy shaders cost battery and can drop frames, most of all on 4K.
  The player's Media info (Settings menu) shows dropped frames.
- A shader that fails to compile is skipped; the reason is in mpv's log
  (Settings → Help & Diagnostics → Last log).
- From a link: Settings → mpv → Shaders → Install from URL (GitHub
  "blob" links are turned into the raw file).
