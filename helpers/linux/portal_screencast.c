/*
 * portal_screencast.c — open an xdg-desktop-portal ScreenCast session of one
 * monitor and read its PipeWire stream: one frame (a still), or frames at a
 * constant rate into an encoder (a recording).
 *
 * GuiAssert's `linux-portal-pipewire` capture backend uses it for compositors
 * that offer screen capture only through the portal. The portal is the
 * consent point: whatever chooser or dialog the portal backend shows is
 * shown, and this helper waits for the user's answer (it never bypasses it).
 *
 *   portal_screencast --report FILE [--cursor] [--timeout-ms N] --still OUT.ppm
 *   portal_screencast --report FILE [--cursor] [--timeout-ms N] --fps F -- ENCODER...
 *
 * The portal steps (https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html):
 * CreateSession, SelectSources (one monitor; the cursor embedded with
 * --cursor, hidden otherwise, when the portal offers the mode), Start, and
 * OpenPipeWireRemote, which hands over a file descriptor of a PipeWire
 * connection that can see the stream's node. Each portal request is answered
 * by a `Response` signal on its request object
 * (https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Request.html),
 * subscribed to before the call is made. The portal session lives as long
 * as this process's bus connection.
 *
 * The stream is consumed here with libpipewire, on the portal's descriptor
 * (https://docs.pipewire.org/page_tutorial5.html): raw video in a 32-bit
 * RGB layout, mapped shared memory, and every buffer returned to the stream
 * the moment its pixels are copied out, so the producer never runs out.
 * (A GStreamer consumer was tried first: its start-up pause and resume left
 * xdg-desktop-portal-wlr 0.8 believing every buffer was still in flight,
 * after which the stream delivered nothing, in about one session in three.)
 *
 * --still writes the first frame as a binary PPM
 * (https://netpbm.sourceforge.net/doc/ppm.html). --fps runs ENCODER as a
 * child, with `%W%` and `%H%` in its arguments replaced by the frame size,
 * and writes the latest frame as raw RGB24 to its standard input every 1/F
 * seconds from the first frame on (a frame is repeated while the screen does
 * not change: a portal sends frames only on damage), until SIGINT or
 * SIGTERM; then it closes the encoder's input and waits for it to finish
 * the file. The encoder dies with this process (PR_SET_PDEATHSIG).
 *
 * FILE receives `key=value` lines, rewritten whole (write then rename):
 *   state=starting|streaming|stopped|failed|denied
 *   node=N  x=X  y=Y  width=W  height=H   (the stream's monitor, logical px)
 *   frameWidth=W  frameHeight=H           (the frames, pixels)
 *   frames=N       frames written to the encoder
 *   pid=P          this helper's pid
 *   child=C        the encoder's pid, once it runs
 *   code=N         the encoder's exit status, or this helper's
 *   message=TEXT   why it failed (names portal calls and codes only)
 * `streaming` is written once the first frame has arrived.
 *
 * Exit status: 0 success; 2 usage; 3 no portal or no ScreenCast interface;
 * 4 the user or the portal refused (Response 1); 5 any other portal or
 * stream failure; 6 the encoder failed; 7 timeout.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <pipewire/pipewire.h>
#include <pthread.h>
#include <signal.h>
#include <spa/param/video/format-utils.h>
#include <spa/param/video/type-info.h>
#include <spa/param/buffers.h>
#include <spa/utils/result.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define PORTAL_BUS "org.freedesktop.portal.Desktop"
#define PORTAL_PATH "/org/freedesktop/portal/desktop"
#define SCREENCAST "org.freedesktop.portal.ScreenCast"

static const char *report_path;
static char st_state[32] = "starting", st_message[512] = "";
static long st_node = -1, st_child = -1, st_code = 0, st_frames = 0;
static int st_x, st_y, st_w, st_h, st_fw, st_fh;

static void write_report(void) {
  if (!report_path)
    return;
  char tmp[4096];
  snprintf(tmp, sizeof tmp, "%s.tmp", report_path);
  FILE *f = fopen(tmp, "w");
  if (!f)
    return;
  fprintf(f, "state=%s\npid=%ld\nnode=%ld\nx=%d\ny=%d\nwidth=%d\nheight=%d\n"
             "frameWidth=%d\nframeHeight=%d\nframes=%ld\nchild=%ld\ncode=%ld\nmessage=%s\n",
          st_state, (long)getpid(), st_node, st_x, st_y, st_w, st_h, st_fw, st_fh,
          st_frames, st_child, st_code, st_message);
  fclose(f);
  rename(tmp, report_path);
}

static int fail(const char *state, int code, const char *msg) {
  snprintf(st_state, sizeof st_state, "%s", state);
  snprintf(st_message, sizeof st_message, "%s", msg);
  st_code = code;
  write_report();
  fprintf(stderr, "portal_screencast: %s\n", msg);
  return code;
}

/* --- one portal request and its Response ---------------------------------- */

