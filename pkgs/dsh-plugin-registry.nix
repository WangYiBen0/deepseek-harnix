# Turn the curated plugin catalog (pkgs/dsh-plugins.nix) into a static,
# servable npm registry tree — the "subscription link" dsh's plugin manager
# can install from via its registry field (pnpm `--registry`).
#
#   nix build .#dshPluginRegistry
#   cd result && python3 -m http.server 4873
#   # then point the plugin manager (or `pnpm --registry`) at
#   # http://127.0.0.1:4873
#
# Layout per package: <encoded-name>/index.json (npm metadata document with
# dist.tarball/shasum/integrity and the plugin's `engines.dsh` range) and
# <encoded-name>/-/<tarball>. A top-level catalog.json summarizes the list.
{
  lib,
  stdenv,
  nodejs,
  plugins ? { },
  registryBaseUrl ? "http://127.0.0.1:4873",
}:

let
  writer = ./dsh-registry-writer.js;

  # Per-plugin metadata, read from the plugin's manifest (IFD, already
  # computed by mkDshPlugin and cached by Nix).
  metaOf =
    plugin:
    let
      m = builtins.fromJSON (builtins.readFile plugin.passthru.manifest);
    in
    {
      name = m.name;
      version = m.version;
      description = m.description;
      dshVersionRange = plugin.passthru.dshVersionRange or null;
      # npm registry encoding: @scope%2fname; tarball file drops the scope.
      enc = lib.replaceStrings [ "/" ] [ "%2f" ] m.name;
      tarballFile = "${lib.last (lib.splitString "/" m.name)}-${m.version}.tgz";
    };

  registryDoc =
    name: plugin:
    let
      m = metaOf plugin;
    in
    builtins.toJSON {
      _id = m.name;
      name = m.name;
      "dist-tags" = { latest = m.version; };
      versions = {
        ${m.version} = {
          name = m.name;
          version = m.version;
          description = m.description;
          engines = lib.optionalAttrs (m.dshVersionRange != null) { dsh = m.dshVersionRange; };
          dist = {
            tarball = "${registryBaseUrl}/${m.enc}/-/${m.tarballFile}";
            shasum = "@SHASUM@";
            integrity = "@INTEGRITY@";
          };
        };
      };
    };

  catalogData = {
    inherit registryBaseUrl;
    plugins = lib.mapAttrs (name: plugin: (metaOf plugin) // { source = toString plugin; }) plugins;
  };
in
stdenv.mkDerivation {
  name = "dsh-plugin-registry";

  nativeBuildInputs = [ nodejs ];

  catalogJson = builtins.toJSON catalogData;
  docsJson = builtins.toJSON (
    lib.mapAttrsToList (
      name: plugin:
      let m = metaOf plugin; in
      {
        name = m.name;
        enc = m.enc;
        version = m.version;
        description = m.description;
        dshVersionRange = m.dshVersionRange;
        tarballUrl = "${registryBaseUrl}/${m.enc}/-/${m.tarballFile}";
      }
    ) plugins
  );
  passAsFile = [ "catalogJson" "docsJson" ];

  buildCommand = ''
    mkdir -p $out
    : > rows.tsv

    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: plugin:
        let
          m = metaOf plugin;
        in
        ''
          pluginPath=${toString plugin}
          enc=${m.enc}
          mkdir -p "$out/$enc/-"
          tgz="$out/$enc/-/${m.tarballFile}"
          # npm tarballs carry a single top-level package/ directory.
          tar --transform 's,^\./,package/,' -czf "$tgz" -C "$pluginPath" .

          shasum=$(sha1sum "$tgz" | cut -d" " -f1)
          integrity="sha512-$(printf "$(sha512sum "$tgz" | cut -d" " -f1 | sed 's/../\\x&/g')" | base64 -w0)"
          printf '%s\t%s\t%s\n' "$enc" "$shasum" "$integrity" >> rows.tsv
        ''
      ) plugins
    )}

    node ${writer} "$out" "$docsJsonPath" "$catalogJsonPath" rows.tsv

    ! grep -l '@SHASUM@\|@INTEGRITY@' $out/*/index.json
    test -f $out/catalog.json
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: plugin: ''test -f "$out/${(metaOf plugin).enc}/index.json"'') plugins
    )}
  '';

  passthru = {
    inherit plugins registryBaseUrl;
  };

  meta = {
    description = "Static npm registry tree serving the curated dsh plugin catalog";
  };
}
