{
  description = "Zig tmux-sessionizer package and mise development shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ self, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, system, ... }:
        let
          lib = pkgs.lib;
          versionLines = builtins.filter (match: match != null) (
            map
              (line: builtins.match ''[[:space:]]*\.version[[:space:]]*=[[:space:]]*"([^"]+)",[[:space:]]*'' line)
              (lib.splitString "\n" (builtins.readFile ./build.zig.zon))
          );
          version =
            assert builtins.length versionLines == 1;
            builtins.head (builtins.head versionLines);
          compilerSources = {
            x86_64-linux = {
              platform = "x86_64-linux";
              sha256 = "3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a";
            };
            aarch64-linux = {
              platform = "aarch64-linux";
              sha256 = "a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795";
            };
            x86_64-darwin = {
              platform = "x86_64-macos";
              sha256 = "9af07b20319fbd0c92ee46ad23e81d6a782b1aaea2cfb8dcbff35f1d2c7ddbb7";
            };
            aarch64-darwin = {
              platform = "aarch64-macos";
              sha256 = "75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d";
            };
          };
          compilerSource = compilerSources.${system};
          zig = pkgs.stdenvNoCC.mkDerivation {
            pname = "zig";
            version = "0.17.1";
            src = pkgs.fetchurl {
              url = "https://ziglang.org/download/0.17.1/zig-${compilerSource.platform}-0.17.1.tar.xz";
              inherit (compilerSource) sha256;
            };
            dontConfigure = true;
            dontBuild = true;
            dontFixup = true;
            installPhase = ''
              mkdir -p "$out"
              cp -r . "$out/"
              mkdir -p "$out/bin"
              ln -s ../zig "$out/bin/zig"
            '';
            meta = {
              mainProgram = "zig";
              license = lib.licenses.mit;
              platforms = builtins.attrNames compilerSources;
            };
          };
          sdkFlags = lib.optionalString pkgs.stdenv.isDarwin "--sysroot ${pkgs.apple-sdk.sdkroot}";
          zigTarget = "${pkgs.stdenv.hostPlatform.parsed.cpu.name}-${
            if pkgs.stdenv.isDarwin then "macos" else "linux-musl"
          }";
          tmux-sessionizer = pkgs.stdenvNoCC.mkDerivation {
            pname = "tmux-sessionizer";
            inherit version;
            src = lib.cleanSourceWith {
              src = ./.;
              filter = path: type:
                let
                  relative = lib.removePrefix (toString ./. + "/") (toString path);
                  top = builtins.head (lib.splitString "/" relative);
                in
                path == toString ./. || builtins.elem top [
                  "build.zig" "build.zig.zon" "src" "vendor" "scripts" "LICENSE"
                ] || lib.any (prefix: lib.hasPrefix prefix (lib.toUpper top)) [
                  "LICENSE" "LICENCE" "COPYING" "COPYRIGHT" "NOTICE" "THIRD_PARTY"
                ];
            };
            strictDeps = true;
            nativeBuildInputs = [ zig pkgs.python3 pkgs.installShellFiles ];
            nativeCheckInputs = [ pkgs.git pkgs.tmux pkgs.jujutsu ];
            dontConfigure = true;
            buildPhase = ''
              runHook preBuild
              export HOME="$TMPDIR"
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
              zig build --system --release=fast -Dcpu=baseline -Dtarget=${zigTarget} ${sdkFlags} -j"$NIX_BUILD_CORES"
              runHook postBuild
            '';
            doCheck = true;
            checkPhase = ''
              runHook preCheck
              zig build test --system -Dtarget=${zigTarget} ${sdkFlags} -j"$NIX_BUILD_CORES"
              test "$(zig-out/bin/tms --version)" = "tmux-sessionizer ${version}"
              runHook postCheck
            '';
            installPhase = ''
              runHook preInstall
              install -Dm755 zig-out/bin/tms "$out/bin/tms"
              python3 scripts/package.py notices --dest "$out/share/licenses/tms"
              for shell in bash fish zsh; do
                COMPLETE="$shell" "$out/bin/tms" > "tms.$shell"
                test -s "tms.$shell"
              done
              installShellCompletion --cmd tms \
                --bash tms.bash --fish tms.fish --zsh tms.zsh
              runHook postInstall
            '';
            meta = {
              description = "Tmux session manager with an embedded picker";
              homepage = "https://github.com/rickyhugo/tmux-sessionizer";
              license = lib.licenses.mit;
              mainProgram = "tms";
              platforms = builtins.attrNames compilerSources;
            };
          };
        in
        {
          packages = {
            default = tmux-sessionizer;
            inherit tmux-sessionizer;
          };
          checks = { inherit tmux-sessionizer; };
          devShells.default = pkgs.mkShellNoCC {
            packages = [ pkgs.mise ];
          };
        };

      flake.overlays.default = final: prev: {
        inherit (self.packages.${final.stdenv.hostPlatform.system}) tmux-sessionizer;
      };
    };
}
