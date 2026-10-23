/*
 * xtest_input.c — synthesized input and window placement on an X server,
 * the helper of GuiAssert's `linux-xtest` input backend
 * (src/gui_assert/backends/input/linux_xtest.nim).
 *
 * Pointer and key events are the XTest extension's fake device events
 * (https://www.x.org/releases/current/doc/xextproto/xtest.html), which the
 * server processes as if a real mouse and keyboard produced them. Desktop
 * coordinates (spec §5) are the root window's of the default screen.
 *
 * Keys are named by keysym. A keysym the server's keyboard mapping has on
 * the first level of some key code is pressed there; one on the second
 * level is pressed with Shift held; any other (a character outside the
 * layout) is put on a key code the mapping leaves empty for the time it is
 * needed (XChangeKeyboardMapping), and the code is emptied again once the
 * client has had the time to read it. X clients re-read the mapping lazily
 * after a MappingNotify, so a code is never re-mapped, and the mapping is
 * never restored, until `REMAP_SETTLE_MS` after its last use (no request
 * tells a client when another client has re-read the mapping, so this is
 * a wait, paid only by a script that borrows a code). Every exit of a
 * script, a failure or a cancellation included, releases what it holds and
 * empties the codes it borrowed (`run_cleanup`).
 *
 * Usage (the script on stdin, see input_script.h):
 *
 *   xtest_input run                 execute the script; "ok" or "error …"
 *   xtest_input probe               "ok xtest=0|1 width=W height=H"
 *   xtest_input focus <window>      raise <window> and give it the input
 *                                   focus; "ok"
 *   xtest_input bounds <window> X Y W H
 *                                   move and resize <window>; "ok"
 *
 * Exit status: see input_script.h.
 */
#define _GNU_SOURCE
#include <X11/XKBlib.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XTest.h>
#include <X11/keysym.h>
#include <unistd.h>

#include "input_script.h"

#define REMAP_SETTLE_MS 250

static Display *dpy;
static int min_kc, max_kc, per_kc;
static KeySym *mapping;

/* Run once by `fail` before the helper exits, while a script runs: it
   releases what the script holds and empties every borrowed key code, so
   no exit path leaves a key down or the keyboard mapping changed. */
static void (*on_fail)(void);

static void fail(int status, const char *fmt, const char *a) {
  void (*cleanup)(void) = on_fail;
  on_fail = NULL;
  if (cleanup) cleanup();
  printf("error ");
  printf(fmt, a);
  printf("\n");
  fflush(stdout);
  exit(status);
}

/* An X error is recorded, not acted on: Xlib forbids requests from inside
   the handler, and the cleanup `fail` runs makes some. `check_x` turns it
   into the helper's failure after the next XSync. */
static int x_failed;
static char x_failed_text[128];

static int x_error(Display *d, XErrorEvent *e) {
  if (!x_failed) XGetErrorText(d, e->error_code, x_failed_text, sizeof x_failed_text);
  x_failed = 1;
  return 0;
}

static void check_x(void) {
  if (x_failed) fail(EXIT_FAILED, "failed the X server refused a request: %s", x_failed_text);
}

static void open_display(void) {
  dpy = XOpenDisplay(NULL);
  if (!dpy) fail(EXIT_CONNECT, "connect cannot open the X display %s",
                 getenv("DISPLAY") ? getenv("DISPLAY") : "(DISPLAY unset)");
  XSetErrorHandler(x_error);
}

static int has_xtest(void) {
  int ev, er, maj, min;
  return XTestQueryExtension(dpy, &ev, &er, &maj, &min);
}

static void load_mapping(void) {
  XDisplayKeycodes(dpy, &min_kc, &max_kc);
  if (mapping) XFree(mapping);
  mapping = XGetKeyboardMapping(dpy, (KeyCode)min_kc, max_kc - min_kc + 1, &per_kc);
}

static KeySym sym_at(int kc, int col) {
  if (col >= per_kc) return NoSymbol;
  return mapping[(kc - min_kc) * per_kc + col];
}

