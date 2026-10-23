/*
 * input_script.h — the input script GuiAssert's Linux input helpers
 * (`wayland_input`, `xtest_input`, `uinput_input`) execute.
 *
 * The `linux-wlr-virtual`, `linux-xtest` and `linux-uinput` input backends
 * (src/gui_assert/backends/input/) plan every verb as a list of primitive
 * events and write it to the helper's STANDARD INPUT, one per line, never on
 * its command line: a typed text is visible to other local users in argv,
 * and a script carries one key event per typed character (spec §7.5,
 * "Secrets off argv"). The helper reads the whole script before it sends
 * anything, so a malformed script or a point outside the desktop is refused
 * with nothing delivered.
 *
 *   move X Y              move the pointer to desktop point (X, Y)
 *   button B down|up      press or release B: left, right or middle
 *   scroll v|h N line     turn the wheel N notches (positive: down / right)
 *   scroll v|h N pixel    scroll N pixels smoothly (positive: down / right)
 *   key K down|up         press or release the key of X keysym K (hex, 0x…)
 *   code C down|up        press or release Linux input key code C (uinput)
 *   sleep MS              wait MS milliseconds
 *
 * Shared by the helpers; header-only so each stays one translation unit.
 */
#ifndef GUIASSERT_INPUT_SCRIPT_H
#define GUIASSERT_INPUT_SCRIPT_H

#include <errno.h>
#include <linux/input-event-codes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum op_kind { OP_MOVE, OP_BUTTON, OP_SCROLL, OP_KEY, OP_CODE, OP_SLEEP };

struct op {
  enum op_kind kind;
  int x, y;          /* OP_MOVE */
  uint32_t button;   /* OP_BUTTON: BTN_LEFT, BTN_RIGHT, BTN_MIDDLE */
  int down;          /* OP_BUTTON, OP_KEY, OP_CODE */
  int vertical;      /* OP_SCROLL */
  int amount;        /* OP_SCROLL */
  int pixel;         /* OP_SCROLL: 1 pixel, 0 line */
  uint32_t keysym;   /* OP_KEY */
  uint32_t code;     /* OP_CODE */
  int ms;            /* OP_SLEEP */
};

struct script {
  struct op *ops;
  size_t len, cap;
};

/* The longest script line (every command is short). */
#define SCRIPT_LINE_MAX 128
/* The most events one script holds: a 1 MiB text is at most 2^20 code
   points, each a press and a release (plus a sleep with --interval-ms). */
#define SCRIPT_OPS_MAX (4u * 1024u * 1024u)

static inline int script_push(struct script *s, struct op o) {
  if (s->len == s->cap) {
    size_t cap = s->cap ? s->cap * 2 : 256;
    if (cap > SCRIPT_OPS_MAX) cap = SCRIPT_OPS_MAX;
    if (cap <= s->len) return -1;
    struct op *n = realloc(s->ops, cap * sizeof *n);
    if (!n) return -1;
    s->ops = n;
    s->cap = cap;
  }
  s->ops[s->len++] = o;
  return 0;
}

static inline int parse_state(const char *w, int *down) {
  if (strcmp(w, "down") == 0) *down = 1;
  else if (strcmp(w, "up") == 0) *down = 0;
  else return -1;
  return 0;
}

/* Read the whole script from `in`. Returns 0, or -1 with `why` naming the
   first problem (and its line number). */
