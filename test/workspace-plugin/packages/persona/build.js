const fs = require("fs");
const yaml = require("js-yaml");
const patch = yaml.load(fs.readFileSync("cordis.patch.yml", "utf8"));
fs.mkdirSync("lib", { recursive: true });
fs.writeFileSync(
  "lib/index.js",
  "export const persona = " + JSON.stringify(patch) + ";\n",
);
