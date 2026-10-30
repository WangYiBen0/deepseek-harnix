{
  lib,
  stdenv,
  bash,
  bash-completion,
  bubblewrap,
  curl,
  fetchFromGitHub,
  fetchPnpmDeps,
  fetchzip,
  fish,
  makeBinaryWrapper,
  nodejs_24,
  pnpm_11,
  pnpmBuildHook,
  pnpmConfigHook,
  runCommand,
  nix-update-script,
  testers,
  zsh,

  # Out-of-tree plugin ("bundle") derivations to bake into this installation.
  # Each plugin is symlinked into the installation's node_modules so the
  # two-anchor bundle resolver (installation anchor first, then the profile
  # directory) finds it for every profile — no pnpm install, no network.
  # Activate a baked-in plugin per profile either through the declarative
  # module options (programs.dsh.profiles.<name>.plugins) or interactively
  # with `dsh plugin`.
  #
  # Usage:
  #   deepseek-harness.override {
  #     pluginList = [ (mkDshPlugin { source = fetchFromGitHub { ... }; }) ];
  #   }
  #
  # Every plugin declaring `dshVersionRange` is checked against `version`
  # here, at evaluation time — this is the enforcement point that also covers
  # a direct `.override { pluginList = …; }` call, which does not pass through
  # the package set's `withPlugins`. `rangeChecker` is the node-semver subset
  # from `lib/`; the flake supplies it (standalone `callPackage` leaves it
  # null, so only the repository's own builds gate plugins).
  pluginList ? [],
  rangeChecker ? null,

  # Release coordinates. The flake passes these from versions.json; the
  # defaults keep this file standalone-buildable with callPackage.
  version ? "0.2.1-alpha.3",
  srcHash ? "sha256-W8iZIFJ7+RlB1O88D0g7fmAgPIFhVu2xnjtkVl90fMg=",
  pnpmDepsHash ? "sha256-gfDO4Z6Uks1dFLs7A+96tqTKEF1zEbZjVsQZzSQPFYA=",

  # The exact tag commit. When set, the source is fetched as a commit-pinned
  # tarball (deterministic across fetches); leaveDotGit's git-clone fetch is
  # not, which is why versions.json carries the commit for every entry.
  commit ? null,

  # Source override for the `git` channel: the archive URL of a specific
  # commit (`/archive/<sha>.tar.gz`) instead of the tag archive derived from
  # `version`. Still a commit-pinned tarball, so it stays deterministic.
  srcUrl ? null,

  # Appended to the derivation name for a channel build that shares upstream's
  # version string (again `git`). `version` keeps upstream's value, so
  # `dsh --version` output and passthru.tests.version stay truthful while the
  # store path and `nix flake show` still tell the two apart.
  nameSuffix ? null,
}:

let
  # A plugin's static compatibility gate, resolved from its passthru (what
  # `mkDshPlugin` sets) or a plain attribute for foreign derivations.
  pluginRange =
    plugin: plugin.passthru.dshVersionRange or plugin.dshVersionRange or null;

  checkedPluginList =
    if rangeChecker == null then
      pluginList
    else
      map (
        plugin:
        let
          range = pluginRange plugin;
        in
        if range == null then
          plugin
        else
          assert rangeChecker version range
            || throw "plugin ${plugin.pnpmName or plugin.pname or plugin.name} requires dsh ${range}, but this package is ${version}";
          plugin
      ) pluginList;

in

