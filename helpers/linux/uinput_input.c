/*
 * uinput_input.c — synthesized input through the kernel's uinput device,
 * the helper of GuiAssert's `linux-uinput` input backend
 * (src/gui_assert/backends/input/linux_uinput.nim).
 *
 * It creates two input devices with /dev/uinput
 * (https://www.kernel.org/doc/html/latest/input/uinput.html) for the time of
 * one script, so any compositor (or X server) that reads the host's input
 * devices through libinput sees them as hardware:
 *
 *   * an ABSOLUTE pointer (ABS_X / ABS_Y with BTN_LEFT / BTN_RIGHT /
 *     BTN_MIDDLE and the wheels, the shape of a virtual machine's tablet),
 *     whose axis range is the desktop extent given on the command line, so
 *     a position is a desktop coordinate (compositors map such a device onto
 *     the whole output layout);
 *   * a keyboard of every Linux key code. Keys are given as key codes
 *     (`code C down|up`): the backend translates keys and characters with
 *     the US layout the host's keyboard is assumed to have, and refuses a
 *     character it has no key for before running the helper.
 *
 * Opening /dev/uinput needs write access to it, which the default device
 * permissions (root only) do not give: that is `error access` and exit
 * status 6, the backend's exit 6 / `uinput-access`.
 *
 * A new device is announced to the compositor by udev and opened by
 * libinput asynchronously, with no acknowledgement a client can wait for,
 * so the helper waits `SETTLE_MS` after creating the devices.
 *
 * Usage (the script on stdin, see input_script.h):
 *
 *   uinput_input run X Y W H    execute the script against the desktop
 *                               extent (X, Y, W, H); "ok" or "error …"
 *   uinput_input probe          "ok" when /dev/uinput opens for writing
 *
 * Exit status: see input_script.h.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/uinput.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "input_script.h"

#define SETTLE_MS 600
#define DEVICE "/dev/uinput"

static void fail(int status, const char *fmt, const char *a) {
  printf("error ");
  printf(fmt, a);
  printf("\n");
  fflush(stdout);
  exit(status);
}

static int open_uinput(void) {
  int fd = open(DEVICE, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) {
    if (errno == EACCES || errno == EPERM)
      fail(EXIT_ACCESS, "access no write access to " DEVICE ": %s", strerror(errno));
    if (errno == ENOENT || errno == ENODEV)
      fail(EXIT_PROTOCOL, "protocol " DEVICE " does not exist (the uinput module is not loaded): %s",
           strerror(errno));
    fail(EXIT_FAILED, "failed cannot open " DEVICE ": %s", strerror(errno));
  }
  return fd;
}

static void ioctl_or_fail(int fd, unsigned long req, long arg, const char *what) {
  if (ioctl(fd, req, arg) < 0) fail(EXIT_FAILED, "failed %s", what);
}

static void emit(int fd, int type, int code, int value) {
  struct input_event ev;
  memset(&ev, 0, sizeof ev);
  ev.type = (unsigned short)type;
  ev.code = (unsigned short)code;
  ev.value = value;
  if (write(fd, &ev, sizeof ev) != (ssize_t)sizeof ev)
    fail(EXIT_FAILED, "failed writing an input event: %s", strerror(errno));
}

static void syn(int fd) { emit(fd, EV_SYN, SYN_REPORT, 0); }

static int create_pointer(int w, int h) {
  int fd = open_uinput();
  ioctl_or_fail(fd, UI_SET_EVBIT, EV_KEY, "UI_SET_EVBIT EV_KEY");
  ioctl_or_fail(fd, UI_SET_EVBIT, EV_ABS, "UI_SET_EVBIT EV_ABS");
  ioctl_or_fail(fd, UI_SET_EVBIT, EV_REL, "UI_SET_EVBIT EV_REL");
  ioctl_or_fail(fd, UI_SET_EVBIT, EV_SYN, "UI_SET_EVBIT EV_SYN");
  int buttons[] = {BTN_LEFT, BTN_RIGHT, BTN_MIDDLE};
  for (int i = 0; i < 3; i++) ioctl_or_fail(fd, UI_SET_KEYBIT, buttons[i], "UI_SET_KEYBIT");
  int rels[] = {REL_WHEEL, REL_HWHEEL, REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES};
  for (int i = 0; i < 4; i++) ioctl_or_fail(fd, UI_SET_RELBIT, rels[i], "UI_SET_RELBIT");
  ioctl_or_fail(fd, UI_SET_PROPBIT, INPUT_PROP_POINTER, "UI_SET_PROPBIT");
  int axes[2] = {ABS_X, ABS_Y}, extent[2] = {w, h};
  for (int i = 0; i < 2; i++) {
    ioctl_or_fail(fd, UI_SET_ABSBIT, axes[i], "UI_SET_ABSBIT");
    struct uinput_abs_setup a;
    memset(&a, 0, sizeof a);
    a.code = (unsigned short)axes[i];
    a.absinfo.minimum = 0;
    a.absinfo.maximum = extent[i] - 1;
    if (ioctl(fd, UI_ABS_SETUP, &a) < 0) fail(EXIT_FAILED, "failed %s", "UI_ABS_SETUP");
  }
  struct uinput_setup u;
  memset(&u, 0, sizeof u);
  u.id.bustype = BUS_VIRTUAL;
  u.id.vendor = 0x4741;   /* "GA" */
  u.id.product = 0x0001;
  snprintf(u.name, sizeof u.name, "GuiAssert virtual pointer");
  if (ioctl(fd, UI_DEV_SETUP, &u) < 0) fail(EXIT_FAILED, "failed %s", "UI_DEV_SETUP");
  if (ioctl(fd, UI_DEV_CREATE) < 0) fail(EXIT_FAILED, "failed %s", "UI_DEV_CREATE");
  return fd;
}

