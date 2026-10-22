/*
 * x11_probe.c — what an X server says about its screen and windows, and a
 * window of a known colour to find in it.
 *
 * GuiAssert's `linux-x11` capture backend enumerates through this helper
 * (Xlib has no command-line tool that reports geometry, stacking, focus and
 * the owning pid in one consistent read), and its live tests use the
 * `window` mode as their fixture application.
 *
 *   x11_probe list
 *     Prints one JSON line:
 *       {"screen":0,"width":W,"height":H,"wm":bool,"focus":ID|null,
 *        "windows":[{"id":ID,"pid":N|null,"class":S|null,"instance":S|null,
 *                    "title":S|null,"x":X,"y":Y,"width":W,"height":H,
 *                    "mapped":bool,"overrideRedirect":bool}, ...]}
 *     `windows` is bottom to top (the order XQueryTree returns the root's
 *     children: https://www.x.org/releases/current/doc/libX11/libX11/libX11.html#XQueryTree).
 *     A window is a CLIENT window: with a reparenting window manager the
 *     root's child is the frame, and the client is the descendant carrying
 *     WM_STATE (ICCCM §4.1.3.1); without a window manager (`wm` false: no
 *     _NET_SUPPORTING_WM_CHECK on the root) the root's children are the
 *     clients. Geometry is the client's, translated to root coordinates.
 *     `pid` is _NET_WM_PID (EWMH), else the pid of the client that owns
 *     the window as the X-Resource extension reports it (local clients
 *     only: https://www.x.org/releases/current/doc/resourceproto/resproto.txt),
 *     else null. `title` is _NET_WM_NAME
 *     (UTF-8), else WM_NAME. `focus` is the client holding the input focus
 *     (XGetInputFocus, mapped to its client), or null.
 *
 *   x11_probe window --geometry WxH+X+Y (--rgb RRGGBB | --image PPM)
 *                    [--title T] [--class C] [--hold MS]
 *     Opens a mapped top-level window filled with the colour, or showing
 *     the binary PPM of exactly WxH pixels (`ppm_image.h`; the live OCR
 *     suite draws invented text into it) as its background, its WM_CLASS
 *     `C` (default `gui-assert-x11-probe`), its title, and its _NET_WM_PID,
 *     waits for the first Expose, prints {"id":ID} and keeps it painted for
 *     MS milliseconds (default 60000), or until SIGTERM.
 *
 *   x11_probe grab --geometry WxH+X+Y --out FILE
 *     Writes the rectangle of the screen as a binary PPM, read with
 *     XGetImage from the root window.
 *
 *   x11_probe record --geometry WxH+X+Y --fps F --report FILE -- ARGV...
 *     Feeds an encoder (ARGV, reading raw RGB24 frames on its standard
 *     input) one XGetImage grab of the rectangle every 1/F seconds until
 *     SIGINT or SIGTERM; see `record` below.
 *
 * Strings are JSON-escaped; bytes that are not valid UTF-8 are passed as
 * U+FFFD so the output is always valid JSON.
 */
#define _GNU_SOURCE
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XRes.h>
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "ppm_image.h"

static Atom a_wm_state, a_net_wm_pid, a_net_wm_name, a_utf8, a_net_check;

static int ignore_errors(Display *d, XErrorEvent *e) {
  (void)d;
  (void)e;
  return 0; /* a window may vanish while it is read; it is then skipped */
}

static void put_json_string(const unsigned char *s, size_t n) {
  putchar('"');
  for (size_t i = 0; i < n;) {
    unsigned char c = s[i];
    size_t len = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3
                 : (c >> 3) == 30 ? 4 : 0;
    int ok = len > 0 && i + len <= n;
    for (size_t k = 1; ok && k < len; k++)
      ok = (s[i + k] & 0xC0) == 0x80;
    if (!ok) {
      fputs("\\ufffd", stdout);
      i++;
      continue;
    }
    if (len == 1) {
      if (c == '"' || c == '\\')
        printf("\\%c", c);
      else if (c < 0x20)
        printf("\\u%04x", c);
      else
        putchar(c);
    } else {
      fwrite(s + i, 1, len, stdout);
    }
    i += len;
  }
  putchar('"');
}

