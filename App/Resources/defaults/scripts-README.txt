mpv scripts
===========

Lua scripts that run inside mpv while a video plays: they can react to
what happens (a file opening, a pause, a track change), change any mpv
option or property, show messages and drawings over the video, and add
commands of their own.

Put *.lua files here, or a folder with a main.lua inside. They load every
time a video starts, like ~~/scripts on a computer. Folio → Settings →
mpv → Scripts can import files, install one from a link, and switch
scripts on and off. A script's options go in ../script-opts/<name>.conf
(Settings → mpv → script-opts).

Folio's mpv runs Lua 5.1 (LuaJIT). JavaScript (.js) scripts don't run.


What a script can do
- Act when something happens: mp.register_event("file-loaded", f),
  mp.observe_property("pause", "bool", f), "end-file", "seek"…
- Read and change any property or option: mp.get_property, mp.set_property
  ("sub-delay", "speed", "aid", "sid", "deband", "video-zoom"…).
- Run any mpv command: mp.command("seek 85"), mp.commandv("show-text", "Hi").
- Show text: mp.osd_message("Hello", 2); or draw with ASS:
  mp.create_osd_overlay("ass-events").
- Timers: mp.add_timeout(5, f), mp.add_periodic_timer(1, f).
- Commands of its own: mp.add_key_binding(nil, "action", f) makes
  "script-binding <script>/action", for input.conf or the player's
  Commands menu (Settings → mpv → Player commands).
- Messages from elsewhere: mp.register_script_message("toggle", f), sent
  with "script-message-to <script> toggle".
- Files: io.open and mp.utils.readdir work inside Folio's own folders (the
  mpv folder, Media). mp.utils.parse_json / format_json for JSON.
- Options: require "mp.options".read_options(o, "name") reads
  script-opts/name.conf.
- Logging: mp.msg.info("…") goes to mpv's log (Settings → Help &
  Diagnostics → Last log).


What doesn't work on iOS
- Starting other programs: mp.utils.subprocess, io.popen, os.execute
  (iOS has no curl, yt-dlp, ffmpeg or python to start).
- Network calls from Lua (no sockets). mpv itself still opens any link a
  script gives it with "loadfile".
- Mouse-only interfaces (osc, uosc) need a mouse or trackpad.
- Playlist scripts that load the folder's other files fight Folio's own
  queue (Up Next, Continue Watching): leave those off.


A first script: save as ~~/scripts/title.lua
------------------------------------------------------------------------
-- Shows the title for 3 seconds when a video starts.
mp.register_event("file-loaded", function()
    mp.osd_message(mp.get_property("media-title", ""), 3)
end)
------------------------------------------------------------------------

Another: a key that jumps 85 s ahead (past an opening).
------------------------------------------------------------------------
-- ~~/scripts/skip85.lua; then in input.conf:  Ctrl+o script-binding skip85/skip
mp.add_key_binding(nil, "skip", function()
    mp.commandv("seek", "85")
    mp.osd_message("+85 s", 1)
end)
------------------------------------------------------------------------

Lua scripting manual: https://mpv.io/manual/stable/#lua-scripting
