/*
 * wlr_screencopy.c — record one output (or a rectangle of it) of a wlroots
 * compositor through wlr-screencopy, at a constant rate, into an encoder.
 *
 * GuiAssert's `linux-wlr` capture backend records with this helper.
 *
 *   wlr_screencopy record --output NAME [--region X,Y,W,H] --fps F
 *                         --report FILE -- ENCODER...
 *
 * NAME is the wl_output's name (wl_output version 4, the name sway's IPC
 * reports); the region is in the output's own logical coordinates
 * (https://wayland.app/protocols/wlr-screencopy-unstable-v1#zwlr_screencopy_manager_v1:request:capture_output_region).
 * ENCODER runs as a child, with `%W%` and `%H%` in its arguments replaced by
 * the frame size in pixels; it reads raw RGB24 frames on its standard input.
 *
 * Frame k is copied from the compositor at k/F seconds after the first, on
 * the monotonic clock, and written to the encoder before frame k+1 is
 * copied. Each copy uses `copy` (not `copy_with_damage`), which the
 * compositor answers at its next output commit whether or not anything
 * changed, so a still screen still yields frames. When the encoder reads
 * slowly the write blocks and the copies that follow are made back to back
 * until the schedule is met again: frames are never dropped and never
 * queued unboundedly. On SIGINT or SIGTERM the helper stops copying, closes
 * the encoder's input and waits for the encoder to encode every frame it was
 * given and finish the file. The encoder dies with this process
 * (PR_SET_PDEATHSIG), so a helper killed outright leaves an unfinished file,
 * never a finished one.
 *
 * Why not wf-recorder: it encodes on a second thread from a pool of 16
 * captured frames, stops copying while the pool is full, and on SIGINT ends
 * that thread without encoding the frames still in the pool. An encoder
 * latency spike longer than the rest of the recording (measured on a loaded
 * host: libx264 inside it busy on one frame for over a second) then leaves a
 * file of one or two frames however long the recording ran.
 *
 * FILE receives `key=value` lines, rewritten whole (write then rename):
 *   state=starting|recording|stopped|failed
 *   frameWidth=W  frameHeight=H   (the frames, pixels)
 *   frames=N      frames written to the encoder
 *   pid=P  child=C  code=N  message=TEXT
 * `recording` is written once the first frame has been copied and the
 * encoder runs.
 *
 * Exit status: 0 success; 2 usage; 4 no compositor, no wlr-screencopy or no
 * such output; 5 a copy failed; 6 the encoder failed.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

#include "wlr-screencopy-unstable-v1-client-protocol.h"

/* --- report --------------------------------------------------------------- */

static const char *report_path;
static long frame_w, frame_h, frames, child_pid = -1;

static void report(const char *state, int code, const char *message) {
  char tmp[4096];
  snprintf(tmp, sizeof tmp, "%s.tmp", report_path);
  FILE *f = fopen(tmp, "w");
  if (!f)
    return;
  fprintf(f, "state=%s\npid=%ld\nchild=%ld\nframeWidth=%ld\nframeHeight=%ld\nframes=%ld\n"
             "code=%d\nmessage=%s\n",
          state, (long)getpid(), child_pid, frame_w, frame_h, frames, code, message);
  if (fclose(f) == 0)
    rename(tmp, report_path);
}

static volatile sig_atomic_t stop_requested;
static void on_term(int sig) {
  (void)sig;
  stop_requested = 1;
}

/* --- the compositor's globals ------------------------------------------- */

#define MAX_OUTPUTS 16
struct output {
  struct wl_output *wl;
  char name[128];
};

static struct wl_shm *shm;
static struct zwlr_screencopy_manager_v1 *manager;
static uint32_t manager_version;
static struct output outputs[MAX_OUTPUTS];
static int n_outputs;

static void output_geometry(void *data, struct wl_output *o, int32_t x, int32_t y, int32_t pw,
                            int32_t ph, int32_t subpixel, const char *make, const char *model,
                            int32_t transform) {
  (void)data, (void)o, (void)x, (void)y, (void)pw, (void)ph, (void)subpixel, (void)make,
      (void)model, (void)transform;
}
static void output_mode(void *data, struct wl_output *o, uint32_t flags, int32_t w, int32_t h,
                        int32_t refresh) {
  (void)data, (void)o, (void)flags, (void)w, (void)h, (void)refresh;
}
static void output_done(void *data, struct wl_output *o) { (void)data, (void)o; }
static void output_scale(void *data, struct wl_output *o, int32_t f) { (void)data, (void)o, (void)f; }
static void output_name(void *data, struct wl_output *o, const char *name) {
  (void)o;
  struct output *out = data;
  snprintf(out->name, sizeof out->name, "%s", name);
}
static void output_description(void *data, struct wl_output *o, const char *d) {
  (void)data, (void)o, (void)d;
}
static const struct wl_output_listener output_listener = {
    .geometry = output_geometry,
    .mode = output_mode,
    .done = output_done,
    .scale = output_scale,
    .name = output_name,
    .description = output_description,
};

