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
          miseSources = {
            x86_64-linux = {
              platform = "linux-x64-musl";
              sha256 = "54dc5f1a0de14bddf70a4d8273603647c140eedd8b9d083a8f73ca13a9a82f53";
            };
            aarch64-linux = {
              platform = "linux-arm64-musl";
              sha256 = "745a1a5401c42090953a8da493243d5c666fffc2c98f9a3dee33bd8afc77a9ee";
            };
            x86_64-darwin = {
              platform = "macos-x64";
              sha256 = "e42418100e2f781f9be00b9feaa60378e77551741faececc2bf360992c5410c8";
            };
            aarch64-darwin = {
              platform = "macos-arm64";
              sha256 = "d7c50c1683524a764260986ccc9c41c0de5e1fcd491714b5640b657b76781af6";
            };
          };
          miseSource = miseSources.${system};
          mise = pkgs.stdenvNoCC.mkDerivation {
            pname = "mise";
            version = "2026.10.17";
            src = pkgs.fetchurl {
              url = "https://github.com/jdx/mise/releases/download/v2026.10.17/mise-v2026.10.17-${miseSource.platform}.tar.gz";
              inherit (miseSource) sha256;
            };
            nativeBuildInputs = [ pkgs.makeWrapper ];
            dontConfigure = true;
            dontBuild = true;
            dontFixup = true;
            installPhase = ''
              runHook preInstall
              install -Dm755 bin/mise "$out/bin/mise"
              install -Dm644 LICENSE "$out/share/licenses/mise/LICENSE"
              mkdir -p "$out/lib/mise"
              touch "$out/lib/mise/.disable-self-update"
              wrapProgram "$out/bin/mise" \
                --prefix PATH : ${lib.makeBinPath [ pkgs.bash pkgs.coreutils pkgs.git ]} \
                --set-default SSL_CERT_FILE ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
              runHook postInstall
            '';
            doInstallCheck = true;
            installCheckPhase = ''
              runHook preInstallCheck
              export HOME="$TMPDIR"
              export MISE_DISABLE_UPDATE_WARNING=1
              "$out/bin/mise" --version | grep -F "2026.10.17"
              "$out/bin/mise" backends ls | grep -Fx packslip
              runHook postInstallCheck
            '';
            meta = {
              description = "Pinned mise task runner with the packslip backend";
              homepage = "https://mise.jdx.dev";
              license = lib.licenses.mit;
              mainProgram = "mise";
              platforms = builtins.attrNames miseSources;
            };
          };
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
            # Nix's syscall filter rejects xattr fixture setup with ENOTSUP.
            TMS_TEST_ALLOW_UNSUPPORTED_XATTR = "1";
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
              license = with lib.licenses; [ mit mpl20 asl20 unicode-30 ];
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
          checks = { inherit tmux-sessionizer mise; };
          devShells.default = pkgs.mkShellNoCC {
            packages = [ mise ];
          };
        };

      flake.overlays.default = final: prev: {
        inherit (self.packages.${final.stdenv.hostPlatform.system}) tmux-sessionizer;
      };
    };
}
