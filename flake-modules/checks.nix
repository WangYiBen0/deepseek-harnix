{ lib, flakelib, self, ... }:

{
  perSystem =
    { pkgs, ... }:
    let
      set = flakelib.mkDshPackageSet pkgs flakelib.defaultRelease;
      e2ePlugin = set.mkDshPlugin { source = ../test/minimal-plugin; };
      e2eHarness = set.deepseek-harness.override { pluginList = [ e2ePlugin ]; };
      e2eProfileCfg = {
        includeBase = true;
        bundles = [ ];
        plugins = [ e2ePlugin ];
        disabledPlugins = [ ];
        patches = [ ];
      };
      e2eSync = import ../modules/profile-sync.nix {
        inherit pkgs lib;
        dshHome = "$DSH_HOME";
        profiles = { e2e = e2eProfileCfg; };
      };
    in
    {
      checks = {
        # mkDshPlugin through every supported packaging path.
        mkDshPlugin-npm = pkgs.runCommand "dsh-mkplugin-npm-check"
          { plugin = set.mkDshPlugin {
              source = ../test/npm-plugin;
              npmDepsHash = "sha256-YvMlco6yhkcHf9gQBU9nCmUrHZ9EG/TpmOPM3a/V5D4=";
              dshVersionRange = ">=0.2.1-alpha.1 <0.3";
            }; }
          ''
            test -f $plugin/package.json
            test -f $plugin/dist/marker.js
            test -f $plugin/cordis.patch.yml
            test -d $plugin/node_modules/js-yaml
            echo $plugin > $out
          '';

        mkDshPlugin-pnpm-workspace = pkgs.runCommand "dsh-mkplugin-pnpm-workspace-check"
          { plugin = set.mkDshPlugin {
              source = ../test/workspace-plugin;
              packageDir = "packages/persona";
              pnpmDepsHash = "sha256-8w0PxLScmoAsePC+lUMGbieXl+TKWcndrvOKnBY+B2A=";
            }; }
          ''
            test -f $plugin/package.json
            test -f $plugin/lib/index.js
            grep -q persona $plugin/lib/index.js
            test -d $plugin/node_modules/js-yaml
            echo $plugin > $out
          '';

        mkDshPlugin-npm-registry = pkgs.runCommand "dsh-mkplugin-npm-registry-check"
          { plugin = set.mkDshPlugin {
              npmName = "ms";
              npmVersion = "2.1.3";
              hash = "sha256-9mFuFeUw7VUvnaotPOcZY5R8a8fJjJtk/T5nP9AmIsY=";
            }; }
          ''
            test -f $plugin/package.json
            grep -q '"name": "ms"' $plugin/package.json
            echo $plugin > $out
          '';

        # The curated catalog turns into a servable npm registry tree.
        plugin-registry = pkgs.runCommand "dsh-plugin-registry-check"
          {
            registry = pkgs.callPackage ../pkgs/dsh-plugin-registry.nix {
              plugins = {
                inherit (import ../pkgs/dsh-plugins.nix { inherit pkgs; }) test-persona;
              };
            };
          }
          ''
            test -f $registry/catalog.json
            test -f $registry/dsh-test-persona/index.json
            test -f $registry/dsh-test-persona/-/dsh-test-persona-1.0.0.tgz
            grep -q '"engines"' $registry/dsh-test-persona/index.json
            grep -q 'sha512-' $registry/dsh-test-persona/index.json
            echo $registry > $out
          '';

        # The static dsh-version-range gate: accepts matching ranges,
        # rejects (at evaluation time) non-matching ones.
        range-eval =
          let
            ok = flakelib.dshSatisfiesRange "0.2.1-rc.2" ">=0.2.1-alpha.1, <0.3";
            caret = flakelib.dshSatisfiesRange "0.2.1-rc.2" "^0.2.0";
            tilde = flakelib.dshSatisfiesRange "0.2.1-rc.2" "~0.2.0";
            # tryEval only reaches weak head normal form, so force the
            # derivation path — where the range assert actually fires.
            blocked = builtins.tryEval (
              (set.withPlugins [
                (set.mkDshPlugin {
                  source = ../test/minimal-plugin;
                  dshVersionRange = ">=99.0";
                })
              ]).drvPath
            );
          in
          pkgs.runCommand "dsh-range-eval-check"
            {
              expectOk = if ok then 1 else 0;
              expectCaret = if caret then 1 else 0;
              expectTilde = if tilde then 1 else 0;
              expectBlocked = if blocked.success then 1 else 0;
              passAsFile = [ "expectOk" "expectCaret" "expectTilde" "expectBlocked" ];
            }
            ''
              test "$(cat $expectOkPath)" = 1
              test "$(cat $expectCaretPath)" = 1
              test "$(cat $expectTildePath)" = 1
              test "$(cat $expectBlockedPath)" = 0
              echo ok > $out
            '';

        versions-json = pkgs.runCommand "dsh-versions-json-eval"
          {
            names = lib.concatStringsSep "\n" (map (e: e.version) flakelib.releases);
            passAsFile = [ "names" ];
          }
          ''
            test -s $namesPath
            grep -q '${flakelib.defaultRelease.version}' $namesPath
            echo "$namesPath" > $out
          '';

        plugin-e2e = pkgs.runCommand "dsh-plugin-e2e"
          {
            nativeBuildInputs = [ e2eHarness ];
          }
          ''
            export HOME=$TMPDIR
            export DSH_HOME=$TMPDIR/dsh-home

            ${e2eSync}

            status=0
            ${e2eHarness}/bin/dsh --profile e2e --dump-default-config > dump.out 2> dump.err || status=$?
            if [ "$status" -ne 0 ]; then
              echo "dsh --dump-default-config failed ($status):" >&2
              cat dump.err dump.out >&2
              exit 1
            fi
            if ! grep -q "dsh-test-persona" dump.out; then
              echo "profile did not mount the Nix-built plugin; dump:" >&2
              cat dump.out dump.err >&2
              exit 1
            fi
            if ! grep -q "NIX-DSH-PLUGIN-E2E-MARKER" dump.out; then
              echo "plugin patch layer did not apply; dump:" >&2
              cat dump.out dump.err >&2
              exit 1
            fi
            cp dump.out $out
          '';

        home-manager-module =
          let
            hmConfig = (self.inputs.home-manager.lib.homeManagerConfiguration {
              inherit pkgs;
              modules = [
                ../modules/home-manager.nix
                {
                  home.username = "e2e";
                  home.homeDirectory = "/home/e2e";
                  home.stateVersion = "25.05";
                  programs.dsh.enable = true;
                  # Pin the package so the check reuses the built e2e harness
                  # instead of pulling a fresh full build of the default.
                  programs.dsh.package = e2eHarness;
                  programs.dsh.profiles.e2e = e2eProfileCfg;
                  programs.dsh.services.web.enable = true;
                }
              ];
            }).config;
            activationText = hmConfig.home.activation.dshProfiles.data;
            webExecStart = hmConfig.systemd.user.services."dsh-web".Service.ExecStart;
          in
          pkgs.runCommand "dsh-home-manager-eval"
            {
              inherit activationText webExecStart;
              passAsFile = [ "activationText" "webExecStart" ];
            }
            ''
              grep -q 'dsh_sync_profile e2e' "$activationTextPath"
              grep -q 'dsh-profile-e2e' "$activationTextPath"
              grep -q 'bin/dsh --profile web' "$webExecStartPath"
              grep -q -- '--no-open' "$webExecStartPath"
              echo "$activationTextPath" > $out
            '';
      };
    };
}