static int get_property(Display *d, Window w, Atom prop, Atom type,
                        unsigned char **data, unsigned long *n) {
  Atom actual;
  int format;
  unsigned long after;
  *data = NULL;
  *n = 0;
  if (XGetWindowProperty(d, w, prop, 0, 1 << 16, False, type, &actual,
                         &format, n, &after, data) != Success ||
      *data == NULL) {
    return 0;
  }
  if (actual == None) {
    XFree(*data);
    *data = NULL;
    return 0;
  }
  return format;
}

static int has_wm_state(Display *d, Window w) {
  unsigned char *data;
  unsigned long n;
  if (get_property(d, w, a_wm_state, AnyPropertyType, &data, &n)) {
    XFree(data);
    return 1;
  }
  return 0;
}

/* The client window at or below `w` (the one with WM_STATE), or None. */
static Window find_client(Display *d, Window w, int depth) {
  if (has_wm_state(d, w))
    return w;
  if (depth > 4)
    return None;
  Window root, parent, *children = NULL;
  unsigned int n = 0;
  if (!XQueryTree(d, w, &root, &parent, &children, &n))
    return None;
  Window found = None;
  for (unsigned int i = n; i-- > 0 && found == None;)
    found = find_client(d, children[i], depth + 1);
  if (children)
    XFree(children);
  return found;
}

static void print_title(Display *d, Window w) {
  unsigned char *data;
  unsigned long n;
  if (get_property(d, w, a_net_wm_name, a_utf8, &data, &n) == 8) {
    put_json_string(data, n);
    XFree(data);
    return;
  }
  if (get_property(d, w, XA_WM_NAME, AnyPropertyType, &data, &n) == 8) {
    put_json_string(data, n);
    XFree(data);
    return;
  }
  fputs("null", stdout);
}

static void print_window(Display *d, Window root, Window client, Window frame,
                         int *first) {
  XWindowAttributes attrs, frame_attrs;
  if (!XGetWindowAttributes(d, client, &attrs) ||
      !XGetWindowAttributes(d, frame, &frame_attrs))
    return;
  if (attrs.class != InputOutput)
    return;
  int x = 0, y = 0;
  Window child;
  if (!XTranslateCoordinates(d, client, root, 0, 0, &x, &y, &child))
    return;
  printf("%s{\"id\":%lu,\"pid\":", *first ? "" : ",", (unsigned long)client);
  *first = 0;
  unsigned char *data;
  unsigned long n;
  if (get_property(d, client, a_net_wm_pid, XA_CARDINAL, &data, &n) == 32 &&
      n >= 1) {
    printf("%lu", ((unsigned long *)data)[0]);
    XFree(data);
  } else {
    long xres_pid = -1;
    XResClientIdSpec spec = {client, XRES_CLIENT_ID_PID_MASK};
    long num = 0;
    XResClientIdValue *ids = NULL;
    if (XResQueryClientIds(d, 1, &spec, &num, &ids) == Success) {
      for (long k = 0; k < num && xres_pid < 0; k++)
        if (XResGetClientIdType(&ids[k]) == XRES_CLIENT_ID_PID)
          xres_pid = (long)XResGetClientPid(&ids[k]);
      XResClientIdsDestroy(num, ids);
    }
    if (xres_pid > 0)
      printf("%ld", xres_pid);
    else
      fputs("null", stdout);
  }
  XClassHint hint = {0};
  if (XGetClassHint(d, client, &hint)) {
    fputs(",\"class\":", stdout);
    if (hint.res_class)
      put_json_string((unsigned char *)hint.res_class, strlen(hint.res_class));
    else
      fputs("null", stdout);
    fputs(",\"instance\":", stdout);
    if (hint.res_name)
      put_json_string((unsigned char *)hint.res_name, strlen(hint.res_name));
    else
      fputs("null", stdout);
    if (hint.res_class)
      XFree(hint.res_class);
    if (hint.res_name)
      XFree(hint.res_name);
  } else {
    fputs(",\"class\":null,\"instance\":null", stdout);
  }
  fputs(",\"title\":", stdout);
  print_title(d, client);
  printf(",\"x\":%d,\"y\":%d,\"width\":%d,\"height\":%d,\"mapped\":%s,"
         "\"overrideRedirect\":%s}",
         x, y, attrs.width, attrs.height,
         frame_attrs.map_state == IsViewable ? "true" : "false",
         frame_attrs.override_redirect ? "true" : "false");
}

