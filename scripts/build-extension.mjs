// Builds both variants of the extension from extension/ into dist/:
//   dist/<variant>/                     unpacked, for "Load unpacked"
//   dist/tidy-tabs-<variant>-<v>.zip    for stores and manual installs
//   dist/tidy-tabs-<variant>-<v>.crx    signed, only when a signing key is available
// The key comes from CRX_PRIVATE_KEY (PEM text, as CI provides it) or keys/tidy-tabs.pem. It must match the "key" in
// the manifest, which fixes the extension ID the native host trusts; without it, no CRX is written, because crx3
// would sign with a fresh key and produce an extension the host refuses.
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import crx3 from "crx3";

const root = new URL("..", import.meta.url).pathname;
const source = join(root, "extension");
const dist = join(root, "dist");
const variants = {
  aside: { name: "Tidy Tabs for Aside" },
  chrome: { name: "Tidy Tabs" },
};

const manifest = JSON.parse(readFileSync(join(source, "manifest.json"), "utf8"));
const keyPath = signingKey();

rmSync(dist, { recursive: true, force: true });
for (const [variant, settings] of Object.entries(variants)) {
  const out = join(dist, variant);
  cpSync(source, out, { recursive: true });
  writeFileSync(join(out, "variant.js"), `export const VARIANT = ${JSON.stringify(variant)};\n`);
  writeFileSync(join(out, "manifest.json"), JSON.stringify({ ...manifest, name: settings.name }, null, 2) + "\n");

  const base = join(dist, `tidy-tabs-${variant}-${manifest.version}`);
  // crx3 always signs; with no real key, sign with a throwaway one and keep only the zip.
  const throwaway = keyPath ? null : mkdtempSync(join(tmpdir(), "tidy-tabs-"));
  await crx3([join(out, "manifest.json")], {
    keyPath: keyPath ?? join(throwaway, "key.pem"),
    crxPath: keyPath ? `${base}.crx` : join(throwaway, "unsigned.crx"),
    zipPath: `${base}.zip`,
  });
  if (throwaway) rmSync(throwaway, { recursive: true, force: true });
  console.log(`built ${variant}: ${base}.zip${keyPath ? " + .crx" : " (no signing key, so no .crx)"}`);
}

function signingKey() {
  if (process.env.CRX_PRIVATE_KEY) {
    const dir = mkdtempSync(join(tmpdir(), "tidy-tabs-key-"));
    const path = join(dir, "key.pem");
    writeFileSync(path, process.env.CRX_PRIVATE_KEY, { mode: 0o600 });
    process.on("exit", () => rmSync(dir, { recursive: true, force: true }));
    return path;
  }
  const local = join(root, "keys", "tidy-tabs.pem");
  return existsSync(local) ? local : null;
}
