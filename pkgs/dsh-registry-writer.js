#!/usr/bin/env node
// Assemble the npm registry metadata documents (eval-time JSON plus the
// runtime-computed tarball hashes) and write catalog.json.
"use strict";

const fs = require("fs");
const path = require("path");

const [outDir, docsJsonFile, catalogJsonFile, rowsFile] = process.argv.slice(2);
const docs = JSON.parse(fs.readFileSync(docsJsonFile, "utf8"));
const catalog = JSON.parse(fs.readFileSync(catalogJsonFile, "utf8"));

const hashes = {};
for (const line of fs.readFileSync(rowsFile, "utf8").split("\n").filter(Boolean)) {
  const [enc, shasum, integrity] = line.split("\t");
  hashes[enc] = { shasum, integrity };
}

for (const doc of docs) {
  const { shasum, integrity } = hashes[doc.enc] || {};
  if (!shasum) {
    console.error("no hashes recorded for " + doc.name);
    process.exit(1);
  }
  const version = {
    name: doc.name,
    version: doc.version,
    description: doc.description,
    engines: doc.dshVersionRange ? { dsh: doc.dshVersionRange } : undefined,
    dist: {
      tarball: doc.tarballUrl,
      shasum,
      integrity,
    },
  };
  const docOut = {
    _id: doc.name,
    name: doc.name,
    "dist-tags": { latest: doc.version },
    versions: { [doc.version]: version },
  };
  fs.mkdirSync(path.join(outDir, doc.enc, "-"), { recursive: true });
  fs.writeFileSync(
    path.join(outDir, doc.enc, "index.json"),
    JSON.stringify(docOut, null, 2) + "\n",
  );
}

fs.writeFileSync(path.join(outDir, "catalog.json"), JSON.stringify(catalog, null, 2) + "\n");
