/*
 * wayland_input.c — synthesized pointer and keyboard input for a Wayland
 * compositor, the helper of GuiAssert's `linux-wlr-virtual` input backend
 * (src/gui_assert/backends/input/linux_wlr_virtual.nim), and the keymap
 * reader of its `linux-mutter` backend.
 *
 * Input goes through two DEVICES the helper creates, so every event takes
 * the compositor's own routing to the surface under the cursor or with the
 * keyboard focus, as a mouse's and a keyboard's would:
 *
 *   * a pointer from wlroots' virtual-pointer protocol
 *     (https://wayland.app/protocols/wlr-virtual-pointer-unstable-v1);
 *   * a keyboard from the virtual-keyboard protocol
 *     (https://wayland.app/protocols/virtual-keyboard-unstable-v1), with a
 *     keymap the helper writes for the script it runs: every keysym the
 *     script presses gets a key of its own (a letter a–z its upper case on
 *     the shift level), and Shift_L, Control_L, Alt_L and Super_L are the
 *     Shift, Control, Mod1 and Mod4 modifiers. A Unicode character is typed
 *     as its own keysym, so any text types whatever layout the session has.
 *     A virtual keyboard's key events do not update its modifier state by
 *     themselves (the compositor takes it from the `modifiers` request), so
 *     the helper sends the modifiers it holds after each modifier key.
 *
 * Desktop coordinates (spec §5) are the compositor's logical layout, which
 * the helper reads from xdg-output (each output's logical position and size,
 * https://wayland.app/protocols/xdg-output-unstable-v1); an absolute motion
 * is sent against the extent of the layout's bounding box, which wlroots maps
 * onto that box when the device is mapped to no single output. A point on no
 * output is refused before anything is sent.
 *
 * A seat that had no keyboard (or pointer) before this helper's device
 * gains the capability with it, and each client binds its `wl_keyboard`
 * only once it has read the seat's new `capabilities` event: a key sent
 * before that reaches no `wl_keyboard` of the client and is lost (the
 * compositor sends the focused client an `enter` when it binds, but not
 * the keys it missed). The helper waits for what it can observe (a
 * roundtrip, then the seat reporting the capability to the helper's own
 * connection), but no protocol tells a client when ANOTHER client has
 * bound its keyboard, so when the helper's device brought the capability
 * it then waits `SETTLE_MS` before the first event. Measured on a headless
 * sway 1.11 with GTK 3 / GTK 4 clients: with no wait, about one key verb in
 * five lost its key (the key-table and typing tests red); with 400 ms, none
 * in every run. A seat that already had the capability (any session with
 * a real keyboard and mouse) pays nothing.
 *
 * Usage (the script on stdin, see input_script.h; nothing on the command
 * line but the mode):
 *
 *   wayland_input run       execute the script; prints "ok" or "error …"
 *   wayland_input probe     prints "ok pointer=0|1 keyboard=0|1 outputs=N"
 *   wayland_input keysyms   for each keysym on stdin (hex, one per line),
 *                           prints whether the seat keyboard's CURRENT
 *                           keymap has a key for it in its active layout
 *                           ("1" / "0"), after an "ok" line
 *
 * Exit status: see input_script.h.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <poll.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include "input_script.h"
#include "virtual-keyboard-unstable-v1-client-protocol.h"
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"
#include "xdg-output-unstable-v1-client-protocol.h"

#define SETTLE_MS 400
#define MAX_OUTPUTS 16

static struct zwlr_virtual_pointer_manager_v1 *pointer_manager;
static struct zwp_virtual_keyboard_manager_v1 *keyboard_manager;
static struct zxdg_output_manager_v1 *output_manager;
static struct wl_seat *seat;
static uint32_t seat_caps;
static int seat_caps_known;

struct output {
  struct wl_output *wl;
  struct zxdg_output_v1 *xdg;
  int x, y, w, h;
  int have;
};
static struct output outputs[MAX_OUTPUTS];
static int n_outputs;

/* The seat keyboard's keymap (`keysyms` mode). */
static struct wl_keyboard *seat_keyboard;
static struct xkb_context *xkb;
static struct xkb_keymap *seat_keymap;
static uint32_t seat_group;

static void fail(int status, const char *fmt, const char *a) {
  printf("error ");
  printf(fmt, a);
  printf("\n");
  fflush(stdout);
  exit(status);
}

