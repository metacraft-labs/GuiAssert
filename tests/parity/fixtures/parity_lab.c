/*
 * parity_lab.c — the invented application window of the Linux parity
 * harness (tests/parity/linux_parity.nim, run by tests/parity/linux_parity.sh,
 * GS13). It carries one widget for each kind of thing the Linux computer-use
 * scenarios of GuiAssert's consumer drive or read, so every scenario of the
 * harness runs against one window:
 *
 *   label    "Account"          text-field  (accessible name "Account")
 *   label    "Passcode"         text-field  (a password entry, name "Passcode")
 *   button   "Sign in"          enabled
 *   button   "Archive"          disabled (insensitive): the state filter's subject
 *   label    "State: idle"      the status label (see below)
 *   list     "Rows"             twenty rows "Row 1" … "Row 20" in a scrolled
 *                               area 120 px high, so a scroll moves it
 *   label    "Volume"           slider "Volume" 0..100, step 1, at 50
 *   canvas   "Signboard"        a drawing area that paints SIGN_TEXT in large
 *                               black letters on white; its accessible node
 *                               carries a name and no text, so its text is
 *                               found only by OCR (tree-then-OCR)
 *
 * The status label reports the last thing that happened to the window:
 *
 *   "State: idle"                        at start
 *   "State: signed in <n> as <account>; passcode of <m> characters"
 *                                        Sign in pressed the n-th time (by a
 *                                        pointer click or AT-SPI's Action)
 *   "State: scrolled <v>"                the list scrolled to offset v
 *   "State: volume <v>"                  the slider moved to v
 *
 * The passcode itself never appears anywhere.
 *
 * Usage: parity_lab [--title T] [--name N] [--dialog-after-ms MS]
 *   --title T   the window title (default "Parity Lab"); the harness gives
 *               each window a unique one.
 *   --name N    the program name (g_set_prgname), which is the application
 *               name AT-SPI reports (default "guiassert-parity").
 *   --dialog-after-ms MS
 *               MS milliseconds after the window is mapped, open a dialog
 *               titled "Reminder" (AT-SPI role dialog) saying "Timer
 *               elapsed" with an OK button, transient for the window: the
 *               subject of the timer-driven wait. 0 (the default) never opens
 *               it.
 *
 * Compiled against GTK 3 and against GTK 4 by the harness. Prints
 * "ready <pid>" on stdout once the window is mapped, then runs until SIGTERM,
 * SIGINT or the window is closed. Every string is invented.
 */
#include <glib-unix.h>
#include <gtk/gtk.h>
#include <pango/pangocairo.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SIGN_TEXT "COPPER LANTERN 52"

static GtkWidget *window;
static GtkWidget *account_entry;
static GtkWidget *passcode_entry;
static GtkWidget *status_label;
static int sign_ins;
static int dialog_after_ms;
static gboolean announced;
static gboolean stop_requested;

#if GTK_MAJOR_VERSION >= 4
#define append(box, child) gtk_box_append(GTK_BOX(box), child)
static void set_name(GtkWidget *w, const char *name) {
  gtk_accessible_update_property(GTK_ACCESSIBLE(w), GTK_ACCESSIBLE_PROPERTY_LABEL, name, -1);
}
static const char *entry_text(GtkWidget *w) { return gtk_editable_get_text(GTK_EDITABLE(w)); }
#else
#define append(box, child) gtk_box_pack_start(GTK_BOX(box), child, FALSE, FALSE, 0)
static void set_name(GtkWidget *w, const char *name) {
  atk_object_set_name(gtk_widget_get_accessible(w), name);
}
static const char *entry_text(GtkWidget *w) { return gtk_entry_get_text(GTK_ENTRY(w)); }
#endif

