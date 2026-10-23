/*
 * atspi_form.c — the invented form window the Linux accessibility-tree live
 * suite (tests/live/ttree_linux.nim) reads through AT-SPI, and the Linux input
 * live suite (tests/live/tinput_linux.nim) drives with real input events.
 *
 * One source, compiled twice by the suite: against GTK 3 (whose widgets
 * reach AT-SPI through the ATK bridge, at-spi2-atk) and against GTK 4 (whose
 * widgets speak AT-SPI themselves), so the `linux-atspi` backend is checked
 * against both toolkit implementations of the same form:
 *
 *   label    "Display name"          text-field  (accessible name "Display name")
 *   label    "Passphrase"            text-field  (a password entry, name "Passphrase")
 *   checkbox "Remember this device"
 *   label    "Delivery notes"        text-area   (name "Delivery notes", holds NOTES)
 *   button   "Submit"
 *
 * Pressing Submit (through AT-SPI's Action interface, or a real pointer click
 * at the button) ADDS a status label "Submitted <display name>; passphrase of
 * <n> characters" (the passphrase itself never appears), so a test
 * sees the press's effect as a node that was not in the tree before.
 *
 * Usage: atspi_form [--title T] [--name N] [--csd] [--clipped-field] [--position X,Y]
 *                   [--input-log PATH]
 *   --title T   the window title (default "Order Form"); a suite gives each
 *               window a unique one so it can tell instances apart.
 *   --name N    the program name (g_set_prgname), which is the application
 *               name AT-SPI reports (default "guiassert-form").
 *   --csd       a header bar as the titlebar, so the toolkit draws the
 *               decorations (and a floating window's shadow) itself.
 *   --clipped-field
 *               add a text field "Archived note" scrolled out of a small
 *               viewport above Submit, its centre on Submit, and below Submit
 *               a text field "Covered note" with a button "Cover" over its
 *               centre that presses like Submit (the focus test
 *               of tests/live/ttree_linux.nim).
 *   --position X,Y
 *               GTK 3 on X11 only: ask for the window's top-left there (an
 *               X server without a window manager grants it as asked).
 *   --input-log PATH
 *               add the input lab of the input live suite (tests/live/
 *               tinput_linux.nim; see "The input lab" below): a slider and
 *               two canvases that log the events they receive to PATH.
 *
 * Prints "ready <pid>" on stdout once the window is mapped, then runs until
 * SIGTERM or the window is closed. Every string is invented.
 */
#include <glib-unix.h>
#include <gtk/gtk.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define NOTES "Leave the parcel at the side door."

static GtkWidget *form_box;
static GtkWidget *name_entry;
static GtkWidget *pass_entry;
static GtkWidget *status_label;
static gboolean announced;

#if GTK_MAJOR_VERSION >= 4
#define append(box, child) gtk_box_append(GTK_BOX(box), child)
#define gtk_widget_set_focusable_compat(w) gtk_widget_set_focusable(w, TRUE)
static void set_name(GtkWidget *w, const char *name) {
  gtk_accessible_update_property(GTK_ACCESSIBLE(w), GTK_ACCESSIBLE_PROPERTY_LABEL, name, -1);
}
static const char *entry_text(GtkWidget *w) { return gtk_editable_get_text(GTK_EDITABLE(w)); }
#else
#define append(box, child) gtk_box_pack_start(GTK_BOX(box), child, FALSE, FALSE, 0)
#define gtk_widget_set_focusable_compat(w) gtk_widget_set_can_focus(w, TRUE)
static void set_name(GtkWidget *w, const char *name) {
  atk_object_set_name(gtk_widget_get_accessible(w), name);
}
static const char *entry_text(GtkWidget *w) { return gtk_entry_get_text(GTK_ENTRY(w)); }
#endif

static void on_submit(GtkWidget *button, gpointer data) {
  (void)button;
  (void)data;
  char text[512];
  snprintf(text, sizeof text, "Submitted %s; passphrase of %ld characters",
           entry_text(name_entry), (long)g_utf8_strlen(entry_text(pass_entry), -1));
  if (status_label == NULL) {
    status_label = gtk_label_new(text);
    append(form_box, status_label);
#if GTK_MAJOR_VERSION < 4
    gtk_widget_show(status_label);
#endif
  } else {
    gtk_label_set_text(GTK_LABEL(status_label), text);
  }
}

