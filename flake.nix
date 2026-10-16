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
            ++ lib.optionals pkgs.stdenv.isLinux desktopEnvPackages;

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
