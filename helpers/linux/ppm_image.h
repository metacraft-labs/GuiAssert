/*
 * ppm_image.h — read a binary PPM image, for the fixture windows of the
 * Linux helpers (`wm_probe image=`, `x11_probe window --image`).
 *
 * The live OCR tests draw invented text into an image whose every pixel is
 * known in advance and show it in a real window; a binary PPM is the
 * simplest lossless format both a test (ffmpeg writes it) and a helper with
 * no image library can handle. Format:
 * https://netpbm.sourceforge.net/doc/ppm.html — "P6", width, height and
 * maxval as ASCII decimals separated by whitespace (with `#` comments), one
 * whitespace byte, then width * height RGB triples. Only maxval 255 (one byte
 * per sample) is accepted.
 */
#ifndef GUI_ASSERT_PPM_IMAGE_H
#define GUI_ASSERT_PPM_IMAGE_H

#include <stdio.h>
#include <stdlib.h>

/* The next header number of `f` (skipping whitespace and comments), or -1. */
static long ppm_header_number(FILE *f) {
  int c = fgetc(f);
  for (;;) {
    while (c == ' ' || c == '\t' || c == '\n' || c == '\r')
      c = fgetc(f);
    if (c != '#')
      break;
    while (c != '\n' && c != EOF)
      c = fgetc(f);
  }
  if (c < '0' || c > '9')
    return -1;
  long v = 0;
  while (c >= '0' && c <= '9') {
    v = v * 10 + (c - '0');
    if (v > 1000000)
      return -1;
    c = fgetc(f);
  }
  /* The single whitespace byte after the number is consumed here. */
  if (c != ' ' && c != '\t' && c != '\n' && c != '\r')
    return -1;
  return v;
}

/*
 * The pixels of the PPM at `path` as packed RGB24 (malloc'd; the caller frees
 * them), its size in `*w` / `*h`. NULL when the file cannot be read or is not
 * a binary PPM with maxval 255 and at most 8192 pixels on a side (so that
 * a helper's two XRGB8888 buffers of it, 8192 * 8192 * 4 * 2 bytes, fit the
 * `int32_t` size of a `wl_shm` pool); `*why` then names the problem.
 */
static unsigned char *read_ppm(const char *path, int *w, int *h, const char **why) {
  FILE *f = fopen(path, "rb");
  if (!f) {
    *why = "cannot open the image";
    return NULL;
  }
  unsigned char *px = NULL;
  if (fgetc(f) != 'P' || fgetc(f) != '6') {
    *why = "the image is not a binary PPM (P6)";
    goto done;
  }
  long width = ppm_header_number(f), height = ppm_header_number(f),
       maxval = ppm_header_number(f);
  if (width <= 0 || height <= 0 || width > 8192 || height > 8192) {
    *why = "the image's size is missing or out of range";
    goto done;
  }
  if (maxval != 255) {
    *why = "the image's maxval is not 255";
    goto done;
  }
  size_t n = (size_t)width * (size_t)height * 3;
  px = malloc(n);
  if (!px) {
    *why = "out of memory";
    goto done;
  }
  if (fread(px, 1, n, f) != n) {
    *why = "the image is truncated";
    free(px);
    px = NULL;
    goto done;
  }
  *w = (int)width;
  *h = (int)height;
done:
  fclose(f);
  return px;
}

#endif