static inline int script_read(FILE *in, struct script *s, char *why, size_t whylen) {
  char line[SCRIPT_LINE_MAX + 2];
  unsigned long n = 0;
  while (fgets(line, sizeof line, in)) {
    n++;
    size_t l = strlen(line);
    if (l > 0 && line[l - 1] == '\n') line[--l] = '\0';
    else if (!feof(in)) {
      snprintf(why, whylen, "line %lu is too long", n);
      return -1;
    }
    if (l == 0) continue;
    char a[32] = "", b[32] = "", c[32] = "", extra[8] = "", more[8] = "";
    int k = sscanf(line, "%31s %31s %31s %7s %7s", a, b, c, extra, more);
    struct op o;
    memset(&o, 0, sizeof o);
    int ok = 0;
    char *end = NULL;
    if (strcmp(a, "move") == 0 && k == 3) {
      long x = strtol(b, &end, 10);
      if (*end == '\0') {
        long y = strtol(c, &end, 10);
        if (*end == '\0' && x > -1000000 && x < 1000000 && y > -1000000 && y < 1000000) {
          o.kind = OP_MOVE;
          o.x = (int)x;
          o.y = (int)y;
          ok = 1;
        }
      }
    } else if (strcmp(a, "button") == 0 && k == 3) {
      o.kind = OP_BUTTON;
      o.button = strcmp(b, "left") == 0 ? BTN_LEFT
                 : strcmp(b, "right") == 0 ? BTN_RIGHT
                 : strcmp(b, "middle") == 0 ? BTN_MIDDLE : 0;
      ok = o.button != 0 && parse_state(c, &o.down) == 0;
    } else if (strcmp(a, "scroll") == 0 && k == 4) {
      o.kind = OP_SCROLL;
      o.vertical = strcmp(b, "v") == 0;
      long v = strtol(c, &end, 10);
      ok = (o.vertical || strcmp(b, "h") == 0) && *end == '\0' && v >= -100000 &&
           v <= 100000 && (strcmp(extra, "line") == 0 || strcmp(extra, "pixel") == 0);
      o.amount = (int)v;
      o.pixel = strcmp(extra, "pixel") == 0;
    } else if ((strcmp(a, "key") == 0 || strcmp(a, "code") == 0) && k == 3) {
      unsigned long v = strtoul(b, &end, a[0] == 'k' ? 16 : 10);
      ok = *end == '\0' && b[0] != '\0' && v > 0 && v <= 0x1fffffffUL &&
           parse_state(c, &o.down) == 0;
      if (a[0] == 'k') {
        o.kind = OP_KEY;
        o.keysym = (uint32_t)v;
      } else {
        o.kind = OP_CODE;
        o.code = (uint32_t)v;
        ok = ok && v <= KEY_MAX;
      }
    } else if (strcmp(a, "sleep") == 0 && k == 2) {
      long v = strtol(b, &end, 10);
      ok = *end == '\0' && v >= 0 && v <= 600000;
      o.kind = OP_SLEEP;
      o.ms = (int)v;
    }
    if (!ok) {
      snprintf(why, whylen, "line %lu is not a script command", n);
      return -1;
    }
    if (script_push(s, o) != 0) {
      snprintf(why, whylen, "the script holds more than %u events", SCRIPT_OPS_MAX);
      return -1;
    }
  }
  if (ferror(in)) {
    snprintf(why, whylen, "cannot read the script: %s", strerror(errno));
    return -1;
  }
  return 0;
}

/* Set by SIGTERM / SIGINT: the helper stops between two events, releases
   what it holds and exits (a cancelled verb, spec §8.6). */
static volatile sig_atomic_t script_cancelled;

static inline void script_on_signal(int sig) {
  (void)sig;
  script_cancelled = 1;
}

static inline void script_install_signals(void) {
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = script_on_signal;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGINT, &sa, NULL);
  signal(SIGPIPE, SIG_IGN);
}

/* Sleep `ms`, returning early (and 1) once cancelled. */
static inline int script_sleep(int ms) {
  struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
  while (!script_cancelled && nanosleep(&ts, &ts) != 0 && errno == EINTR) {
  }
  return script_cancelled ? 1 : 0;
}

static inline uint32_t script_now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint32_t)((uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u);
}

/* What every helper prints as its one result line on stdout, and its exit
   status. The reasons the backends map: */
#define EXIT_OK 0
#define EXIT_SCRIPT 2    /* "error script …": a malformed script */
#define EXIT_OUTSIDE 3   /* "error outside X Y": a point on no output */
#define EXIT_CONNECT 4   /* "error connect …": no display server */
#define EXIT_PROTOCOL 5  /* "error protocol …": the server lacks what is needed */
#define EXIT_ACCESS 6    /* "error access …": the device is not writable (uinput) */
#define EXIT_FAILED 7    /* "error failed …": the server refused or the link broke */
#define EXIT_CANCELLED 8 /* "error cancelled": SIGTERM / SIGINT */

#endif