static int create_keyboard(void) {
  int fd = open_uinput();
  ioctl_or_fail(fd, UI_SET_EVBIT, EV_KEY, "UI_SET_EVBIT EV_KEY");
  ioctl_or_fail(fd, UI_SET_EVBIT, EV_SYN, "UI_SET_EVBIT EV_SYN");
  for (int k = KEY_ESC; k < BTN_MISC; k++) ioctl_or_fail(fd, UI_SET_KEYBIT, k, "UI_SET_KEYBIT");
  struct uinput_setup u;
  memset(&u, 0, sizeof u);
  u.id.bustype = BUS_VIRTUAL;
  u.id.vendor = 0x4741;
  u.id.product = 0x0002;
  snprintf(u.name, sizeof u.name, "GuiAssert virtual keyboard");
  if (ioctl(fd, UI_DEV_SETUP, &u) < 0) fail(EXIT_FAILED, "failed %s", "UI_DEV_SETUP");
  if (ioctl(fd, UI_DEV_CREATE) < 0) fail(EXIT_FAILED, "failed %s", "UI_DEV_CREATE");
  return fd;
}

static int mode_run(char **argv) {
  long box[4];
  for (int i = 0; i < 4; i++) {
    char *end;
    box[i] = strtol(argv[i], &end, 10);
    if (*end != '\0' || box[i] < (i < 2 ? -100000 : 1) || box[i] > 100000)
      fail(EXIT_SCRIPT, "script extent value %s is out of range", argv[i]);
  }
  struct script s = {0};
  char why[160];
  if (script_read(stdin, &s, why, sizeof why) != 0) fail(EXIT_SCRIPT, "script %s", why);
  int need_ptr = 0, need_kbd = 0;
  size_t downs = 0;
  for (size_t i = 0; i < s.len; i++) {
    struct op *o = &s.ops[i];
    if (o->kind == OP_MOVE || o->kind == OP_BUTTON || o->kind == OP_SCROLL) need_ptr = 1;
    if (o->kind == OP_CODE) {
      need_kbd = 1;
      if (o->down) downs++;
    }
    if (o->kind == OP_KEY) fail(EXIT_SCRIPT, "script %s", "uinput takes key codes, not keysyms");
    if (o->kind == OP_MOVE && (o->x < box[0] || o->y < box[1] || o->x >= box[0] + box[2] ||
                               o->y >= box[1] + box[3])) {
      char at[48];
      snprintf(at, sizeof at, "%d %d", o->x, o->y);
      fail(EXIT_OUTSIDE, "outside %s", at);
    }
  }
  int pfd = need_ptr ? create_pointer((int)box[2], (int)box[3]) : -1;
  int kfd = need_kbd ? create_keyboard() : -1;
  int *held = calloc(downs + 1, sizeof *held);
  int held_buttons[3], n_buttons = 0;
  size_t n_held = 0;
  if (!held) fail(EXIT_FAILED, "failed %s", "out of memory");
  script_sleep(SETTLE_MS);
  for (size_t i = 0; i < s.len && !script_cancelled; i++) {
    struct op *o = &s.ops[i];
    switch (o->kind) {
    case OP_MOVE:
      emit(pfd, EV_ABS, ABS_X, (int)(o->x - box[0]));
      emit(pfd, EV_ABS, ABS_Y, (int)(o->y - box[1]));
      syn(pfd);
      break;
    case OP_BUTTON: {
      emit(pfd, EV_KEY, (int)o->button, o->down);
      syn(pfd);
      /* Each of the three buttons is held once at most, so the list
         cannot overflow whatever the script presses. */
      int at = -1;
      for (int k = 0; k < n_buttons; k++)
        if (held_buttons[k] == (int)o->button) at = k;
      if (o->down && at < 0) held_buttons[n_buttons++] = (int)o->button;
      if (!o->down && at >= 0) held_buttons[at] = held_buttons[--n_buttons];
      break;
    }
    case OP_SCROLL: {
      /* The wheel counts away from the user: positive REL_WHEEL scrolls up,
         so a scroll down is negative. 120 hi-res units are one notch. */
      int sign = o->vertical ? -1 : 1;
      if (o->pixel) {
        emit(pfd, EV_REL, o->vertical ? REL_WHEEL_HI_RES : REL_HWHEEL_HI_RES,
             sign * o->amount * 8);
        syn(pfd);
      } else {
        int step = o->amount < 0 ? -1 : 1;
        for (int n = 0; n != o->amount && !script_cancelled; n += step) {
          emit(pfd, EV_REL, o->vertical ? REL_WHEEL : REL_HWHEEL, sign * step);
          emit(pfd, EV_REL, o->vertical ? REL_WHEEL_HI_RES : REL_HWHEEL_HI_RES, sign * step * 120);
          syn(pfd);
        }
      }
      break;
    }
    case OP_CODE:
      emit(kfd, EV_KEY, (int)o->code, o->down);
      syn(kfd);
      if (o->down) held[n_held++] = (int)o->code;
      else
        for (size_t k = 0; k < n_held; k++)
          if (held[k] == (int)o->code) {
            held[k] = held[--n_held];
            break;
          }
      break;
    case OP_SLEEP:
      script_sleep(o->ms);
      break;
    case OP_KEY:
      break;
    }
  }
  int status = script_cancelled ? EXIT_CANCELLED : EXIT_OK;
  while (n_buttons > 0) {
    emit(pfd, EV_KEY, held_buttons[--n_buttons], 0);
    syn(pfd);
  }
  while (n_held > 0) {
    emit(kfd, EV_KEY, held[--n_held], 0);
    syn(kfd);
  }
  /* Let the compositor read the last events before the devices go. */
  struct timespec ts = {0, 100 * 1000000L};
  nanosleep(&ts, NULL);
  if (pfd >= 0) {
    ioctl(pfd, UI_DEV_DESTROY);
    close(pfd);
  }
  if (kfd >= 0) {
    ioctl(kfd, UI_DEV_DESTROY);
    close(kfd);
  }
  printf(status == EXIT_OK ? "ok\n" : "error cancelled\n");
  return status;
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IOLBF, 0);
  script_install_signals();
  if (argc == 6 && strcmp(argv[1], "run") == 0) return mode_run(argv + 2);
  if (argc == 2 && strcmp(argv[1], "probe") == 0) {
    close(open_uinput());
    printf("ok\n");
    return EXIT_OK;
  }
  fprintf(stderr, "usage: uinput_input run X Y W H | probe (script on stdin)\n");
  return EXIT_SCRIPT;
}