typedef struct {
  GMainLoop *loop;
  guint32 response;
  GVariant *results;
  int done;
} Pending;

static void on_response(GDBusConnection *c, const gchar *sender,
                        const gchar *path, const gchar *iface,
                        const gchar *signal, GVariant *params, gpointer data) {
  (void)c;
  (void)sender;
  (void)path;
  (void)iface;
  (void)signal;
  Pending *p = data;
  g_variant_get(params, "(u@a{sv})", &p->response, &p->results);
  p->done = 1;
  g_main_loop_quit(p->loop);
}

static gboolean on_timeout(gpointer data) {
  Pending *p = data;
  g_main_loop_quit(p->loop);
  return G_SOURCE_REMOVE;
}

static char *sender_token(GDBusConnection *conn) {
  /* ":1.42" -> "1_42", as the Request object path spells the sender. */
  char *s = g_strdup(g_dbus_connection_get_unique_name(conn) + 1);
  for (char *q = s; *q; q++)
    if (*q == '.')
      *q = '_';
  return s;
}

static int counter;

/* Call `method` with `args` (whose a{sv} must carry handle_token =
 * `token`), wait for the Response. Returns the portal's response code
 * (0 success, 1 cancelled by the user, 2 other), or -1 for a D-Bus error,
 * -2 for a timeout. */
static int request(GDBusConnection *conn, const char *method, GVariant *args,
                   const char *token, int timeout_ms, GVariant **results,
                   char *err, size_t errlen) {
  char *sender = sender_token(conn);
  char *path = g_strdup_printf(PORTAL_PATH "/request/%s/%s", sender, token);
  g_free(sender);
  Pending p = {g_main_loop_new(NULL, FALSE), 2, NULL, 0};
  guint sub = g_dbus_connection_signal_subscribe(
      conn, NULL, "org.freedesktop.portal.Request", "Response", path,
      NULL, G_DBUS_SIGNAL_FLAGS_NONE, on_response, &p, NULL);
  GError *e = NULL;
  GVariant *ret = g_dbus_connection_call_sync(
      conn, PORTAL_BUS, PORTAL_PATH, SCREENCAST, method, args,
      G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, timeout_ms, NULL, &e);
  if (!ret) {
    snprintf(err, errlen, "%s: %s", method, e->message);
    g_error_free(e);
    g_dbus_connection_signal_unsubscribe(conn, sub);
    g_main_loop_unref(p.loop);
    g_free(path);
    return -1;
  }
  g_variant_unref(ret);
  guint timer = g_timeout_add(timeout_ms, on_timeout, &p);
  if (!p.done)
    g_main_loop_run(p.loop);
  if (p.done)
    g_source_remove(timer);
  g_dbus_connection_signal_unsubscribe(conn, sub);
  g_main_loop_unref(p.loop);
  g_free(path);
  if (!p.done) {
    snprintf(err, errlen, "%s: no response within %d ms", method, timeout_ms);
    return -2;
  }
  *results = p.results;
  if (p.response != 0)
    snprintf(err, errlen, "%s: the portal answered %u", method, p.response);
  return (int)p.response;
}

static char *next_token(void) {
  return g_strdup_printf("guiassert%d_%d", (int)getpid(), ++counter);
}


/* --- the PipeWire stream -------------------------------------------------- */

static volatile sig_atomic_t stop_requested;

static void on_signal(int sig) {
  (void)sig;
  stop_requested = 1;
}

typedef struct {
  struct pw_thread_loop *loop;
  struct pw_stream *stream;
  struct spa_hook listener;
  struct spa_video_info_raw info;
  int have_format;
  /* The latest frame as RGB24, under `lock`. */
  pthread_mutex_t lock;
  unsigned char *rgb;
  int width, height;
  long received;
  int size_changed;
} Consumer;