static int list(Display *d) {
  int screen = DefaultScreen(d);
  Window root = RootWindow(d, screen);
  unsigned char *data;
  unsigned long n;
  int wm = 0;
  if (get_property(d, root, a_net_check, XA_WINDOW, &data, &n) == 32 && n >= 1) {
    wm = 1;
    XFree(data);
  }
  Window focus_win;
  int revert;
  XGetInputFocus(d, &focus_win, &revert);
  Window r, parent, *children = NULL;
  unsigned int count = 0;
  if (!XQueryTree(d, root, &r, &parent, &children, &count)) {
    fprintf(stderr, "x11_probe: XQueryTree of the root window failed\n");
    return 1;
  }
  /* The focused client: the focus window, or the client of the frame or
   * subwindow that holds it. */
  Window focus_client = None;
  if (focus_win != None && focus_win != PointerRoot) {
    Window w = focus_win;
    for (int depth = 0; depth < 8 && w != None && w != root; depth++) {
      if (has_wm_state(d, w)) {
        focus_client = w;
        break;
      }
      Window rr, pp, *cc = NULL;
      unsigned int nn = 0;
      if (!XQueryTree(d, w, &rr, &pp, &cc, &nn))
        break;
      if (cc)
        XFree(cc);
      if (pp == root) {
        focus_client = wm ? find_client(d, w, 0) : w;
        break;
      }
      w = pp;
    }
  }
  printf("{\"screen\":%d,\"width\":%d,\"height\":%d,\"wm\":%s,\"focus\":", screen,
         DisplayWidth(d, screen), DisplayHeight(d, screen), wm ? "true" : "false");
  if (focus_client != None)
    printf("%lu", (unsigned long)focus_client);
  else
    fputs("null", stdout);
  fputs(",\"windows\":[", stdout);
  int first = 1;
  for (unsigned int i = 0; i < count; i++) {
    Window client = wm ? find_client(d, children[i], 0) : children[i];
    if (client == None)
      continue;
    print_window(d, root, client, children[i], &first);
  }
  fputs("]}\n", stdout);
  if (children)
    XFree(children);
  return 0;
}

static volatile sig_atomic_t stop_requested;
static void on_term(int sig) {
  (void)sig;
  stop_requested = 1;
}

/* The pixel value of an RGB colour in a TrueColor visual's channel masks. */
static unsigned long true_color_pixel(const Visual *visual, unsigned r, unsigned g,
                                      unsigned b) {
  unsigned long pixel = 0;
  unsigned long masks[3] = {visual->red_mask, visual->green_mask, visual->blue_mask};
  unsigned long channels[3] = {r & 0xff, g & 0xff, b & 0xff};
  for (int c = 0; c < 3; c++) {
    unsigned long m = masks[c];
    int shift = 0, bits = 0;
    while (m && !(m & 1)) {
      m >>= 1;
      shift++;
    }
    while (m & 1) {
      m >>= 1;
      bits++;
    }
    /* Scale the 8-bit channel to the mask's width (wider masks: depth 30). */
    unsigned long v = bits <= 8 ? channels[c] >> (8 - bits) : channels[c] << (bits - 8);
    pixel |= v << shift;
  }
  return pixel;
}

