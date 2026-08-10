// scripts/consensus.mjs
import fs from "node:fs";
import { parseArgs } from "./lib/args.mjs";

export function evaluateConsensus(claudePos, codexPos, opts) {
  const { round, defaultRounds, maxExtra } = opts;
  const cap = defaultRounds + Math.max(0, Math.min(maxExtra ?? 0, 2));
  // Tolerate both a raw position and a codex-client wrapper ({ threadId, text,
  // structured, status }) — the position fields live under `.structured` in the
  // wrapper, at the top level in a raw position.
  const claude = claudePos.structured ?? claudePos;
  const codex = codexPos.structured ?? codexPos;
  const a = new Set(claude.key_points ?? []);
  const b = new Set(codex.key_points ?? []);
  let divergence = 0;
  for (const p of a) if (!b.has(p)) divergence++;
  for (const p of b) if (!a.has(p)) divergence++;
  const consensus = Boolean(claude.agrees_with_opponent) && Boolean(codex.agrees_with_opponent);
  const capReached = round >= cap;
  const reason = consensus
    ? "both sides agree"
    : capReached
      ? `round cap ${cap} reached without consensus`
      : `divergence ${divergence}, continue`;
  return { consensus, divergence, capReached, reason };
}

function main() {
  const opts = parseArgs(process.argv.slice(2), {
    flags: [],
    values: ["claude", "codex", "round", "default-rounds", "max-extra", "out"]
  });
  const claudePos = JSON.parse(fs.readFileSync(opts.claude, "utf8"));
  const codexPos = JSON.parse(fs.readFileSync(opts.codex, "utf8"));
  const result = evaluateConsensus(claudePos, codexPos, {
    round: Number(opts.round),
    defaultRounds: Number(opts["default-rounds"] ?? 3),
    maxExtra: Number(opts["max-extra"] ?? 2)
  });
  fs.writeFileSync(opts.out, JSON.stringify(result, null, 2));
}

if (import.meta.url === `file://${process.argv[1]}`) main();