/* Byte offsets of red, green and blue in a 4-byte pixel of `fmt`, or -1. */
static int channel_offsets(uint32_t fmt, int *r, int *g, int *b) {
  switch (fmt) {
  case SPA_VIDEO_FORMAT_BGRx: case SPA_VIDEO_FORMAT_BGRA:
    *b = 0; *g = 1; *r = 2; return 0;
  case SPA_VIDEO_FORMAT_RGBx: case SPA_VIDEO_FORMAT_RGBA:
    *r = 0; *g = 1; *b = 2; return 0;
  case SPA_VIDEO_FORMAT_xRGB: case SPA_VIDEO_FORMAT_ARGB:
    *r = 1; *g = 2; *b = 3; return 0;
  case SPA_VIDEO_FORMAT_xBGR: case SPA_VIDEO_FORMAT_ABGR:
    *b = 1; *g = 2; *r = 3; return 0;
  default:
    return -1;
  }
}

static void on_param_changed(void *data, uint32_t id, const struct spa_pod *param) {
  Consumer *c = data;
  if (param == NULL || id != SPA_PARAM_Format)
    return;
  uint32_t media_type, media_subtype;
  if (spa_format_parse(param, &media_type, &media_subtype) < 0 ||
      media_type != SPA_MEDIA_TYPE_video || media_subtype != SPA_MEDIA_SUBTYPE_raw)
    return;
  if (spa_format_video_raw_parse(param, &c->info) < 0)
    return;
  c->have_format = 1;
  /* Ask for buffers in memory this process can map. */
  uint8_t buf[1024];
  struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof buf);
  const struct spa_pod *params[1];
  params[0] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
      SPA_PARAM_BUFFERS_dataType,
      SPA_POD_CHOICE_FLAGS_Int((1 << SPA_DATA_MemFd) | (1 << SPA_DATA_MemPtr)));
  pw_stream_update_params(c->stream, params, 1);
}

static void on_process(void *data) {
  Consumer *c = data;
  struct pw_buffer *pb = pw_stream_dequeue_buffer(c->stream);
  if (!pb)
    return;
  struct spa_buffer *sb = pb->buffer;
  struct spa_data *d = &sb->datas[0];
  int r, g, bl;
  if (c->have_format && d->data && d->chunk && d->chunk->size > 0 &&
      channel_offsets(c->info.format, &r, &g, &bl) == 0) {
    int w = (int)c->info.size.width, h = (int)c->info.size.height;
    int stride = d->chunk->stride > 0 ? d->chunk->stride : w * 4;
    const unsigned char *src = (const unsigned char *)d->data + d->chunk->offset;
    /* Copy only a buffer that holds every row the format promises: a row is
     * at least w 4-byte pixels, and offset + h rows lie within the mapping. */
    if (w > 0 && h > 0 && stride >= w * 4 && d->chunk->offset <= d->maxsize &&
        (size_t)stride * h <= d->maxsize - d->chunk->offset) {
      pthread_mutex_lock(&c->lock);
      if (c->rgb && (w != c->width || h != c->height)) {
        c->size_changed = 1;
      } else {
        if (!c->rgb) {
          c->rgb = malloc((size_t)w * h * 3);
          c->width = w;
          c->height = h;
        }
        if (c->rgb) {
          for (int y = 0; y < h; y++) {
            const unsigned char *s = src + (size_t)y * stride;
            unsigned char *o = c->rgb + (size_t)y * w * 3;
            for (int x = 0; x < w; x++, s += 4, o += 3) {
              o[0] = s[r];
              o[1] = s[g];
              o[2] = s[bl];
            }
          }
          c->received++;
        }
      }
      pthread_mutex_unlock(&c->lock);
    }
  }
  pw_stream_queue_buffer(c->stream, pb);
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .param_changed = on_param_changed,
    .process = on_process,
};

