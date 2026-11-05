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
  zstd,
  sqlite,

  # Source tree holding the plugin's package.json (optionally under
  # `packageDir`). Any fetcher result or plain store path works.
  source ? null,

  # Alternative to `src`: fetch the plugin from the npm registry. `npmVersion`
  # and `hash` (the registry tarball hash) normally come with it, or from
  # `pluginLock` below.
  npmName ? null,
  # A concrete version, or "latest" to take the version the lock resolved.
  # `null` behaves like "latest" when a lock entry exists, so a declaration
  # that tracks a published package carries no version at all.
  npmVersion ? null,
  hash ? null,

  # Machine-generated pin data: a JSON file (or an already-parsed attrset)
  # whose `plugins.<lockKey>` entry supplies the resolved `version` plus
  # `hash`, `npmDepsHash`, `pnpmDepsHash`, `yarnDepsHash` and an optional
  # `npmLockfile` path (relative to the lock file). With a lock the call site
  # carries no hashes and no version — the one file
  # `scripts/lock-dsh-plugins.py` writes is the whole pin, so bumping a plugin
  # is a regeneration rather than a hand-copied digest.
  #
  # Deliberately not named `lock`: nixpkgs has a `pkgs.lock`, and callPackage
  # would inject it as an argument nobody asked for — the same trap that put
  # nixpkgs' `src` and `commit` into the harness derivation.
  pluginLock ? null,
  # Which lock entry this plugin reads. Defaults to `npmName`, then `pname`,
  # then the package name from package.json, so a registry plugin needs no
  # key of its own.
  lockKey ? null,

  # Overrides for the metadata read from package.json.
  pname ? null,
  version ? null,

  # Subdirectory of `src` holding the plugin package (workspace member).
  packageDir ? null,

  # Dependency-store hashes for the detected package manager. `null` (the
  # default) falls back to the lock entry, and then to lib.fakeHash, whose
  # first build fails with the real hash to copy in.
  pnpmDepsHash ? null,
  npmDepsHash ? null,
  yarnDepsHash ? null,

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
  # bundling a second shared instance is undesirable — but a frozen install
  # also fails with ERR_PNPM_LOCKFILE_CONFIG_MISMATCH when this disagrees
  # with the plugin's lockfile. `null` (the default) follows the lockfile and
  # falls back to false when the lock records no setting.
  autoInstallPeers ? null,

  # Extra `npm ci` flags for the npm path. Defaults to --legacy-peer-deps so
  # peer dependencies (cordis, @deepseek-ai/*) are left to the dsh runtime
  # instead of being resolved against the registry.
  npmFlags ? null,

  # Offline pnpm store for a nested workspace that the plugin's build script
  # installs itself (for example a vendored git submodule with its own
  # pnpm-lock.yaml). Pass `fetchPnpmDeps { src = ./vendor/foo; ...; }`.
  # Nix builds have no network, so the nested `pnpm install` must find every
  # package in this store.
  nestedPnpmDeps ? null,

  # Directory of that nested workspace, relative to the source root
  # (for example "vendor/dsh-std"). Its pnpm-workspace.yaml is extended
  # with the offline store settings.
  nestedPnpmDir ? null,

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

  # ── lock ──────────────────────────────────────────────────────────────────
  # `pluginLock` is either a path to the JSON file
  # `scripts/lock-dsh-plugins.py` maintains or an already-parsed attrset of it
  # (the generator passes a stubbed one in). Only `plugins.<key>` is read.
  lockData =
    if pluginLock == null then
      null
    else if builtins.isAttrs pluginLock then
      pluginLock
    else
      builtins.fromJSON (builtins.readFile pluginLock);

  # The lock key is the plugin's npm name, so a registry plugin needs none of
  # its own. A source plugin falls back to its package.json name; that read is
  # lazy and never happens for a registry plugin (whose npmVersion resolves
  # from the lock, whose key resolves from npmName — no cycle).
  lockKeyFinal =
    if lockKey != null then
      lockKey
    else if npmName != null then
      npmName
    else if pname != null then
      pname
    else if lockData != null then
      manifest.name
    else
      null;

  lockEntry =
    if lockData == null then
      null
    else
      lockData.plugins.${lockKeyFinal} or (throw ''
        mkDshPlugin: ${lockKeyFinal} has no entry in the lock.
        Run scripts/lock-dsh-plugins.py to generate it.'');

  # "latest" is the declaration-side spelling of "whatever the lock resolved
  # to". `null` means the same thing, so a plugin that tracks a published
  # package carries no version at all and one that is pinned says so.
  npmVersionFinal =
    if npmVersion != null && npmVersion != "latest" then
      npmVersion
    else if lockEntry != null then
      lockEntry.version or (throw "mkDshPlugin: lock entry ${lockKeyFinal} has no `version`")
    else
      npmVersion;

  hashFinal =
    if hash != null then
      hash
    else if lockEntry != null then
      lockEntry.hash or (throw "mkDshPlugin: lock entry ${lockKeyFinal} has no `hash`")
    else
      hash;

  # A lock entry may name a resolved dependency tree ("npmLockfile": a path
  # relative to the lock file itself), which is how `scripts/lock-dsh-plugins.py`
  # keeps a plugin with runtime dependencies to one declaration and one
  # generated file. Resolving it against the lock's own directory is what
  # makes the pair relocatable — the same lock works from a checkout, a store
  # path, or a consumer's `fetchFromGitHub`.
  lockfileFromLock =
    if lockEntry == null || !(lockEntry ? npmLockfile) then
      null
    else if !builtins.isPath pluginLock then
      throw ''
        mkDshPlugin: lock entry ${lockKeyFinal} names a package-lock.json, so
        `pluginLock` has to be a path (its directory is what that name is
        relative to), not an already-parsed attrset.''
    else
      dirOf pluginLock + "/${lockEntry.npmLockfile}";

  npmLockfileFinal = if npmLockfile != null then npmLockfile else lockfileFromLock;

  # An explicit argument wins over the lock, and a lock entry wins over the
  # placeholder hash whose failed build prints the real one.
  depHash =
    name: explicit:
    if explicit != null then
      explicit
    else if lockEntry != null && lockEntry ? ${name} then
      lockEntry.${name}
    else
      lib.fakeHash;

  # `@scope%2fname` for scoped packages, plain name otherwise. The leading
  # `@` is part of npm's scoped path — dropping it requests a different
  # (nonexistent) package and the mirror answers 404, so it stays.
  tarballUrl =
    assert hasRegistry -> npmVersionFinal != null;
    if npmVersionFinal == "latest" then
      throw ''
        mkDshPlugin: ${npmName} asks for the "latest" tag but no lock resolved
        it. Either name a version, or pass `pluginLock`
        (scripts/lock-dsh-plugins.py writes one).''
    else
      let
        encoded = lib.replaceStrings [ "/" ] [ "%2f" ] npmName;
        tarballBase = lib.last (lib.splitString "/" (lib.removePrefix "@" npmName));
      in
      "https://registry.npmjs.org/${encoded}/-/${tarballBase}-${npmVersionFinal}.tgz";

  registryTarball = fetchurl {
    url = tarballUrl;
    hash = hashFinal;
  };

  # Registry tarball with an injected package-lock.json (when upstream ships
  # none and the lock supplies one).
  srcWithLock =
    if hasRegistry && npmLockfileFinal != null then
      runCommand "dsh-plugin-src-${lib.strings.sanitizeDerivationName npmName}-${npmVersionFinal}-locked" { } ''
        mkdir -p $out
        cp -r ${rawSrc}/. $out/
        cp ${npmLockfileFinal} $out/package-lock.json
        chmod -R u+w $out
      ''
    else
      rawSrc;

  rawSrc =
    if hasRegistry then
      runCommand "dsh-plugin-src-${lib.strings.sanitizeDerivationName npmName}-${npmVersionFinal}" { } ''
        mkdir -p $out
        tar -xzf ${registryTarball} -C $out --strip-components=1
      ''
    else
      source;

  # A directory `source` is readable at evaluation time, so its metadata needs
  # no build at all. That matters beyond speed: import-from-derivation cannot
  # build a foreign system's derivation, so a Darwin evaluation on a Linux
  # machine would fail on every path-sourced plugin. Keep the field list in
  # step with the script in `manifestDrv` below.
  manifestFrom =
    root: pkgDir:
    let
      packageJson = builtins.fromJSON (builtins.readFile (pkgDir + "/package.json"));
      count = deps: if deps == null then 0 else builtins.length (builtins.attrNames deps);
      lockfile =
        if builtins.pathExists (root + "/pnpm-lock.yaml") then
          "pnpm"
        else if builtins.pathExists (root + "/package-lock.json") then
          "npm"
        else if builtins.pathExists (root + "/yarn.lock") then
          "yarn"
        else
          null;
      # pnpm records the settings a lockfile was created with; a frozen
      # install fails if our configuration disagrees.
      peerValue =
        if lockfile == "pnpm" then
          lib.findFirst (m: m != null) null (
            map (builtins.match "[[:space:]]*autoInstallPeers:[[:space:]]*(true|false).*") (
              lib.splitString "\n" (builtins.readFile (root + "/pnpm-lock.yaml"))
            )
          )
        else
          null;
    in
    {
      name = packageJson.name or null;
      version = packageJson.version or null;
      description = packageJson.description or "";
      hasBuildScript = (packageJson.scripts or { }) ? build;
      inherit lockfile;
      dependencyCount = count (packageJson.dependencies or null) + count (packageJson.devDependencies or null);
      runtimeDependencyCount = count (packageJson.dependencies or null);
      pnpmAutoInstallPeers = if peerValue == null then null else builtins.elemAt peerValue 0 == "true";
    };

  # A plain path is read directly.
  dirManifestUsable =
    !hasRegistry
    && builtins.isPath source
    && builtins.pathExists (
      if packageDir != null then source + "/${packageDir}/package.json" else source + "/package.json"
    );

  # Import-from-derivation read of the package metadata for sources that
  # cannot be read directly (fetched store paths, registry tarballs)
  manifestDrv = runCommand "dsh-plugin-manifest-${lib.strings.sanitizeDerivationName (
    if hasRegistry then "${npmName}-${npmVersionFinal}" else (baseNameOf (toString source))
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
        // pnpm records the settings a lockfile was created with; a frozen
        // install fails if our configuration disagrees.
        let pnpmAutoInstallPeers = null;
        if (lockfile === "pnpm") {
          const lock = fs.readFileSync(path.join(lockRoot, "pnpm-lock.yaml"), "utf8");
          const m = lock.match(/^\s*autoInstallPeers:\s*(true|false)\s*$/m);
          if (m) pnpmAutoInstallPeers = m[1] === "true";
        }
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
          pnpmAutoInstallPeers,
        };
        fs.writeFileSync(out, JSON.stringify(result, null, 2));
      ' "$pkg_dir" "$source" "$out"
    '';

  manifest =
    if dirManifestUsable then
      manifestFrom source (if packageDir != null then source + "/${packageDir}" else source)
    else
      # A registry tarball has to be unpacked before its package.json can be
      # read, which only a build can do (`fetchTarball` hashes the unpacked
      # tree, not the tarball we pinned).
      builtins.fromJSON (builtins.readFile manifestDrv);

  finalName = if pname != null then pname else manifest.name;

  autoInstallPeersFinal =
    if autoInstallPeers != null then
      autoInstallPeers
    else
      (manifest.pnpmAutoInstallPeers or null) == true;

  # Some upstreams list platform-specific binaries as plain dependencies
  # instead of optionalDependencies; npm then hard-fails with EBADPLATFORM on
  # any other platform. Detect that case in the lockfile and only then relax
  # the platform check.
  npmLockData =
    if hasRegistry && npmLockfileFinal != null then
      builtins.fromJSON (builtins.readFile npmLockfileFinal)
    else if !hasRegistry && manifest.lockfile == "npm" then
      builtins.fromJSON (builtins.readFile (rawSrc + "/package-lock.json"))
    else
      null;

  nodePlatform =
    {
      "x86_64-linux" = { cpu = "x64"; os = "linux"; };
      "aarch64-linux" = { cpu = "arm64"; os = "linux"; };
      "aarch64-darwin" = { cpu = "arm64"; os = "darwin"; };
    }
    .${stdenv.hostPlatform.system} or null;

  lockNeedsPlatformRelax =
    npmLockData != null
    && nodePlatform != null
    && lib.any (
      entry:
      !(entry.optional or false)
      && (
        (entry ? cpu && !(builtins.elem nodePlatform.cpu entry.cpu))
        || (entry ? os && !(builtins.elem nodePlatform.os entry.os))
      )
    ) (lib.attrValues (npmLockData.packages or { }));

  npmFlagsFinal =
    if npmFlags != null then
      npmFlags
    else
      lib.concatStringsSep " " (
        lib.optional (manifest.lockfile == "npm" && !autoInstallPeersFinal) "--legacy-peer-deps"
        ++ lib.optional lockNeedsPlatformRelax "--force"
      );
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
  !hasRegistry || (npmVersionFinal != null && hashFinal != null) || throw
    "mkDshPlugin: `npmName` needs a version and a hash: pass them explicitly, or pass `pluginLock` and let it resolve them";