static void global(void *data, struct wl_registry *r, uint32_t id, const char *iface,
                   uint32_t version) {
  (void)data;
  if (strcmp(iface, wl_shm_interface.name) == 0) {
    shm = wl_registry_bind(r, id, &wl_shm_interface, 1);
  } else if (strcmp(iface, zwlr_screencopy_manager_v1_interface.name) == 0) {
    manager_version = version < 3 ? version : 3;
    manager = wl_registry_bind(r, id, &zwlr_screencopy_manager_v1_interface, manager_version);
  } else if (strcmp(iface, wl_output_interface.name) == 0 && version >= 4 &&
             n_outputs < MAX_OUTPUTS) {
    /* The name event exists from version 4 on. */
    struct output *o = &outputs[n_outputs++];
    o->wl = wl_registry_bind(r, id, &wl_output_interface, 4);
    wl_output_add_listener(o->wl, &output_listener, o);
  }
}
static void global_remove(void *data, struct wl_registry *r, uint32_t id) {
  (void)data, (void)r, (void)id;
}
static const struct wl_registry_listener registry_listener = {global, global_remove};

/* --- one copy ------------------------------------------------------------- */

/* The shared-memory buffer the compositor copies into, reused while the
 * frame's format and size stay the same. */
struct shm_buffer {
  struct wl_buffer *wl;
  void *data;
  size_t size;
  uint32_t format;
  int width, height, stride;
};

struct copy {
  struct shm_buffer *buf;
  uint32_t format;
  int width, height, stride;
  int have_buffer; /* a wl_shm `buffer` event arrived */
  int copy_sent;
  int done;        /* 1 ready, -1 failed */
  int y_invert;
};

static int make_buffer(struct shm_buffer *b, uint32_t format, int w, int h, int stride) {
  if (b->wl && b->format == format && b->width == w && b->height == h && b->stride == stride)
    return 1;
  if (b->wl) {
    wl_buffer_destroy(b->wl);
    munmap(b->data, b->size);
    b->wl = NULL;
  }
  size_t size = (size_t)stride * h;
  int fd = memfd_create("guiassert-wlr-screencopy", MFD_CLOEXEC);
  if (fd < 0)
    return 0;
  if (ftruncate(fd, (off_t)size) < 0) {
    close(fd);
    return 0;
  }
  void *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (data == MAP_FAILED) {
    close(fd);
    return 0;
  }
  struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
  b->wl = wl_shm_pool_create_buffer(pool, 0, w, h, stride, format);
  wl_shm_pool_destroy(pool);
  close(fd);
  b->data = data;
  b->size = size;
  b->format = format;
  b->width = w;
  b->height = h;
  b->stride = stride;
  return 1;
}

static void send_copy(struct zwlr_screencopy_frame_v1 *frame, struct copy *c) {
  if (c->copy_sent || !c->have_buffer)
    return;
  if (!make_buffer(c->buf, c->format, c->width, c->height, c->stride)) {
    c->done = -1;
    return;
  }
  zwlr_screencopy_frame_v1_copy(frame, c->buf->wl);
  c->copy_sent = 1;
}

