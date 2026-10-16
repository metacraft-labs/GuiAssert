/*
 * virtual_pointer.c — a real pointer device for a wlroots compositor.
 *
 * A headless sway has no input devices, so its seat advertises no pointer
 * capability and no client ever binds `wl_pointer`. This client creates a
 * pointer DEVICE through wlroots' `zwlr_virtual_pointer_manager_v1`, so the
 * seat gains the capability and every event below reaches the surface under
 * the cursor through the compositor's own routing, as a mouse's would.
 * Protocol: https://wayland.app/protocols/wlr-virtual-pointer-unstable-v1
 *
 * Commands, one per line on stdin. After each one the compositor has
 * processed it (a `wl_display_roundtrip`), and the helper answers `ok` (or
 * `error <reason>`) on stdout, so a driver can proceed in lockstep:
 *
 *   abs X Y            move to output position (X, Y), in pixels
 *   down [BUTTON]      press BUTTON: left (default), right or middle
 *   up [BUTTON]        release it
 *   wheel N            turn the wheel N discrete notches (positive: down)
 *   sleep MS           wait MS milliseconds
 *   quit               exit (end of input does too)
 *
 * It prints `ready` once the device exists.
 *
 * Usage: virtual_pointer <extent-width> <extent-height> — the extent the
 * absolute positions are measured against (the output layout's size).
 *
 * Derived from isonim-gpui's tools/virtual_pointer.c, which it replaces.
 */
#define _POSIX_C_SOURCE 200809L
#include <linux/input-event-codes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>

#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

static struct zwlr_virtual_pointer_manager_v1 *manager;
static struct wl_seat *seat;

static void global_add(void *data, struct wl_registry *registry, uint32_t name,
                       const char *interface, uint32_t version) {
  (void)data;
  (void)version;
  if (strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name) == 0) {
    manager = wl_registry_bind(registry, name,
                               &zwlr_virtual_pointer_manager_v1_interface, 1);
  } else if (strcmp(interface, wl_seat_interface.name) == 0 && !seat) {
    seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
  }
}

static void global_remove(void *data, struct wl_registry *registry,
                          uint32_t name) {
  (void)data;
  (void)registry;
  (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = global_add, .global_remove = global_remove};

static uint32_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

/* Linux input button code for a name; 0 for an unknown one. */
static uint32_t button_code(const char *rest) {
  char name[32] = "left";
  if (sscanf(rest, "%31s", name) < 1)
    strcpy(name, "left");
  if (strcmp(name, "left") == 0)
    return BTN_LEFT;
  if (strcmp(name, "right") == 0)
    return BTN_RIGHT;
  if (strcmp(name, "middle") == 0)
    return BTN_MIDDLE;
  return 0;
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s <extent-width> <extent-height>\n", argv[0]);
    return 2;
  }
  uint32_t extent_w = (uint32_t)atoi(argv[1]);
  uint32_t extent_h = (uint32_t)atoi(argv[2]);
  setvbuf(stdout, NULL, _IOLBF, 0);
  struct wl_display *display = wl_display_connect(NULL);
  if (!display) {
    printf("error cannot connect to the compositor\n");
    return 1;
  }
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  wl_display_roundtrip(display);
  if (!manager) {
    printf("error the compositor offers no zwlr_virtual_pointer_manager_v1\n");
    return 1;
  }
  struct zwlr_virtual_pointer_v1 *ptr =
      zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, seat);
  if (wl_display_roundtrip(display) < 0) {
    printf("error the compositor refused the virtual pointer\n");
    return 1;
  }
  printf("ready\n");

  char line[256];
  while (fgets(line, sizeof line, stdin)) {
    double a = 0, b = 0;
    const char *err = NULL;
    if (sscanf(line, "abs %lf %lf", &a, &b) == 2) {
      if (a < 0 || b < 0 || a > extent_w || b > extent_h) {
        err = "position outside the extent";
      } else {
        zwlr_virtual_pointer_v1_motion_absolute(ptr, now_ms(), (uint32_t)a,
                                                (uint32_t)b, extent_w,
                                                extent_h);
        zwlr_virtual_pointer_v1_frame(ptr);
      }
    } else if (strncmp(line, "down", 4) == 0 || strncmp(line, "up", 2) == 0) {
      int down = line[0] == 'd';
      uint32_t code = button_code(line + (down ? 4 : 2));
      if (code == 0) {
        err = "unknown button";
      } else {
        zwlr_virtual_pointer_v1_button(
            ptr, now_ms(), code,
            down ? WL_POINTER_BUTTON_STATE_PRESSED
                 : WL_POINTER_BUTTON_STATE_RELEASED);
        zwlr_virtual_pointer_v1_frame(ptr);
      }
    } else if (sscanf(line, "wheel %lf", &a) == 1) {
      int notches = (int)a;
      zwlr_virtual_pointer_v1_axis_source(ptr, WL_POINTER_AXIS_SOURCE_WHEEL);
      zwlr_virtual_pointer_v1_axis_discrete(
          ptr, now_ms(), WL_POINTER_AXIS_VERTICAL_SCROLL,
          wl_fixed_from_double(15.0 * notches), notches);
      zwlr_virtual_pointer_v1_frame(ptr);
    } else if (sscanf(line, "sleep %lf", &a) == 1) {
      struct timespec ts = {(time_t)(a / 1000),
                            (long)((long)a % 1000) * 1000000L};
      nanosleep(&ts, NULL);
    } else if (strncmp(line, "quit", 4) == 0) {
      break;
    } else {
      err = "unknown command";
    }
    if (wl_display_roundtrip(display) < 0) {
      printf("error the compositor connection failed\n");
      return 1;
    }
    if (err)
      printf("error %s\n", err);
    else
      printf("ok\n");
  }
  zwlr_virtual_pointer_v1_destroy(ptr);
  wl_display_roundtrip(display);
  wl_display_disconnect(display);
  return 0;
}
