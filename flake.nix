{
  description = "GuiAssert — visual + scripting assertion library for CodeTracer GUI sessions.";

  # Pinned nixpkgs so the OCR/ffmpeg vision toolchain is hermetic and
  # reproducible. Same stable channel as the sibling codetracer-flame-server
  # flake (nixos-25.11) for cache reuse across the workspace.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
      # at-spi2-core whose bus launcher runs the PINNED dbus-daemon for the
      # accessibility bus it starts (GS7). nixpkgs builds the launcher to
      # spawn /run/current-system/sw/bin/dbus-daemon, and to prefer a
      # dbus-broker-launch there, which is the host's (NixOS) or nothing (any
      # other host, and the Nix build sandbox, where the launcher then fails).
      # The broker path is pointed where none exists, so the launcher always
      # takes the daemon. Only the launcher is taken from this build; GTK keeps
      # nixpkgs' at-spi2-core.
      atspiLauncherFor =
        pkgs:
        pkgs.at-spi2-core.overrideAttrs (old: {
          mesonFlags = map (
            flag:
            if lib.hasPrefix "-Ddbus_daemon=" flag then
              "-Ddbus_daemon=${pkgs.dbus}/bin/dbus-daemon"
            else if lib.hasPrefix "-Ddbus_broker=" flag then
              "-Ddbus_broker=/nonexistent/dbus-broker-launch"
            else
              flag
          ) old.mesonFlags;
        });
    in
    {
      # The `guiassert` program, built twice from one main (spec §3.4, §9.2):
      # `guiassert` with every backend for the target OS (its fixture
      # recordings encode MP4 with the pinned ffmpeg), and `guiassert-fixture`
      # (-d:guiassertMinimal: the pure core and the fixture backends only, no
      # platform code), which consumers' contract tests pin by revision.
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          version = builtins.head (
            builtins.match ''.*version *= *"([^"]+)".*'' (builtins.readFile ./gui_assert.nimble)
          );
          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./src
              ./gui_assert.nimble
              ./config.nims
              ./helpers
            ];
          };
          # The Linux capture and input backends (spec §4.2) run GuiAssert's own
          # C helpers (`helpers/linux`: `x11_probe` for linux-x11,
          # `portal_screencast` for linux-portal-pipewire and `wlr_screencopy`
          # for linux-wlr recordings; `wayland_input` for linux-wlr-virtual and
          # linux-mutter's keymap check, `xtest_input` for linux-xtest and
          # `uinput_input` for linux-uinput (GS8); beside the
          # desktop-environment targets' `wm_probe` and `virtual_pointer`) and
          # these tools: grim (linux-wlr stills), swaymsg (sway's IPC,
          # linux-wlr and linux-wlr-virtual's window management), gdbus (GNOME
          # Shell, linux-gnome) and ffmpeg (the encoder of every Linux recorder
          # helper, via FFMPEG_BIN).
          linuxHelperInputs = with pkgs; [
            wayland
            wayland-protocols
            wlr-protocols
            xorg.libX11
            xorg.libXres
            xorg.libXtst
            xorg.libXi
            libxkbcommon
            glib
            pipewire
          ];
          # `sway-unwrapped`, not nixpkgs' `sway`: that wrapper runs the
          # compositor under `dbus-run-session` when no session bus is set,
          # which reads /etc/dbus-1/session.conf and fails where there is none
          # (a Nix build sandbox, a container without system D-Bus); a
          # linux-sway session (GS10) starts its own session bus beside the
          # compositor anyway, and the capture and input backends need only
          # `swaymsg`, which both packages ship.
          linuxCaptureTools = with pkgs; [
            grim
            sway-unwrapped
            glib.bin
            ffmpeg
          ];
          # The private Linux sessions (GS10) start these in the session host:
          # linux-sway the headless sway with its own session bus and settings
          # portal (the portal frontend, its GTK backend and the GSettings
          # schemas are named by the GUI_ASSERT_* variables below), linux-xvfb
          # Xvfb, its own dbus-daemon and Openbox; `--vnc` runs wayvnc (sway)
          # or x11vnc (Xvfb); every session starts its AT-SPI bus with the
          # launcher `atspiLauncherFor` builds. linux-gnome needs GNOME Shell,
          # which the package does not carry (it is large and only that
          # backend uses it): it is found through GUI_ASSERT_GNOME_SHELL or the
          # caller's PATH, and without it linux-gnome answers exit 4 /
          # missing-tool.
          linuxSessionTools = with pkgs; [
            dbus
            xorg.xvfb
            openbox
            wayvnc
            x11vnc
          ];
          linuxHelpers = [
            "x11_probe"
            "portal_screencast"
            "wlr_screencopy"
            "wm_probe"
            "virtual_pointer"
            "wayland_input"
            "xtest_input"
            "uinput_input"
          ];
          mkGuiassert =
            name: defines: wrap:
            let
              # Only the full program on Linux has Linux capture backends.
              helpers = wrap && pkgs.stdenv.isLinux;
              helperDir = "${placeholder "out"}/libexec/guiassert";
              # The packaged program carries its external tools: ffmpeg for
              # the media backend and tesseract (with its default English
              # traineddata) for the `tesseract` OCR engine, the Linux default
              # (spec §4.2, "Pinned by the flake"). On Linux it also carries
              # the capture backends' helpers and tools: GUI_ASSERT_HELPER_DIR
              # names the helpers built here, and the tools come first on the
              # PATH, so a capture runs the pinned tools rather than the
              # host's. `--set-default` keeps a caller's own FFMPEG_BIN /
              # TESSERACT_BIN / GUI_ASSERT_HELPER_DIR.
              wrapArgs = [
                "--set-default"
                "FFMPEG_BIN"
                "${pkgs.ffmpeg}/bin/ffmpeg"
                "--set-default"
                "TESSERACT_BIN"
                "${pkgs.tesseract}/bin/tesseract"
              ]
              ++ lib.optionals helpers [
                "--set-default"
                "GUI_ASSERT_HELPER_DIR"
                helperDir
                "--prefix"
                "PATH"
                ":"
                (lib.makeBinPath (linuxCaptureTools ++ linuxSessionTools))
                "--set-default"
                "GUI_ASSERT_ATSPI_BUS_LAUNCHER"
                "${atspiLauncherFor pkgs}/libexec/at-spi-bus-launcher"
                "--set-default"
                "GUI_ASSERT_XDG_DESKTOP_PORTAL"
                "${pkgs.xdg-desktop-portal}/libexec/xdg-desktop-portal"
                "--set-default"
                "GUI_ASSERT_XDG_DESKTOP_PORTAL_GTK"
                "${pkgs.xdg-desktop-portal-gtk}/libexec/xdg-desktop-portal-gtk"
                "--set-default"
                "GUI_ASSERT_GSETTINGS_SCHEMAS"
                "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas"
              ];
            in
            pkgs.stdenv.mkDerivation {
              pname = name;
              inherit version src;
              nativeBuildInputs = [
                pkgs.nim
              ]
              ++ lib.optional wrap pkgs.makeWrapper
              ++ lib.optionals helpers [
                pkgs.pkg-config
                pkgs.wayland-scanner
              ];
              buildInputs = lib.optionals helpers linuxHelperInputs;
              buildPhase = ''
                runHook preBuild
                export HOME="$TMPDIR"
                nim c --hints:off -d:release ${defines} \
                  --nimcache:"$TMPDIR/nimcache" -o:"$TMPDIR/${name}" src/guiassert.nim
              ''
              + lib.optionalString helpers ''
                bash helpers/linux/build.sh "$TMPDIR/linux-helpers"
              ''
              + ''
                runHook postBuild
              '';
              installPhase = ''
                runHook preInstall
                install -Dm755 "$TMPDIR/${name}" "$out/bin/${name}"
              ''
              + lib.optionalString helpers ''
                for h in ${lib.escapeShellArgs linuxHelpers}; do
                  install -Dm755 "$TMPDIR/linux-helpers/$h" "${helperDir}/$h"
                done
              ''
              + ''
                runHook postInstall
              '';
              postFixup = lib.optionalString wrap ''
                wrapProgram "$out/bin/${name}" ${lib.escapeShellArgs wrapArgs}
              '';
              meta = {
                description = "GuiAssert desktop substrate CLI (contract guiassert-desktop/1)";
                license = lib.licenses.mit;
                mainProgram = name;
              };
            };
        in
        rec {
          guiassert = mkGuiassert "guiassert" "" true;
          guiassert-fixture = mkGuiassert "guiassert-fixture" "-d:guiassertMinimal" false;
          default = guiassert;
        }
      );

      # The packaged `guiassert` finds its tesseract with no dev shell and no
      # PATH: run from an empty environment, its probed `tesseract` OCR
      # feature must be `supported` (the program ran and listed its default
      # language), so a package whose wrapper lost TESSERACT_BIN fails here.
      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          guiassert = self.packages.${system}.guiassert;
        in
        {
          guiassert-packaged-tesseract =
            pkgs.runCommand "guiassert-packaged-tesseract" { nativeBuildInputs = [ pkgs.jq ]; }
              ''
                export HOME="$TMPDIR"
                env -i HOME="$HOME" ${guiassert}/bin/guiassert --state-dir "$TMPDIR/state" \
                  --ocr-backend tesseract capabilities --probe > caps.json
                jq -e '.ok == true and ([.data.features[]
                         | select(.feature == "ocr" and .backend == "tesseract"
                                  and .state == "supported")] | length == 1)' caps.json
                touch "$out"
              '';
        }
        # The packaged `guiassert` captures on Linux with no dev shell and no
        # PATH: against a private Xvfb, from an empty environment, linux-x11
        # (the session-following default with only DISPLAY set) must probe
        # `supported`, take a screenshot of the expected size, and record a
        # finalized MP4 (its helper from GUI_ASSERT_HELPER_DIR, its encoder
        # from FFMPEG_BIN). Then, against a private headless sway (pixman
        # renderer, no GPU), linux-wlr must record a finalized MP4 through
        # its `wlr_screencopy` helper. A package that lost its helpers or
        # tools fails here instead of answering `missing-tool` to a consumer.
        # It also reads text from a capture with the packaged tesseract (the
        # Linux default OCR engine, GS6): an invented two-line label, drawn
        # here by ffmpeg in DejaVu Sans and shown in an `x11_probe` window,
        # must come back word for word from `ocr --window`, in reading order,
        # with the window's origin, and from `ocr --region` with the region's.
        // lib.optionalAttrs pkgs.stdenv.isLinux {
          guiassert-packaged-linux-capture =
            pkgs.runCommand "guiassert-packaged-linux-capture"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.xorg.xvfb
                  pkgs.ffmpeg
                ];
                # Only the label is drawn with a font; the package needs none.
                FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
              }
              ''
                export HOME="$TMPDIR"
                Xvfb :71 -screen 0 320x240x24 -nolisten tcp > xvfb.log 2>&1 &
                xvfb=$!
                trap 'kill $xvfb' EXIT
                for _ in $(seq 100); do
                  [ -e /tmp/.X11-unix/X71 ] && break
                  sleep 0.1
                done
                ga() {
                  env -i HOME="$HOME" DISPLAY=:71 ${guiassert}/bin/guiassert \
                    --state-dir "$TMPDIR/state" "$@"
                }
                ga capabilities --probe > caps.json
                jq -e '.ok == true and .data.selected.capture == "linux-x11" and
                       ([.data.features[] | select(.backend == "linux-x11" and
                         .feature == "display-capture" and .state == "supported")]
                        | length == 1)' caps.json
                ga screenshot --out "$TMPDIR/shot.png" > shot.json
                jq -e '.ok == true and .data.image.width == 320 and
                       .data.image.height == 240' shot.json
                ga record --out "$TMPDIR/rec.mp4" --duration-ms 1000 --fps 10 > rec.json
                jq -e '.ok == true and .data.recording.state == "stopped" and
                       .data.recording.frames >= 5' rec.json
                # OCR of a capture with the packaged tesseract: the label in a
                # window at (10, 60), read through linux-x11.
                ffmpeg -hide_banner -loglevel error -f lavfi -i \
                  "color=c=white:s=300x100,drawtext=font='DejaVu Sans':fontsize=28:fontcolor=black:text='QUARTZ 4719':x=12:y=14,drawtext=font='DejaVu Sans':fontsize=28:fontcolor=black:text='PELICAN DOCK':x=12:y=58" \
                  -frames:v 1 -pix_fmt rgb24 label.ppm
                env -i DISPLAY=:71 ${guiassert}/libexec/guiassert/x11_probe window \
                  --geometry 300x100+10+60 --image label.ppm --title label --hold 120000 \
                  > win.json 2> win.log &
                win=$!
                trap 'kill $xvfb $win' EXIT
                for _ in $(seq 100); do
                  [ -s win.json ] && break
                  sleep 0.1
                done
                [ -s win.json ] || { cat win.log; exit 1; }
                id=$(jq -r .id win.json)
                ga ocr --window "$id" --out "$TMPDIR/ocr.png" > ocr.json 2> ocr.err \
                  || { cat ocr.json ocr.err; exit 1; }
                [ ! -s ocr.err ] || { cat ocr.err; exit 1; }
                jq -e '.ok == true and .data.backend == "tesseract" and
                       .data.languages == ["eng"] and
                       .data.text == "QUARTZ 4719\nPELICAN DOCK" and
                       .data.image.origin == [10, 60] and
                       ([.data.words[].text] == ["QUARTZ", "4719", "PELICAN", "DOCK"]) and
                       ([.data.words[] | select(.confidence >= 50 and .confidence <= 100)]
                        | length == 4)' ocr.json || { cat ocr.json; exit 1; }
                ga ocr --region 14,64,280,44 --out "$TMPDIR/ocr-region.png" > ocr-region.json
                jq -e '.ok == true and .data.text == "QUARTZ 4719" and
                       .data.image.origin == [14, 64]' ocr-region.json || { cat ocr-region.json; exit 1; }
                kill $win
                trap 'kill $xvfb' EXIT
                # linux-wlr in a private headless sway (unwrapped: the wrapper
                # starts it under dbus-run-session, and no bus is needed here).
                run="$TMPDIR/run"
                mkdir -m 700 "$run"
                printf 'output HEADLESS-1 mode 320x240\nxwayland disable\n' > sway.conf
                env XDG_RUNTIME_DIR="$run" WLR_BACKENDS=headless WLR_RENDERER=pixman \
                  WLR_LIBINPUT_NO_DEVICES=1 ${pkgs.sway-unwrapped}/bin/sway -c sway.conf > sway.log 2>&1 &
                sway=$!
                trap 'kill $xvfb $sway' EXIT
                # Its IPC and Wayland sockets (stdenv globs with nullglob, so an
                # unmatched pattern is an empty loop).
                sock= wl=
                for _ in $(seq 100); do
                  for f in "$run"/sway-ipc.*.sock; do [ -S "$f" ] && sock=$f; done
                  for f in "$run"/wayland-[0-9]; do [ -S "$f" ] && wl=$(basename "$f"); done
                  [ -n "$sock" ] && [ -n "$wl" ] && break
                  sleep 0.1
                done
                [ -n "$sock" ] && [ -n "$wl" ] || { cat sway.log; exit 1; }
                env -i HOME="$HOME" XDG_RUNTIME_DIR="$run" WAYLAND_DISPLAY="$wl" \
                  SWAYSOCK="$sock" ${guiassert}/bin/guiassert --state-dir "$TMPDIR/state-wlr" \
                  record --out "$TMPDIR/rec-wlr.mp4" --duration-ms 1000 --fps 10 > rec-wlr.json \
                  || { cat rec-wlr.json sway.log; exit 1; }
                jq -e '.ok == true and .data.recording.state == "stopped" and
                       .data.recording.width == 320 and .data.recording.frames >= 10' rec-wlr.json
                touch "$out"
              '';

          # The packaged `guiassert` reads an accessibility tree on Linux with
          # no dev shell and no PATH (GS7): against a private Xvfb with its own
          # session bus and AT-SPI bus (at-spi-bus-launcher, the registry it
          # activates), the invented GTK 3 form of the live suite
          # (`tests/live/fixtures/atspi_form.c`, built here) must come back
          # from `tree --app` with its golden names, its window at the
          # position it asked for (desktop coordinates: linux-atspi places the
          # frame through the window linux-x11 reports, with the packaged
          # x11_probe), its password field protected with value and text null;
          # `find`, `element-action press` and `wait --element` must drive it;
          # and the probed `tree-read` feature must be `supported`. The tree
          # verbs need nothing on the wrapper: the backend speaks D-Bus itself.
          guiassert-packaged-linux-tree =
            pkgs.runCommandCC "guiassert-packaged-linux-tree"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.xorg.xvfb
                  pkgs.dbus
                  pkgs.pkg-config
                ];
                buildInputs = [ pkgs.gtk3 ];
                FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
              }
              ''
                export HOME="$TMPDIR"
                cc -O1 -Wall -Werror -o form ${./tests/live/fixtures/atspi_form.c} \
                  $(pkg-config --cflags --libs gtk+-3.0)
                run="$TMPDIR/run"
                mkdir -m 700 "$run"
                Xvfb :72 -screen 0 800x600x24 -nolisten tcp > xvfb.log 2>&1 &
                xvfb=$!
                dbus-daemon --config-file=${pkgs.dbus}/share/dbus-1/session.conf --nofork \
                  --address="unix:path=$run/bus" > bus.log 2>&1 &
                bus=$!
                trap 'kill $xvfb $bus' EXIT
                for _ in $(seq 100); do
                  [ -e /tmp/.X11-unix/X72 ] && [ -S "$run/bus" ] && break
                  sleep 0.1
                done
                [ -S "$run/bus" ] || { cat bus.log xvfb.log; exit 1; }
                session=(DISPLAY=:72 XDG_RUNTIME_DIR="$run" DBUS_SESSION_BUS_ADDRESS="unix:path=$run/bus")
                env -i HOME="$HOME" "''${session[@]}" \
                  ${atspiLauncherFor pkgs}/libexec/at-spi-bus-launcher --launch-immediately \
                  > launcher.log 2>&1 &
                launcher=$!
                trap 'kill $launcher $xvfb $bus' EXIT
                for _ in $(seq 100); do
                  env -i "''${session[@]}" dbus-send --session --print-reply \
                    --dest=org.freedesktop.DBus /org/freedesktop/DBus \
                    org.freedesktop.DBus.NameHasOwner string:org.a11y.Bus 2>/dev/null \
                    | grep -q 'boolean true' && break
                  sleep 0.1
                done
                env -i HOME="$HOME" "''${session[@]}" GDK_BACKEND=x11 GSETTINGS_BACKEND=memory \
                  FONTCONFIG_FILE="$FONTCONFIG_FILE" ./form --title "Order Form 7" \
                  --position 40,30 > form.out 2> form.log &
                form=$!
                trap 'kill $form $launcher $xvfb $bus' EXIT
                ga() {
                  env -i HOME="$HOME" "''${session[@]}" ${guiassert}/bin/guiassert \
                    --state-dir "$TMPDIR/state" "$@"
                }
                ga wait --element --role button --name Submit \
                  --wait-ms 30000 > ready.json || { cat ready.json form.log launcher.log; exit 1; }
                ga tree --app guiassert-form > tree.json 2> tree.err || { cat tree.json tree.err; exit 1; }
                [ ! -s tree.err ] || { cat tree.err; exit 1; }
                jq -e '.ok == true and .data.root.role == "application" and
                       .data.root.name == "guiassert-form" and .data.truncated == false and
                       ([.data.root | .. | objects | select(has("name")) | .name] as $n |
                        ["Order Form 7", "Display name", "Passphrase", "Remember this device",
                         "Delivery notes", "Submit"] | all(. as $g | $n | index($g) != null)) and
                       (.data.root.children[0].role == "window") and
                       (.data.root.children[0].bounds[0:2] == [40, 30]) and
                       ([.data.root | .. | objects | select(.nativeRole? == "password text")] |
                        length == 1 and .[0].value == null and .[0].text == null and
                        (.[0].states | index("protected") != null))' tree.json \
                  || { cat tree.json; exit 1; }
                ga find --app guiassert-form --role button --name Submit > find.json
                jq -e '.ok == true and (.data.elements | length == 1) and
                       (.data.elements[0].actions | index("press") != null) and
                       .data.elements[0].bounds[0] >= 40 and .data.elements[0].bounds[1] > 30' \
                  find.json || { cat find.json; exit 1; }
                ga element-action "$(jq -r '.data.elements[0].path' find.json)" press > press.json
                jq -e '.ok == true and .data.action == "press"' press.json || { cat press.json; exit 1; }
                ga wait --element --app guiassert-form --role label --name-contains Submitted \
                  --wait-ms 10000 > status.json || { cat status.json; exit 1; }
                ga capabilities --probe > caps.json
                jq -e '.ok == true and .data.selected.tree == "linux-atspi" and
                       ([.data.features[] | select(.feature == "tree-read" and
                         .backend == "linux-atspi" and .state == "supported")] | length == 1)' \
                  caps.json || { cat caps.json; exit 1; }
                ga apps > apps.json
                jq -e '.ok == true and ([.data.apps[] | select(.name == "guiassert-form" and
                         .accessible == true)] | length == 1)' apps.json || { cat apps.json; exit 1; }
                touch "$out"
              '';

          # The packaged `guiassert` sends input on Linux with no dev shell and
          # no PATH (GS8): in a private Xvfb with its own session and AT-SPI
          # buses, linux-xtest (the session-following default with DISPLAY
          # set) must probe pointer and keyboard input `supported`; a click at
          # the centre of the invented GTK 3 form's Display name field (its
          # bounds read through linux-atspi) and a `type --stdin` of a text
          # with a character outside the server's keymap (typed through a
          # borrowed key code by the packaged `xtest_input`) must set the
          # field's value, read back through the tree; a click beside Submit
          # must press nothing and a click at its centre must add the status
          # label. Typed text must reach neither stdout nor stderr.
          guiassert-packaged-linux-input =
            pkgs.runCommandCC "guiassert-packaged-linux-input"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.xorg.xvfb
                  pkgs.dbus
                  pkgs.pkg-config
                ];
                buildInputs = [ pkgs.gtk3 ];
                FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
              }
              ''
                export HOME="$TMPDIR"
                cc -O1 -Wall -Werror -o form ${./tests/live/fixtures/atspi_form.c} \
                  $(pkg-config --cflags --libs gtk+-3.0)
                run="$TMPDIR/run"
                mkdir -m 700 "$run"
                Xvfb :73 -screen 0 800x900x24 -nolisten tcp > xvfb.log 2>&1 &
                xvfb=$!
                dbus-daemon --config-file=${pkgs.dbus}/share/dbus-1/session.conf --nofork \
                  --address="unix:path=$run/bus" > bus.log 2>&1 &
                bus=$!
                trap 'kill $xvfb $bus' EXIT
                for _ in $(seq 100); do
                  [ -e /tmp/.X11-unix/X73 ] && [ -S "$run/bus" ] && break
                  sleep 0.1
                done
                [ -S "$run/bus" ] || { cat bus.log xvfb.log; exit 1; }
                session=(DISPLAY=:73 XDG_RUNTIME_DIR="$run" DBUS_SESSION_BUS_ADDRESS="unix:path=$run/bus")
                env -i HOME="$HOME" "''${session[@]}" \
                  ${atspiLauncherFor pkgs}/libexec/at-spi-bus-launcher --launch-immediately \
                  > launcher.log 2>&1 &
                launcher=$!
                trap 'kill $launcher $xvfb $bus' EXIT
                for _ in $(seq 100); do
                  env -i "''${session[@]}" dbus-send --session --print-reply \
                    --dest=org.freedesktop.DBus /org/freedesktop/DBus \
                    org.freedesktop.DBus.NameHasOwner string:org.a11y.Bus 2>/dev/null \
                    | grep -q 'boolean true' && break
                  sleep 0.1
                done
                env -i HOME="$HOME" "''${session[@]}" GDK_BACKEND=x11 GSETTINGS_BACKEND=memory \
                  FONTCONFIG_FILE="$FONTCONFIG_FILE" ./form --title "Input Form 8" \
                  --position 40,30 > form.out 2> form.log &
                form=$!
                trap 'kill $form $launcher $xvfb $bus' EXIT
                ga() {
                  env -i HOME="$HOME" "''${session[@]}" ${guiassert}/bin/guiassert \
                    --state-dir "$TMPDIR/state" "$@"
                }
                centre() { jq -r '.data.elements[0].bounds as [$x, $y, $w, $h] |
                                  "\($x + ($w / 2 | floor)),\($y + ($h / 2 | floor))"' "$1"; }
                ga wait --element --role button --name Submit \
                  --wait-ms 30000 > ready.json || { cat ready.json form.log launcher.log; exit 1; }
                ga capabilities --probe > caps.json
                jq -e '.ok == true and .data.selected.input == "linux-xtest" and
                       ([.data.features[] | select((.feature == "pointer-input" or
                         .feature == "keyboard-input") and .backend == "linux-xtest" and
                         .state == "supported")] | length == 2)' caps.json || { cat caps.json; exit 1; }
                ga windows --title "Input Form 8" > windows.json
                ga window-focus "$(jq -r '.data.windows[0].id' windows.json)" > focus.json \
                  || { cat focus.json; exit 1; }
                ga find --app guiassert-form --role text-field --name "Display name" > field.json
                ga click --at "$(centre field.json)" > click.json || { cat click.json; exit 1; }
                printf 'Wren Halloway 7 \xc3\xa9' | ga type --stdin > type.json 2> type.err \
                  || { cat type.json type.err; exit 1; }
                [ ! -s type.err ] || { cat type.err; exit 1; }
                jq -e '.ok == true and .data.input.length == 17 and .data.input.kind == "type"' \
                  type.json || { cat type.json; exit 1; }
                if grep -q Halloway type.json; then cat type.json; exit 1; fi
                for _ in $(seq 50); do
                  ga find --app guiassert-form --role text-field --name "Display name" > value.json
                  jq -e '.data.elements[0].value == "Wren Halloway 7 é"' value.json \
                    > /dev/null && break
                  sleep 0.1
                done
                jq -e '.data.elements[0].value == "Wren Halloway 7 é"' value.json \
                  || { cat value.json; exit 1; }
                ga find --app guiassert-form --role button --name Submit > submit.json
                above=$(jq -r '.data.elements[0].bounds as [$x, $y, $w, $h] |
                               "\($x + ($w / 2 | floor)),\($y - 4)"' submit.json)
                ga click --at "$above" > beside.json || { cat beside.json; exit 1; }
                sleep 0.5
                ga find --app guiassert-form --role label --name-contains Submitted > none.json
                jq -e '.data.elements | length == 0' none.json || { cat none.json; exit 1; }
                ga click --at "$(centre submit.json)" > press.json || { cat press.json; exit 1; }
                ga wait --element --app guiassert-form --role label \
                  --name-contains "Submitted Wren Halloway" --wait-ms 10000 > status.json \
                  || { cat status.json; exit 1; }
                touch "$out"
              '';

          # The packaged `guiassert` starts, uses and stops private Linux
          # sessions with no dev shell and no PATH (GS10): from an empty
          # environment, `capabilities --probe` must find every tool of
          # linux-xvfb and linux-sway (`session-headless` and `session-vnc`
          # supported); a linux-xvfb session with `--vnc` must come up
          # running with its display, cookie, session bus and AT-SPI bus in
          # `env`, its VNC endpoint on 127.0.0.1 greeting with an RFB banner,
          # an `x11_probe` window launched into it listed by `windows` and
          # captured by `screenshot`, and the session's accessibility granted;
          # a linux-sway session (pixman renderer, no GPU) must report its
          # output's size and list a `wm_probe` window launched into it; and
          # `session-stop` must leave no record and no process of either
          # session behind. A package that lost a session tool or one of the
          # GUI_ASSERT_* paths fails here instead of answering missing-tool
          # or session-failed to a consumer.
          guiassert-packaged-linux-session =
            pkgs.runCommand "guiassert-packaged-linux-session"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.procps
                ];
              }
              ''
                export HOME="$TMPDIR"
                ga() {
                  env -i HOME="$HOME" ${guiassert}/bin/guiassert --state-dir "$TMPDIR/state" "$@"
                }
                helpers=${guiassert}/libexec/guiassert
                for b in linux-xvfb linux-sway; do
                  ga --session-backend "$b" capabilities --probe > "caps-$b.json"
                  jq -e --arg b "$b" '.ok == true and ([.data.features[] | select(.backend == $b
                         and (.feature == "session-headless" or .feature == "session-vnc")
                         and .state == "supported")] | length == 2)' "caps-$b.json" \
                    || { cat "caps-$b.json"; exit 1; }
                done
                # linux-xvfb with a loopback VNC endpoint.
                ga --session-backend linux-xvfb session-start --kind headless --name x1 \
                  --width 320 --height 240 --vnc > x1.json || { cat x1.json; exit 1; }
                jq -e '.data.session | .state == "running" and .backend == "linux-xvfb" and
                       .displays[0].bounds == [0, 0, 320, 240] and
                       (.env | has("DISPLAY") and has("XAUTHORITY") and
                         has("DBUS_SESSION_BUS_ADDRESS") and has("AT_SPI_BUS_ADDRESS")) and
                       .vnc.host == "127.0.0.1" and .vnc.port > 0' x1.json || { cat x1.json; exit 1; }
                port=$(jq -r .data.session.vnc.port x1.json)
                exec 3<>"/dev/tcp/127.0.0.1/$port"
                banner=$(head -c 11 <&3)
                exec 3<&-
                [ "$banner" = "RFB 003.008" ] || { echo "no RFB banner: $banner"; exit 1; }
                ga --session x1 app-launch --wait-window-ms 20000 -- "$helpers/x11_probe" window \
                  --geometry 100x80+20+30 --rgb d23c78 --title "Session Probe" --hold 120000 \
                  > x1-launch.json || { cat x1-launch.json; exit 1; }
                ga --session x1 windows --title "Session Probe" > x1-windows.json
                jq -e --argjson pid "$(jq .data.app.pid x1-launch.json)" \
                  '.ok == true and (.data.windows | length == 1) and .data.windows[0].pid == $pid' \
                  x1-windows.json || { cat x1-windows.json; exit 1; }
                ga --session x1 screenshot --window "$(jq -r '.data.windows[0].id' x1-windows.json)" \
                  --out "$TMPDIR/x1.png" > x1-shot.json
                jq -e '.ok == true and .data.image.width == 100 and .data.image.height == 80' \
                  x1-shot.json || { cat x1-shot.json; exit 1; }
                ga --session x1 permissions > x1-perms.json
                jq -e '.data.permissions.accessibility == "granted"' x1-perms.json \
                  || { cat x1-perms.json; exit 1; }
                # linux-sway.
                ga --session-backend linux-sway session-start --kind headless --name w1 \
                  --width 320 --height 240 > w1.json || { cat w1.json; exit 1; }
                jq -e '.data.session | .state == "running" and .backend == "linux-sway" and
                       .displays[0].bounds == [0, 0, 320, 240] and
                       (.env | has("WAYLAND_DISPLAY") and has("AT_SPI_BUS_ADDRESS"))' w1.json \
                  || { cat w1.json; exit 1; }
                ga --session w1 app-launch --wait-window-ms 20000 -- "$helpers/wm_probe" \
                  "title=Sway Probe" map rgb=28a05a hold=120000 > w1-launch.json \
                  || { cat w1-launch.json; exit 1; }
                ga --session w1 windows --title "Sway Probe" > w1-windows.json
                jq -e '.ok == true and (.data.windows | length == 1)' w1-windows.json \
                  || { cat w1-windows.json; exit 1; }
                # Stopped: no record, and no process of either session.
                for s in x1 w1; do
                  tag=$(jq -r .private.tag "$TMPDIR/state/sessions/$s.json")
                  ga session-stop "$s" > "$s-stop.json"
                  jq -e '.data.session.state == "stopped"' "$s-stop.json" || { cat "$s-stop.json"; exit 1; }
                  [ ! -e "$TMPDIR/state/sessions/$s.json" ] || { echo "$s left a record"; exit 1; }
                  if grep -lsz "GUIASSERT_LINUX_SESSION_TAG=$tag" /proc/[0-9]*/environ; then
                    echo "$s left processes"; exit 1
                  fi
                done
                touch "$out"
              '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          # A minimal fontconfig config exposing DejaVu so ffmpeg's `drawtext`
          # filter (used by the vision e2e fixtures to render window/label text
          # for OCR) resolves a default font with zero host setup.
          fontsConf = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };

          # Linux only. The headless sway target (compositor, pointer and key
          # injection, frame capture, IPC readback) and the session stack that
          # serves desktop settings to the application under test (a private
          # D-Bus session, xdg-desktop-portal with its GTK backend, GSettings
          # schemas). The C helpers under `helpers/linux` are compiled against
          # wayland-client and the protocol XML with the toolchain listed here.
          desktopEnvPackages = with pkgs; [
            sway
            grim
            wtype
            wayland-utils
            wayland
            wayland-scanner
            wayland-protocols
            wlr-protocols
            pkg-config
            gcc
            dbus
            xdg-desktop-portal
            xdg-desktop-portal-gtk
            glib
            gsettings-desktop-schemas
            # The headless GNOME target: GNOME Shell (with its Mutter) and the
            # GNOME portal backend, as a real GNOME session runs them.
            gnome-shell
            xdg-desktop-portal-gnome
            # The Linux capture backends (GS5) and their live tests:
            # `linux-wlr` records through the `wlr_screencopy` helper
            # (wlr-screencopy into ffmpeg; wf-recorder stays for the legacy
            # `gui_assert/capture` API); `linux-x11` captures an
            # Xvfb server through the `x11_probe` helper (XGetImage; this
            # ffmpeg has no x11grab), which also lists and draws its windows,
            # compiled against libX11 and libXres;
            # `linux-portal-pipewire` asks xdg-desktop-portal (its wlroots
            # backend) for a ScreenCast stream, which the `portal_screencast`
            # helper reads with libpipewire; its live tests run a private
            # PipeWire and WirePlumber.
            wf-recorder
            xorg.xvfb
            xorg.libX11
            xorg.libXres
            pipewire
            wireplumber
            xdg-desktop-portal-wlr
            # The Linux accessibility-tree backend's live tests (GS7,
            # `linux-atspi`): the GTK 3, GTK 4 and Qt 6 Widgets toolkits the
            # invented form fixtures are compiled against (Qt's platform
            # plugins are named by GUI_ASSERT_QT_PLUGIN_PATH below), and
            # libXtst for the X11 click helper that presses a fixture button
            # at the centre of its reported bounds (and for `xtest_input`,
            # GS8; libxkbcommon for `wayland_input`). (GTK brings
            # at-spi2-core; a test session starts its private AT-SPI bus with
            # the launcher named by GUI_ASSERT_ATSPI_BUS_LAUNCHER below.)
            gtk3
            gtk4
            qt6.qtbase
            xorg.libXtst
            libxkbcommon
            # The Linux off-screen sessions (GS10): `linux-xvfb` runs Openbox
            # as its minimal window manager, and the optional loopback VNC
            # endpoint of a session is `wayvnc` (linux-sway) or `x11vnc`
            # (linux-xvfb).
            openbox
            wayvnc
            x11vnc
          ];
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              # nim ships the `nim` compiler; nimble is packaged separately.
              nim
              nimble
              just
              # Plain `ffmpeg` (NOT ffmpeg-full): the default nixpkgs build ships
              # libx264 + freetype/fontconfig (so `drawtext` works) which the
              # vision tests require, while avoiding the ffmpeg-full/kvazaar
              # ctest failure that breaks `nix develop` on aarch64-darwin.
              ffmpeg
              # tesseract 5.x with the default (English-included) traineddata.
              tesseract
              # libpcre for Nim's std/re module, should any suite pull it in.
              pcre
            ]
            # Desktop-environment targets (`gui_assert/desktop_env`): the
            # compositors and session stack a target starts, pinned here so a
            # target's identity is part of this flake's lock rather than of
            # whatever the host or a consumer's shell provides.
            ++ lib.optionals pkgs.stdenv.isLinux desktopEnvPackages
            # The Linux host TTS engine (`speech_synth` / the `espeak`
            # speech-synthesis provider run `espeak-ng -w <out> <text>`).
            # macOS ships its counterpart, `say`, with the OS; on Linux it has
            # to come from this shell, or tmedia's TTS test in `just test`
            # fails with the provider's missing-dependency error.
            ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.espeak-ng ];

            shellHook = ''
              # Canonicalize TMPDIR to its physical path. On macOS /tmp is a
              # symlink to private/tmp, and this tesseract's leptonica 1.85
              # (libcurl-enabled) fails to open image files whose path traverses
              # that symlink — the OCR e2e fixtures write frames under $TMPDIR, so
              # without this the vision suites fail. No-op on Linux (/tmp is real).
              if [ -n "''${TMPDIR:-}" ] && [ -d "$TMPDIR" ]; then
                export TMPDIR="$(cd "$TMPDIR" && pwd -P)"
              fi

              # Export the PINNED binaries so gui_assert/{media,ocr,video_analysis}
              # resolve them (they honor FFMPEG_BIN/FFMPEG/FFPROBE/TESSERACT_BIN
              # before falling back to $PATH) with no host toolchain needed.
              export FFMPEG_BIN="${pkgs.ffmpeg}/bin/ffmpeg"
              export FFMPEG="$FFMPEG_BIN"
              export FFPROBE="${pkgs.ffmpeg}/bin/ffprobe"
              export TESSERACT_BIN="${pkgs.tesseract}/bin/tesseract"
              # Let ffmpeg's drawtext find a font via fontconfig.
              export FONTCONFIG_FILE="${fontsConf}"
              export PATH="${pkgs.ffmpeg}/bin:${pkgs.tesseract}/bin:$PATH"
            '' + lib.optionalString pkgs.stdenv.isLinux ''
              # Where the desktop-environment targets find what they start.
              # Exported as paths into this flake's closure so a target never
              # resolves a compositor or a portal from the host.
              export GUI_ASSERT_XDG_DESKTOP_PORTAL="${pkgs.xdg-desktop-portal}/libexec/xdg-desktop-portal"
              export GUI_ASSERT_XDG_DESKTOP_PORTAL_GTK="${pkgs.xdg-desktop-portal-gtk}/libexec/xdg-desktop-portal-gtk"
              export GUI_ASSERT_GSETTINGS_SCHEMAS="${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas"
              export GUI_ASSERT_GNOME_SHELL="${pkgs.gnome-shell}/bin/gnome-shell"
              export GUI_ASSERT_XDG_DESKTOP_PORTAL_GNOME="${pkgs.xdg-desktop-portal-gnome}/libexec/xdg-desktop-portal-gnome"
              # The AT-SPI bus launcher (GS7), running the pinned dbus-daemon
              # (`atspiLauncherFor`): a Linux tree live test starts the
              # accessibility bus of its private session with it.
              export GUI_ASSERT_ATSPI_BUS_LAUNCHER="${atspiLauncherFor pkgs}/libexec/at-spi-bus-launcher"
              # Qt's platform plugins (xcb, wayland) for the Qt form fixture (GS7).
              export GUI_ASSERT_QT_PLUGIN_PATH="${pkgs.qt6.qtbase}/lib/qt-6/plugins"
              # The wlroots portal backend (ScreenCast for the linux-portal-pipewire
              # capture backend's live tests, GS5).
              export GUI_ASSERT_XDG_DESKTOP_PORTAL_WLR="${pkgs.xdg-desktop-portal-wlr}/libexec/xdg-desktop-portal-wlr"
              # Where GLib finds the GNOME session's settings schemas (each
              # package's compiled schemas live under its own data dir).
              export GUI_ASSERT_GNOME_SCHEMA_DATA_DIRS="${pkgs.gnome-shell}/share/gsettings-schemas/${pkgs.gnome-shell.name}:${pkgs.mutter}/share/gsettings-schemas/${pkgs.mutter.name}:${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}"
            '' + ''

              echo "GuiAssert dev shell (pinned nixpkgs nixos-25.11)"
              echo "  nim:       $(nim --version | head -1)"
              echo "  ffmpeg:    $("$FFMPEG_BIN" -version | head -1)"
              echo "  tesseract: $("$TESSERACT_BIN" --version 2>&1 | head -1)"
              echo "Run: nix develop -c nimble test"
            '';
          };
        }
      );
    };
}
