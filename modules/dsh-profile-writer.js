#!/usr/bin/env node
// Write the dsh profile manifest files: package.json (dependencies +
// dsh.profile.bundles), cordis.patch.yml (the user patch layer as JSON —
// a valid YAML array), and pnpm-workspace.yaml (the boilerplate dsh writes
// into fresh profiles).
//
// Usage: dsh-profile-writer.js <outDir> <profileName> <staticBundlesJsonFile>
//        <patchesJsonFile> <pluginsTsv>
// plugins.tsv rows: <npmName>\t<version>\t<active:true|false>

"use strict";

const fs = require("fs");
const path = require("path");

const [outDir, profileName, staticBundlesFile, patchesFile, pluginsTsv] =
  process.argv.slice(2);

const staticBundles = JSON.parse(fs.readFileSync(staticBundlesFile, "utf8"));
const patches = JSON.parse(fs.readFileSync(patchesFile, "utf8"));

const rows = fs
  .readFileSync(pluginsTsv, "utf8")
  .split("\n")
  .filter((line) => line.length > 0)
  .map((line) => line.split("\t"));

const dependencies = {};
const activeBundles = [];
for (const [name, version, active] of rows) {
  dependencies[name] = version;
  if (active === "true") activeBundles.push(name);
}

const manifest = {
  name: "dsh-profile-" + profileName,
  private: true,
  dependencies,
  dsh: { profile: { bundles: [...staticBundles, ...activeBundles] } },
};

fs.writeFileSync(
  path.join(outDir, "package.json"),
  JSON.stringify(manifest, null, 2) + "\n",
);
// JSON is a valid YAML subset, and dsh's patch loader accepts either.
fs.writeFileSync(path.join(outDir, "cordis.patch.yml"), JSON.stringify(patches) + "\n");
fs.writeFileSync(
  path.join(outDir, "pnpm-workspace.yaml"),
  "packages:\n  - .\n\nnodeLinker: hoisted\nautoInstallPeers: false\n",
);
