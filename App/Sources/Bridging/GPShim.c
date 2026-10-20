#include "GPShim.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

void *gp_gl_get_proc_address(void *ctx, const char *name) {
    (void)ctx;
    return dlsym(RTLD_DEFAULT, name);
}

const char *gp_render_api_opengl(void) { return MPV_RENDER_API_TYPE_OPENGL; }
const char *gp_render_api_sw(void) { return MPV_RENDER_API_TYPE_SW; }

int gp_set_chapters(mpv_handle *mpv, int count, const char *const *titles, const double *times) {
    if (count < 0) count = 0;
    mpv_node *items = count ? calloc((size_t)count, sizeof(mpv_node)) : NULL;
    mpv_node *values = count ? calloc((size_t)count * 2, sizeof(mpv_node)) : NULL;
    char **keys = count ? calloc((size_t)count * 2, sizeof(char *)) : NULL;
    mpv_node_list *maps = count ? calloc((size_t)count, sizeof(mpv_node_list)) : NULL;
    static char k_title[] = "title";
    static char k_time[] = "time";

    for (int i = 0; i < count; i++) {
        values[i * 2].format = MPV_FORMAT_STRING;
        values[i * 2].u.string = (char *)titles[i];
        values[i * 2 + 1].format = MPV_FORMAT_DOUBLE;
        values[i * 2 + 1].u.double_ = times[i];
        keys[i * 2] = k_title;
        keys[i * 2 + 1] = k_time;
        maps[i].num = 2;
        maps[i].values = &values[i * 2];
        maps[i].keys = &keys[i * 2];
        items[i].format = MPV_FORMAT_NODE_MAP;
        items[i].u.list = &maps[i];
    }

    mpv_node_list list = { .num = count, .values = items, .keys = NULL };
    mpv_node root = { .format = MPV_FORMAT_NODE_ARRAY };
    root.u.list = &list;
    int r = mpv_set_property(mpv, "chapter-list", MPV_FORMAT_NODE, &root);

    free(items); free(values); free(keys); free(maps);
    return r;
}
