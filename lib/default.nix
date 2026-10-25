# Internal helpers shared by the flake-modules output wiring.
{ lib }:

let
  # Compose the release-shaped entry for the branch head. The version stays
  # upstream's own string (so `dsh --version` and the version test are
  # truthful) and the commit is what distinguishes the build.
  unstableRelease = {
    inherit (unstablePin) version commit srcHash pnpmDepsHash;
    srcUrl = "https://github.com/deepseek-ai/deepseek-harness/archive/${unstablePin.commit}.tar.gz";
    nameSuffix = "unstable-${builtins.substring 0 7 unstablePin.commit}";
    unstable = true;
  };

  releases = (builtins.fromJSON (builtins.readFile ../pkgs/versions.json)).versions;

  # Tracking pin for the `unstable` package set (branch head, rewritten by the
  # update workflow), kept separate from the append-only release list.
  unstablePin = builtins.fromJSON (builtins.readFile ../pkgs/unstable.json);

  toIntOr0 = s: if builtins.match "[0-9]+" s != null then lib.toInt s else 0;

  # Split a version into comparable parts: main numeric components, the
  # pre-release label ("" when stable) and its number.
  versionInfo =
    v:
    let
      parts = lib.splitString "-" v;
      preHead = if lib.length parts > 1 then lib.head (lib.tail parts) else "";
      preParts = lib.splitString "." preHead;
    in
    {
      mainNums = map toIntOr0 (lib.splitString "." (lib.head parts));
      preLabel = if preParts == [ "" ] then "" else lib.head preParts;
      preNum = if lib.length preParts > 1 then toIntOr0 (lib.elemAt preParts 1) else 0;
    };

  # alpha < beta < rc < stable; unknown labels rank as stable.
  preRankOf = l: { alpha = 0; beta = 1; rc = 2; }.${l} or 3;

  cmpNums =
    x: y:
    if x == [ ] && y == [ ] then 0
    else if x == [ ] then (if lib.head y == 0 then cmpNums [ ] (lib.tail y) else -1)
    else if y == [ ] then (if lib.head x == 0 then cmpNums (lib.tail x) [ ] else 1)
    else if lib.head x < lib.head y then -1
    else if lib.head x > lib.head y then 1
    else cmpNums (lib.tail x) (lib.tail y);

  # Semver-ish compare of two version strings: -1 / 0 / 1.
  versionCompare =
    a: b:
    let
      ia = versionInfo a;
      ib = versionInfo b;
      mainCmp = cmpNums ia.mainNums ib.mainNums;
      preCmp =
        if preRankOf ia.preLabel != preRankOf ib.preLabel then
          (if preRankOf ia.preLabel < preRankOf ib.preLabel then -1 else 1)
        else if ia.preNum != ib.preNum then
          (if ia.preNum < ib.preNum then -1 else 1)
        else
          0;
    in
    if mainCmp != 0 then mainCmp else preCmp;

  # "0.2.1-rc.2" → "rc"; "1.0.0" → "stable".
  channelOf = v: (versionInfo v).preLabel;

  # 0.2.1-rc.2 → 0_2_1_rc_2 (derivation-ish output names cannot contain dots).
  sanitizeVersion =
    v:
    lib.concatStrings (
      map (c: if builtins.match "[A-Za-z0-9]" c != null then c else "_") (lib.stringToCharacters v)
    );

  # Node-semver range subset for static plugin ↔ harness gating: whitespace
  # or comma separated comparators `>= > <= < =` plus `^` and `~` (expanded
  # to an upper bound). Unknown syntax fails evaluation loudly instead of
  # passing silently.
  dshSatisfiesRange =
    let
      bump =
        index: target:
        let
          main = lib.head (lib.splitString "-" target);
          parts = lib.splitString "." main;
          padded = parts ++ lib.genList (_: "0") (3 - lib.length parts);
          bumped = lib.imap0 (
            i: p: if i < index then p else if i == index then toString ((toIntOr0 p) + 1) else "0"
          ) padded;
        in
        lib.concatStringsSep "." bumped;

      cmpToken =
        version: op: target:
        let c = versionCompare version target; in
        if op == ">=" then c >= 0
        else if op == ">" then c > 0
        else if op == "<=" then c <= 0
        else if op == "<" then c < 0
        else c == 0;

      tokenOk =
        version: token:
        let
          m = builtins.match "(>=|<=|>|<|=|\\^|~)?[[:space:]]*([^ ].*)" token;
        in
        if m == null then
          throw "dshVersionRange: cannot parse token ${builtins.toJSON token} (supported: >= > <= < = ^ ~)"
        else
          let
            op = lib.head m;
            target = lib.elemAt m 1;
          in
          if op == "^" then
            dshSatisfiesRange version ">=${target} <${bump 0 target}"
          else if op == "~" then
            dshSatisfiesRange version ">=${target} <${bump 1 target}"
          else
            cmpToken version (if op == "" then "=" else op) target;
    in
    version: range:
    lib.all (tokenOk version) (
      lib.filter (t: t != "") (
        lib.splitString " " (lib.replaceStrings [ "," "\n" "\t" ] [ " " " " " " ] range)
      )
    );
in
{
  inherit releases versionCompare channelOf sanitizeVersion dshSatisfiesRange;
  inherit unstableRelease;
  defaultRelease = lib.last releases;

  # Newest release of a channel ("any", "stable", "rc", "beta", "alpha");
  # null when the channel has no release.
  latestOf =
    channel:
    let
      candidates =
        if channel == "any" then releases
        else lib.filter (e: channelOf e.version == channel) releases;
    in
    if candidates == [ ] then
      null
    else
      lib.foldl' (
        acc: e: if versionCompare e.version acc.version > 0 then e else acc
      ) (lib.head candidates) candidates;

  # One release entry (pkgs/versions.json) → one package set.
  mkDshPackageSet =
    pkgs: entry:
    let
      deepseek-harness = pkgs.callPackage ../pkgs/deepseek-harness.nix {
        inherit (entry) version srcHash pnpmDepsHash;
        commit = entry.commit or null;
        srcUrl = entry.srcUrl or null;
        nameSuffix = entry.nameSuffix or null;
        # The harness itself gates its `pluginList`, so a bare
        # `.override { pluginList = …; }` — which bypasses `withPlugins` —
        # is checked too.
        rangeChecker = dshSatisfiesRange;
      };
    in
    {
      inherit (entry) version;
      unstable = entry.unstable or false;
      inherit deepseek-harness;
      dsh = deepseek-harness;
      # Static compatibility gate: a plugin's `dshVersionRange` (if declared)
      # must admit this set's harness version. Kept here as well as in the
      # harness so the failure names the package set (more legible than a
      # bare derivation error) and so this path stays explicit.
      withPlugins =
        pluginList:
        deepseek-harness.override {
          pluginList = map (
            plugin:
            let
              range = plugin.passthru.dshVersionRange or plugin.dshVersionRange or null;
            in
            if range == null then
              plugin
            else
              assert dshSatisfiesRange entry.version range
                || throw "plugin ${plugin.pnpmName or plugin.pname or plugin.name} requires dsh ${range}, but this package set is ${entry.version}";
              plugin
          ) pluginList;
        };
      mkDshPlugin = args: pkgs.callPackage ../pkgs/mkDshPlugin.nix args;
    };
}
