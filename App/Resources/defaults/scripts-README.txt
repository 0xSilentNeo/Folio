mpv scripts
===========

Put Lua scripts (*.lua) or script folders (with a main.lua inside) here.
They load automatically every time playback starts, just like
~~/scripts on desktop mpv. Option files go in ../script-opts/<name>.conf.

You can also manage scripts in GlassPlayer → Settings → Scripts, which can
import files, install from a URL and switch scripts on and off.

What works on iOS
- mp.* API, observers, timers, OSD messages, overlays (mp.create_osd_overlay)
- mp.command_native for mpv commands, script-message, user-data
- key bindings (hardware keyboard), or run them from the player's
  "Commands" menu: script-binding <script>/<name>

What does not work on iOS
- mp.utils.subprocess / run (iOS cannot launch other programs: no curl,
  yt-dlp, ffmpeg, python)
- io.popen / os.execute
- JavaScript (.js) scripts
- mouse-only UIs (osc/uosc need a mouse or trackpad)