static int consumer_start(Consumer *c, int fd, uint32_t node, char *err, size_t errlen) {
  pthread_mutex_init(&c->lock, NULL);
  c->loop = pw_thread_loop_new("guiassert-portal", NULL);
  if (!c->loop) {
    snprintf(err, errlen, "cannot create the PipeWire loop");
    return -1;
  }
  struct pw_context *ctx = pw_context_new(pw_thread_loop_get_loop(c->loop), NULL, 0);
  if (!ctx || pw_thread_loop_start(c->loop) < 0) {
    snprintf(err, errlen, "cannot start the PipeWire loop");
    return -1;
  }
  pw_thread_loop_lock(c->loop);
  struct pw_core *core = pw_context_connect_fd(ctx, fd, NULL, 0);
  if (!core) {
    pw_thread_loop_unlock(c->loop);
    snprintf(err, errlen, "cannot connect to PipeWire through the portal's descriptor");
    return -1;
  }
  c->stream = pw_stream_new(core, "guiassert-capture",
      pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture",
                        PW_KEY_MEDIA_ROLE, "Screen", NULL));
  pw_stream_add_listener(c->stream, &c->listener, &stream_events, c);
  uint8_t buf[1024];
  struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof buf);
  const struct spa_pod *params[1];
  params[0] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
      SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
      SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
      SPA_FORMAT_VIDEO_format, SPA_POD_CHOICE_ENUM_Id(9,
          SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_RGBx,
          SPA_VIDEO_FORMAT_BGRA, SPA_VIDEO_FORMAT_RGBA, SPA_VIDEO_FORMAT_xRGB,
          SPA_VIDEO_FORMAT_xBGR, SPA_VIDEO_FORMAT_ARGB, SPA_VIDEO_FORMAT_ABGR),
      SPA_FORMAT_VIDEO_size, SPA_POD_CHOICE_RANGE_Rectangle(
          &SPA_RECTANGLE(640, 480), &SPA_RECTANGLE(1, 1), &SPA_RECTANGLE(16384, 16384)),
      SPA_FORMAT_VIDEO_framerate, SPA_POD_CHOICE_RANGE_Fraction(
          &SPA_FRACTION(30, 1), &SPA_FRACTION(0, 1), &SPA_FRACTION(240, 1)));
  int rc = pw_stream_connect(c->stream, PW_DIRECTION_INPUT, node,
      PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS, params, 1);
  pw_thread_loop_unlock(c->loop);
  if (rc < 0) {
    snprintf(err, errlen, "cannot connect to the stream's node %u: %s", node, spa_strerror(rc));
    return -1;
  }
  return 0;
}

static long now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

/* Wait for the first frame; 0 on success, 7 on timeout, 6 when stopped. */
static int wait_first_frame(Consumer *c, int timeout_ms) {
  long start = now_ms();
  for (;;) {
    pthread_mutex_lock(&c->lock);
    long n = c->received;
    pthread_mutex_unlock(&c->lock);
    if (n > 0)
      return 0;
    if (stop_requested)
      return 6;
    if (now_ms() - start > timeout_ms)
      return 7;
    usleep(5000);
  }
}

static int write_still(Consumer *c, const char *path) {
  FILE *f = fopen(path, "wb");
  if (!f)
    return fail("failed", 5, "cannot write the still frame");
  pthread_mutex_lock(&c->lock);
  fprintf(f, "P6\n%d %d\n255\n", c->width, c->height);
  size_t n = (size_t)c->width * c->height * 3;
  int ok = fwrite(c->rgb, 1, n, f) == n;
  pthread_mutex_unlock(&c->lock);
  ok = fclose(f) == 0 && ok;
  if (!ok)
    return fail("failed", 5, "cannot write the still frame");
  snprintf(st_state, sizeof st_state, "stopped");
  write_report();
  return 0;
}