static void set_status(const char *fmt, ...) G_GNUC_PRINTF(1, 2);
static void set_status(const char *fmt, ...) {
  char text[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(text, sizeof text, fmt, ap);
  va_end(ap);
  gtk_label_set_text(GTK_LABEL(status_label), text);
}

static void on_sign_in(GtkWidget *button, gpointer data) {
  (void)button;
  (void)data;
  sign_ins += 1;
  set_status("State: signed in %d as %s; passcode of %ld characters", sign_ins,
             entry_text(account_entry), (long)g_utf8_strlen(entry_text(passcode_entry), -1));
}

static void on_scrolled(GtkAdjustment *adj, gpointer data) {
  (void)data;
  set_status("State: scrolled %.0f", gtk_adjustment_get_value(adj));
}

static void on_volume(GtkRange *range, gpointer data) {
  (void)data;
  set_status("State: volume %.0f", gtk_range_get_value(range));
}

/* The signboard: SIGN_TEXT in bold sans on white, left-aligned with a margin. */
static void paint_sign(cairo_t *cr, int width, int height) {
  cairo_set_source_rgb(cr, 1, 1, 1);
  cairo_rectangle(cr, 0, 0, width, height);
  cairo_fill(cr);
  cairo_set_source_rgb(cr, 0, 0, 0);
  PangoLayout *layout = pango_cairo_create_layout(cr);
  PangoFontDescription *font = pango_font_description_from_string("Sans Bold 30");
  pango_layout_set_font_description(layout, font);
  pango_layout_set_text(layout, SIGN_TEXT, -1);
  cairo_move_to(cr, 16, 16);
  pango_cairo_show_layout(cr, layout);
  pango_font_description_free(font);
  g_object_unref(layout);
}

#if GTK_MAJOR_VERSION >= 4
static void draw_sign(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer d) {
  (void)area;
  (void)d;
  paint_sign(cr, width, height);
}
#else
static gboolean draw_sign(GtkWidget *w, cairo_t *cr, gpointer d) {
  (void)d;
  paint_sign(cr, gtk_widget_get_allocated_width(w), gtk_widget_get_allocated_height(w));
  return FALSE;
}
#endif

static GtkWidget *signboard(void) {
#if GTK_MAJOR_VERSION >= 4
  /* GTK 4 exposes a plain drawing area as an unnamed generic node; as a
     group it carries its accessible name. */
  GtkWidget *a = g_object_new(GTK_TYPE_DRAWING_AREA, "accessible-role",
                              GTK_ACCESSIBLE_ROLE_GROUP, NULL);
  gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(a), 460);
  gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(a), 80);
  gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(a), draw_sign, NULL, NULL);
#else
  GtkWidget *a = gtk_drawing_area_new();
  gtk_widget_set_size_request(a, 460, 80);
  g_signal_connect(a, "draw", G_CALLBACK(draw_sign), NULL);
#endif
  set_name(a, "Signboard");
  return a;
}

static GtkWidget *row_list(void) {
  GtkWidget *list = gtk_list_box_new();
  set_name(list, "Rows");
  for (int i = 1; i <= 20; i++) {
    char text[32];
    snprintf(text, sizeof text, "Row %d", i);
    gtk_list_box_insert(GTK_LIST_BOX(list), gtk_label_new(text), -1);
  }
#if GTK_MAJOR_VERSION >= 4
  GtkWidget *scroller = gtk_scrolled_window_new();
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), list);
#else
  GtkWidget *scroller = gtk_scrolled_window_new(NULL, NULL);
  gtk_container_add(GTK_CONTAINER(scroller), list);
#endif
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroller), GTK_POLICY_NEVER,
                                 GTK_POLICY_ALWAYS);
  gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroller), 120);
  gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(scroller), 120);
  g_signal_connect(gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(scroller)),
                   "value-changed", G_CALLBACK(on_scrolled), NULL);
  return scroller;
}

/* ------------------------------------------------------------------------ */
/* The timer-driven dialog                                                  */
/* ------------------------------------------------------------------------ */

static void close_dialog(GtkWidget *button, gpointer dialog) {
  (void)button;
#if GTK_MAJOR_VERSION >= 4
  gtk_window_destroy(GTK_WINDOW(dialog));
#else
  gtk_widget_destroy(GTK_WIDGET(dialog));
#endif
}

static gboolean open_dialog(gpointer data) {
  (void)data;
#if GTK_MAJOR_VERSION >= 4
  GtkWidget *dialog = g_object_new(GTK_TYPE_WINDOW, "accessible-role",
                                   GTK_ACCESSIBLE_ROLE_DIALOG, NULL);
  GtkWidget *body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  gtk_window_set_child(GTK_WINDOW(dialog), body);
#else
  GtkWidget *dialog = gtk_dialog_new();
  GtkWidget *body = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
#endif
  gtk_window_set_title(GTK_WINDOW(dialog), "Reminder");
  gtk_window_set_transient_for(GTK_WINDOW(dialog), GTK_WINDOW(window));
  gtk_window_set_default_size(GTK_WINDOW(dialog), 260, 120);
  append(body, gtk_label_new("Timer elapsed"));
  GtkWidget *ok = gtk_button_new_with_label("OK");
  g_signal_connect(ok, "clicked", G_CALLBACK(close_dialog), dialog);
  append(body, ok);
#if GTK_MAJOR_VERSION >= 4
  gtk_window_present(GTK_WINDOW(dialog));
#else
  gtk_widget_show_all(dialog);
#endif
  return G_SOURCE_REMOVE;
}

/* ------------------------------------------------------------------------ */
/* Start-up                                                                 */
/* ------------------------------------------------------------------------ */