static void frame_buffer(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t format,
                         uint32_t w, uint32_t h, uint32_t stride) {
  struct copy *c = data;
  c->format = format;
  c->width = (int)w;
  c->height = (int)h;
  c->stride = (int)stride;
  c->have_buffer = 1;
  /* Before version 3 the shm `buffer` event is the only one: copy now.
   * From version 3 on, wait for `buffer_done` (every offer has been made). */
  if (manager_version < 3)
    send_copy(frame, c);
}
static void frame_flags(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t flags) {
  (void)frame;
  ((struct copy *)data)->y_invert = (flags & ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT) != 0;
}
static void frame_ready(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t hi,
                        uint32_t lo, uint32_t ns) {
  (void)frame, (void)hi, (void)lo, (void)ns;
  ((struct copy *)data)->done = 1;
}
static void frame_failed(void *data, struct zwlr_screencopy_frame_v1 *frame) {
  (void)frame;
  ((struct copy *)data)->done = -1;
}
static void frame_damage(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t x,
                         uint32_t y, uint32_t w, uint32_t h) {
  (void)data, (void)frame, (void)x, (void)y, (void)w, (void)h;
}
static void frame_dmabuf(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t format,
                         uint32_t w, uint32_t h) {
  (void)data, (void)frame, (void)format, (void)w, (void)h; /* shm only */
}
static void frame_buffer_done(void *data, struct zwlr_screencopy_frame_v1 *frame) {
  struct copy *c = data;
  if (!c->have_buffer)
    c->done = -1; /* no shared-memory buffer offered */
  else
    send_copy(frame, c);
}
static const struct zwlr_screencopy_frame_v1_listener frame_listener = {
    .buffer = frame_buffer,
    .flags = frame_flags,
    .ready = frame_ready,
    .failed = frame_failed,
    .damage = frame_damage,
    .linux_dmabuf = frame_dmabuf,
    .buffer_done = frame_buffer_done,
};

/* Dispatch until `c` is done, the connection breaks (-1) or a stop is
 * requested (0, with `c` not done). Polls in 100 ms steps so a stop is seen
 * even while the compositor sends nothing. */
static int wait_copy(struct wl_display *d, struct copy *c) {
  while (!c->done) {
    while (wl_display_prepare_read(d) != 0) {
      if (wl_display_dispatch_pending(d) < 0)
        return -1;
      if (c->done)
        return 1;
    }
    if (wl_display_flush(d) < 0 && errno != EAGAIN) {
      wl_display_cancel_read(d);
      return -1;
    }
    struct pollfd p = {wl_display_get_fd(d), POLLIN, 0};
    int n = poll(&p, 1, 100);
    if (n <= 0) {
      wl_display_cancel_read(d);
      if (n < 0 && errno != EINTR)
        return -1;
      if (stop_requested)
        return 0;
      continue;
    }
    if (wl_display_read_events(d) < 0 || wl_display_dispatch_pending(d) < 0)
      return -1;
  }
  return 1;
}

/* Copy one frame of the output (or the region of it) into `buf`: 1 done,
 * 0 stopped before it was, -1 failed, -2 the connection broke. */
static int copy_frame(struct wl_display *d, struct wl_output *o, const int *region,
                      struct shm_buffer *buf, struct copy *out) {
  struct copy c = {.buf = buf};
  struct zwlr_screencopy_frame_v1 *frame =
      region ? zwlr_screencopy_manager_v1_capture_output_region(manager, 1, o, region[0],
                                                                 region[1], region[2], region[3])
             : zwlr_screencopy_manager_v1_capture_output(manager, 1, o);
  zwlr_screencopy_frame_v1_add_listener(frame, &frame_listener, &c);
  int r = wait_copy(d, &c);
  zwlr_screencopy_frame_v1_destroy(frame);
  *out = c;
  if (r < 0)
    return -2;
  if (r == 0)
    return 0;
  return c.done == 1 ? 1 : -1;
}

/* The copied frame as packed RGB24 (top row first) in `px`; 0 for a pixel
 * format this helper does not read. wl_shm formats are little-endian
 * (https://wayland.app/protocols/wayland#wl_shm:enum:format): XRGB8888 is
 * the bytes B, G, R, X in memory; XBGR8888 is R, G, B, X. */
static int to_rgb(const struct copy *c, unsigned char *px) {
  int ri, gi, bi;
  switch (c->format) {
  case WL_SHM_FORMAT_XRGB8888:
  case WL_SHM_FORMAT_ARGB8888:
    ri = 2, gi = 1, bi = 0;
    break;
  case WL_SHM_FORMAT_XBGR8888:
  case WL_SHM_FORMAT_ABGR8888:
    ri = 0, gi = 1, bi = 2;
    break;
  default:
    return 0;
  }
  /* The compositor chose the size and the stride: every row read must lie
   * inside the buffer it was copied into. */
  if (c->width <= 0 || c->height <= 0 || c->stride < c->width * 4 ||
      (size_t)c->stride * c->height > c->buf->size)
    return 0;
  for (int row = 0; row < c->height; row++) {
    int src_row = c->y_invert ? c->height - 1 - row : row;
    const unsigned char *s = (const unsigned char *)c->buf->data + (size_t)src_row * c->stride;
    unsigned char *o = px + (size_t)row * c->width * 3;
    for (int col = 0; col < c->width; col++, s += 4, o += 3) {
      o[0] = s[ri];
      o[1] = s[gi];
      o[2] = s[bi];
    }
  }
  return 1;
}