stdenv.mkDerivation (finalAttrs: {
  pname = "deepseek-harness";
  inherit version;

  name = "deepseek-harness-${version}" + lib.optionalString (nameSuffix != null) "-${nameSuffix}";

  strictDeps = true;
  __structuredAttrs = true;

  src =
    if commit != null then
      # Tag-named archive via fetchzip: deterministic bytes, no git clone.
      # (fetchFromGitHub falls back to a git clone for commit revs, which is
      # both slow and — with leaveDotGit — not reproducible.)
      fetchzip {
        # A release is the tag archive for its version; `git` passes the
        # archive of one specific commit instead (still a commit-pinned
        # tarball, so the fetch stays deterministic).
        url =
          if srcUrl != null then
            srcUrl
          else
            "https://github.com/deepseek-ai/deepseek-harness/archive/refs/tags/dsh-v${finalAttrs.version}.tar.gz";
        hash = srcHash;
        postFetch = ''
          echo ${commit} > $out/.git-commit
        '';
      }
    else
      fetchFromGitHub {
        owner = "deepseek-ai";
        repo = "deepseek-harness";
        rev = "dsh-v${finalAttrs.version}";
        hash = srcHash;

        # Capture the commit hash at fetch time to avoid git build dependency.
        # NOTE: git-clone fetches are not always reproducible — versions.json
        # entries carry `commit` so new releases use the branch above.
        leaveDotGit = true;
        postFetch = ''
          cd $out
          git rev-parse HEAD > .git-commit
          rm -rf .git
        '';
      };

  env = {
    pnpm_config_reporter = "append-only";
  } // lib.optionalAttrs (checkedPluginList != []) {
    # Space-separated plugin store paths. A list attr would not survive as an
    # environment variable under __structuredAttrs, and plugin names are only
    # known once each plugin's package.json exists, so the per-plugin symlink
    # loop below reads the name back at install time with node.
    dsh_plugin_store_paths = lib.concatMapStringsSep " " toString checkedPluginList;
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_11;
    fetcherVersion = 4;
    hash = pnpmDepsHash;
  };

  postPatch = ''
    substituteInPlace packages/boot/app-boot/src/profile-resolution/resolver.ts \
      --replace-fail \
      "  const addon = require('node-addon-require-builtin') as { requireBuiltin(moduleId: string): unknown }" \
      "  const requireBuiltin: (moduleId: string) => unknown = process.execArgv.includes('--expose-internals') ? require : require('node-addon-require-builtin').requireBuiltin" \
      --replace-fail \
      "addon.requireBuiltin(" \
      "requireBuiltin("

    # ── NixOS: the PTY backend hardcodes /bin/bash ──────────────────────────
    # terminal-bash's DEFAULT_BASH_SHELL is the literal "/bin/bash". NixOS has
    # no /bin/bash (only /bin/sh), so the persistent-shell PTY dies instantly
    # and tool-bash-persistent reports "PTY shell exited during startup". The
    # PTY execs argv[0] directly and never falls back to a PATH lookup, so the
    # default has to be the unmerged-usr name bash actually lives under.
    #
    # Only src/ is patched. The emitted lib/ (the tsdown bundle that is the
    # package "main", plus the tsc output) does NOT exist at patchPhase — it is
    # generated later by pnpmBuildHook, so patching it here aborts the build
    # with "file does not exist". No post-build fixup is needed in turn:
    # `build:lib:host` runs `tsc -b` then tsdown, both regenerating from src/,
    # so this one edit propagates into every emitted copy. Verified in the
    # built store output (lib/index.js, lib/types/config.js, lib/types/config.d.ts).
    bash_shell_path=/run/current-system/sw/bin/bash

    substituteInPlace packages/terminal/terminal-bash/src/config.ts \
      --replace-fail "export const DEFAULT_BASH_SHELL = '/bin/bash'" \
        "export const DEFAULT_BASH_SHELL = '$bash_shell_path'"

    grep -q "DEFAULT_BASH_SHELL = '$bash_shell_path'" \
      packages/terminal/terminal-bash/src/config.ts
  '';

  nativeBuildInputs = [
    nodejs_24
    pnpmConfigHook
    pnpmBuildHook
    pnpm_11
    makeBinaryWrapper
  ];

  # Only used by installCheckPhase, which drives each shell's real completion
  # machinery against the installed scripts.
  nativeCheckInputs = [
    bash
    bash-completion
    fish
    zsh
  ];

  preBuild = ''
    export DSH_CLIENT_COMMIT_HASH=$(cat $src/.git-commit)
    export DSH_CLIENT_BUILD_PROFILE="official";
  '';

  # The root 'build' script runs both 'build:lib' and 'build:web'
  # pnpmBuildHook runs 'pnpm run build' by default
  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/libexec/dsh
    cp -r . $out/libexec/dsh/

    # The .git-commit marker only feeds the build-time commit stamp.
    rm -f $out/libexec/dsh/.git-commit

    # The whole tree is shipped because workspace packages resolve in-tree via
    # linkWorkspacePackages; dev/test/doc files come along for the ride.

    # Optional cross-platform binary packages leave dangling symlinks in
    # node_modules/.pnpm; drop them so the fixup phase passes.
    find $out/libexec/dsh/node_modules/.pnpm -type l ! -exec test -e {} \; -delete

    # pnpm only links workspace packages into each dependent package's own
    # node_modules, so the loader's bare `import(name)` (vendor/loader) cannot
    # resolve workspace specifiers from its own directory. Mirror the virtual
    # store's scoped packages into the root node_modules so bare specifiers
    # resolve anywhere in the tree. This relies on `linkWorkspacePackages: true`
    # in upstream's pnpm-workspace.yaml, which is what places workspace
    # packages under .pnpm/node_modules at all.
    shopt -s nullglob
    store_scopes=("$out/libexec/dsh/node_modules/.pnpm/node_modules/"@*/)
    for scope in "''${store_scopes[@]}"; do
      scope_name=$(basename "$scope")
      mkdir -p "$out/libexec/dsh/node_modules/$scope_name"
      for pkg in "$scope"*; do
        # -n: do not dereference an existing symlink-to-dir (e.g. the root
        # devDep dsh-tool-session-query) when replacing it.
        ln -sfn "../.pnpm/node_modules/$scope_name/$(basename "$pkg")" \
          "$out/libexec/dsh/node_modules/$scope_name/$(basename "$pkg")"
      done
    done

    # ── Baked-in out-of-tree plugins (pluginList) ────────────────────────────
    # The bundle resolver probes Node's own node_modules lookup from the
    # installation anchor (the running app's package.json) before falling back
    # to the profile directory, so a plugin symlinked anywhere on that chain —
    # the workspace mirror above uses the same trick for in-tree packages —
    # resolves for every profile without a pnpm install. Each plugin ships its
    # own node_modules, and missing peers (cordis and friends) are supplied by
    # the runtime resolver, exactly as for profile-installed plugins.
    if [ -n "''${dsh_plugin_store_paths:-}" ]; then
      for plugin in $dsh_plugin_store_paths; do
        plugin_name=$(${nodejs_24}/bin/node -p "require('$plugin/package.json').name")
        plugin_dir=$out/libexec/dsh/node_modules/$(dirname "$plugin_name")
        mkdir -p "$plugin_dir"
        # -n: an unscoped name must not dereference an existing symlink.
        ln -sfn "$plugin" "$out/libexec/dsh/node_modules/$plugin_name"
      done
    fi

    ln -s ../libexec/dsh/node_modules/pnpm/bin/pnpm.mjs $out/bin/pnpm

    # --expose-internals is required by the HMR service and the loader's
    # internal module loader; it must precede the script path so it lands in
    # process.execArgv. Depends on Node internals, not a stable API.
    makeBinaryWrapper ${nodejs_24}/bin/node $out/bin/dsh \
      --add-flags "--expose-internals $out/libexec/dsh/apps/cli/lib/bin.js" \
      --prefix PATH : ${
        lib.makeBinPath (
          # Linux namespaces are what the sandbox uses; macOS has no
          # equivalent, so the wrapper simply ships without it there.
          lib.optionals stdenv.hostPlatform.isLinux [ bubblewrap ] ++ [ nodejs_24 ]
        )
      }:$out/bin

    # ── Shell completions ─────────────────────────────────────────────────────
    # dsh ships none (commander has no completion support); these static
    # scripts mirror the 0.2.x CLI surface and complete profile names from
    # $DSH_HOME/profiles at runtime.
    install -Dm444 ${./completions/dsh.bash} $out/share/bash-completion/completions/dsh
    install -Dm444 ${./completions/_dsh.zsh} $out/share/zsh/site-functions/_dsh
    install -Dm444 ${./completions/dsh.fish} $out/share/fish/vendor_completions.d/dsh.fish

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    export HOME=$TMPDIR
    $out/bin/dsh --version

    expected_pnpm_version=$(
      ${nodejs_24}/bin/node -p \
        "require('$out/libexec/dsh/package.json').packageManager.split('@')[1]"
    )
    actual_pnpm_version=$(
      cd $out/libexec/dsh
      PNPM_CONFIG_PM_ON_FAIL=error $out/bin/pnpm --version
    )
    test "$actual_pnpm_version" = "$expected_pnpm_version"

    # ── Shell completions ────────────────────────────────────────────────────
    # A file that exists but cannot register itself is indistinguishable from
    # a missing one to the user, so each shell is driven through its own
    # completion machinery and the words it offers are compared. The checks
    # live in a script to keep the shell quoting readable.
    dsh_out=$out \
    dsh_bash=${bash} \
    dsh_bashcomp=${bash-completion} \
    dsh_fish=${fish} \
    dsh_zsh=${zsh} \
      ${bash}/bin/bash ${./completions/install-check.sh}
  '';

  passthru = {
    # The plugins baked into this installation, and the same override as a
    # call: `harness.withPlugins [ more-plugin ]`.
    pluginList = checkedPluginList;
    withPlugins = more: finalAttrs.finalPackage.override { pluginList = checkedPluginList ++ more; };

    # NOTE: in this repository the canonical update path is the append-only
    # versions.json maintained by .github/workflows/update-versions.yml; the
    # updateScript only serves standalone callPackage use of this file.
    updateScript = nix-update-script {
      # TODO: Drop after 1.0
      # Tags are prefixed with "dsh-v"; strip it during extraction so the
      # prefix never leaks into the `version` field (which happens when the
      # pinned version is already the latest tag — nix-update falls back to
      # the raw tag and only strips a bare "v", corrupting
      # `rev = "dsh-v${finalAttrs.version}"`).
      extraArgs = [
        "--flake"
        "--version"
        "unstable"
        "--version-regex"
        "dsh-v(.*)"
      ];
    };
    tests = {
      version = testers.testVersion { package = finalAttrs.finalPackage; };

      # Boots the web profile and verifies the server actually serves. Guards the
      # fragile parts: the loader's bare import() of workspace specifiers and the
      # --expose-internals requirement.
      web-boot = runCommand "deepseek-harness-web-boot" { nativeBuildInputs = [ curl ]; } ''
        export HOME=$TMPDIR

        echo "Running deepseek-harness..."
        ${finalAttrs.finalPackage}/bin/dsh --profile web --no-open >server.log 2>&1 &
        pid=$!
        trap 'kill $pid 2>/dev/null || true' EXIT

        # Find the serving url with the session cookie
        for i in $(seq 1 30); do
          if launch_url=$(grep -o 'http://127.0.0.1:3080/?token=[^[:space:]]*' server.log); then
            break
          fi
          sleep 1
        done
        if [ -z "''${launch_url:-}" ]; then
          echo "dsh web profile failed to print the authenticated launch URL" >&2
          cat server.log >&2
          exit 1
        fi
        echo "✓ Found launch URL on server logs ($launch_url)"

        # Verify we get a seemingly valid page served.
        if ! curl -fsSL -c cookies.txt "$launch_url" >page.html 2>curl.log \
          || ! grep -q '<!doctype html>' page.html; then
          echo "dsh web profile failed to serve the index via the launch token" >&2
          cat curl.log >&2
          cat server.log >&2
          exit 1
        fi
        echo "✓ Found seemingly valid HTML on it"

        touch $out
      '';
    };
  };

  meta = {
    description = "AI agent harness with a plugin-based architecture";
    longDescription = ''
      DeepSeek Harness (dsh) is a self-hosted AI agent harness built around a
      plugin architecture — "Everything is a Plugin". It ships a CLI and a web
      UI and is extended through workspace plugins.
    '';
    homepage = "https://github.com/deepseek-ai/deepseek-harness";
    license = lib.licenses.mit;

    mainProgram = "dsh";

    platforms = [
      "aarch64-linux"
      "x86_64-linux"
      "aarch64-darwin"
    ];
  };
})