/* A key code the mapping has no keysym on. */
static int empty_code(void) {
  for (int kc = max_kc; kc >= min_kc; kc--) {
    int empty = 1;
    for (int c = 0; c < per_kc && empty; c++) empty = sym_at(kc, c) == NoSymbol;
    if (empty) return kc;
  }
  return 0;
}

/* Where a keysym is pressed. */
struct place {
  uint32_t sym;
  int code;
  int shift;       /* hold Shift (second level) */
  int remapped;    /* a borrowed empty code */
  uint32_t last;   /* when it was last released (ms) */
};
static struct place *places;
static size_t n_places;

static struct place *place_of(uint32_t sym) {
  for (size_t i = 0; i < n_places; i++)
    if (places[i].sym == sym) return &places[i];
  return NULL;
}

/* Empty every borrowed key code again, once `REMAP_SETTLE_MS` passed since
   the last use of any (a code borrowed but never released counts as used
   now). Safe to call twice. */
static void restore_remapped(void) {
  uint32_t now = script_now_ms(), latest = 0;
  int any = 0;
  for (size_t i = 0; i < n_places; i++) {
    if (!places[i].remapped) continue;
    if (places[i].last == 0) places[i].last = now;
    if (places[i].last > latest) latest = places[i].last;
    any = 1;
  }
  if (!any) return;
  if (now - latest < REMAP_SETTLE_MS) {
    struct timespec ts = {0, (long)(REMAP_SETTLE_MS - (now - latest)) * 1000000L};
    nanosleep(&ts, NULL);
  }
  for (size_t i = 0; i < n_places; i++) {
    if (!places[i].remapped) continue;
    KeySym none[2] = {NoSymbol, NoSymbol};
    XChangeKeyboardMapping(dpy, places[i].code, 2, none, 1);
    places[i].remapped = 0;
  }
  XSync(dpy, False);
}

static void plan_keys(struct script *s) {
  load_mapping();
  places = calloc(s->len + 1, sizeof *places);
  if (!places) fail(EXIT_FAILED, "failed %s", "out of memory");
  for (size_t i = 0; i < s->len; i++) {
    if (s->ops[i].kind != OP_KEY || place_of(s->ops[i].keysym)) continue;
    struct place p = {.sym = s->ops[i].keysym};
    for (int kc = min_kc; kc <= max_kc && !p.code; kc++) {
      if (sym_at(kc, 0) == p.sym) p.code = kc;
    }
    for (int kc = min_kc; kc <= max_kc && !p.code; kc++) {
      if (sym_at(kc, 1) == p.sym) {
        p.code = kc;
        p.shift = 1;
      }
    }
    if (!p.code) {
      int kc = empty_code();
      if (!kc) fail(EXIT_FAILED, "failed %s",
                    "the keyboard mapping has no empty key code left for a character");
      KeySym both[2] = {(KeySym)p.sym, (KeySym)p.sym};
      p.code = kc;
      p.remapped = 1;
      /* Recorded before the request, so a failure from here on empties it
         again (`run_cleanup`). */
      places[n_places++] = p;
      XChangeKeyboardMapping(dpy, kc, 2, both, 1);
      XSync(dpy, False);
      check_x();
      load_mapping();
      continue;
    }
    places[n_places++] = p;
  }
  if (n_places > 0) {
    /* Give clients the time to re-read a changed mapping before its first
       use (see the module comment). */
    for (size_t i = 0; i < n_places; i++)
      if (places[i].remapped) {
        script_sleep(REMAP_SETTLE_MS);
        break;
      }
  }
}

static int held_buttons[8], n_held_buttons;
static int *held_codes;
static size_t n_held_codes;

static void press_code(int code, int down) {
  XTestFakeKeyEvent(dpy, (unsigned)code, down ? True : False, CurrentTime);
  if (down) {
    held_codes[n_held_codes++] = code;
  } else {
    for (size_t i = 0; i < n_held_codes; i++)
      if (held_codes[i] == code) {
        held_codes[i] = held_codes[--n_held_codes];
        break;
      }
  }
}