/* --- the encoder ---------------------------------------------------------- */

/* ARGV with %W% and %H% replaced by the frame size. */
static char **encoder_argv(char **argv, int w, int h) {
  int n = 0;
  while (argv[n])
    n++;
  char **out = calloc((size_t)n + 1, sizeof *out);
  if (!out)
    return NULL;
  for (int i = 0; i < n; i++) {
    const char *a = argv[i];
    size_t cap = strlen(a) + 64;
    char *s = malloc(cap);
    if (!s)
      return NULL;
    size_t len = 0;
    while (*a) {
      if (strncmp(a, "%W%", 3) == 0 || strncmp(a, "%H%", 3) == 0) {
        len += (size_t)snprintf(s + len, cap - len, "%d", a[1] == 'W' ? w : h);
        a += 3;
      } else {
        s[len++] = *a++;
      }
      if (len + 16 >= cap) {
        cap *= 2;
        char *grown = realloc(s, cap);
        if (!grown)
          return NULL;
        s = grown;
      }
    }
    s[len] = 0;
    out[i] = s;
  }
  return out;
}

static int write_all(int fd, const unsigned char *p, size_t n) {
  size_t done = 0;
  while (done < n) {
    ssize_t k = write(fd, p + done, n - done);
    if (k < 0 && errno == EINTR)
      continue;
    if (k <= 0)
      return 0;
    done += (size_t)k;
  }
  return 1;
}

static double seconds_since(const struct timespec *t0) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (now.tv_sec - t0->tv_sec) + (now.tv_nsec - t0->tv_nsec) / 1e9;
}

/* --- record ----------------------------------------------------------------- */

static int usage(void) {
  fprintf(stderr, "usage: wlr_screencopy record --output NAME [--region X,Y,W,H] --fps F "
                  "--report FILE -- ENCODER...\n");
  return 2;
}