static void seat_capabilities(void *data, struct wl_seat *s, uint32_t caps) {
  (void)data;
  (void)s;
  seat_caps = caps;
  seat_caps_known = 1;
}
static void seat_name(void *data, struct wl_seat *s, const char *name) {
  (void)data;
  (void)s;
  (void)name;
}
static const struct wl_seat_listener seat_listener = {seat_capabilities, seat_name};

static void xo_position(void *data, struct zxdg_output_v1 *o, int32_t x, int32_t y) {
  (void)o;
  struct output *out = data;
  out->x = x;
  out->y = y;
}
static void xo_size(void *data, struct zxdg_output_v1 *o, int32_t w, int32_t h) {
  (void)o;
  struct output *out = data;
  out->w = w;
  out->h = h;
  out->have = 1;
}
static void xo_done(void *data, struct zxdg_output_v1 *o) {
  (void)data;
  (void)o;
}
static void xo_name(void *data, struct zxdg_output_v1 *o, const char *n) {
  (void)data;
  (void)o;
  (void)n;
}
static void xo_description(void *data, struct zxdg_output_v1 *o, const char *d) {
  (void)data;
  (void)o;
  (void)d;
}
static const struct zxdg_output_v1_listener xo_listener = {xo_position, xo_size, xo_done,
                                                           xo_name, xo_description};

static void global_add(void *data, struct wl_registry *registry, uint32_t name,
                       const char *interface, uint32_t version) {
  (void)data;
  if (strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name) == 0) {
    pointer_manager =
        wl_registry_bind(registry, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
  } else if (strcmp(interface, zwp_virtual_keyboard_manager_v1_interface.name) == 0) {
    keyboard_manager =
        wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
  } else if (strcmp(interface, zxdg_output_manager_v1_interface.name) == 0) {
    output_manager = wl_registry_bind(registry, name, &zxdg_output_manager_v1_interface,
                                      version < 2 ? version : 2);
  } else if (strcmp(interface, wl_seat_interface.name) == 0 && !seat) {
    seat = wl_registry_bind(registry, name, &wl_seat_interface, version < 5 ? version : 5);
    wl_seat_add_listener(seat, &seat_listener, NULL);
  } else if (strcmp(interface, wl_output_interface.name) == 0 && n_outputs < MAX_OUTPUTS) {
    outputs[n_outputs++].wl = wl_registry_bind(registry, name, &wl_output_interface, 1);
  }
}
static void global_remove(void *data, struct wl_registry *r, uint32_t name) {
  (void)data;
  (void)r;
  (void)name;
}
static const struct wl_registry_listener registry_listener = {global_add, global_remove};

static struct wl_display *connect_display(void) {
  struct wl_display *d = wl_display_connect(NULL);
  if (!d) fail(EXIT_CONNECT, "connect cannot connect to the Wayland display %s",
               getenv("WAYLAND_DISPLAY") ? getenv("WAYLAND_DISPLAY") : "(WAYLAND_DISPLAY unset)");
  struct wl_registry *registry = wl_display_get_registry(d);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  if (wl_display_roundtrip(d) < 0 || wl_display_roundtrip(d) < 0)
    fail(EXIT_FAILED, "failed %s", "the compositor connection broke");
  if (output_manager) {
    for (int i = 0; i < n_outputs; i++) {
      outputs[i].xdg = zxdg_output_manager_v1_get_xdg_output(output_manager, outputs[i].wl);
      zxdg_output_v1_add_listener(outputs[i].xdg, &xo_listener, &outputs[i]);
    }
    if (wl_display_roundtrip(d) < 0)
      fail(EXIT_FAILED, "failed %s", "the compositor connection broke");
  }
  return d;
}

static void roundtrip(struct wl_display *d) {
  if (wl_display_roundtrip(d) < 0) fail(EXIT_FAILED, "failed %s", "the compositor connection broke");
}

/* ------------------------------------------------------------------------ */
/* keysyms: the seat keyboard's keymap                                       */
/* ------------------------------------------------------------------------ */

