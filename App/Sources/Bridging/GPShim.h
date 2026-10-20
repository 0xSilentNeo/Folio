#ifndef GPShim_h
#define GPShim_h

#include <mpv/client.h>
#include <mpv/render.h>

/// Resolves OpenGL ES entry points for mpv (they live in the process image).
void *gp_gl_get_proc_address(void *ctx, const char *name);

/// The render-API type strings are #defines; Swift imports them awkwardly,
/// so expose them as plain C strings.
const char *gp_render_api_opengl(void);
const char *gp_render_api_sw(void);

/// Builds an mpv_node list of chapter maps ({title, time}) and sets
/// "chapter-list". Returns the mpv error code.
int gp_set_chapters(mpv_handle *mpv, int count, const char *const *titles, const double *times);

#endif
