#ifndef Folio_Bridging_Header_h
#define Folio_Bridging_Header_h

#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>
#include "GPShim.h"
// The Metal renderer drawing into Folio's buffers (engine 3, 1.28.0).
#include "FolioTarget.h"
// SMB browsing (1.20.3): the engine's libsmbclient, the one mpv's FFmpeg plays smb:// with.
#include <samba-4.0/libsmbclient.h>

#endif