assert
  manifest.name != null || pname != null || throw
    "mkDshPlugin: source package.json has no `name`; pass `pname` explicitly";
assert
  manifest.version != null || version != null || throw
    "mkDshPlugin: source package.json has no `version`; pass `version` explicitly";
assert
  manifest.lockfile != null || npmLockfileFinal != null || (if hasRegistry then manifest.runtimeDependencyCount else manifest.dependencyCount) == 0 || throw ''
    mkDshPlugin: ${finalName} declares dependencies but no lockfile is available.
    Nix builds without network, so the dependency tree has to be resolved
    ahead of time — npm/pnpm cannot honour a semver range here.
    Supply the resolution you already own:
      * pass `pluginLock`: scripts/lock-dsh-plugins.py resolves the tree and
        writes it into the lock entry next to the tarball hash
      * npm:  npmLockfile = ./package-lock.json
              (any lock you control; `npm install --package-lock-only` in a
              package.json that lists this plugin generates one)
      * pnpm: point `source` at the tree whose pnpm-lock.yaml covers the
              plugin and pass `pnpmDepsHash`
      * or vendor the dependencies and drop dependencyCount via `packageDir`.'';

stdenv.mkDerivation (finalAttrs: {
  pname = lib.strings.sanitizeDerivationName finalName;
  version = finalVersion;

  src = if hasRegistry then srcWithLock else rawSrc;

  env =
    lib.optionalAttrs (manifest.lockfile == "pnpm") {
      pnpm_config_auto_install_peers = if autoInstallPeersFinal then "true" else "false";
    }
    // lib.optionalAttrs (npmRegistry != null) {
      npm_config_registry = npmRegistry;
      pnpm_config_registry = npmRegistry;
    }
    // env;

  preBuild =
    lib.optionalString (npmRegistry != null) ''
      printf 'registry=%s\n' "$npm_config_registry" > .npmrc
    ''
    + lib.optionalString (nestedPnpmDeps != null) (
      let
        store = "$TMPDIR/nested-pnpm-store";
      in
      ''
        echo "mkDshPlugin: unpacking the nested pnpm store"
        nested_store=${store}
        mkdir -p "$nested_store"
        tar --zstd -xf ${nestedPnpmDeps}/pnpm-store.tar.zst -C "$nested_store"
        chmod -R +w "$nested_store"
        if [ -f "$nested_store/v11/index.db.sql" ]; then
          sqlite3 "$nested_store/v11/index.db" < "$nested_store/v11/index.db.sql"
          rm -f "$nested_store/v11/index.db.sql"
        fi
        # Nix builds have no network: point the nested workspace at this
        # store and make pnpm refuse to reach for a registry.
        ${lib.optionalString (nestedPnpmDir != null) ''
          nested_ws=${lib.escapeShellArg nestedPnpmDir}
          printf 'storeDir: %s\noffline: true\n' "$nested_store" >> "$nested_ws/pnpm-workspace.yaml"
        ''}
      ''
    );

  npmFlags = npmFlagsFinal;

  pnpmRoot = if packageDir != null then packageDir else null;

  nativeBuildInputs =
    [ nodejs_24 ]
    ++ lib.optionals (nestedPnpmDeps != null) [
      zstd
      sqlite
    ]
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
        hash = depHash "pnpmDepsHash" pnpmDepsHash;
      }
    else
      null;

  npmDeps =
    if hasRegistry && (manifest.lockfile == "npm" || npmLockfileFinal != null) then
      fetchNpmDeps {
        inherit (finalAttrs) pname version;
        src = srcWithLock;
        forceEmptyCache = manifest.dependencyCount == 0 && npmLockfileFinal == null;
        # Registry tarballs ship prebuilt lib/: install the runtime tree only.
        npmInstallFlags = if npmBuild then "" else "--omit=dev";
        hash = depHash "npmDepsHash" npmDepsHash;
      }
    else if manifest.lockfile == "npm" then
      fetchNpmDeps {
        inherit (finalAttrs) pname version;
        src = source;
        forceEmptyCache = manifest.dependencyCount == 0;
        hash = depHash "npmDepsHash" npmDepsHash;
      }
    else
      null;

  yarnOfflineCache =
    if manifest.lockfile == "yarn" then
      fetchYarnDeps {
        inherit (finalAttrs) pname version;
        src = source;
        hash = depHash "yarnDepsHash" yarnDepsHash;
      }
    else
      null;

  # Plugins without a build script ship their sources as-is.
  dontPnpmBuild = manifest.lockfile == "pnpm" && !manifest.hasBuildScript;
  dontNpmBuild =
    (manifest.lockfile != "pnpm" && (!manifest.hasBuildScript || hasRegistry)) && !npmBuild;
  inherit npmBuildScript;
  # pnpmBuildHook reads pnpmBuildScript, not npmBuildScript.
  pnpmBuildScript = npmBuildScript;

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
    # The parsed metadata; `manifest` is the derivation that produced it, kept
    # for callers that want the raw file.
    manifest = manifestDrv;
    manifestInfo = manifest;
    inherit dshVersionRange;
    # The lock entry this plugin resolved from, so a lock refresher can tell
    # which declarations still need one and which are already pinned.
    inherit lockKeyFinal npmVersionFinal;
    lockEntry = lockEntry;
  };

  meta = {
    description = manifest.description;
    # A plugin may carry any license; this generic builder does not guess.
    platforms = nodejs_24.meta.platforms;
  } // meta;
})
