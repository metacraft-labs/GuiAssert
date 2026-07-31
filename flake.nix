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
            ];

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