static void key(uint32_t sym, int down) {
  struct place *p = place_of(sym);
  int shift_code = XKeysymToKeycode(dpy, XK_Shift_L);
  int shift_held = 0;
  for (size_t i = 0; i < n_held_codes; i++)
    if (held_codes[i] == shift_code) shift_held = 1;
  if (down && p->shift && !shift_held) press_code(shift_code, 1);
  press_code(p->code, down);
  if (down && p->shift && !shift_held) press_code(shift_code, 0);
  if (!down) p->last = script_now_ms();
}

static unsigned x_button(uint32_t code) {
  return code == BTN_LEFT ? 1 : code == BTN_MIDDLE ? 2 : 3;
}

static void button(unsigned b, int down) {
  XTestFakeButtonEvent(dpy, b, down ? True : False, CurrentTime);
  int at = -1;
  for (int i = 0; i < n_held_buttons; i++)
    if (held_buttons[i] == (int)b) at = i;
  /* Each button is held once at most (there are three), so the list
     cannot overflow whatever the script presses. */
  if (down && at < 0) held_buttons[n_held_buttons++] = (int)b;
  if (!down && at >= 0) held_buttons[at] = held_buttons[--n_held_buttons];
}

/* Release every button and key still held, then empty the borrowed key
   codes: the end of every script, and `fail`'s cleanup once one runs. */
static void run_cleanup(void) {
  while (n_held_buttons > 0) button((unsigned)held_buttons[n_held_buttons - 1], 0);
  while (n_held_codes > 0) press_code(held_codes[n_held_codes - 1], 0);
  XSync(dpy, False);
  restore_remapped();
}

static int mode_run(void) {
  struct script s = {0};
  char why[160];
  if (script_read(stdin, &s, why, sizeof why) != 0) fail(EXIT_SCRIPT, "script %s", why);
  open_display();
  if (!has_xtest()) fail(EXIT_PROTOCOL, "protocol %s", "the X server has no XTEST extension");
  int w = DisplayWidth(dpy, DefaultScreen(dpy)), h = DisplayHeight(dpy, DefaultScreen(dpy));
  size_t downs = 0;
  for (size_t i = 0; i < s.len; i++) {
    struct op *o = &s.ops[i];
    if (o->kind == OP_MOVE && (o->x < 0 || o->y < 0 || o->x >= w || o->y >= h)) {
      char at[48];
      snprintf(at, sizeof at, "%d %d", o->x, o->y);
      fail(EXIT_OUTSIDE, "outside %s", at);
    }
    if (o->kind == OP_SCROLL && o->pixel)
      fail(EXIT_SCRIPT, "script %s", "the X core protocol scrolls by wheel notches only");
    if (o->kind == OP_CODE) fail(EXIT_SCRIPT, "script %s", "key codes are for uinput");
    if (o->kind == OP_KEY && o->down) downs++;
  }
  held_codes = calloc(2 * downs + 4, sizeof *held_codes);
  if (!held_codes) fail(EXIT_FAILED, "failed %s", "out of memory");
  on_fail = run_cleanup;
  plan_keys(&s);
  int screen = DefaultScreen(dpy);
  for (size_t i = 0; i < s.len && !script_cancelled; i++) {
    struct op *o = &s.ops[i];
    switch (o->kind) {
    case OP_MOVE:
      XTestFakeMotionEvent(dpy, screen, o->x, o->y, CurrentTime);
      break;
    case OP_BUTTON:
      button(x_button(o->button), o->down);
      break;
    case OP_SCROLL: {
      /* Buttons 4/5 (up/down) and 6/7 (left/right), one click per notch. */
      unsigned b = o->vertical ? (o->amount < 0 ? 4 : 5) : (o->amount < 0 ? 6 : 7);
      int n = o->amount < 0 ? -o->amount : o->amount;
      for (int k = 0; k < n && !script_cancelled; k++) {
        XTestFakeButtonEvent(dpy, b, True, CurrentTime);
        XTestFakeButtonEvent(dpy, b, False, CurrentTime);
        XSync(dpy, False);
        check_x();
      }
      break;
    }
    case OP_KEY:
      key(o->keysym, o->down);
      break;
    case OP_SLEEP:
      XSync(dpy, False);
      check_x();
      script_sleep(o->ms);
      break;
    case OP_CODE:
      break;
    }
    XSync(dpy, False);
    check_x();
  }
  int status = script_cancelled ? EXIT_CANCELLED : EXIT_OK;
  on_fail = NULL;
  run_cleanup();
  XCloseDisplay(dpy);
  printf(status == EXIT_OK ? "ok\n" : "error cancelled\n");
  return status;
}