static void announce(void) {
  if (announced) return;
  announced = TRUE;
  printf("ready %d\n", (int)getpid());
  fflush(stdout);
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
#endif

static GtkWidget *labelled_entry(const char *label, gboolean password) {
  append(form_box, gtk_label_new(label));
#if GTK_MAJOR_VERSION >= 4
  GtkWidget *entry = password ? gtk_password_entry_new() : gtk_entry_new();
#else
  GtkWidget *entry = gtk_entry_new();
  if (password) gtk_entry_set_visibility(GTK_ENTRY(entry), FALSE);
#endif
  set_name(entry, label);
  append(form_box, entry);
  return entry;
}

/* ------------------------------------------------------------------------ */
/* The input lab (--input-log PATH; the input live suite, GS8)              */
/* ------------------------------------------------------------------------ */
/*
 * With --input-log the form gains, below Submit:
 *
 *   slider   "Level"        0..100, step 1, starting at 50 (a GtkScale)
 *   canvas   "Sketch pad"   300x120: logs every press, release, motion with
 *                           the left button held, and scroll it receives
 *   canvas   "Key log"      300x40, focusable (a click focuses it): while it
 *                           has the focus, every key press reaching the
 *                           window is logged and consumed
 *
 * and appends one line per event to PATH, flushed at once:
 *
 *   press <button> <n> <x> <y> <mods>   n: 1 single, 2 double, 3 triple
 *   release <button> <x> <y>
 *   trail <x> <y>                       motion with button 1 held
 *   scroll <dx> <dy>                    deltas, positive down / right
 *   key <keyval name> <U+XXXX|-> <mods>  the lower-case keyval's name, its
 *                                        character (or -), and the modifiers
 *
 * Coordinates are the canvas's own (logical pixels from its top-left), and
 * <mods> is "-" or letters of c (Control), a (Alt / Mod1), s (Shift) and
 * m (Super / Meta).
 */
static FILE *input_log;
static GtkWidget *key_log;

static void lab_log(const char *fmt, ...) G_GNUC_PRINTF(1, 2);
static void lab_log(const char *fmt, ...) {
  if (!input_log) return;
  va_list ap;
  va_start(ap, fmt);
  vfprintf(input_log, fmt, ap);
  va_end(ap);
  fputc('\n', input_log);
  fflush(input_log);
}

static const char *mods_text(GdkModifierType state, char *buf) {
  char *p = buf;
  if (state & GDK_CONTROL_MASK) *p++ = 'c';
#if GTK_MAJOR_VERSION >= 4
  if (state & GDK_ALT_MASK) *p++ = 'a';
#else
  if (state & GDK_MOD1_MASK) *p++ = 'a';
#endif
  if (state & GDK_SHIFT_MASK) *p++ = 's';
  if (state & (GDK_SUPER_MASK | GDK_META_MASK)) *p++ = 'm';
  if (p == buf) *p++ = '-';
  *p = '\0';
  return buf;
}

static void log_key(guint keyval, GdkModifierType state) {
  char mods[8];
  guint lower = gdk_keyval_to_lower(keyval);
  const char *name = gdk_keyval_name(lower);
  gunichar ch = gdk_keyval_to_unicode(lower);
  char uni[16] = "-";
  if (ch >= 0x20 && ch != 0x7f) snprintf(uni, sizeof uni, "U+%04X", (unsigned)ch);
  lab_log("key %s %s %s", name ? name : "?", uni, mods_text(state, mods));
}

#if GTK_MAJOR_VERSION >= 4
static void pad_pressed(GtkGestureClick *g, int n, double x, double y, gpointer d) {
  (void)d;
  char mods[8];
  GdkModifierType st = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(g));
  lab_log("press %u %d %.0f %.0f %s", gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(g)),
          n, x, y, mods_text(st, mods));
}
static void pad_released(GtkGestureClick *g, int n, double x, double y, gpointer d) {
  (void)n;
  (void)d;
  lab_log("release %u %.0f %.0f", gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(g)), x, y);
}
static void pad_motion(GtkEventControllerMotion *m, double x, double y, gpointer d) {
  (void)d;
  GdkModifierType st = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(m));
  if (st & GDK_BUTTON1_MASK) lab_log("trail %.0f %.0f", x, y);
}
static gboolean pad_scroll(GtkEventControllerScroll *s, double dx, double dy, gpointer d) {
  (void)s;
  (void)d;
  lab_log("scroll %.2f %.2f", dx, dy);
  return TRUE;
}
static void keylog_pressed(GtkGestureClick *g, int n, double x, double y, gpointer d) {
  (void)g; (void)n; (void)x; (void)y; (void)d;
  gtk_widget_grab_focus(key_log);
}
static gboolean window_key(GtkEventControllerKey *k, guint keyval, guint code,
                           GdkModifierType state, gpointer window) {
  (void)k;
  (void)code;
  if (gtk_root_get_focus(GTK_ROOT(window)) != key_log) return FALSE;
  log_key(keyval, state);
  return TRUE;
}
#else
static gboolean pad_button(GtkWidget *w, GdkEventButton *e, gpointer d) {
  (void)w;
  (void)d;
  char mods[8];
  if (e->type == GDK_BUTTON_RELEASE) {
    lab_log("release %u %.0f %.0f", e->button, e->x, e->y);
  } else {
    int n = e->type == GDK_2BUTTON_PRESS ? 2 : e->type == GDK_3BUTTON_PRESS ? 3 : 1;
    lab_log("press %u %d %.0f %.0f %s", e->button, n, e->x, e->y, mods_text(e->state, mods));
  }
  return TRUE;
}
static gboolean pad_motion(GtkWidget *w, GdkEventMotion *e, gpointer d) {
  (void)w;
  (void)d;
  if (e->state & GDK_BUTTON1_MASK) lab_log("trail %.0f %.0f", e->x, e->y);
  return TRUE;
}
static gboolean pad_scroll(GtkWidget *w, GdkEventScroll *e, gpointer d) {
  (void)w;
  (void)d;
  double dx = 0, dy = 0;
  switch (e->direction) {
  case GDK_SCROLL_UP: dy = -1; break;
  case GDK_SCROLL_DOWN: dy = 1; break;
  case GDK_SCROLL_LEFT: dx = -1; break;
  case GDK_SCROLL_RIGHT: dx = 1; break;
  default: gdk_event_get_scroll_deltas((GdkEvent *)e, &dx, &dy); break;
  }
  if (e->direction == GDK_SCROLL_SMOOTH && dx == 0 && dy == 0) return TRUE; /* scroll stop */
  lab_log("scroll %.2f %.2f", dx, dy);
  return TRUE;
}
static gboolean keylog_button(GtkWidget *w, GdkEventButton *e, gpointer d) {
  (void)e;
  (void)d;
  gtk_widget_grab_focus(w);
  return TRUE;
}
static gboolean window_key(GtkWidget *window, GdkEventKey *e, gpointer d) {
  (void)d;
  if (gtk_window_get_focus(GTK_WINDOW(window)) != key_log) return FALSE;
  log_key(e->keyval, e->state);
  return TRUE;
}
#endif

