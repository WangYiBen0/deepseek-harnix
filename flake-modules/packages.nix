{ lib, flakelib, inputs, config, ... }:

let
  pkgsFor = system: inputs.nixpkgs.legacyPackages.${system};
  catalogFor = pkgs: import ../pkgs/dsh-plugins.nix { inherit pkgs; };

  # The single generator for release-keyed derivations. It takes the version
  # string, so nothing is instantiated until a caller actually asks for that
  # version: no attribute set of pre-built packages has to be materialised,
  # and `nix flake check` / `nix flake show` never walk a growing catalogue.
  packageSetFor =
    pkgs: version:
    let
      entry = lib.findFirst (release: release.version == version) null flakelib.releases;
    in
    if entry == null then
      throw "deepseek-harnix: unknown dsh release '${version}'. Known versions: ${
        lib.concatStringsSep ", " (map (release: release.version) flakelib.releases)
      }"
    else
      flakelib.mkDshPackageSet pkgs entry;

  upperFirst =
    s: (lib.toUpper (builtins.substring 0 1 s)) + (builtins.substring 1 (builtins.stringLength s) s);

  # The `unstable` package set: the pinned head of the upstream branch (see
  # pkgs/unstable.json), so this builds the git repository rather than a
  # released tag.
  unstableSetFor = pkgs: flakelib.mkDshPackageSet pkgs flakelib.unstableRelease;

  channels = [ "stable" "rc" "beta" "alpha" ];

  # latestStable / latestRc / latestBeta / latestAlpha — only when the
  # channel has a release.
  channelSets = pkgs: lib.listToAttrs (
    lib.concatMap (
      channel:
      let
        entry = flakelib.latestOf channel;
      in
      lib.optional (entry != null) (
        lib.nameValuePair "latest${upperFirst channel}" (flakelib.mkDshPackageSet pkgs entry)
      )
    ) channels
  );

  # The same channel shortcuts as real, individually nameable packages.
  # `nix flake show` only ever prints derivations, so anything buried in an
  # attribute set of attribute sets — `dshPackageSets` — is invisible to it
  # (no `--legacy` flag changes that: plain attrsets are not recursed into).
  # One alias per channel plus the branch head keeps `packages` O(channels),
  # never O(releases), and every alias resolves to the same derivation as its
  # version, so `nix flake check` still builds each distinct release once.
  channelPackages =
    pkgs:
    lib.listToAttrs (
      lib.concatMap (
        channel:
        let
          entry = flakelib.latestOf channel;
        in
        lib.optional (entry != null) (
          lib.nameValuePair "deepseek-harness-${channel}" (flakelib.mkDshPackageSet pkgs entry).deepseek-harness
        )
      ) channels
    );
in
{
  flake = {
    # Per-release package sets and the curated plugin catalog are plain data,
    # not derivations, so they live under `legacyPackages` — the flake schema
    # has no slot for them, and inventing a top-level output makes
    # `nix flake show` render it as "unknown" and flake checkers warn.
    #
    # Every entry below is a thunk: `dshPackageSet` is a function, and the
    # attrset is built by mapping it over the version list, so referencing one
    # version evaluates one release — never the whole catalogue.
    #
    # One entry per declared system, not just the machine doing the
    # evaluating: `nix flake check` (and the CI job that reviews the macOS
    # outputs on Linux) has to be able to read the attribute set for a system
    # it is not running on. Each system's `pkgs` is still only forced when
    # something asks for it.
    legacyPackages = lib.genAttrs config.systems (
      system:
      let
        pkgs = pkgsFor system;
      in
      {
        dshPackageSet = packageSetFor pkgs;

        dshPackage = version: (packageSetFor pkgs version).deepseek-harness;

        dshPackageSets = {
          latest = flakelib.mkDshPackageSet pkgs (flakelib.latestOf "any");
          unstable = unstableSetFor pkgs;
        } // channelSets pkgs // lib.listToAttrs (
          map (release: lib.nameValuePair release.version (packageSetFor pkgs release.version)) flakelib.releases
        );

        dshPlugins = catalogFor pkgs;
      }
    );
  };

  perSystem =
    { pkgs, config, ... }:
    {
      # Every *versioned* derivation is generated on demand through
      # `legacyPackages.<system>.dshPackageSet`, so `packages` never grows with
      # the release list. What lives here is the default release, the branch
      # head, and one alias per channel: `nix flake show` cannot print an
      # attribute set, and a shortcut that cannot be discovered is not much of
      # a shortcut.
      packages = {
        deepseek-harness = (flakelib.mkDshPackageSet pkgs flakelib.defaultRelease).deepseek-harness;
        default = config.packages.deepseek-harness;
        deepseek-harness-unstable = (unstableSetFor pkgs).deepseek-harness;

        # Static npm registry tree built from the curated catalog — the
        # plugin-manager "subscription link".
        dsh-plugin-registry = pkgs.callPackage ../pkgs/dsh-plugin-registry.nix {
          plugins = catalogFor pkgs;
        };
      } // channelPackages pkgs;

      apps = {
        dsh = {
          type = "app";
          program = "${config.packages.deepseek-harness}/bin/dsh";
        };
        default = config.apps.dsh;
      };
    };
}