static int record(int argc, char **argv) {
  const char *name = NULL;
  int region[4], have_region = 0, sep = -1;
  double fps = 0;
  for (int i = 2; i < argc; i++) {
    if (strcmp(argv[i], "--output") == 0 && i + 1 < argc)
      name = argv[++i];
    else if (strcmp(argv[i], "--region") == 0 && i + 1 < argc) {
      /* A malformed region is a usage error, never the whole output. */
      char tail;
      if (sscanf(argv[++i], "%d,%d,%d,%d%c", &region[0], &region[1], &region[2], &region[3],
                 &tail) != 4 ||
          region[2] <= 0 || region[3] <= 0)
        return usage();
      have_region = 1;
    }
    else if (strcmp(argv[i], "--fps") == 0 && i + 1 < argc)
      fps = atof(argv[++i]);
    else if (strcmp(argv[i], "--report") == 0 && i + 1 < argc)
      report_path = argv[++i];
    else if (strcmp(argv[i], "--") == 0) {
      sep = i;
      break;
    } else
      return usage();
  }
  if (!name || fps <= 0 || fps > 240 || !report_path || sep < 0 || sep + 1 >= argc)
    return usage();

  struct sigaction sa = {0};
  sa.sa_handler = on_term; /* no SA_RESTART: a blocked write or poll returns */
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGTERM, &sa, NULL);
  signal(SIGPIPE, SIG_IGN);
  report("starting", 0, "");

  struct wl_display *d = wl_display_connect(NULL);
  if (!d) {
    report("failed", 4, "cannot connect to the Wayland display (WAYLAND_DISPLAY)");
    return 4;
  }
  struct wl_registry *reg = wl_display_get_registry(d);
  wl_registry_add_listener(reg, &registry_listener, NULL);
  /* Globals, then each output's events (its name). */
  if (wl_display_roundtrip(d) < 0 || wl_display_roundtrip(d) < 0) {
    report("failed", 4, "the Wayland display did not answer");
    return 4;
  }
  if (!manager || !shm) {
    report("failed", 4, "the compositor offers no wlr-screencopy (or no wl_shm)");
    return 4;
  }
  struct wl_output *output = NULL;
  for (int i = 0; i < n_outputs; i++)
    if (strcmp(outputs[i].name, name) == 0)
      output = outputs[i].wl;
  if (!output) {
    char msg[256];
    snprintf(msg, sizeof msg, "no wl_output named %.128s (wl_output version 4 names them)", name);
    report("failed", 4, msg);
    return 4;
  }

  /* The first frame fixes the size the encoder is told. */
  struct shm_buffer buf = {0};
  struct copy c;
  int r = copy_frame(d, output, have_region ? region : NULL, &buf, &c);
  if (r != 1) {
    report("failed", 5, r == 0 ? "stopped before the first frame was copied"
                               : "the compositor failed the first copy");
    return 5;
  }
  frame_w = c.width;
  frame_h = c.height;
  size_t frame_bytes = (size_t)c.width * c.height * 3;
  unsigned char *px = malloc(frame_bytes);
  if (!px || !to_rgb(&c, px)) {
    char msg[128];
    snprintf(msg, sizeof msg, "unsupported frame (pixel format 0x%08x, %dx%d, stride %d)",
             c.format, c.width, c.height, c.stride);
    report("failed", 5, msg);
    return 5;
  }

  char **enc = encoder_argv(argv + sep + 1, c.width, c.height);
  int pipefd[2];
  if (!enc || pipe2(pipefd, O_CLOEXEC) < 0) {
    report("failed", 5, "cannot prepare the encoder");
    return 5;
  }
  pid_t parent = getpid();
  pid_t child = fork();
  if (child < 0) {
    report("failed", 5, "fork failed");
    return 5;
  }
  if (child == 0) {
    prctl(PR_SET_PDEATHSIG, SIGKILL);
    if (getppid() != parent)
      _exit(127);
    signal(SIGTERM, SIG_DFL);
    signal(SIGINT, SIG_IGN); /* the encoder stops at the end of its input */
    signal(SIGPIPE, SIG_DFL);
    dup2(pipefd[0], 0);
    execvp(enc[0], enc);
    fprintf(stderr, "wlr_screencopy: cannot run %s\n", enc[0]);
    _exit(127);
  }
  close(pipefd[0]);
  child_pid = child;

  int failed = 0; /* 1 copy failed, 2 encoder stopped reading, 3 size changed, 4 format */
  struct timespec start;
  clock_gettime(CLOCK_MONOTONIC, &start);
  report("recording", 0, "");
  for (;;) {
    if (!write_all(pipefd[1], px, frame_bytes)) {
      if (!stop_requested)
        failed = 2;
      break;
    }
    frames++;
    if (frames % 10 == 0)
      report("recording", 0, "");
    /* Sleep until frame `frames` is due; when late, copy at once. */
    double next = frames / fps;
    while (!stop_requested) {
      double left = next - seconds_since(&start);
      if (left <= 0)
        break;
      struct timespec ts = {(time_t)left, (long)((left - (time_t)left) * 1e9)};
      nanosleep(&ts, NULL);
    }
    if (stop_requested)
      break;
    /* A copy the compositor answers `failed` (wlroots does when it could
     * not render the frame, e.g. while the output is reconfigured) is
     * retried a few times before the recording fails; a retried copy still
     * yields this frame, so the count stays one per 1/fps. */
    int tries = 0;
    do {
      r = copy_frame(d, output, have_region ? region : NULL, &buf, &c);
    } while (r == -1 && ++tries < 5 && !stop_requested);
    if (r == 0)
      break;
    if (r < 0) {
      failed = 1;
      break;
    }
    if (c.width != frame_w || c.height != frame_h) {
      failed = 3;
      break;
    }
    if (!to_rgb(&c, px)) {
      failed = 4;
      break;
    }
  }
  close(pipefd[1]);
  int status = 0;
  while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
  }
  int code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
  if (failed || code != 0) {
    char msg[160];
    snprintf(msg, sizeof msg,
             failed == 1   ? "the compositor failed a copy while recording"
             : failed == 2 ? "the encoder stopped reading frames"
             : failed == 3 ? "the output's size changed while recording"
             : failed == 4 ? "a copied frame has a pixel format or layout this helper cannot read"
                           : "the encoder exited with status %d",
             code);
    report("failed", code ? code : 5, msg);
    return failed == 1 || failed == 3 || failed == 4 ? 5 : 6;
  }
  report("stopped", 0, "");
  return 0;
}

int main(int argc, char **argv) {
  if (argc >= 2 && strcmp(argv[1], "record") == 0)
    return record(argc, argv);
  return usage();
}