static GtkWidget *canvas(const char *name, int w, int h) {
#if GTK_MAJOR_VERSION >= 4
  /* GTK 4 exposes a drawing area as an unnamed generic panel; a group
     carries its label. */
  GtkWidget *a = g_object_new(GTK_TYPE_DRAWING_AREA, "accessible-role",
                              GTK_ACCESSIBLE_ROLE_GROUP, NULL);
#else
  GtkWidget *a = gtk_drawing_area_new();
#endif
  gtk_widget_set_size_request(a, w, h);
  set_name(a, name);
  return a;
}

static void add_input_lab(GtkWidget *window) {
  GtkWidget *level = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 100, 1);
  gtk_range_set_value(GTK_RANGE(level), 50);
  gtk_scale_set_draw_value(GTK_SCALE(level), FALSE);
  gtk_widget_set_size_request(level, 300, -1);
  set_name(level, "Level");
  append(form_box, gtk_label_new("Level"));
  append(form_box, level);
  GtkWidget *pad = canvas("Sketch pad", 300, 120);
  append(form_box, pad);
  key_log = canvas("Key log", 300, 40);
  gtk_widget_set_focusable_compat(key_log);
  append(form_box, key_log);
#if GTK_MAJOR_VERSION >= 4
  GtkGesture *click = gtk_gesture_click_new();
  gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), 0);
  g_signal_connect(click, "pressed", G_CALLBACK(pad_pressed), NULL);
  g_signal_connect(click, "released", G_CALLBACK(pad_released), NULL);
  gtk_widget_add_controller(pad, GTK_EVENT_CONTROLLER(click));
  GtkEventController *motion = gtk_event_controller_motion_new();
  g_signal_connect(motion, "motion", G_CALLBACK(pad_motion), NULL);
  gtk_widget_add_controller(pad, motion);
  GtkEventController *scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
  g_signal_connect(scroll, "scroll", G_CALLBACK(pad_scroll), NULL);
  gtk_widget_add_controller(pad, scroll);
  GtkGesture *focus = gtk_gesture_click_new();
  g_signal_connect(focus, "pressed", G_CALLBACK(keylog_pressed), NULL);
  gtk_widget_add_controller(key_log, GTK_EVENT_CONTROLLER(focus));
  GtkEventController *keys = gtk_event_controller_key_new();
  gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
  g_signal_connect(keys, "key-pressed", G_CALLBACK(window_key), window);
  gtk_widget_add_controller(window, keys);