static void announce(void) {
  if (announced) return;
  announced = TRUE;
  printf("ready %d\n", (int)getpid());
  fflush(stdout);
  if (dialog_after_ms > 0) g_timeout_add((guint)dialog_after_ms, open_dialog, NULL);
}

#if GTK_MAJOR_VERSION >= 4
static void on_map(GtkWidget *w, gpointer data) {
  (void)w;
  (void)data;
  announce();
}
#else
static gboolean on_map(GtkWidget *w, GdkEvent *e, gpointer data) {
  (void)w;
  (void)e;
  (void)data;
  announce();
  return FALSE;
}
static void on_destroy(GtkWidget *w, gpointer data) {
  (void)w;
  (void)data;
  stop_requested = TRUE;
}
#endif

static gboolean on_term(gpointer data) {
  (void)data;
  stop_requested = TRUE;
  return G_SOURCE_REMOVE;
}

static GtkWidget *labelled_entry(GtkWidget *box, const char *label, gboolean password) {
  append(box, gtk_label_new(label));
#if GTK_MAJOR_VERSION >= 4
  GtkWidget *entry = password ? gtk_password_entry_new() : gtk_entry_new();
#else
  GtkWidget *entry = gtk_entry_new();
  if (password) gtk_entry_set_visibility(GTK_ENTRY(entry), FALSE);
#endif
  set_name(entry, label);
  append(box, entry);
  return entry;
}

int main(int argc, char **argv) {
  const char *title = "Parity Lab";
  const char *name = "guiassert-parity";
  for (int i = 1; i < argc; i += 2) {
    if (i + 1 >= argc) {
      fprintf(stderr, "parity_lab: %s needs a value\n", argv[i]);
      return 2;
    } else if (strcmp(argv[i], "--title") == 0) {
      title = argv[i + 1];
    } else if (strcmp(argv[i], "--name") == 0) {
      name = argv[i + 1];
    } else if (strcmp(argv[i], "--dialog-after-ms") == 0) {
      char *end = NULL;
      long ms = strtol(argv[i + 1], &end, 10);
      if (end == argv[i + 1] || *end != '\0' || ms < 0 || ms > 600000) {
        fprintf(stderr, "parity_lab: --dialog-after-ms takes 0..600000\n");
        return 2;
      }
      dialog_after_ms = (int)ms;
    } else {
      fprintf(stderr, "parity_lab: unknown argument %s\n", argv[i]);
      return 2;
    }
  }
  g_set_prgname(name);
  g_set_application_name(name);
  g_unix_signal_add(SIGTERM, on_term, NULL);
  g_unix_signal_add(SIGINT, on_term, NULL);
#if GTK_MAJOR_VERSION >= 4
  gtk_init();
  window = gtk_window_new();
#else
  gtk_init(&argc, &argv);
  window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
#endif
  gtk_window_set_title(GTK_WINDOW(window), title);
  gtk_window_set_default_size(GTK_WINDOW(window), 520, 640);

  GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
  account_entry = labelled_entry(box, "Account", FALSE);
  passcode_entry = labelled_entry(box, "Passcode", TRUE);
  GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *sign_in = gtk_button_new_with_label("Sign in");
  g_signal_connect(sign_in, "clicked", G_CALLBACK(on_sign_in), NULL);
  append(buttons, sign_in);
  GtkWidget *archive = gtk_button_new_with_label("Archive");
  gtk_widget_set_sensitive(archive, FALSE);
  append(buttons, archive);
  append(box, buttons);
  status_label = gtk_label_new("State: idle");
  append(box, status_label);
  append(box, row_list());
  append(box, gtk_label_new("Volume"));
  GtkWidget *volume = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 100, 1);
  gtk_range_set_value(GTK_RANGE(volume), 50);
  gtk_scale_set_draw_value(GTK_SCALE(volume), FALSE);
  gtk_widget_set_size_request(volume, 460, -1);
  set_name(volume, "Volume");
  g_signal_connect(volume, "value-changed", G_CALLBACK(on_volume), NULL);
  append(box, volume);
  append(box, signboard());

#if GTK_MAJOR_VERSION >= 4
  gtk_window_set_child(GTK_WINDOW(window), box);
  g_signal_connect(window, "map", G_CALLBACK(on_map), NULL);
  gtk_window_present(GTK_WINDOW(window));
  while (!stop_requested && g_list_model_get_n_items(gtk_window_get_toplevels()) > 0)
    g_main_context_iteration(NULL, TRUE);
#else
  gtk_container_add(GTK_CONTAINER(window), box);
  g_signal_connect(window, "map-event", G_CALLBACK(on_map), NULL);
  g_signal_connect(window, "destroy", G_CALLBACK(on_destroy), NULL);
  gtk_widget_show_all(window);
  while (!stop_requested) g_main_context_iteration(NULL, TRUE);
#endif
  return 0;
}
