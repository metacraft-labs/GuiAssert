/*
 * x11_input.c — the Linux tree live suite's hands on a private Xvfb
 * (tests/live/ttree_linux.nim): it moves a fixture's top-level window and
 * clicks at a desktop point, so a test can check that the centre of a node's
 * reported bounds is where the pointer reaches it. (GuiAssert's own X11
 * input backend, `linux-xtest`, is GS8's; this file is test support only.)
 *
 *   x11_input place <pid> <x> <y>
 *     Moves every mapped top-level window whose _NET_WM_PID is <pid> so its
 *     top-left is at (<x>, <y>) in root coordinates (XMoveWindow; with no
 *     window manager on the server the request takes effect as asked), and
 *     waits until the server reports the new position. Prints the window id.
 *   x11_input click <x> <y>
 *     Moves the pointer to (<x>, <y>), gives the input focus to the top-level
 *     window there (what a click-to-focus window manager does; the server
 *     has none, and a GTK 4 client takes the focus for itself when it maps,
 *     so keys would otherwise go to it) and clicks button 1 there with the
 *     XTest extension (https://www.x.org/releases/current/doc/xextproto/xtest.html).
 *   x11_input type <text>
 *     Types <text> (letters, digits and '-') into the focused window with
 *     XTest key events, shift held for an upper-case letter.
 *
 * Exits 0 on success, 1 with a message on stderr otherwise.
 */
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static long window_pid(Display *d, Window w) {
  Atom pid_atom = XInternAtom(d, "_NET_WM_PID", True);
  if (pid_atom == None) return -1;
  Atom type;
  int format;
  unsigned long n, after;
  unsigned char *data = NULL;
  long pid = -1;
  if (XGetWindowProperty(d, w, pid_atom, 0, 1, False, XA_CARDINAL, &type, &format, &n, &after,
                         &data) == Success && data != NULL) {
    if (type == XA_CARDINAL && format == 32 && n == 1) pid = (long)*(unsigned long *)data;
    XFree(data);
  }
  return pid;
}

static int place(Display *d, long pid, int x, int y) {
  Window root = DefaultRootWindow(d), parent, *children = NULL;
  unsigned int n = 0;
  if (!XQueryTree(d, root, &root, &parent, &children, &n)) {
    fprintf(stderr, "x11_input: XQueryTree failed\n");
    return 1;
  }
  int moved = 0;
  for (unsigned int i = 0; i < n; i++) {
    XWindowAttributes a;
    if (!XGetWindowAttributes(d, children[i], &a) || a.map_state != IsViewable) continue;
    if (window_pid(d, children[i]) != pid) continue;
    XMoveWindow(d, children[i], x, y);
    XSync(d, False);
    for (int tries = 0; tries < 200; tries++) {
      Window child;
      int rx, ry;
      XTranslateCoordinates(d, children[i], root, 0, 0, &rx, &ry, &child);
      if (rx == x && ry == y) break;
      usleep(10000);
    }
    printf("%lu\n", (unsigned long)children[i]);
    moved++;
  }
  if (children) XFree(children);
  if (moved == 0) {
    fprintf(stderr, "x11_input: no mapped top-level window of pid %ld\n", pid);
    return 1;
  }
  return 0;
}

static int click(Display *d, int x, int y) {
  int ev, err, major, minor;
  if (!XTestQueryExtension(d, &ev, &err, &major, &minor)) {
    fprintf(stderr, "x11_input: the server has no XTest extension\n");
    return 1;
  }
  XTestFakeMotionEvent(d, -1, x, y, CurrentTime);
  XSync(d, False);
  usleep(50000);
  Window root_return, child = None;
  int rx, ry, wx, wy;
  unsigned int mask;
  XQueryPointer(d, DefaultRootWindow(d), &root_return, &child, &rx, &ry, &wx, &wy, &mask);
  if (child != None) {
    XSetInputFocus(d, child, RevertToPointerRoot, CurrentTime);
    XSync(d, False);
    usleep(30000);
  }
  XTestFakeButtonEvent(d, 1, True, CurrentTime);
  XSync(d, False);
  usleep(30000);
  XTestFakeButtonEvent(d, 1, False, CurrentTime);
  XSync(d, False);
  return 0;
}

static int type_text(Display *d, const char *text) {
  KeyCode shift = XKeysymToKeycode(d, XK_Shift_L);
  for (const char *p = text; *p; p++) {
    char name[2] = {*p, 0};
    int upper = *p >= 'A' && *p <= 'Z';
    if (upper) name[0] = (char)(*p - 'A' + 'a');
    KeySym sym = *p == '-' ? XK_minus : XStringToKeysym(name);
    KeyCode code = sym == NoSymbol ? 0 : XKeysymToKeycode(d, sym);
    if (code == 0) {
      fprintf(stderr, "x11_input: no key types '%c'\n", *p);
      return 1;
    }
    if (upper) XTestFakeKeyEvent(d, shift, True, CurrentTime);
    XTestFakeKeyEvent(d, code, True, CurrentTime);
    XTestFakeKeyEvent(d, code, False, CurrentTime);
    if (upper) XTestFakeKeyEvent(d, shift, False, CurrentTime);
    XSync(d, False);
    usleep(15000);
  }
  return 0;
}

int main(int argc, char **argv) {
  Display *d = XOpenDisplay(NULL);
  if (d == NULL) {
    fprintf(stderr, "x11_input: cannot open the display\n");
    return 1;
  }
  int rc = 2;
  if (argc == 5 && strcmp(argv[1], "place") == 0)
    rc = place(d, atol(argv[2]), atoi(argv[3]), atoi(argv[4]));
  else if (argc == 4 && strcmp(argv[1], "click") == 0)
    rc = click(d, atoi(argv[2]), atoi(argv[3]));
  else if (argc == 3 && strcmp(argv[1], "type") == 0)
    rc = type_text(d, argv[2]);
  else
    fprintf(stderr, "usage: x11_input place <pid> <x> <y> | click <x> <y> | type <text>\n");
  XCloseDisplay(d);
  return rc;
}
