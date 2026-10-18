{
  description = "OpenRig — a coordination layer for coding agents: shared context, messaging, and long-running seats";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # x86_64-darwin: nixpkgs-unstable dropped Intel macOS in 26.11. Pin the
    # last supporting -darwin branch so Intel Mac users still get a
    # current-version install. Do not bump past 26.05-darwin.
    nixpkgs-darwin-legacy.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-darwin-legacy,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor =
        system:
        if system == "x86_64-darwin" then
          import nixpkgs-darwin-legacy {
            inherit system;
            config.allowDeprecatedx86_64Darwin = true;
          }
        else
          nixpkgs.legacyPackages.${system};

      # fetchNpmDeps prefetch output is derived from package-lock.json alone,
      # so the hash is expected to be identical on all systems. Kept as a
      # per-system map so a future platform-conditional fetch change only
      # touches one entry.
      npmDepsHashes = {
        x86_64-linux = "sha256-9zHtWHR0tfVKZBLT5bTrKitQjTd70A2yW1T7rnw/VGM=";
        aarch64-linux = "sha256-9zHtWHR0tfVKZBLT5bTrKitQjTd70A2yW1T7rnw/VGM=";
        x86_64-darwin = "sha256-9zHtWHR0tfVKZBLT5bTrKitQjTd70A2yW1T7rnw/VGM=";
        aarch64-darwin = "sha256-9zHtWHR0tfVKZBLT5bTrKitQjTd70A2yW1T7rnw/VGM=";
      };

      openrigFor =
        system:
        let
          pkgs = pkgsFor system;
          # CI validates on Node 22 (.github/workflows/tests.yml); engines
          # declare ^22 || ^24. Pin the CI major so the flake and CI test the
          # same toolchain.
          nodejs = pkgs.nodejs_22;
          npmDeps = pkgs.fetchNpmDeps {
            name = "openrig-npm-deps";
            src = ./.;
            hash = npmDepsHashes.${system};
          };
          # Runtime tools the CLI/daemon shell out to. tmux and git are hard
          # requirements (CONTRIBUTING.md); the rest enable remote-host and
          # diagnostics commands. Suffix (not prefix) keeps the user's own
          # installs and provider CLIs (claude, codex, ...) ahead on PATH.
          runtimePath = pkgs.lib.makeBinPath [
            pkgs.tmux
            pkgs.git
            pkgs.openssh
            pkgs.rsync
            pkgs.lsof
            pkgs.coreutils
          ];
          stampCommit = self.rev or self.dirtyRev or "";
          stampDirty = self ? dirtyRev;
          stampBuiltAt =
            let
              # flake lastModifiedDate is YYYYMMDDHHMMSS (UTC); reformat to ISO 8601.
              ts = self.lastModifiedDate or "";
              seg = builtins.substring;
            in
            if builtins.stringLength ts == 14 then
              "${seg 0 4 ts}-${seg 4 2 ts}-${seg 6 2 ts}T${seg 8 2 ts}:${seg 10 2 ts}:${seg 12 2 ts}Z"
            else
              "";
          # Packaged build identity — the same stamp scripts/build-package.sh
          # writes into each package's dist at npm publish time, sourced here
          # from the flake's git metadata instead of the absent .git dir.
          buildInfoFile = pkgs.writeText "build-info.js" ''
            // GENERATED at package time — the packaged build-identity stamp.
            export const BUILD_INFO = {
              semver: ${builtins.toJSON (pkgs.lib.importJSON ./packages/cli/package.json).version},
              commit: ${builtins.toJSON stampCommit},
              dirty: ${if stampDirty then "true" else "false"},
              builtAt: ${builtins.toJSON stampBuiltAt},
            };
            export function stampFields(info = BUILD_INFO) {
              if (!info.commit) return {};
              return { semver: info.semver, commit: info.commit, dirty: info.dirty, builtAt: info.builtAt };
            }
          '';
        in
        pkgs.stdenv.mkDerivation {
          pname = "openrig";
          version = (pkgs.lib.importJSON ./packages/cli/package.json).version;
          src = pkgs.lib.cleanSource ./.;

          nativeBuildInputs = [
            nodejs
            pkgs.makeWrapper
          ];

          buildPhase = ''
            runHook preBuild

            # postinstall scripts must not write to a real HOME in the sandbox.
            export HOME=$TMPDIR
            export npm_config_cache=${npmDeps}
            export npm_config_offline=true
            export npm_config_progress=false
            export npm_config_audit=false
            export npm_config_fund=false
            export npm_config_update_notifier=false

            # --ignore-scripts: skips packages/cli's postinstall (check-abi.mjs,
            # verified manually below) and esbuild's postinstall (its platform
            # binary arrives via the @esbuild/* optional dep, not the script).
            npm ci --ignore-scripts
            patchShebangs node_modules

            # Builds workspaces in dependency order: daemon, ui, cli, tui
            # (cli/tui consume @openrig/daemon's emitted .d.ts).
            npm run build

            # The daemon serves built-in context packs from
            # <daemon>/context-packs, resolved relative to its dist at runtime.
            # The directory is gitignored and generated here, matching
            # scripts/build-package.sh.
            node scripts/generate-context-packs.mjs

            # check-abi.mjs did not run (--ignore-scripts), so verify the
            # better-sqlite3 native binding loads under this Node.
            node -e "const D=require('better-sqlite3'); const d=new D(':memory:'); d.exec('select 1'); d.close();"

            runHook postBuild
          '';

          # Installs the monorepo layout the runtime resolvers prefer:
          # packages/{cli,daemon,tui,ui} siblings plus the root node_modules
          # with its @openrig/* workspace symlinks (see resolveDaemonPath /
          # resolveTuiPath — monorepo paths win over the bundled npm layout).
          installPhase = ''
            runHook preInstall

            dest=$out/lib/openrig
            mkdir -p $dest/packages/{cli,daemon,tui,ui}
            cp package.json $dest/
            cp -a node_modules $dest/

            cp packages/cli/package.json $dest/packages/cli/
            cp -r packages/cli/dist $dest/packages/cli/

            cp packages/daemon/package.json $dest/packages/daemon/
            cp -r packages/daemon/dist $dest/packages/daemon/
            for d in assets specs policies context-packs; do
              if [ -d packages/daemon/$d ]; then
                cp -r packages/daemon/$d $dest/packages/daemon/
              fi
            done
            # The daemon materializes reference docs to the user home at
            # startup from ../docs/reference (the npm artifact stages them at
            # daemon/docs/reference — same relative position here).
            mkdir -p $dest/packages/daemon/docs
            cp -r docs/reference $dest/packages/daemon/docs/

            cp packages/tui/package.json $dest/packages/tui/
            cp -r packages/tui/dist $dest/packages/tui/
            cp packages/ui/package.json $dest/packages/ui/
            cp -r packages/ui/dist $dest/packages/ui/

            # Stamp the packaged build identity (scripts/build-package.sh does
            # the same at npm publish time) — commit/dirty/builtAt come from
            # the flake's git metadata, not the repo's .git (absent here).
            cp ${buildInfoFile} $dest/packages/daemon/dist/build-info.js
            cp ${buildInfoFile} $dest/packages/cli/dist/build-info.js

            makeWrapper ${nodejs}/bin/node $out/bin/rig \
              --add-flags "$dest/packages/cli/dist/bin-wrapper.js" \
              --suffix PATH : "$out/bin:${runtimePath}"
            makeWrapper ${nodejs}/bin/node $out/bin/openrig-tui \
              --add-flags "$dest/packages/tui/dist/main.js" \
              --suffix PATH : "$out/bin:${runtimePath}"

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "OpenRig — a coordination layer for coding agents: shared context, messaging, and long-running seats";
            homepage = "https://github.com/mvschwarz/openrig";
            license = licenses.asl20;
            mainProgram = "rig";
            platforms = systems;
          };
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          openrig = openrigFor system;
        in
        {
          default = openrig;
          inherit openrig;
          # Discovery aliases — everything here is a from-source build.
          source = openrig;
          latest = openrig;
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/rig";
        };
        openrig = {
          type = "app";
          program = "${self.packages.${system}.openrig}/bin/rig";
        };
      });

      # Development shell matching CI: Node 22 + tmux + git (CONTRIBUTING.md's
      # hard requirements). npm itself ships inside nodejs_22.
      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.nodejs_22
              pkgs.tmux
              pkgs.git
            ];
          };
        }
      );

      overlays.default = _final: prev: {
        openrig = openrigFor prev.system;
      };
    };
}
