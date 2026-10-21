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
            ];
          };
          mkGuiassert =
            name: defines: wrap:
            pkgs.stdenv.mkDerivation {
              pname = name;
              inherit version src;
              nativeBuildInputs = [ pkgs.nim ] ++ lib.optional wrap pkgs.makeWrapper;
              buildPhase = ''
                runHook preBuild
                export HOME="$TMPDIR"
                nim c --hints:off -d:release ${defines} \
                  --nimcache:"$TMPDIR/nimcache" -o:"$TMPDIR/${name}" src/guiassert.nim
                runHook postBuild
              '';
              installPhase = ''
                runHook preInstall
                install -Dm755 "$TMPDIR/${name}" "$out/bin/${name}"
                runHook postInstall
              '';
              # The packaged program carries its external tools: ffmpeg for the
              # media backend and tesseract (with its default English
              # traineddata) for the `tesseract` OCR engine, the Linux default
              # (spec §4.2, "Pinned by the flake"). `--set-default` keeps a
              # caller's own FFMPEG_BIN / TESSERACT_BIN.
              postFixup = lib.optionalString wrap ''
                wrapProgram "$out/bin/${name}" \
                  --set-default FFMPEG_BIN "${pkgs.ffmpeg}/bin/ffmpeg" \
                  --set-default TESSERACT_BIN "${pkgs.tesseract}/bin/tesseract"
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