static Window parse_window(const char *s) {
  char *end;
  unsigned long id = strtoul(s, &end, 10);
  if (*end != '\0' || id == 0) fail(EXIT_SCRIPT, "script window id %s is not a number", s);
  return (Window)id;
}

/* The window must exist: an X error on a bad id is turned into "not found". */
static int missing;
static int missing_handler(Display *d, XErrorEvent *e) {
  (void)d;
  if (e->error_code == BadWindow || e->error_code == BadDrawable) missing = 1;
  return 0;
}

static void require_window(Window w) {
  XWindowAttributes a;
  int (*old)(Display *, XErrorEvent *) = XSetErrorHandler(missing_handler);
  missing = 0;
  Status ok = XGetWindowAttributes(dpy, w, &a);
  XSync(dpy, False);
  XSetErrorHandler(old);
  if (missing || !ok) {
    char id[32];
    snprintf(id, sizeof id, "%lu", (unsigned long)w);
    fail(EXIT_OUTSIDE, "missing %s", id);
  }
}

static int mode_focus(const char *id) {
  open_display();
  Window w = parse_window(id);
  require_window(w);
  XRaiseWindow(dpy, w);
  XSetInputFocus(dpy, w, RevertToParent, CurrentTime);
  XSync(dpy, False);
  check_x();
  XCloseDisplay(dpy);
  printf("ok\n");
  return EXIT_OK;
}

static int mode_bounds(char **argv) {
  open_display();
  Window w = parse_window(argv[0]);
  long v[4];
  for (int i = 0; i < 4; i++) {
    char *end;
    v[i] = strtol(argv[1 + i], &end, 10);
    if (*end != '\0' || v[i] < (i < 2 ? -100000 : 1) || v[i] > 100000)
      fail(EXIT_SCRIPT, "script bounds value %s is out of range", argv[1 + i]);
  }
  require_window(w);
  XMoveResizeWindow(dpy, w, (int)v[0], (int)v[1], (unsigned)v[2], (unsigned)v[3]);
  XSync(dpy, False);
  check_x();
  /* Wait (bounded) until the server reports the new geometry, so the
     caller's re-read sees it. */
  for (int tries = 0; tries < 100; tries++) {
    Window root, child;
    int x, y;
    unsigned ww, hh, bw, depth;
    if (!XGetGeometry(dpy, w, &root, &x, &y, &ww, &hh, &bw, &depth)) break;
    int rx, ry;
    if (!XTranslateCoordinates(dpy, w, root, 0, 0, &rx, &ry, &child)) break;
    if (rx == v[0] && ry == v[1] && (long)ww == v[2] && (long)hh == v[3]) break;
    usleep(10000);
  }
  XCloseDisplay(dpy);
  printf("ok\n");
  return EXIT_OK;
}

static int mode_probe(void) {
  open_display();
  printf("ok xtest=%d width=%d height=%d\n", has_xtest() ? 1 : 0,
         DisplayWidth(dpy, DefaultScreen(dpy)), DisplayHeight(dpy, DefaultScreen(dpy)));
  XCloseDisplay(dpy);
  return EXIT_OK;
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IOLBF, 0);
  script_install_signals();
  if (argc == 2 && strcmp(argv[1], "run") == 0) return mode_run();
  if (argc == 2 && strcmp(argv[1], "probe") == 0) return mode_probe();
  if (argc == 3 && strcmp(argv[1], "focus") == 0) return mode_focus(argv[2]);
  if (argc == 7 && strcmp(argv[1], "bounds") == 0) return mode_bounds(argv + 2);
  fprintf(stderr, "usage: xtest_input run|probe|focus <window>|bounds <window> X Y W H\n");
  return EXIT_SCRIPT;
}