static void kb_keymap(void *data, struct wl_keyboard *k, uint32_t format, int32_t fd,
                      uint32_t size) {
  (void)data;
  (void)k;
  if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
    close(fd);
    return;
  }
  char *map = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
  close(fd);
  if (map == MAP_FAILED) return;
  if (seat_keymap) xkb_keymap_unref(seat_keymap);
  seat_keymap = xkb_keymap_new_from_buffer(xkb, map, strnlen(map, size),
                                           XKB_KEYMAP_FORMAT_TEXT_V1,
                                           XKB_KEYMAP_COMPILE_NO_FLAGS);
  munmap(map, size);
}
static void kb_enter(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *f,
                     struct wl_array *keys) {
  (void)d; (void)k; (void)s; (void)f; (void)keys;
}
static void kb_leave(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *f) {
  (void)d; (void)k; (void)s; (void)f;
}
static void kb_key(void *d, struct wl_keyboard *k, uint32_t s, uint32_t t, uint32_t key,
                   uint32_t st) {
  (void)d; (void)k; (void)s; (void)t; (void)key; (void)st;
}
static void kb_modifiers(void *d, struct wl_keyboard *k, uint32_t s, uint32_t dep,
                         uint32_t lat, uint32_t lock, uint32_t group) {
  (void)d; (void)k; (void)s; (void)dep; (void)lat; (void)lock;
  seat_group = group;
}
static void kb_repeat(void *d, struct wl_keyboard *k, int32_t rate, int32_t delay) {
  (void)d; (void)k; (void)rate; (void)delay;
}
static const struct wl_keyboard_listener kb_listener = {kb_keymap, kb_enter, kb_leave, kb_key,
                                                        kb_modifiers, kb_repeat};

/* Whether `keymap` has a key producing `sym` at any level of `layout`. */
static int keymap_has(struct xkb_keymap *keymap, xkb_layout_index_t layout, xkb_keysym_t sym) {
  xkb_keycode_t min = xkb_keymap_min_keycode(keymap), max = xkb_keymap_max_keycode(keymap);
  for (xkb_keycode_t kc = min; kc <= max; kc++) {
    xkb_layout_index_t layouts = xkb_keymap_num_layouts_for_key(keymap, kc);
    if (layouts == 0) continue;
    xkb_layout_index_t l = layout < layouts ? layout : 0;
    xkb_level_index_t levels = xkb_keymap_num_levels_for_key(keymap, kc, l);
    for (xkb_level_index_t lv = 0; lv < levels; lv++) {
      const xkb_keysym_t *syms;
      int n = xkb_keymap_key_get_syms_by_level(keymap, kc, l, lv, &syms);
      for (int i = 0; i < n; i++)
        if (syms[i] == sym) return 1;
    }
  }
  return 0;
}

static int mode_keysyms(void) {
  xkb = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  if (!xkb) fail(EXIT_FAILED, "failed %s", "xkbcommon has no context");
  struct wl_display *d = connect_display();
  if (!seat) fail(EXIT_PROTOCOL, "protocol %s", "the compositor offers no seat");
  roundtrip(d);
  if (!(seat_caps & WL_SEAT_CAPABILITY_KEYBOARD))
    fail(EXIT_PROTOCOL, "protocol %s", "the seat has no keyboard");
  seat_keyboard = wl_seat_get_keyboard(seat);
  wl_keyboard_add_listener(seat_keyboard, &kb_listener, NULL);
  roundtrip(d);
  roundtrip(d);
  if (!seat_keymap) fail(EXIT_PROTOCOL, "protocol %s", "the seat keyboard sent no XKB keymap");
  printf("ok\n");
  char line[64];
  while (fgets(line, sizeof line, stdin)) {
    char *end;
    unsigned long sym = strtoul(line, &end, 16);
    if (end == line) continue;
    printf("%d\n", keymap_has(seat_keymap, seat_group, (xkb_keysym_t)sym));
  }
  fflush(stdout);
  return EXIT_OK;
}

/* ------------------------------------------------------------------------ */
/* run                                                                       */
/* ------------------------------------------------------------------------ */

enum { MOD_SHIFT = 1, MOD_CONTROL = 4, MOD_MOD1 = 8, MOD_MOD4 = 64 };
static const uint32_t modifier_syms[4] = {XKB_KEY_Shift_L, XKB_KEY_Control_L, XKB_KEY_Alt_L,
                                          XKB_KEY_Super_L};
static const uint32_t modifier_bits[4] = {MOD_SHIFT, MOD_CONTROL, MOD_MOD1, MOD_MOD4};

/* The keymap's keys: keysym i of `syms` is on key code 9 + i (evdev 1 + i). */
static uint32_t *syms;
static size_t n_syms;

static uint32_t sym_index(uint32_t sym) {
  for (size_t i = 0; i < n_syms; i++)
    if (syms[i] == sym) return (uint32_t)i;
  return UINT32_MAX;
}