#else
  gtk_widget_add_events(pad, GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK |
                                 GDK_BUTTON1_MOTION_MASK | GDK_SCROLL_MASK | GDK_SMOOTH_SCROLL_MASK);
  g_signal_connect(pad, "button-press-event", G_CALLBACK(pad_button), NULL);
  g_signal_connect(pad, "button-release-event", G_CALLBACK(pad_button), NULL);
  g_signal_connect(pad, "motion-notify-event", G_CALLBACK(pad_motion), NULL);
  g_signal_connect(pad, "scroll-event", G_CALLBACK(pad_scroll), NULL);
  gtk_widget_add_events(key_log, GDK_BUTTON_PRESS_MASK);
  g_signal_connect(key_log, "button-press-event", G_CALLBACK(keylog_button), NULL);
  g_signal_connect(window, "key-press-event", G_CALLBACK(window_key), NULL);
#endif
}

/* --clipped-field: a text field scrolled out of a 48-pixel viewport, placed so
   that its own centre lies on the Submit button drawn just below the
   viewport. Its toolkit still reports it showing (GTK 4), so this is the
   field a `focus` by pointer must refuse to click: a click at its centre
   would press Submit. */
static void add_clipped_field(void) {
#if GTK_MAJOR_VERSION >= 4
  GtkWidget *sw = gtk_scrolled_window_new();
#else
  GtkWidget *sw = gtk_scrolled_window_new(NULL, NULL);
#endif
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(sw), GTK_POLICY_NEVER, GTK_POLICY_EXTERNAL);
  gtk_widget_set_size_request(sw, -1, 48);
  GtkWidget *inner = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  /* The viewport (48) plus form_box's spacing (6): the field starts where
     Submit does. */
  GtkWidget *spacer = gtk_label_new("");
  gtk_widget_set_size_request(spacer, -1, 54);
  append(inner, spacer);
  GtkWidget *entry = gtk_entry_new();
  set_name(entry, "Archived note");
  append(inner, entry);
#if GTK_MAJOR_VERSION >= 4
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(sw), inner);
#else
  gtk_container_add(GTK_CONTAINER(sw), inner);
#endif
  append(form_box, sw);
}

/* Also with --clipped-field, below Submit: a text field "Covered note" whose
   centre a button "Cover" overlays (GtkOverlay). The field is unclipped and
   showing, but the point at its centre is the button's, which presses like
   Submit when clicked; a `focus` by pointer must refuse it too. */
static void add_covered_field(void) {
  GtkWidget *ov = gtk_overlay_new();
  GtkWidget *entry = gtk_entry_new();
  set_name(entry, "Covered note");
  GtkWidget *cover = gtk_button_new_with_label("Cover");
  gtk_widget_set_halign(cover, GTK_ALIGN_CENTER);
  gtk_widget_set_valign(cover, GTK_ALIGN_CENTER);
  g_signal_connect(cover, "clicked", G_CALLBACK(on_submit), NULL);
#if GTK_MAJOR_VERSION >= 4
  gtk_overlay_set_child(GTK_OVERLAY(ov), entry);
#else
  gtk_container_add(GTK_CONTAINER(ov), entry);
#endif
  gtk_overlay_add_overlay(GTK_OVERLAY(ov), cover);
  append(form_box, ov);
}

static gboolean stop_requested;
static gboolean on_term(gpointer data) {
  (void)data;
  stop_requested = TRUE;
  return G_SOURCE_REMOVE;
}

