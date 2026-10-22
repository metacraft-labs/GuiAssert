/*
 * wm_probe.c — ask the compositor what it grants a toplevel window.
 *
 * GuiAssert's desktop-environment targets MEASURE their facts where they can
 * rather than declare them, so that a compositor upgrade that changes a
 * capability is noticed instead of contradicted. This client opens one
 * xdg_toplevel (never mapped: no buffer is attached), optionally asks for a
 * decoration mode, waits for the first configure and prints one JSON line:
 *
 *   {"xdg_wm_base_version":6,
 *    "capabilities_reported":true,
 *    "capabilities":["window_menu","maximize","fullscreen","minimize"],
 *    "decoration_manager":true,
 *    "decoration_requested":"client",
 *    "decoration_mode":"client"}
 *
 * `capabilities` is the `xdg_toplevel.wm_capabilities` event (xdg-shell
 * version 5+): https://wayland.app/protocols/xdg-shell#xdg_toplevel:event:wm_capabilities
 * When the compositor's xdg_wm_base is older, `capabilities_reported` is
 * false and the client may assume every capability (the protocol says so).
 * `decoration_mode` is the mode `zxdg_toplevel_decoration_v1.configure`
 * granted, "none" when the compositor has no decoration manager (GNOME):
 * https://wayland.app/protocols/xdg-decoration-unstable-v1
 *
 * Usage: wm_probe [client|server] [fixed]
 *   client|server  the decoration mode to request (none: the compositor
 *                  chooses);
 *   fixed          give the window equal minimum and maximum sizes, which
 *                  is how a dialog asks to float. Sway grants a client-side
 *                  request only to a floating window, so this is how its
 *                  rule is measured rather than assumed.
 *
 *   map            attach a buffer so the window is MAPPED, then ask to be
 *                  maximized and to be fullscreen, one after the other, and
 *                  report whether each request took effect (the toplevel's
 *                  configure states). A compositor may advertise maximize
 *                  and still ignore it for some windows (sway, for a
 *                  floating one), so the request itself is the measurement.
 *
 *   hold=MS        with `map`: keep the window mapped for MS milliseconds
 *                  instead of asking to maximize — a real window for a
 *                  test to find, click and capture. Its buffer is 0x80 grey
 *                  unless `rgb=` says otherwise.
 *
 *   rgb=RRGGBB     with `map`: the window's colour (hex), instead of grey.
 *
 *   image=PATH     with `map`: the window shows this binary PPM
 *                  (`ppm_image.h`) at its size, instead of one colour, so a test
 *                  can read known content in it (the live OCR suite draws
 *                  invented text). With `pulse` the alternate buffer is the
 *                  image with every blue channel XOR 1.
 *
 *   title=TEXT     the toplevel's title (`xdg_toplevel.set_title`).
 *
 *   pulse          with `hold`: repaint every 100 ms, alternating between
 *                  the colour and the colour with its blue channel XOR 1,
 *                  so the screen keeps changing (a screen cast that sends
 *                  frames only on damage then has frames to send) while
 *                  every pixel stays within one step of the colour.
 *
 * The JSON also carries "fixed", and with `map` "maximize_honoured" and
 * "fullscreen_honoured".
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <poll.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

#include "ppm_image.h"
#include "xdg-decoration-unstable-v1-client-protocol.h"
#include "xdg-shell-client-protocol.h"

static struct wl_compositor *compositor;
static struct xdg_wm_base *wm_base;
static uint32_t wm_base_version;
static struct zxdg_decoration_manager_v1 *decoration_manager;
static struct wl_shm *shm;

static int configured;
static int state_maximized, state_fullscreen;
static int capabilities_reported;
static char capabilities[128] = "";
static const char *decoration_mode = "none";

static void global_add(void *data, struct wl_registry *registry, uint32_t name,
                       const char *interface, uint32_t version) {
  (void)data;
  if (strcmp(interface, wl_compositor_interface.name) == 0) {
    compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 1);
  } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
    wm_base_version = version < 6 ? version : 6;
    wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface,
                               wm_base_version);
  } else if (strcmp(interface, wl_shm_interface.name) == 0) {
    shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
  } else if (strcmp(interface, zxdg_decoration_manager_v1_interface.name) == 0) {
    decoration_manager = wl_registry_bind(
        registry, name, &zxdg_decoration_manager_v1_interface, 1);
  }
}

static void global_remove(void *d, struct wl_registry *r, uint32_t n) {
  (void)d;
  (void)r;
  (void)n;
}

static const struct wl_registry_listener registry_listener = {global_add,
                                                              global_remove};

static void wm_base_ping(void *d, struct xdg_wm_base *base, uint32_t serial) {
  (void)d;
  xdg_wm_base_pong(base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = {wm_base_ping};

static void surface_configure(void *d, struct xdg_surface *s, uint32_t serial) {
  (void)d;
  xdg_surface_ack_configure(s, serial);
  configured = 1;
}

static const struct xdg_surface_listener surface_listener = {surface_configure};

static void toplevel_configure(void *d, struct xdg_toplevel *t, int32_t w,
                               int32_t h, struct wl_array *states) {
  (void)d;
  (void)t;
  (void)w;
  (void)h;
  state_maximized = state_fullscreen = 0;
  uint32_t *st;
  wl_array_for_each(st, states) {
    if (*st == XDG_TOPLEVEL_STATE_MAXIMIZED)
      state_maximized = 1;
    if (*st == XDG_TOPLEVEL_STATE_FULLSCREEN)
      state_fullscreen = 1;
  }
}

static void toplevel_close(void *d, struct xdg_toplevel *t) {
  (void)d;
  (void)t;
}

static void toplevel_bounds(void *d, struct xdg_toplevel *t, int32_t w,
                            int32_t h) {
  (void)d;
  (void)t;
  (void)w;
  (void)h;
}

static void toplevel_wm_capabilities(void *d, struct xdg_toplevel *t,
                                     struct wl_array *caps) {
  (void)d;
  (void)t;
  capabilities_reported = 1;
  capabilities[0] = '\0';
  uint32_t *cap;
  wl_array_for_each(cap, caps) {
    const char *name = NULL;
    switch (*cap) {
    case XDG_TOPLEVEL_WM_CAPABILITIES_WINDOW_MENU:
      name = "window_menu";
      break;
    case XDG_TOPLEVEL_WM_CAPABILITIES_MAXIMIZE:
      name = "maximize";
      break;
    case XDG_TOPLEVEL_WM_CAPABILITIES_FULLSCREEN:
      name = "fullscreen";
      break;
    case XDG_TOPLEVEL_WM_CAPABILITIES_MINIMIZE:
      name = "minimize";
      break;
    }
    if (!name)
      continue;
    size_t used = strlen(capabilities);
    snprintf(capabilities + used, sizeof capabilities - used, "%s\"%s\"",
             used ? "," : "", name);
  }
}

static const struct xdg_toplevel_listener toplevel_listener = {
    toplevel_configure, toplevel_close, toplevel_bounds,
    toplevel_wm_capabilities};

static void decoration_configure(void *d,
                                 struct zxdg_toplevel_decoration_v1 *dec,
                                 uint32_t mode) {
  (void)d;
  (void)dec;
  decoration_mode =
      mode == ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE ? "server" : "client";
}

static const struct zxdg_toplevel_decoration_v1_listener decoration_listener = {
    decoration_configure};

int main(int argc, char **argv) {
  const char *requested = "";
  int fixed = 0, map = 0, pulse = 0;
  long hold_ms = 0;
  unsigned long rgb = 0x808080;
  const char *title = NULL, *image = NULL;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "client") == 0 || strcmp(argv[i], "server") == 0)
      requested = argv[i];
    else if (strcmp(argv[i], "fixed") == 0)
      fixed = 1;
    else if (strcmp(argv[i], "map") == 0)
      map = 1;
    else if (strncmp(argv[i], "hold=", 5) == 0)
      hold_ms = atol(argv[i] + 5);
    else if (strncmp(argv[i], "rgb=", 4) == 0)
      rgb = strtoul(argv[i] + 4, NULL, 16) & 0xffffff;
    else if (strncmp(argv[i], "title=", 6) == 0)
      title = argv[i] + 6;
    else if (strncmp(argv[i], "image=", 6) == 0)
      image = argv[i] + 6;
    else if (strcmp(argv[i], "pulse") == 0)
      pulse = 1;
    else {
      fprintf(stderr, "usage: %s [client|server] [fixed] [title=TEXT] "
                      "[map [rgb=RRGGBB | image=PPM] [hold=MS [pulse]]]\n", argv[0]);
      return 2;
    }
  }
  struct wl_display *display = wl_display_connect(NULL);
  if (!display) {
    fprintf(stderr, "wm_probe: cannot connect to the compositor\n");
    return 1;
  }
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  wl_display_roundtrip(display);
  if (!compositor || !wm_base) {
    fprintf(stderr, "wm_probe: the compositor offers no xdg_wm_base\n");
    return 1;
  }
  xdg_wm_base_add_listener(wm_base, &wm_base_listener, NULL);

  struct wl_surface *surface = wl_compositor_create_surface(compositor);
  struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm_base, surface);
  xdg_surface_add_listener(xs, &surface_listener, NULL);
  struct xdg_toplevel *top = xdg_surface_get_toplevel(xs);
  xdg_toplevel_add_listener(top, &toplevel_listener, NULL);
  xdg_toplevel_set_app_id(top, "gui-assert-wm-probe");
  if (title)
    xdg_toplevel_set_title(top, title);
  if (fixed) {
    xdg_toplevel_set_min_size(top, 320, 200);
    xdg_toplevel_set_max_size(top, 320, 200);
  }

  struct zxdg_toplevel_decoration_v1 *dec = NULL;
  if (decoration_manager) {
    dec = zxdg_decoration_manager_v1_get_toplevel_decoration(decoration_manager,
                                                             top);
    zxdg_toplevel_decoration_v1_add_listener(dec, &decoration_listener, NULL);
    if (strcmp(requested, "client") == 0)
      zxdg_toplevel_decoration_v1_set_mode(
          dec, ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
    else if (strcmp(requested, "server") == 0)
      zxdg_toplevel_decoration_v1_set_mode(
          dec, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
  }
  wl_surface_commit(surface);
  for (int i = 0; !configured && i < 50; i++) {
    if (wl_display_roundtrip(display) < 0)
      break;
  }
  if (!configured) {
    fprintf(stderr, "wm_probe: the compositor never configured the window\n");
    return 1;
  }
  int maximize_honoured = -1, fullscreen_honoured = -1;
  if (map) {
    /* An XRGB8888 buffer from an anonymous shared-memory file: 320x200, or
     * the size of `image=`. */
    if (!shm) {
      fprintf(stderr, "wm_probe: the compositor offers no wl_shm\n");
      return 1;
    }
    int w = 320, h = 200;
    unsigned char *rgb24 = NULL;
    if (image) {
      const char *why = "";
      rgb24 = read_ppm(image, &w, &h, &why);
      if (!rgb24) {
        fprintf(stderr, "wm_probe: %s: %s\n", image, why);
        return 1;
      }
    }
    /* Two buffers in one pool: the content, and the pulse content. */
    int stride = w * 4, size = stride * h * 2;
    int fd = memfd_create("wm_probe", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, size) < 0) {
      fprintf(stderr, "wm_probe: cannot allocate a buffer\n");
      free(rgb24);
      return 1;
    }
    uint32_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (px == MAP_FAILED) {
      fprintf(stderr, "wm_probe: cannot map the buffer\n");
      free(rgb24);
      return 1;
    }
    for (int i = 0; i < w * h; i++) {
      uint32_t c = rgb24 ? ((uint32_t)rgb24[i * 3] << 16) |
                               ((uint32_t)rgb24[i * 3 + 1] << 8) | rgb24[i * 3 + 2]
                         : (uint32_t)rgb;
      px[i] = 0xff000000u | c;
      px[w * h + i] = 0xff000000u | (c ^ 1u);
    }
    free(rgb24);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer *buf =
        wl_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_XRGB8888);
    struct wl_buffer *pulse_buf = wl_shm_pool_create_buffer(
        pool, stride * h, w, h, stride, WL_SHM_FORMAT_XRGB8888);
    wl_surface_attach(surface, buf, 0, 0);
    wl_surface_commit(surface);
    for (int i = 0; i < 5; i++)
      wl_display_roundtrip(display);
    if (hold_ms > 0) {
      /* Serve the compositor (pings, configures) until the deadline. */
      struct timespec start, now;
      clock_gettime(CLOCK_MONOTONIC, &start);
      long next_pulse = 100;
      int pulsed = 0;
      for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        long elapsed = (now.tv_sec - start.tv_sec) * 1000 +
                       (now.tv_nsec - start.tv_nsec) / 1000000;
        if (elapsed >= hold_ms)
          break;
        if (pulse && elapsed >= next_pulse) {
          pulsed = !pulsed;
          wl_surface_attach(surface, pulsed ? pulse_buf : buf, 0, 0);
          wl_surface_damage(surface, 0, 0, w, h);
          wl_surface_commit(surface);
          next_pulse = elapsed + 100;
        }
        long wait = hold_ms - elapsed;
        if (pulse && next_pulse - elapsed < wait)
          wait = next_pulse - elapsed;
        wl_display_flush(display);
        struct pollfd pfd = {wl_display_get_fd(display), POLLIN, 0};
        if (poll(&pfd, 1, (int)wait) > 0 &&
            wl_display_dispatch(display) < 0)
          break;
      }
    } else {
    xdg_toplevel_set_maximized(top);
    wl_surface_commit(surface);
    for (int i = 0; i < 10; i++)
      wl_display_roundtrip(display);
    maximize_honoured = state_maximized;
    xdg_toplevel_unset_maximized(top);
    xdg_toplevel_set_fullscreen(top, NULL);
    wl_surface_commit(surface);
    for (int i = 0; i < 10; i++)
      wl_display_roundtrip(display);
    fullscreen_honoured = state_fullscreen;
    }
    wl_buffer_destroy(buf);
    wl_buffer_destroy(pulse_buf);
    wl_shm_pool_destroy(pool);
    munmap(px, size);
    close(fd);
  }
  printf("{\"xdg_wm_base_version\":%u,\"capabilities_reported\":%s,"
         "\"capabilities\":[%s],\"decoration_manager\":%s,"
         "\"decoration_requested\":\"%s\",\"decoration_mode\":\"%s\","
         "\"fixed\":%s,\"maximize_honoured\":%s,\"fullscreen_honoured\":%s}\n",
         wm_base_version, capabilities_reported ? "true" : "false",
         capabilities, decoration_manager ? "true" : "false",
         requested[0] ? requested : "none", decoration_mode,
         fixed ? "true" : "false",
         maximize_honoured < 0 ? "null" : (maximize_honoured ? "true" : "false"),
         fullscreen_honoured < 0 ? "null" : (fullscreen_honoured ? "true" : "false"));
  if (dec)
    zxdg_toplevel_decoration_v1_destroy(dec);
  xdg_toplevel_destroy(top);
  xdg_surface_destroy(xs);
  wl_surface_destroy(surface);
  wl_display_roundtrip(display);
  wl_display_disconnect(display);
  return 0;
}