static void add_sym(uint32_t sym) {
  if (sym_index(sym) != UINT32_MAX) return;
  uint32_t *n = realloc(syms, (n_syms + 1) * sizeof *n);
  if (!n) fail(EXIT_FAILED, "failed %s", "out of memory");
  syms = n;
  syms[n_syms++] = sym;
}

/* The XKB keymap text of `syms` (xkbcommon's keymap format,
   https://xkbcommon.org/doc/current/keymap-text-format-v1.html). */
static char *keymap_text(void) {
  size_t cap = 4096 + n_syms * 160, len = 0;
  char *t = malloc(cap);
  if (!t) fail(EXIT_FAILED, "failed %s", "out of memory");
  /* Once the text outgrows `cap`, EMIT only counts (snprintf to nothing),
     never writes past the buffer; the check below then refuses it. */
#define EMIT(...)                                                              \
  do {                                                                         \
    int n_ = snprintf(len < cap ? t + len : NULL, len < cap ? cap - len : 0,   \
                      __VA_ARGS__);                                            \
    if (n_ > 0) len += (size_t)n_;                                             \
  } while (0)
  EMIT("xkb_keymap {\nxkb_keycodes \"guiassert\" {\n  minimum = 8;\n  maximum = %zu;\n",
       n_syms + 9 < 255 ? (size_t)255 : n_syms + 9);
  for (size_t i = 0; i < n_syms; i++) EMIT("  <K%zu> = %zu;\n", i, i + 9);
  EMIT("};\nxkb_types \"guiassert\" { include \"complete\" };\n"
       "xkb_compatibility \"guiassert\" { include \"complete\" };\n"
       "xkb_symbols \"guiassert\" {\n");
  for (size_t i = 0; i < n_syms; i++) {
    char name[64], upper[64];
    xkb_keysym_get_name(syms[i], name, sizeof name);
    if (syms[i] >= XKB_KEY_a && syms[i] <= XKB_KEY_z) {
      xkb_keysym_get_name(syms[i] - XKB_KEY_a + XKB_KEY_A, upper, sizeof upper);
      EMIT("  key <K%zu> { [ %s, %s ] };\n", i, name, upper);
    } else {
      EMIT("  key <K%zu> { [ %s ] };\n", i, name);
    }
  }
  static const char *mod_names[4] = {"Shift", "Control", "Mod1", "Mod4"};
  for (int m = 0; m < 4; m++)
    EMIT("  modifier_map %s { <K%u> };\n", mod_names[m], sym_index(modifier_syms[m]));
  EMIT("};\n};\n");
#undef EMIT
  if (len >= cap) fail(EXIT_FAILED, "failed %s", "the keymap does not fit");
  return t;
}

static int keymap_fd(const char *text, size_t *size) {
  *size = strlen(text) + 1;
  int fd = memfd_create("guiassert-keymap", MFD_CLOEXEC);
  if (fd < 0) fail(EXIT_FAILED, "failed memfd_create: %s", strerror(errno));
  size_t off = 0;
  while (off < *size) {
    ssize_t w = write(fd, text + off, *size - off);
    if (w <= 0) fail(EXIT_FAILED, "failed writing the keymap: %s", strerror(errno));
    off += (size_t)w;
  }
  return fd;
}

static int on_output(int x, int y) {
  for (int i = 0; i < n_outputs; i++) {
    struct output *o = &outputs[i];
    if (o->have && x >= o->x && y >= o->y && x < o->x + o->w && y < o->y + o->h) return 1;
  }
  return 0;
}

static struct zwlr_virtual_pointer_v1 *ptr;
static struct zwp_virtual_keyboard_v1 *kbd;
static uint32_t held_buttons[3];
static int n_held_buttons;
static uint32_t *held_keys;
static size_t n_held_keys;
static uint32_t mods;

static void send_mods(void) { zwp_virtual_keyboard_v1_modifiers(kbd, mods, 0, 0, 0); }

static int modifier_of(uint32_t sym) {
  for (int m = 0; m < 4; m++)
    if (modifier_syms[m] == sym) return m;
  return -1;
}

static void key(uint32_t sym, int down) {
  uint32_t idx = sym_index(sym);
  zwp_virtual_keyboard_v1_key(kbd, script_now_ms(), idx + 1,
                              down ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);
  if (down) {
    held_keys[n_held_keys++] = sym;
  } else {
    for (size_t i = 0; i < n_held_keys; i++)
      if (held_keys[i] == sym) {
        held_keys[i] = held_keys[--n_held_keys];
        break;
      }
  }
  int m = modifier_of(sym);
  if (m >= 0) {
    if (down) mods |= modifier_bits[m];
    else mods &= ~modifier_bits[m];
    send_mods();
  }
}

