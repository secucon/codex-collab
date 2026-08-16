// scripts/consensus.mjs
import fs from "node:fs";
import { parseArgs } from "./lib/args.mjs";

// A codex-client wrapper for a turn that died carries status:"error" and a null
// `structured`. Scored naively that reads as key_points=[] +
// agrees_with_opponent=undefined — an ordinary "divergence N, continue" — so a
// crashed Codex turn would silently become a debate round. Refuse it here
// rather than relying on the orchestrator remembering to check.
function usablePosition(side, pos) {
  if (pos === null || typeof pos !== "object") throw new Error(`${side} position is not usable: expected an object`);
  let position = pos;
  if ("structured" in pos || "status" in pos) {
    if (pos.status === "error") {
      throw new Error(`${side} position is not usable: turn status "error" — ${pos.error ?? "no error text"}`);
    }
    if (pos.structured === null || pos.structured === undefined) {
      throw new Error(`${side} position is not usable: structured output is missing (status "${pos.status}")`);
    }
    position = pos.structured;
  }
  // The two fields this gate actually scores. Without them a malformed round is
  // indistinguishable from an honest disagreement, so it would quietly cost
  // extra rounds instead of stopping.
  if (position === null || typeof position !== "object" || Array.isArray(position)) {
    throw new Error(`${side} position is not usable: expected a position object`);
  }
  if (typeof position.agrees_with_opponent !== "boolean") {
    throw new Error(`${side} position is not usable: agrees_with_opponent must be a boolean`);
  }
  if (!Array.isArray(position.key_points)) {
    throw new Error(`${side} position is not usable: key_points must be an array`);
  }
  return position;
}

export function evaluateConsensus(claudePos, codexPos, opts) {
  const { round, defaultRounds, maxExtra } = opts;
  const cap = defaultRounds + Math.max(0, Math.min(maxExtra ?? 0, 2));
  // Tolerate both a raw position and a codex-client wrapper ({ threadId, text,
  // structured, status }) — the position fields live under `.structured` in the
  // wrapper, at the top level in a raw position.
  const claude = usablePosition("claude", claudePos);
  const codex = usablePosition("codex", codexPos);
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

// `capReached: true` forces the loop to stop: a round that cannot be scored must
// not read as "continue" (which would spin) or as a plain disagreement.
function gateErrorMarker(error) {
  return JSON.stringify({ status: "error", error, consensus: false, divergence: null, capReached: true }, null, 2);
}

function main() {
  const opts = parseArgs(process.argv.slice(2), {
    flags: [],
    values: ["claude", "codex", "round", "default-rounds", "max-extra", "out"]
  });
  // Same pending-marker-first rule as codex-client: a crash, a kill, or an
  // unusable input must never leave a previous round's verdict readable as this
  // round's.
  fs.writeFileSync(opts.out, gateErrorMarker("consensus did not complete: process was killed or crashed before a result was written"));
  try {
    const claudePos = JSON.parse(fs.readFileSync(opts.claude, "utf8"));
    const codexPos = JSON.parse(fs.readFileSync(opts.codex, "utf8"));
    const result = evaluateConsensus(claudePos, codexPos, {
      round: Number(opts.round),
      defaultRounds: Number(opts["default-rounds"] ?? 3),
      maxExtra: Number(opts["max-extra"] ?? 2)
    });
    fs.writeFileSync(opts.out, JSON.stringify(result, null, 2));
  } catch (e) {
    fs.writeFileSync(opts.out, gateErrorMarker(String(e.message ?? e)));
    console.error(e.message ?? e);
    process.exitCode = 1;
  }
}

if (import.meta.url === `file://${process.argv[1]}`) main();
