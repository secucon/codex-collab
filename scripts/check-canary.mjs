import fs from "node:fs";
import { pathToFileURL } from "node:url";

export function canaryPasses(result) {
  if (result.ok === true) return result.phase === "turn-completed";
  if (!["initialized", "thread-started"].includes(result.phase)) return false;
  const info = result.codexErrorInfo;
  const unauthorized = info === "Unauthorized" || (info && typeof info === "object" && (
    Object.hasOwn(info, "Unauthorized") || Object.values(info).some(v => v?.httpStatusCode === 401)
  ));
  // Older CLI versions provide only text for missing local credentials. Match
  // explicit authentication failures, never an arbitrary post-handshake error.
  const missingCredentials = /^unexpected status 401 Unauthorized: Missing bearer or basic authentication in header(?:, url: https:\/\/api\.openai\.com\/v1\/responses(?:, cf-ray: [A-Za-z0-9-]+)?(?:, request id: [A-Za-z0-9_-]+)?)?\.?$/i.test(result.error ?? "");
  return Boolean(unauthorized || missingCredentials || /^(not logged in\.?|authentication required\.?|missing bearer or basic authentication in header\.?)$/i.test(result.error ?? ""));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const result = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
    if (!canaryPasses(result)) throw new Error(`canary failed at ${result.phase}: ${result.error ?? "invalid result"}`);
    console.log(result.ok ? "canary: completed" : "canary: explicit authentication failure (turn not verified)");
  } catch (e) { console.error(e.message); process.exitCode = 1; }
}