static void button(uint32_t code, int down) {
  zwlr_virtual_pointer_v1_button(ptr, script_now_ms(), code,
                                 down ? WL_POINTER_BUTTON_STATE_PRESSED
                                      : WL_POINTER_BUTTON_STATE_RELEASED);
  zwlr_virtual_pointer_v1_frame(ptr);
  int at = -1;
  for (int i = 0; i < n_held_buttons; i++)
    if (held_buttons[i] == code) at = i;
  /* Each of the three buttons is held once at most, so the list cannot
     overflow whatever the script presses. */
  if (down && at < 0) held_buttons[n_held_buttons++] = code;
  if (!down && at >= 0) held_buttons[at] = held_buttons[--n_held_buttons];
}

/* Release everything still held (a cancelled script, or one that pressed
   without releasing): nothing stays down once the helper is gone. */
static void release_all(void) {
  while (n_held_buttons > 0) button(held_buttons[n_held_buttons - 1], 0);
  while (kbd && n_held_keys > 0) key(held_keys[n_held_keys - 1], 0);
}

static int wait_caps(struct wl_display *d, uint32_t want) {
  for (int i = 0; i < 50; i++) {
    roundtrip(d);
    if ((seat_caps & want) == want) return 1;
    script_sleep(20);
  }
  return 0;
}