static int open_window(Display *d, int argc, char **argv) {
  int w = 0, h = 0, x = 0, y = 0;
  unsigned long rgb = 0x808080;
  const char *title = NULL, *klass = "gui-assert-x11-probe", *image = NULL;
  long hold_ms = 60000;
  int have_geometry = 0;
  for (int i = 2; i < argc; i++) {
    if (strcmp(argv[i], "--geometry") == 0 && i + 1 < argc) {
      have_geometry = sscanf(argv[++i], "%dx%d+%d+%d", &w, &h, &x, &y) == 4;
    } else if (strcmp(argv[i], "--rgb") == 0 && i + 1 < argc) {
      rgb = strtoul(argv[++i], NULL, 16);
    } else if (strcmp(argv[i], "--image") == 0 && i + 1 < argc) {
      image = argv[++i];
    } else if (strcmp(argv[i], "--title") == 0 && i + 1 < argc) {
      title = argv[++i];
    } else if (strcmp(argv[i], "--class") == 0 && i + 1 < argc) {
      klass = argv[++i];
    } else if (strcmp(argv[i], "--hold") == 0 && i + 1 < argc) {
      hold_ms = atol(argv[++i]);
    } else {
      fprintf(stderr, "x11_probe window: unknown argument %s\n", argv[i]);
      return 2;
    }
  }
  if (!have_geometry || w <= 0 || h <= 0) {
    fprintf(stderr, "x11_probe window: --geometry WxH+X+Y is required\n");
    return 2;
  }
  int screen = DefaultScreen(d);
  Visual *visual = DefaultVisual(d, screen);
  if (visual->class != TrueColor) {
    fprintf(stderr, "x11_probe window: the default visual is not TrueColor\n");
    return 1;
  }
  XSetWindowAttributes sa = {0};
  unsigned long attr_mask = CWEventMask;
  sa.event_mask = ExposureMask | StructureNotifyMask;
  Pixmap background = None;
  if (image) {
    /* The image becomes the window's background pixmap, so the server
     * repaints it on every exposure. */
    int iw = 0, ih = 0;
    const char *why = "";
    unsigned char *rgb24 = read_ppm(image, &iw, &ih, &why);
    if (!rgb24) {
      fprintf(stderr, "x11_probe window: %s: %s\n", image, why);
      return 1;
    }
    if (iw != w || ih != h) {
      fprintf(stderr, "x11_probe window: %s is %dx%d, not the window's %dx%d\n",
              image, iw, ih, w, h);
      free(rgb24);
      return 2;
    }
    int depth = DefaultDepth(d, screen);
    char *data = malloc((size_t)w * h * 4);
    XImage *xi = data ? XCreateImage(d, visual, (unsigned)depth, ZPixmap, 0, data,
                                     (unsigned)w, (unsigned)h, 32, 0)
                      : NULL;
    if (!xi) {
      fprintf(stderr, "x11_probe window: cannot create the image\n");
      free(data);
      free(rgb24);
      return 1;
    }
    for (int row = 0; row < h; row++)
      for (int col = 0; col < w; col++) {
        const unsigned char *p = rgb24 + ((size_t)row * w + col) * 3;
        XPutPixel(xi, col, row, true_color_pixel(visual, p[0], p[1], p[2]));
      }
    free(rgb24);
    background = XCreatePixmap(d, RootWindow(d, screen), (unsigned)w, (unsigned)h,
                               (unsigned)depth);
    GC gc = XCreateGC(d, background, 0, NULL);
    XPutImage(d, background, gc, xi, 0, 0, 0, 0, (unsigned)w, (unsigned)h);
    XFreeGC(d, gc);
    XDestroyImage(xi); /* frees `data` too */
    sa.background_pixmap = background;
    attr_mask |= CWBackPixmap;
  } else {
    sa.background_pixel =
        true_color_pixel(visual, (rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff);
    attr_mask |= CWBackPixel;
  }
  Window win = XCreateWindow(d, RootWindow(d, screen), x, y, w, h, 0,
                             CopyFromParent, InputOutput, CopyFromParent,
                             attr_mask, &sa);
  XSizeHints *size = XAllocSizeHints();
  size->flags = PPosition | PSize | USPosition | USSize;
  size->x = x;
  size->y = y;
  size->width = w;
  size->height = h;
  XSetWMNormalHints(d, win, size);
  XFree(size);
  XClassHint hint = {(char *)klass, (char *)klass};
  XSetClassHint(d, win, &hint);
  if (title) {
    XStoreName(d, win, title);
    XChangeProperty(d, win, a_net_wm_name, a_utf8, 8, PropModeReplace,
                    (const unsigned char *)title, (int)strlen(title));
  }
  unsigned long pid = (unsigned long)getpid();
  XChangeProperty(d, win, a_net_wm_pid, XA_CARDINAL, 32, PropModeReplace,
                  (unsigned char *)&pid, 1);
  XMapRaised(d, win);
  XSync(d, False);
  for (;;) {
    XEvent ev;
    XNextEvent(d, &ev);
    if (ev.type == Expose)
      break;
  }
  printf("{\"id\":%lu}\n", (unsigned long)win);
  fflush(stdout);
  signal(SIGTERM, on_term);
  signal(SIGINT, on_term);
  struct timespec start, now;
  clock_gettime(CLOCK_MONOTONIC, &start);
  while (!stop_requested) {
    clock_gettime(CLOCK_MONOTONIC, &now);
    long elapsed = (now.tv_sec - start.tv_sec) * 1000 +
                   (now.tv_nsec - start.tv_nsec) / 1000000;
    if (elapsed >= hold_ms)
      break;
    while (XPending(d)) {
      XEvent ev;
      XNextEvent(d, &ev);
      if (ev.type == Expose)
        XClearWindow(d, win);
    }
    struct pollfd pfd = {ConnectionNumber(d), POLLIN, 0};
    poll(&pfd, 1, 100);
  }
  XDestroyWindow(d, win);
  if (background != None)
    XFreePixmap(d, background);
  XCloseDisplay(d);
  return 0;
}

/* --- grab and record ------------------------------------------------------ */

static int parse_geometry(const char *s, int *w, int *h, int *x, int *y) {
  return sscanf(s, "%dx%d+%d+%d", w, h, x, y) == 4 && *w > 0 && *h > 0;
}

/* The rectangle's pixels as packed RGB24, read with XGetImage from the
 * root window (what is on screen, whatever window shows it). 0 on failure:
 * the rectangle does not lie within the screen (BadMatch). */
static int grab_rgb(Display *d, int x, int y, int w, int h, unsigned char *out) {
  Window root = DefaultRootWindow(d);
  XImage *img = XGetImage(d, root, x, y, (unsigned)w, (unsigned)h, AllPlanes, ZPixmap);
  if (!img)
    return 0;
  unsigned long masks[3] = {img->red_mask, img->green_mask, img->blue_mask};
  int shift[3], bits[3];
  for (int c = 0; c < 3; c++) {
    unsigned long m = masks[c];
    shift[c] = bits[c] = 0;
    while (m && !(m & 1)) {
      m >>= 1;
      shift[c]++;
    }
    while (m & 1) {
      m >>= 1;
      bits[c]++;
    }
  }
  for (int row = 0; row < h; row++) {
    for (int col = 0; col < w; col++) {
      unsigned long p;
      if (img->bits_per_pixel == 32 && img->byte_order == LSBFirst)
        p = ((uint32_t *)(img->data + row * img->bytes_per_line))[col];
      else
        p = XGetPixel(img, col, row);
      unsigned char *o = out + ((size_t)row * w + col) * 3;
      for (int c = 0; c < 3; c++) {
        unsigned long v = (p & masks[c]) >> shift[c];
        /* A visual without this channel (mask 0) reads as 0, never a
         * division by zero. */
        o[c] = bits[c] == 0  ? 0
               : bits[c] >= 8 ? (unsigned char)(v >> (bits[c] - 8))
                              : (unsigned char)(v * 255 / ((1ul << bits[c]) - 1));
      }
    }
  }
  XDestroyImage(img);
  return 1;
}

/* grab --geometry WxH+X+Y --out FILE.ppm: one frame as a binary PPM
 * (https://netpbm.sourceforge.net/doc/ppm.html), written to FILE. */
static int grab(Display *d, int argc, char **argv) {
  int w = 0, h = 0, x = 0, y = 0, have = 0;
  const char *out = NULL;
  for (int i = 2; i < argc; i++) {
    if (strcmp(argv[i], "--geometry") == 0 && i + 1 < argc)
      have = parse_geometry(argv[++i], &w, &h, &x, &y);
    else if (strcmp(argv[i], "--out") == 0 && i + 1 < argc)
      out = argv[++i];
    else {
      fprintf(stderr, "x11_probe grab: unknown argument %s\n", argv[i]);
      return 2;
    }
  }
  if (!have || !out) {
    fprintf(stderr, "x11_probe grab: --geometry WxH+X+Y and --out are required\n");
    return 2;
  }
  unsigned char *px = malloc((size_t)w * h * 3);
  if (!px || !grab_rgb(d, x, y, w, h, px)) {
    fprintf(stderr, "x11_probe grab: XGetImage failed (is the rectangle on the screen?)\n");
    return 4;
  }
  FILE *f = fopen(out, "wb");
  if (!f) {
    fprintf(stderr, "x11_probe grab: cannot write the output file\n");
    return 5;
  }
  fprintf(f, "P6\n%d %d\n255\n", w, h);
  int ok = fwrite(px, 1, (size_t)w * h * 3, f) == (size_t)w * h * 3;
  ok = (fclose(f) == 0) && ok;
  free(px);
  return ok ? 0 : 5;
}

static const char *report_path;
static void write_report(const char *state, long child, long frames, int code,
                         const char *message) {
  char tmp[4096];
  snprintf(tmp, sizeof tmp, "%s.tmp", report_path);
  FILE *f = fopen(tmp, "w");
  if (!f)
    return;
  fprintf(f, "state=%s\npid=%ld\nchild=%ld\nframes=%ld\ncode=%d\nmessage=%s\n", state,
          (long)getpid(), child, frames, code, message);
  fclose(f);
  rename(tmp, report_path);
}

/* record --geometry WxH+X+Y --fps F --report FILE -- ARGV...
 * Runs ARGV (an encoder reading raw RGB24 frames of WxH on its standard
 * input) and feeds it one XGetImage grab every 1/F seconds until SIGINT or
 * SIGTERM, then closes its input and waits for it to finish the file. The
 * encoder dies with this process (PR_SET_PDEATHSIG), so a recorder killed
 * outright leaves an unfinished file, never a finished one. FILE gets
 * `state=recording|stopped|failed`, `pid`, `child`, `frames`, `code` and
 * `message` lines, rewritten whole. */
static int record(Display *d, int argc, char **argv) {
  int w = 0, h = 0, x = 0, y = 0, have = 0, sep = -1;
  double fps = 0;
  for (int i = 2; i < argc; i++) {
    if (strcmp(argv[i], "--geometry") == 0 && i + 1 < argc)
      have = parse_geometry(argv[++i], &w, &h, &x, &y);
    else if (strcmp(argv[i], "--fps") == 0 && i + 1 < argc)
      fps = atof(argv[++i]);
    else if (strcmp(argv[i], "--report") == 0 && i + 1 < argc)
      report_path = argv[++i];
    else if (strcmp(argv[i], "--") == 0) {
      sep = i;
      break;
    } else {
      fprintf(stderr, "x11_probe record: unknown argument %s\n", argv[i]);
      return 2;
    }
  }
  if (!have || fps <= 0 || fps > 240 || !report_path || sep < 0 || sep + 1 >= argc) {
    fprintf(stderr, "x11_probe record: --geometry, --fps (0, 240], --report and "
                    "-- ARGV are required\n");
    return 2;
  }
  size_t frame_bytes = (size_t)w * h * 3;
  unsigned char *px = malloc(frame_bytes);
  if (!px || !grab_rgb(d, x, y, w, h, px)) {
    write_report("failed", -1, 0, 4, "XGetImage failed (is the rectangle on the screen?)");
    return 4;
  }
  int pipefd[2];
  if (pipe(pipefd) < 0) {
    write_report("failed", -1, 0, 5, "pipe failed");
    return 5;
  }
  signal(SIGTERM, on_term);
  signal(SIGINT, on_term);
  signal(SIGPIPE, SIG_IGN);
  pid_t parent = getpid();
  pid_t child = fork();
  if (child < 0) {
    write_report("failed", -1, 0, 5, "fork failed");
    return 5;
  }
  if (child == 0) {
    prctl(PR_SET_PDEATHSIG, SIGKILL);
    if (getppid() != parent)
      _exit(127);
    signal(SIGTERM, SIG_DFL);
    signal(SIGINT, SIG_IGN); /* the encoder stops at end of input */
    dup2(pipefd[0], 0);
    close(pipefd[0]);
    close(pipefd[1]);
    execvp(argv[sep + 1], argv + sep + 1);
    fprintf(stderr, "x11_probe record: cannot run %s\n", argv[sep + 1]);
    _exit(127);
  }
  close(pipefd[0]);
  long frames = 0;
  int failed = 0;
  struct timespec start, now;
  clock_gettime(CLOCK_MONOTONIC, &start);
  write_report("recording", child, frames, 0, "");
  while (!stop_requested) {
    if (frames > 0 && !grab_rgb(d, x, y, w, h, px)) {
      failed = 1;
      break;
    }
    size_t done = 0;
    while (done < frame_bytes) {
      ssize_t n = write(pipefd[1], px + done, frame_bytes - done);
      if (n < 0 && errno == EINTR)
        continue;
      if (n <= 0) {
        failed = 2;
        break;
      }
      done += (size_t)n;
    }
    if (failed)
      break;
    frames++;
    if (frames % 10 == 0)
      write_report("recording", child, frames, 0, "");
    /* Sleep until the next frame's time on the monotonic clock. */
    double next = frames / fps;
    for (;;) {
      clock_gettime(CLOCK_MONOTONIC, &now);
      double elapsed = (now.tv_sec - start.tv_sec) + (now.tv_nsec - start.tv_nsec) / 1e9;
      if (elapsed >= next || stop_requested)
        break;
      double left = next - elapsed;
      struct timespec ts = {(time_t)left, (long)((left - (time_t)left) * 1e9)};
      nanosleep(&ts, NULL);
    }
  }
  close(pipefd[1]);
  int status = 0;
  while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
  }
  int code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
  if (failed || code != 0) {
    char msg[160];
    snprintf(msg, sizeof msg, failed == 1 ? "XGetImage failed while recording"
                              : failed == 2 ? "the encoder stopped reading frames"
                                            : "the encoder exited with status %d", code);
    write_report("failed", child, frames, code ? code : 5, msg);
    return 6;
  }
  write_report("stopped", child, frames, 0, "");
  return 0;
}

