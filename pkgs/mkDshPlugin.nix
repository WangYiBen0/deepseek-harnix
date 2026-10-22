# Build a DeepSeek Harness plugin ("bundle") from an npm package or a
# GitHub (or any) source tree, with no manual metadata.
#
# A DSH plugin is an npm package whose package.json declares
#   "dsh": { "bundle": { "patch": "./cordis.patch.yml" } }
# and whose code extends the harness through the cordis plugin loader
# (see dsh docs/cordis-primer.md). This helper:
#
#   * reads the package name, version, and description from the source's
#     package.json (a tiny import-from-derivation read, cached by Nix),
#   * detects the lockfile (pnpm-lock.yaml / package-lock.json / yarn.lock)
#     and builds with the matching package manager, fully offline,
#   * ships the package together with its node_modules so the plugin is
#     self-contained: dsh resolves a bundle's dependencies from the bundle's
#     own directory, and missing peers (cordis and friends) are supplied by
#     dsh's runtime resolver — a plugin must never bundle a second copy of
#     the cordis instance,
#   * outputs the plugin package directory (package.json at $out), ready to
#     be passed to deepseek-harness.override { pluginList = [ ... ]; } or to
#     the declarative module options.
#
# Usage:
#   mkDshPlugin {
#     source = fetchFromGitHub {
#       owner = "acme"; repo = "dsh-plugin-acme"; tag = "v1.2.3";
#       hash = "sha256-...";
#     };
#     pnpmDepsHash = "sha256-...";   # first run: keep lib.fakeHash and copy
#   }                                # the "got:" hash from the build error
#
#   mkDshPlugin {
#     npmName = "@acme/dsh-plugin-acme";
#     npmVersion = "1.2.3";
#     hash = "sha256-...";           # registry tarball hash
#     npmDepsHash = "sha256-...";
#   }
#
# For a pnpm/npm workspace repository, point at the member that is the
# plugin: mkDshPlugin { source = ...; packageDir = "packages/plugin"; }.
{

  lib,
  stdenv,
  nodejs_24,
  pnpm_11,
  pnpmConfigHook,
  pnpmBuildHook,
  npmHooks,
  fetchPnpmDeps,
  fetchNpmDeps,
  fetchYarnDeps,
  yarnConfigHook,
  fetchurl,
  runCommand,

  # Source tree holding the plugin's package.json (optionally under
  # `packageDir`). Any fetcher result or plain store path works.
  source ? null,

  # Alternative to `src`: fetch the plugin from the npm registry. Requires
  # `npmVersion` and `hash` (the registry tarball hash).
  npmName ? null,
  npmVersion ? null,
  hash ? null,

  # Overrides for the metadata read from package.json.
  pname ? null,
  version ? null,

  # Subdirectory of `src` holding the plugin package (workspace member).
  packageDir ? null,

  # Dependency-store hashes for the detected package manager. The default
  # lib.fakeHash makes the first build fail with the real hash to copy in.
  pnpmDepsHash ? lib.fakeHash,
  npmDepsHash ? lib.fakeHash,
  yarnDepsHash ? lib.fakeHash,

  # npm/yarn build script name.
  npmBuildScript ? "build",

  # Build a registry tarball from source despite it shipping lib/ (rarely
  # needed: the tarball is upstream's published artifact).
  npmBuild ? false,

  # A package-lock.json for registry tarballs that ship no lockfile. The
  # common case: generate once online from the tarball's package.json
  #   npm install --package-lock-only
  # and pass it here; `npm ci` then installs the runtime dependency tree
  # offline from the fetched npm cache. Regenerate when bumping npmVersion.
  npmLockfile ? null,

  # Drop devDependencies from the shipped node_modules (pnpm prune --prod /
  # npm prune --omit=dev). Off by default: some build layouts do not survive
  # pruning; enable when closure size matters.
  pruneDevDependencies ? false,

  # Extra env and native build inputs for the plugin's own build.
  env ? { },
  nativeBuildInputs ? [ ],

  # npm registry override for the build phase (pnpm/npm read
  # npm_config_registry). Useful behind networks that block
  # registry.npmjs.org; lockfile integrity hashes still apply.
  npmRegistry ? null,

  # Whether pnpm may auto-install missing peer dependencies while building.
  # dsh supplies peers (cordis and friends) through its runtime resolver, so
  # the default is false — a plugin must not bundle a second shared
  # instance. If the plugin's lockfile was generated with autoInstallPeers
  # enabled, pnpm fails with ERR_PNPM_LOCKFILE_CONFIG_MISMATCH: either set
  # this to true (the plugin will bundle its peers) or regenerate the
  # lockfile with `autoInstallPeers: false` in pnpm-workspace.yaml.
  autoInstallPeers ? false,

  # Static compatibility gate: a node-semver range the plugin supports,
  # checked against the harness version at evaluation time wherever the
  # plugin is wired in (package-set `withPlugins`, module plugin lists).
  # Mirrors dsh's own `engines.dsh` admission.
  dshVersionRange ? null,

  # nixpkgs-style meta overrides.
  meta ? { },

}:


