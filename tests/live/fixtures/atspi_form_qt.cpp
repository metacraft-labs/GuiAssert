// atspi_form_qt.cpp — the invented form window of the Linux tree live suite
// (tests/live/ttree_linux.nim) in Qt 6 Widgets, whose AT-SPI bridge is Qt's
// own (qtbase's linuxaccessibility), so the `linux-atspi` backend is checked
// against a third toolkit implementation of the same form as
// `atspi_form.c` (GTK 3 and GTK 4):
//
//   label    "Display name"          text-field  (accessible name "Display name")
//   label    "Passphrase"            text-field  (echo mode Password, name "Passphrase")
//   checkbox "Remember this device"
//   label    "Delivery notes"        text-area   (name "Delivery notes", holds NOTES)
//   button   "Submit"
//
// Pressing Submit ADDS a status label "Submitted <display name>; passphrase
// of <n> characters" (the passphrase itself never appears).
//
// Usage: atspi_form_qt [--title T] [--name N]
//   --title T   the window title (default "Order Form");
//   --name N    the application name AT-SPI reports, and the Wayland app id
//               (default "guiassert-form").
//
// Prints "ready <pid>" on stdout once the window is shown. Every string is
// invented. Built without moc: the only connection is to a lambda.
#include <QApplication>
#include <QCheckBox>
#include <QLabel>
#include <QLineEdit>
#include <QMainWindow>
#include <QPlainTextEdit>
#include <QPushButton>
#include <QTimer>
#include <QVBoxLayout>
#include <QWidget>
#include <cstdio>
#include <cstring>
#include <unistd.h>

static const char *notes = "Leave the parcel at the side door.";

int main(int argc, char **argv) {
  const char *title = "Order Form";
  const char *name = "guiassert-form";
  for (int i = 1; i < argc; i += 2) {
    if (i + 1 >= argc) {
      std::fprintf(stderr, "atspi_form_qt: %s needs a value\n", argv[i]);
      return 2;
    }
    if (std::strcmp(argv[i], "--title") == 0) title = argv[i + 1];
    else if (std::strcmp(argv[i], "--name") == 0) name = argv[i + 1];
    else {
      std::fprintf(stderr, "atspi_form_qt: unknown argument %s\n", argv[i]);
      return 2;
    }
  }
  int qargc = 1;
  QApplication app(qargc, argv);
  QApplication::setApplicationName(QString::fromUtf8(name));
  QGuiApplication::setDesktopFileName(QString::fromUtf8(name));

  // A main window, so the top level is a frame (a bare QWidget is a filler).
  QMainWindow window;
  window.setWindowTitle(QString::fromUtf8(title));
  window.resize(360, 420);
  auto *form = new QWidget;
  window.setCentralWidget(form);
  auto *box = new QVBoxLayout(form);
  box->addWidget(new QLabel(QStringLiteral("Display name")));
  auto *nameEntry = new QLineEdit;
  nameEntry->setAccessibleName(QStringLiteral("Display name"));
  box->addWidget(nameEntry);
  box->addWidget(new QLabel(QStringLiteral("Passphrase")));
  auto *passEntry = new QLineEdit;
  passEntry->setEchoMode(QLineEdit::Password);
  passEntry->setAccessibleName(QStringLiteral("Passphrase"));
  box->addWidget(passEntry);
  box->addWidget(new QCheckBox(QStringLiteral("Remember this device")));
  box->addWidget(new QLabel(QStringLiteral("Delivery notes")));
  auto *notesEdit = new QPlainTextEdit(QString::fromUtf8(notes));
  notesEdit->setAccessibleName(QStringLiteral("Delivery notes"));
  notesEdit->setFixedHeight(60);
  box->addWidget(notesEdit);
  auto *submit = new QPushButton(QStringLiteral("Submit"));
  box->addWidget(submit);
  box->addStretch(1);
  QLabel *status = nullptr;
  QObject::connect(submit, &QPushButton::clicked, [&]() {
    const QString text = QStringLiteral("Submitted %1; passphrase of %2 characters")
                             .arg(nameEntry->text())
                             .arg(passEntry->text().length());
    if (status == nullptr) {
      status = new QLabel(text);
      box->insertWidget(box->count() - 1, status);
    } else {
      status->setText(text);
    }
  });
  window.show();
  QTimer::singleShot(0, [] {
    std::printf("ready %d\n", static_cast<int>(getpid()));
    std::fflush(stdout);
  });
  return app.exec();
}
