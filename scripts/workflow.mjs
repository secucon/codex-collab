import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs } from "./lib/args.mjs";
import { normalizePositionVote } from "./lib/contracts.mjs";
import { cmdTurn } from "./codex-client.mjs";
import { evaluateConsensus, proposalId } from "./consensus.mjs";

const read = file => JSON.parse(fs.readFileSync(file, "utf8"));
function write(file, value) {
  const temp = `${file}.${randomUUID()}.tmp`;
  fs.writeFileSync(temp, JSON.stringify(value, null, 2), { flag: "wx", mode: 0o600 });
  fs.renameSync(temp, file);
}

export function initRun(kind, root = process.cwd()) {
  if (!["ask", "evaluate", "debate"].includes(kind)) throw new Error("kind must be ask, evaluate, or debate");
  const runId = randomUUID();
  const dir = path.join(root, ".codex-collab", "runs", runId);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const state = { runId, kind, round: 0, status: "ready", threadId: null, rounds: [] };
  write(path.join(dir, "state.json"), state);
  return { runId, dir, nextRound: 1 };
}

export async function debateRound(dir, options = {}) {
  const lock = path.join(dir, "round.lock");
  // No automatic stale-lock recovery: a previous invocation may still be alive.
  const fd = fs.openSync(lock, "wx", 0o600);
  let state;
  let started = false;
  try {
    state = read(path.join(dir, "state.json"));
    if (state.kind !== "debate" || state.status !== "ready" || !Number.isInteger(state.round) || state.round < 0 || state.round >= 5) throw new Error("debate is not ready for another round");
    const round = state.round + 1;
    const prefix = path.join(dir, `round-${round}`);
    const proposal = state.nextProposal ?? null;
    const id = proposal ? proposalId(proposal) : null;
    const claudeVote = normalizePositionVote(read(`${prefix}-claude.json`), id);
    const claude = claudeVote.position;
    const topic = fs.readFileSync(path.join(dir, "topic.txt"), "utf8");
    const prompt = proposal
      ? `${topic}\n\nEvaluate this fixed candidate from Claude's previous position. Return your current position and objections. Accept ONLY if you endorse the entire candidate unchanged: set agrees_with_opponent=true and accepted_proposal_id to ${id}. Otherwise use false and null. Your earlier turns are already in this thread.\nCandidate:\n${JSON.stringify(proposal)}\n`
      : `${topic}\n\nForm your position independently. No candidate has been supplied: set agrees_with_opponent=false and accepted_proposal_id=null. Do not read other models' analysis or collaboration artifacts under .codex-collab.\n`;
    fs.writeFileSync(`${prefix}-prompt.txt`, prompt);
    state.status = "running";
    write(path.join(dir, "state.json"), state);
    started = true;
    const codex = await cmdTurn({
      sandbox: "read-only", "prompt-file": `${prefix}-prompt.txt`,
      schema: fileURLToPath(new URL("../schemas/position.json", import.meta.url)),
      out: `${prefix}-codex.json`, resume: state.threadId, "run-id": state.runId,
      model: options.model, effort: options.effort,
    });
    const codexVote = normalizePositionVote(codex.structured, id);
    const warnings = { claude: claudeVote.warnings, codex: codexVote.warnings };
    const consensus = evaluateConsensus(claude, { ...codex, structured: codexVote.position }, { round, defaultRounds: 3, maxExtra: 2, proposal });
    write(`${prefix}-consensus.json`, consensus);
    state.rounds.push({ round, claude, codex: codexVote.position, proposal, consensus, warnings,
      originalVotes: { claude: claudeVote.originalVote, codex: codexVote.originalVote },
      metrics: codex.metrics, tokenUsage: codex.tokenUsage });
    state.round = round;
    state.threadId = codex.threadId;
    state.status = consensus.consensus || consensus.capReached ? "completed" : "ready";
    state.agreedProposal = consensus.consensus ? proposal : null;
    // Only candidate content is hashed. Votes about older candidates cannot
    // accidentally become part of the proposal or carry forward as acceptance.
    state.nextProposal = state.status === "ready" ? {
      stance: claude.stance, reasoning: claude.reasoning, key_points: claude.key_points,
      proposed_change: claude.proposed_change ?? null,
    } : null;
    write(path.join(dir, "state.json"), state);
    return { runId: state.runId, status: state.status, round, consensus, warnings, agreedProposal: state.agreedProposal,
      nextProposal: state.nextProposal, nextProposalId: state.nextProposal ? proposalId(state.nextProposal) : null };
  } catch (e) {
    if (started) {
      state.status = "error";
      state.error = e.message;
      write(path.join(dir, "state.json"), state);
    }
    throw e;
  } finally {
    fs.closeSync(fd);
    fs.unlinkSync(lock);
  }
}

async function main() {
  const [command, ...args] = process.argv.slice(2);
  const opts = parseArgs(args, { values: ["kind", "dir", "model", "effort"] });
  if (command === "init") console.log(JSON.stringify(initRun(opts.kind)));
  else if (command === "round") console.log(JSON.stringify(await debateRound(opts.dir, opts)));
  else throw new Error("usage: workflow.mjs init --kind ask|evaluate|debate OR round --dir <run-directory>");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main().catch(e => { console.error(e.message); process.exitCode = 1; });