let
  hasSrc = source != null;
  hasRegistry = npmName != null;

  registryTarball = fetchurl {
    url = let
      # @scope%2fname for scoped packages, plain name otherwise.
      encoded = lib.replaceStrings [ "/" ] [ "%2f" ] (lib.removePrefix "@" npmName);
      tarballBase = lib.last (lib.splitString "/" (lib.removePrefix "@" npmName));
    in assert hasRegistry -> npmVersion != null;
      "https://registry.npmjs.org/${encoded}/-/${tarballBase}-${npmVersion}.tgz";
    inherit hash;
  };

  # Registry tarball with an injected package-lock.json (when upstream ships
  # none and `npmLockfile` is provided).
  srcWithLock =
    if hasRegistry && npmLockfile != null then
      runCommand "dsh-plugin-src-${lib.strings.sanitizeDerivationName npmName}-${npmVersion}-locked" { } ''
        mkdir -p $out
        cp -r ${rawSrc}/. $out/
        cp ${npmLockfile} $out/package-lock.json
        chmod -R u+w $out
      ''
    else
      rawSrc;

  rawSrc =
    if hasRegistry then
      runCommand "dsh-plugin-src-${lib.strings.sanitizeDerivationName npmName}-${npmVersion}" { } ''
        mkdir -p $out
        tar -xzf ${registryTarball} -C $out --strip-components=1
      ''
    else
      source;

  # One cheap import-from-derivation read of the package metadata. Eval cost
  # is a single runCommand per unique plugin source; Nix caches the result.
  manifestDrv = runCommand "dsh-plugin-manifest-${lib.strings.sanitizeDerivationName (
    if hasRegistry then "${npmName}-${npmVersion}" else (baseNameOf (toString source))
  )}"
    {
      source = if hasRegistry then srcWithLock else rawSrc;
      nativeBuildInputs = [ nodejs_24 ];
      packageRelDir = if packageDir != null then packageDir else "";
    }
    ''
      pkg_dir="$source"
      if [ -n "$packageRelDir" ]; then
        pkg_dir="$source/$packageRelDir"
      fi
      if [ ! -f "$pkg_dir/package.json" ]; then
        echo "mkDshPlugin: no package.json at $pkg_dir" >&2
        echo '  For a pnpm/npm workspace repository set `packageDir` to the' >&2
        echo '  subdirectory containing the plugin package.' >&2
        exit 1
      fi
      node -e '
        const fs = require("fs");
        const path = require("path");
        const [pkgDir, lockRoot, out] = process.argv.slice(1);
        const manifest = JSON.parse(fs.readFileSync(path.join(pkgDir, "package.json"), "utf8"));
        let lockfile = null;
        for (const [file, name] of [
          ["pnpm-lock.yaml", "pnpm"],
          ["package-lock.json", "npm"],
          ["yarn.lock", "yarn"],
        ]) {
          if (fs.existsSync(path.join(lockRoot, file))) { lockfile = name; break; }
        }
        const count = (deps) => deps ? Object.keys(deps).length : 0;
        const result = {
          name: manifest.name,
          version: manifest.version,
          description: manifest.description || "",
          hasBuildScript: Boolean(manifest.scripts && manifest.scripts.build),
          lockfile,
          // runtime + dev: everything an offline install must materialize
          dependencyCount: count(manifest.dependencies) + count(manifest.devDependencies),
          // runtime only: what consumers of a published tarball need
          runtimeDependencyCount: count(manifest.dependencies),
        };
        fs.writeFileSync(out, JSON.stringify(result, null, 2));
      ' "$pkg_dir" "$source" "$out"
    '';

  manifest = builtins.fromJSON (builtins.readFile manifestDrv);

  finalName = if pname != null then pname else manifest.name;
  finalVersion = if version != null then version else manifest.version;

  # Directory the package manager operates in, relative to the source root.
  buildDir = if packageDir != null then packageDir else ".";

  pruneSnippet =
    if !pruneDevDependencies then "" else
    if manifest.lockfile == "pnpm" then
      "\n    (cd ${buildDir} && pnpm prune --prod)"
    else if manifest.lockfile == "npm" then
      "\n    (cd ${buildDir} && npm prune --omit=dev)"
    else "";

in
assert (hasSrc || hasRegistry) || throw "mkDshPlugin: pass `source` or `npmName`";
assert (hasSrc && hasRegistry) == false || throw "mkDshPlugin: pass `source` or `npmName`, not both";
assert
  !hasRegistry || (npmVersion != null && hash != null) || throw
    "mkDshPlugin: `npmName` requires `npmVersion` and `hash`";
assert
  manifest.name != null || pname != null || throw
    "mkDshPlugin: source package.json has no `name`; pass `pname` explicitly";
assert
  manifest.version != null || version != null || throw
    "mkDshPlugin: source package.json has no `version`; pass `version` explicitly";
assert
  manifest.lockfile != null || npmLockfile != null || (if hasRegistry then manifest.runtimeDependencyCount else manifest.dependencyCount) == 0 || throw ''
    mkDshPlugin: ${finalName} declares dependencies but ships no lockfile.
    Offline packaging needs one of pnpm-lock.yaml, package-lock.json, or
    yarn.lock at the source root. Ask upstream to commit one, or vendor the
    dependencies and clear dependencyCount by passing a `packageDir`.'';