int main(int argc, char **argv) {
  const char *modes[] = {"list", "window", "grab", "record"};
  int mode = -1;
  for (int i = 0; argc >= 2 && i < 4; i++)
    if (strcmp(argv[1], modes[i]) == 0)
      mode = i;
  if (mode < 0) {
    fprintf(stderr, "usage: %s list | window --geometry WxH+X+Y (--rgb RRGGBB | --image PPM) "
                    "[--title T] [--class C] [--hold MS] | grab --geometry WxH+X+Y "
                    "--out FILE | record --geometry WxH+X+Y --fps F --report FILE "
                    "-- ARGV...\n", argv[0]);
    return 2;
  }
  Display *d = XOpenDisplay(NULL);
  if (!d) {
    fprintf(stderr, "x11_probe: cannot open the X display\n");
    if (mode == 3 && argc > 2) {
      for (int i = 2; i + 1 < argc; i++)
        if (strcmp(argv[i], "--report") == 0) {
          report_path = argv[i + 1];
          write_report("failed", -1, 0, 3, "cannot open the X display");
        }
    }
    return 3;
  }
  XSetErrorHandler(ignore_errors);
  a_wm_state = XInternAtom(d, "WM_STATE", False);
  a_net_wm_pid = XInternAtom(d, "_NET_WM_PID", False);
  a_net_wm_name = XInternAtom(d, "_NET_WM_NAME", False);
  a_utf8 = XInternAtom(d, "UTF8_STRING", False);
  a_net_check = XInternAtom(d, "_NET_SUPPORTING_WM_CHECK", False);
  int rc;
  switch (mode) {
  case 0:
    rc = list(d);
    break;
  case 1:
    return open_window(d, argc, argv);
  case 2:
    rc = grab(d, argc, argv);
    break;
  default:
    rc = record(d, argc, argv);
    break;
  }
  XCloseDisplay(d);
  return rc;
}
