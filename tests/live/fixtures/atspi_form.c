/*
 * atspi_form.c — the invented form window the Linux accessibility-tree live
 * suite (tests/live/ttree_linux.nim) reads through AT-SPI.
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
 * Usage: atspi_form [--title T] [--name N] [--csd] [--position X,Y]
 *   --title T   the window title (default "Order Form"); a suite gives each
 *               window a unique one so it can tell instances apart.
 *   --name N    the program name (g_set_prgname), which is the application
 *               name AT-SPI reports (default "guiassert-form").
 *   --csd       a header bar as the titlebar, so the toolkit draws the
 *               decorations (and a floating window's shadow) itself.
 *   --position X,Y
 *               GTK 3 on X11 only: ask for the window's top-left there (an
 *               X server without a window manager grants it as asked).
 *
 * Prints "ready <pid>" on stdout once the window is mapped, then runs until
 * SIGTERM or the window is closed. Every string is invented.
 */
#include <glib-unix.h>
#include <gtk/gtk.h>
#include <signal.h>
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
  int pos_x = -1, pos_y = -1;
  for (int i = 1; i < argc; i += 2) {
    if (strcmp(argv[i], "--csd") == 0) {
      csd = TRUE;
      i -= 1;
    } else if (i + 1 >= argc) {
      fprintf(stderr, "atspi_form: %s needs a value\n", argv[i]);
      return 2;
    } else if (strcmp(argv[i], "--title") == 0) title = argv[i + 1];
    else if (strcmp(argv[i], "--name") == 0) name = argv[i + 1];
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
  gtk_window_set_default_size(GTK_WINDOW(window), 360, 420);
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
  GtkWidget *submit = gtk_button_new_with_label("Submit");
  g_signal_connect(submit, "clicked", G_CALLBACK(on_submit), NULL);
  append(form_box, submit);

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