static int record(Consumer *c, double fps, char **argv, int argc) {
  char wtext[16], htext[16];
  snprintf(wtext, sizeof wtext, "%d", c->width);
  snprintf(htext, sizeof htext, "%d", c->height);
  char **args = calloc((size_t)argc + 1, sizeof *args);
  for (int i = 0; i < argc; i++) {
    GString *s = g_string_new(argv[i]);
    g_string_replace(s, "%W%", wtext, 0);
    g_string_replace(s, "%H%", htext, 0);
    args[i] = g_string_free(s, FALSE);
  }
  int pipefd[2];
  if (pipe(pipefd) < 0)
    return fail("failed", 5, "pipe failed");
  signal(SIGPIPE, SIG_IGN);
  pid_t parent = getpid();
  pid_t child = fork();
  if (child < 0)
    return fail("failed", 5, "fork failed");
  if (child == 0) {
    prctl(PR_SET_PDEATHSIG, SIGKILL);
    if (getppid() != parent)
      _exit(127);
    signal(SIGINT, SIG_IGN); /* the encoder stops at the end of its input */
    signal(SIGTERM, SIG_DFL);
    dup2(pipefd[0], 0);
    close(pipefd[0]);
    close(pipefd[1]);
    execvp(args[0], args);
    fprintf(stderr, "portal_screencast: cannot run %s: %s\n", args[0], strerror(errno));
    _exit(127);
  }
  close(pipefd[0]);
  st_child = child;
  size_t frame_bytes = (size_t)c->width * c->height * 3;
  unsigned char *frame = malloc(frame_bytes);
  int failed = 0;
  snprintf(st_state, sizeof st_state, "streaming");
  write_report();
  struct timespec start, now;
  clock_gettime(CLOCK_MONOTONIC, &start);
  while (!stop_requested && frame) {
    pthread_mutex_lock(&c->lock);
    int changed = c->size_changed;
    memcpy(frame, c->rgb, frame_bytes);
    pthread_mutex_unlock(&c->lock);
    if (changed) {
      failed = 3;
      break;
    }
    size_t done = 0;
    while (done < frame_bytes) {
      ssize_t n = write(pipefd[1], frame + done, frame_bytes - done);
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
    st_frames++;
    if (st_frames % 10 == 0)
      write_report();
    double next = st_frames / fps;
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
  if (failed || code != 0 || !frame) {
    char msg[160];
    snprintf(msg, sizeof msg, failed == 3 ? "the stream's frame size changed while recording"
                              : failed == 2 ? "the encoder stopped reading frames"
                                            : "the encoder exited with status %d", code);
    st_code = code;
    fail("failed", 6, msg);
    return 6;
  }
  snprintf(st_state, sizeof st_state, "stopped");
  write_report();
  return 0;
}

int main(int argc, char **argv) {
  int cursor = 0, timeout_ms = 60000, sep = -1;
  const char *still = NULL;
  double fps = 0;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--report") == 0 && i + 1 < argc)
      report_path = argv[++i];
    else if (strcmp(argv[i], "--cursor") == 0)
      cursor = 1;
    else if (strcmp(argv[i], "--timeout-ms") == 0 && i + 1 < argc)
      timeout_ms = atoi(argv[++i]);
    else if (strcmp(argv[i], "--still") == 0 && i + 1 < argc)
      still = argv[++i];
    else if (strcmp(argv[i], "--fps") == 0 && i + 1 < argc)
      fps = atof(argv[++i]);
    else if (strcmp(argv[i], "--") == 0) {
      sep = i;
      break;
    } else {
      fprintf(stderr, "portal_screencast: unknown argument %s\n", argv[i]);
      return 2;
    }
  }
  int recording = sep >= 0 && sep + 1 < argc && fps > 0 && fps <= 240;
  if (!report_path || timeout_ms <= 0 || (still != NULL) == recording) {
    fprintf(stderr, "usage: %s --report FILE [--cursor] [--timeout-ms N] "
                    "(--still OUT.ppm | --fps F -- ENCODER...)\n", argv[0]);
    return 2;
  }
  struct sigaction sa = {0};
  sa.sa_handler = on_signal;
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGTERM, &sa, NULL);
  write_report();
  pw_init(&argc, &argv);

  GError *e = NULL;
  GDBusConnection *conn = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &e);
  if (!conn) {
    char msg[512];
    snprintf(msg, sizeof msg, "no session bus: %s", e->message);
    return fail("failed", 3, msg);
  }
  /* The portal must offer ScreenCast: read its version. */
  GVariant *ver = g_dbus_connection_call_sync(
      conn, PORTAL_BUS, PORTAL_PATH, "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", SCREENCAST, "version"), G_VARIANT_TYPE("(v)"),
      G_DBUS_CALL_FLAGS_NONE, timeout_ms, NULL, &e);
  if (!ver) {
    char msg[512];
    snprintf(msg, sizeof msg, "the portal offers no ScreenCast interface: %s", e->message);
    return fail("failed", 3, msg);
  }
  g_variant_unref(ver);
  guint32 cursor_modes = 0;
  GVariant *cm = g_dbus_connection_call_sync(
      conn, PORTAL_BUS, PORTAL_PATH, "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", SCREENCAST, "AvailableCursorModes"),
      G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, timeout_ms, NULL, NULL);
  if (cm) {
    GVariant *v;
    g_variant_get(cm, "(v)", &v);
    if (g_variant_is_of_type(v, G_VARIANT_TYPE_UINT32))
      cursor_modes = g_variant_get_uint32(v);
    g_variant_unref(v);
    g_variant_unref(cm);
  }

  char err[512] = "";
  GVariant *res = NULL;
  /* CreateSession */
  char *tok = next_token(), *stok = next_token();
  GVariantBuilder b;
  g_variant_builder_init(&b, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&b, "{sv}", "handle_token", g_variant_new_string(tok));
  g_variant_builder_add(&b, "{sv}", "session_handle_token", g_variant_new_string(stok));
  int r = request(conn, "CreateSession", g_variant_new("(a{sv})", &b), tok,
                  timeout_ms, &res, err, sizeof err);
  if (r != 0)
    return fail(r == 1 ? "denied" : "failed", r == 1 ? 4 : r == -2 ? 7 : 5, err);
  const char *session = NULL;
  if (!g_variant_lookup(res, "session_handle", "&s", &session) || !session)
    return fail("failed", 5, "CreateSession: no session_handle in the response");
  char *session_path = g_strdup(session);
  g_variant_unref(res);

  /* SelectSources: one monitor. */
  tok = next_token();
  g_variant_builder_init(&b, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&b, "{sv}", "handle_token", g_variant_new_string(tok));
  g_variant_builder_add(&b, "{sv}", "types", g_variant_new_uint32(1));
  g_variant_builder_add(&b, "{sv}", "multiple", g_variant_new_boolean(FALSE));
  guint32 want = cursor ? 2 : 1; /* embedded : hidden */
  if (cursor_modes & want)
    g_variant_builder_add(&b, "{sv}", "cursor_mode", g_variant_new_uint32(want));
  r = request(conn, "SelectSources", g_variant_new("(oa{sv})", session_path, &b),
              tok, timeout_ms, &res, err, sizeof err);
  if (r != 0)
    return fail(r == 1 ? "denied" : "failed", r == 1 ? 4 : r == -2 ? 7 : 5, err);
  g_variant_unref(res);

  /* Start: the user (or the backend's configured chooser) picks the monitor. */
  tok = next_token();
  g_variant_builder_init(&b, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&b, "{sv}", "handle_token", g_variant_new_string(tok));
  r = request(conn, "Start", g_variant_new("(osa{sv})", session_path, "", &b), tok,
              timeout_ms, &res, err, sizeof err);
  if (r != 0)
    return fail(r == 1 ? "denied" : "failed", r == 1 ? 4 : r == -2 ? 7 : 5, err);
  GVariant *streams = g_variant_lookup_value(res, "streams", G_VARIANT_TYPE("a(ua{sv})"));
  if (!streams || g_variant_n_children(streams) < 1)
    return fail("failed", 5, "Start: the response names no stream");
  guint32 node;
  GVariant *props;
  g_variant_get_child(streams, 0, "(u@a{sv})", &node, &props);
  st_node = node;
  g_variant_lookup(props, "position", "(ii)", &st_x, &st_y);
  g_variant_lookup(props, "size", "(ii)", &st_w, &st_h);
  g_variant_unref(props);
  g_variant_unref(streams);
  g_variant_unref(res);

  /* OpenPipeWireRemote: the descriptor the consumer connects with. */
  GVariantBuilder empty;
  g_variant_builder_init(&empty, G_VARIANT_TYPE_VARDICT);
  GUnixFDList *fds = NULL;
  GVariant *ret = g_dbus_connection_call_with_unix_fd_list_sync(
      conn, PORTAL_BUS, PORTAL_PATH, SCREENCAST, "OpenPipeWireRemote",
      g_variant_new("(oa{sv})", session_path, &empty), G_VARIANT_TYPE("(h)"),
      G_DBUS_CALL_FLAGS_NONE, timeout_ms, NULL, &fds, NULL, &e);
  if (!ret) {
    char msg[512];
    snprintf(msg, sizeof msg, "OpenPipeWireRemote: %s", e->message);
    return fail("failed", 5, msg);
  }
  gint32 handle;
  g_variant_get(ret, "(h)", &handle);
  int fd = g_unix_fd_list_get(fds, handle, &e);
  g_variant_unref(ret);
  g_object_unref(fds);
  if (fd < 0)
    return fail("failed", 5, "OpenPipeWireRemote: no descriptor was passed");
  if (stop_requested)
    return fail("failed", 6, "interrupted before the stream started");
  Consumer c = {0};
  char perr[256];
  if (consumer_start(&c, fd, (uint32_t)st_node, perr, sizeof perr) < 0)
    return fail("failed", 5, perr);
  int w = wait_first_frame(&c, timeout_ms);
  if (w == 7)
    return fail("failed", 7, "the stream sent no frame in time");
  if (w == 6)
    return fail("failed", 6, "interrupted before the first frame");
  st_fw = c.width;
  st_fh = c.height;
  int code = still ? write_still(&c, still) : record(&c, fps, argv + sep + 1, argc - sep - 1);
  pw_thread_loop_lock(c.loop);
  pw_stream_destroy(c.stream);
  pw_thread_loop_unlock(c.loop);
  pw_thread_loop_stop(c.loop);
  g_object_unref(conn);
  return code;
}