static int mode_run(void) {
  struct script s = {0};
  char why[160];
  if (script_read(stdin, &s, why, sizeof why) != 0) fail(EXIT_SCRIPT, "script %s", why);
  int need_ptr = 0, need_kbd = 0, held = 0;
  for (size_t i = 0; i < s.len; i++) {
    struct op *o = &s.ops[i];
    if (o->kind == OP_MOVE || o->kind == OP_BUTTON || o->kind == OP_SCROLL) need_ptr = 1;
    if (o->kind == OP_KEY) {
      need_kbd = 1;
      add_sym(o->keysym);
      if (o->down) held++;
    }
    if (o->kind == OP_CODE) fail(EXIT_SCRIPT, "script %s", "key codes are for uinput");
  }
  struct wl_display *d = connect_display();
  if (need_ptr && !pointer_manager)
    fail(EXIT_PROTOCOL, "protocol %s",
         "the compositor offers no zwlr_virtual_pointer_manager_v1 (virtual pointers)");
  if (need_kbd && !keyboard_manager)
    fail(EXIT_PROTOCOL, "protocol %s",
         "the compositor offers no zwp_virtual_keyboard_manager_v1 (virtual keyboards)");
  if (!seat) fail(EXIT_PROTOCOL, "protocol %s", "the compositor offers no seat");
  int min_x = 0, min_y = 0, max_x = 0, max_y = 0, any = 0;
  for (int i = 0; i < n_outputs; i++) {
    struct output *o = &outputs[i];
    if (!o->have) continue;
    if (!any || o->x < min_x) min_x = o->x;
    if (!any || o->y < min_y) min_y = o->y;
    if (!any || o->x + o->w > max_x) max_x = o->x + o->w;
    if (!any || o->y + o->h > max_y) max_y = o->y + o->h;
    any = 1;
  }
  if (need_ptr && !output_manager)
    fail(EXIT_PROTOCOL, "protocol %s",
         "the compositor offers no zxdg_output_manager_v1 (output layout)");
  if (need_ptr && !any) fail(EXIT_PROTOCOL, "protocol %s", "the compositor reports no output");
  for (size_t i = 0; i < s.len; i++) {
    if (s.ops[i].kind == OP_MOVE && !on_output(s.ops[i].x, s.ops[i].y)) {
      char at[48];
      snprintf(at, sizeof at, "%d %d", s.ops[i].x, s.ops[i].y);
      fail(EXIT_OUTSIDE, "outside %s", at);
    }
  }
  uint32_t had = seat_caps;
  uint32_t want = 0;
  if (need_ptr) {
    ptr = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(pointer_manager, seat);
    want |= WL_SEAT_CAPABILITY_POINTER;
  }
  if (need_kbd) {
    for (int m = 0; m < 4; m++) add_sym(modifier_syms[m]);
    held_keys = calloc(n_syms + (size_t)held + 4, sizeof *held_keys);
    if (!held_keys) fail(EXIT_FAILED, "failed %s", "out of memory");
    kbd = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(keyboard_manager, seat);
    char *text = keymap_text();
    size_t size;
    int fd = keymap_fd(text, &size);
    zwp_virtual_keyboard_v1_keymap(kbd, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t)size);
    close(fd);
    free(text);
    want |= WL_SEAT_CAPABILITY_KEYBOARD;
    send_mods();
  }
  roundtrip(d);
  if (want && !wait_caps(d, want))
    fail(EXIT_FAILED, "failed %s", "the seat never gained the helper's devices");
  if ((want & ~had) != 0 && script_sleep(SETTLE_MS)) {
    printf("error cancelled\n");
    return EXIT_CANCELLED;
  }
  int status = EXIT_OK;
  for (size_t i = 0; i < s.len && !script_cancelled; i++) {
    struct op *o = &s.ops[i];
    switch (o->kind) {
    case OP_MOVE:
      zwlr_virtual_pointer_v1_motion_absolute(ptr, script_now_ms(), (uint32_t)(o->x - min_x),
                                              (uint32_t)(o->y - min_y),
                                              (uint32_t)(max_x - min_x),
                                              (uint32_t)(max_y - min_y));
      zwlr_virtual_pointer_v1_frame(ptr);
      break;
    case OP_BUTTON:
      button(o->button, o->down);
      break;
    case OP_SCROLL: {
      uint32_t axis = o->vertical ? WL_POINTER_AXIS_VERTICAL_SCROLL
                                  : WL_POINTER_AXIS_HORIZONTAL_SCROLL;
      uint32_t t = script_now_ms();
      if (o->pixel) {
        zwlr_virtual_pointer_v1_axis_source(ptr, WL_POINTER_AXIS_SOURCE_FINGER);
        zwlr_virtual_pointer_v1_axis(ptr, t, axis, wl_fixed_from_int(o->amount));
        zwlr_virtual_pointer_v1_frame(ptr);
        zwlr_virtual_pointer_v1_axis_source(ptr, WL_POINTER_AXIS_SOURCE_FINGER);
        zwlr_virtual_pointer_v1_axis_stop(ptr, t, axis);
        zwlr_virtual_pointer_v1_frame(ptr);
      } else {
        /* One discrete notch per frame, 15 units each (wl_pointer's
           conventional wheel step), as a wheel turned notch by notch. */
        int step = o->amount < 0 ? -1 : 1;
        for (int n = 0; n != o->amount && !script_cancelled; n += step) {
          zwlr_virtual_pointer_v1_axis_source(ptr, WL_POINTER_AXIS_SOURCE_WHEEL);
          zwlr_virtual_pointer_v1_axis_discrete(ptr, script_now_ms(), axis,
                                                wl_fixed_from_int(15 * step), step);
          zwlr_virtual_pointer_v1_frame(ptr);
          roundtrip(d);
        }
      }
      break;
    }
    case OP_KEY:
      key(o->keysym, o->down);
      break;
    case OP_SLEEP:
      roundtrip(d);
      script_sleep(o->ms);
      break;
    case OP_CODE:
      break;
    }
    if (wl_display_flush(d) < 0 && errno != EAGAIN)
      fail(EXIT_FAILED, "failed %s", "the compositor connection broke");
  }
  if (script_cancelled) status = EXIT_CANCELLED;
  release_all();
  roundtrip(d);
  if (kbd) zwp_virtual_keyboard_v1_destroy(kbd);
  if (ptr) zwlr_virtual_pointer_v1_destroy(ptr);
  roundtrip(d);
  wl_display_disconnect(d);
  printf(status == EXIT_OK ? "ok\n" : "error cancelled\n");
  return status;
}

static int mode_probe(void) {
  struct wl_display *d = connect_display();
  roundtrip(d);
  int n = 0;
  for (int i = 0; i < n_outputs; i++) n += outputs[i].have;
  printf("ok pointer=%d keyboard=%d outputs=%d\n", pointer_manager != NULL && output_manager != NULL,
         keyboard_manager != NULL, n);
  wl_display_disconnect(d);
  return EXIT_OK;
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IOLBF, 0);
  script_install_signals();
  if (argc == 2 && strcmp(argv[1], "run") == 0) return mode_run();
  if (argc == 2 && strcmp(argv[1], "probe") == 0) return mode_probe();
  if (argc == 2 && strcmp(argv[1], "keysyms") == 0) return mode_keysyms();
  fprintf(stderr, "usage: wayland_input run|probe|keysyms (input on stdin)\n");
  return EXIT_SCRIPT;
}