stdenv.mkDerivation (finalAttrs: {
  pname = lib.strings.sanitizeDerivationName finalName;
  version = finalVersion;

  src = if hasRegistry then srcWithLock else rawSrc;

  env =
    lib.optionalAttrs (manifest.lockfile == "pnpm") {
      pnpm_config_auto_install_peers = if autoInstallPeers then "true" else "false";
    }
    // lib.optionalAttrs (npmRegistry != null) {
      npm_config_registry = npmRegistry;
      pnpm_config_registry = npmRegistry;
    }
    // env;

  preBuild = lib.optionalString (npmRegistry != null) ''
    printf 'registry=%s\n' "$npm_config_registry" > .npmrc
  '';

  pnpmRoot = if packageDir != null then packageDir else null;

  nativeBuildInputs =
    [ nodejs_24 ]
    ++ lib.optionals (manifest.lockfile == "pnpm") [
      pnpm_11
      pnpmConfigHook
      pnpmBuildHook
    ]
    ++ lib.optionals (manifest.lockfile == "npm") [
      npmHooks.npmConfigHook
      npmHooks.npmBuildHook
    ]
    ++ lib.optionals (manifest.lockfile == "yarn") [
      yarnConfigHook
    ]
    ++ nativeBuildInputs;

  pnpmDeps =
    if manifest.lockfile == "pnpm" then
      fetchPnpmDeps {
        inherit (finalAttrs) pname version;
        src = if hasRegistry then srcWithLock else source;
        pnpm = pnpm_11;
        fetcherVersion = 4;
        hash = pnpmDepsHash;
      }
    else
      null;

  npmDeps =
    if hasRegistry && (manifest.lockfile == "npm" || npmLockfile != null) then
      fetchNpmDeps {
        inherit (finalAttrs) pname version;
        src = srcWithLock;
        forceEmptyCache = manifest.dependencyCount == 0 && npmLockfile == null;
        # Registry tarballs ship prebuilt lib/: install the runtime tree only.
        npmInstallFlags = if npmBuild then "" else "--omit=dev";
        hash = npmDepsHash;
      }
    else if manifest.lockfile == "npm" then
      fetchNpmDeps {
        inherit (finalAttrs) pname version;
        src = source;
        forceEmptyCache = manifest.dependencyCount == 0;
        hash = npmDepsHash;
      }
    else
      null;

  yarnOfflineCache =
    if manifest.lockfile == "yarn" then
      fetchYarnDeps {
        inherit (finalAttrs) pname version;
        src = source;
        hash = yarnDepsHash;
      }
    else
      null;

  # Plugins without a build script ship their sources as-is.
  dontPnpmBuild = manifest.lockfile == "pnpm" && !manifest.hasBuildScript;
  dontNpmBuild =
    (manifest.lockfile != "pnpm" && (!manifest.hasBuildScript || hasRegistry)) && !npmBuild;
  inherit npmBuildScript;

  # yarn has no ready-made build hook: run the build script explicitly.
  buildPhase =
    if manifest.lockfile == "yarn" && manifest.hasBuildScript then
      ''
        runHook preBuild
        (cd ${buildDir} && yarn run ${npmBuildScript})
        runHook postBuild
      ''
    else null;

  installPhase = ''
    runHook preInstall${pruneSnippet}

    ${
      if (manifest.lockfile == "pnpm" && packageDir != null) then
        # Workspace member: `pnpm deploy` produces a self-contained directory
        # (own node_modules, pruned to production dependencies) — copying the
        # package directory alone would leave node_modules symlinks pointing
        # at the workspace root's virtual store.
        ''
        ws_root=$PWD
        while [ ! -f "$ws_root/pnpm-workspace.yaml" ] && [ "$ws_root" != "/" ]; do
          ws_root=$(dirname "$ws_root")
        done
        mkdir -p $out
        (cd "$ws_root" && pnpm --filter=${finalName} deploy --prod "$out")
        ''
    else
      ''
        mkdir -p $out
        cp -a ${buildDir}/. $out/
      ''
    }

    # Cross-platform binary packages can leave dangling symlinks in
    # node_modules/.pnpm; drop them so the fixup phase passes.
    if [ -d "$out/node_modules/.pnpm" ]; then
      find $out/node_modules/.pnpm -type l ! -exec test -e {} \; -delete
    fi

    test -f $out/package.json || {
      echo "mkDshPlugin: install produced no package.json in $out" >&2
      exit 1
    }

    runHook postInstall
  '';

  passthru = {
    # Exact npm package name/version — what profile manifests and bundle
    # lists refer to.
    npmName = finalName;
    npmVersion = finalVersion;
    isDshPlugin = true;
    manifest = manifestDrv;
    inherit dshVersionRange;
  };

  meta = {
    description = manifest.description;
    # A plugin may carry any license; this generic builder does not guess.
    platforms = nodejs_24.meta.platforms;
  } // meta;
})