int main(int argc, char **argv) {
  const char *title = "Order Form";
  const char *name = "guiassert-form";
  gboolean csd = FALSE;
  gboolean clipped = FALSE;
  int pos_x = -1, pos_y = -1;
  const char *input_log_path = NULL;
  for (int i = 1; i < argc; i += 2) {
    if (strcmp(argv[i], "--clipped-field") == 0) {
      clipped = TRUE;
      i -= 1;
    } else if (strcmp(argv[i], "--csd") == 0) {
      csd = TRUE;
      i -= 1;
    } else if (i + 1 >= argc) {
      fprintf(stderr, "atspi_form: %s needs a value\n", argv[i]);
      return 2;
    } else if (strcmp(argv[i], "--title") == 0) title = argv[i + 1];
    else if (strcmp(argv[i], "--name") == 0) name = argv[i + 1];
    else if (strcmp(argv[i], "--input-log") == 0) input_log_path = argv[i + 1];
    else if (strcmp(argv[i], "--position") == 0) {
      if (sscanf(argv[i + 1], "%d,%d", &pos_x, &pos_y) != 2 || pos_x < 0 || pos_y < 0) {
        fprintf(stderr, "atspi_form: --position takes X,Y\n");
        return 2;
      }
    } else {
      fprintf(stderr, "atspi_form: unknown argument %s\n", argv[i]);
      return 2;
    }
  }
  if (input_log_path) {
    input_log = fopen(input_log_path, "a");
    if (!input_log) {
      fprintf(stderr, "atspi_form: cannot open %s\n", input_log_path);
      return 2;
    }
  }
  g_set_prgname(name);
  g_set_application_name(name);
  g_unix_signal_add(SIGTERM, on_term, NULL);
  g_unix_signal_add(SIGINT, on_term, NULL);
#if GTK_MAJOR_VERSION >= 4
  gtk_init();
  GtkWidget *window = gtk_window_new();
#else
  gtk_init(&argc, &argv);
  GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
#endif
  gtk_window_set_title(GTK_WINDOW(window), title);
  gtk_window_set_default_size(GTK_WINDOW(window), 360, input_log_path ? 720 : 420);
  if (csd) {
    /* A header bar as the titlebar: both toolkits then draw the window's
       decorations (and, floating, its shadow) themselves. */
    GtkWidget *bar = gtk_header_bar_new();
#if GTK_MAJOR_VERSION < 4
    gtk_header_bar_set_show_close_button(GTK_HEADER_BAR(bar), TRUE);
#endif
    gtk_window_set_titlebar(GTK_WINDOW(window), bar);
  }
  form_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);

  name_entry = labelled_entry("Display name", FALSE);
  pass_entry = labelled_entry("Passphrase", TRUE);
  append(form_box, gtk_check_button_new_with_label("Remember this device"));
  append(form_box, gtk_label_new("Delivery notes"));
  GtkWidget *notes = gtk_text_view_new();
  gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(notes)), NOTES, -1);
  set_name(notes, "Delivery notes");
  gtk_widget_set_size_request(notes, -1, 60);
  append(form_box, notes);
  if (clipped) add_clipped_field();
  GtkWidget *submit = gtk_button_new_with_label("Submit");
  g_signal_connect(submit, "clicked", G_CALLBACK(on_submit), NULL);
  append(form_box, submit);
  if (clipped) add_covered_field();
  if (input_log_path) add_input_lab(window);

#if GTK_MAJOR_VERSION >= 4
  gtk_window_set_child(GTK_WINDOW(window), form_box);
  g_signal_connect(window, "map", G_CALLBACK(on_map), NULL);
  gtk_window_present(GTK_WINDOW(window));
  while (!stop_requested && g_list_model_get_n_items(gtk_window_get_toplevels()) > 0)
    g_main_context_iteration(NULL, TRUE);
#else
  gtk_container_add(GTK_CONTAINER(window), form_box);
  if (pos_x >= 0) gtk_window_move(GTK_WINDOW(window), pos_x, pos_y);
  g_signal_connect(window, "map-event", G_CALLBACK(on_map), NULL);
  g_signal_connect(window, "destroy", G_CALLBACK(gtk_main_quit), NULL);
  gtk_widget_show_all(window);
  while (!stop_requested && gtk_widget_get_visible(window)) g_main_context_iteration(NULL, TRUE);
#endif
  return 0;
}
