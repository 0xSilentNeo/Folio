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

static mpv_node *gp_map_get(mpv_node *map, const char *key) {
    if (!map || map->format != MPV_FORMAT_NODE_MAP) return NULL;
    mpv_node_list *l = map->u.list;
    for (int i = 0; i < l->num; i++)
        if (strcmp(l->keys[i], key) == 0) return &l->values[i];
    return NULL;
}

unsigned char *gp_screenshot_bgra(mpv_handle *mpv, int max_w, int *out_w, int *out_h) {
    const char *args[] = {"screenshot-raw", "video", NULL};
    mpv_node res;
    if (mpv_command_ret(mpv, args, &res) < 0) return NULL;
    unsigned char *out = NULL;
    mpv_node *nw = gp_map_get(&res, "w"), *nh = gp_map_get(&res, "h");
    mpv_node *ns = gp_map_get(&res, "stride"), *nd = gp_map_get(&res, "data");
    if (nw && nh && ns && nd && nd->format == MPV_FORMAT_BYTE_ARRAY &&
        nw->format == MPV_FORMAT_INT64 && nh->format == MPV_FORMAT_INT64 && ns->format == MPV_FORMAT_INT64) {
        int w = (int)nw->u.int64, h = (int)nh->u.int64;
        long stride = (long)ns->u.int64;
        const unsigned char *src = nd->u.ba->data;
        if (w > 0 && h > 0 && max_w > 0) {
            int dw = w > max_w ? max_w : w;
            int dh = (int)((long)h * dw / w);
            if (dh < 2) dh = 2;
            dw &= ~1; dh &= ~1;
            out = malloc((size_t)dw * dh * 4);
            if (out) {
                for (int y = 0; y < dh; y++) {
                    const unsigned char *row = src + (long)(y * h / dh) * stride;
                    unsigned char *dst = out + (long)y * dw * 4;
                    for (int x = 0; x < dw; x++) {
                        const unsigned char *px = row + (long)(x * w / dw) * 4;
                        dst[x * 4 + 0] = px[0];
                        dst[x * 4 + 1] = px[1];
                        dst[x * 4 + 2] = px[2];
                        dst[x * 4 + 3] = 255;
                    }
                }
                *out_w = dw; *out_h = dh;
            }
        }
    }
    mpv_free_node_contents(&res);
    return out;
}
