/*
 * slow_x264.c — a fault injector for the Linux live capture suite: loaded
 * with LD_PRELOAD into a recorder's encoder, it delays one call of libx264's
 * x264_encoder_encode (https://code.videolan.org/videolan/x264/-/blob/master/x264.h)
 * and then calls the real one, so every frame is still encoded.
 *
 * It models an encoder latency spike, which a recorder must absorb: the
 * frames it captured meanwhile must all reach the file. (It is how the
 * wf-recorder defect behind the linux-wlr flake was reproduced on demand:
 * with one call delayed past the end of a recording, wf-recorder kept the
 * first frame only.)
 *
 *   SLOW_X264_AT=N    the call to delay (1-based; default 2)
 *   SLOW_X264_MS=MS   the delay (default 2000)
 *   SLOW_X264_MARK=F  a file created once the delay has been served, so the
 *                     test knows the injection reached the encoder
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

typedef int (*encode_fn)(void *, void *, int *, void *, void *);

int x264_encoder_encode(void *h, void *nal, int *n_nal, void *pic_in, void *pic_out) {
  static encode_fn real;
  static int calls;
  if (!real)
    real = (encode_fn)dlsym(RTLD_NEXT, "x264_encoder_encode");
  if (!real)
    abort(); /* preloaded into a process without libx264: a test setup error */
  const char *at = getenv("SLOW_X264_AT");
  if (++calls == (at ? atoi(at) : 2)) {
    const char *ms_text = getenv("SLOW_X264_MS");
    long ms = ms_text ? atol(ms_text) : 2000;
    struct timespec ts = {ms / 1000, (ms % 1000) * 1000000L};
    while (nanosleep(&ts, &ts) != 0 && errno == EINTR) {
    }
    const char *mark = getenv("SLOW_X264_MARK");
    if (mark) {
      int fd = open(mark, O_WRONLY | O_CREAT | O_CLOEXEC, 0600);
      if (fd >= 0)
        close(fd);
    }
  }
  return real(h, nal, n_nal, pic_in, pic_out);
}
