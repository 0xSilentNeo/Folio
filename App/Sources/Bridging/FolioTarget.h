#ifndef FolioTarget_h
#define FolioTarget_h

#include <stdbool.h>

// The engine's hook for drawing into Folio's buffers (engine 3,
// engine/patches/0200-folio-external-target.patch): mpv's gpu-next output
// takes its target from these instead of a swapchain, set with
// --folio-target=<address of this struct>. Same layout as in the patch.
// All three run on mpv's video output thread.
struct folio_target {
    void *ctx;
    // Drawing may touch the GPU now; checked before any GPU work.
    bool (*allowed)(void *ctx);
    // An id<MTLTexture> of w x h to draw into (NULL: skip the frame).
    // *fmt: 0 bgra8, 1 rgba16f. *trc: 0 SDR, 1 PQ, 2 HLG. *token: back in present.
    void *(*acquire)(void *ctx, int w, int h, int *fmt, int *trc, void **token);
    // Drawn and finished on the GPU (ok), or not to be shown.
    void (*present)(void *ctx, void *token, double pts, bool ok);
};

#endif
