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
          # The Linux capture backends (spec §4.2) run GuiAssert's own C
          # helpers (`helpers/linux`: `x11_probe` for linux-x11,
          # `portal_screencast` for linux-portal-pipewire and `wlr_screencopy`
          # for linux-wlr recordings, beside the desktop-environment targets'
          # `wm_probe` and `virtual_pointer`) and these tools: grim (linux-wlr
          # stills), swaymsg (sway's IPC, linux-wlr), gdbus (GNOME Shell,
          # linux-gnome) and ffmpeg (the encoder of every Linux recorder
          # helper, via FFMPEG_BIN).
          linuxHelperInputs = with pkgs; [
            wayland
            wayland-protocols
            wlr-protocols
            xorg.libX11
            xorg.libXres
            glib
            pipewire
          ];
          linuxCaptureTools = with pkgs; [
            grim
            sway
            glib.bin
            ffmpeg
          ];
          linuxHelpers = [
            "x11_probe"
            "portal_screencast"
            "wlr_screencopy"
            "wm_probe"
            "virtual_pointer"
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
                (lib.makeBinPath linuxCaptureTools)
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
