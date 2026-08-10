// scripts/consensus.mjs
import fs from "node:fs";
import { parseArgs } from "./lib/args.mjs";

export function evaluateConsensus(claudePos, codexPos, opts) {
  const { round, defaultRounds, maxExtra } = opts;
  const cap = defaultRounds + Math.max(0, Math.min(maxExtra ?? 0, 2));
  const a = new Set(claudePos.key_points ?? []);
  const b = new Set(codexPos.key_points ?? []);
  let divergence = 0;
  for (const p of a) if (!b.has(p)) divergence++;
  for (const p of b) if (!a.has(p)) divergence++;
  const consensus = Boolean(claudePos.agrees_with_opponent) && Boolean(codexPos.agrees_with_opponent);
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
