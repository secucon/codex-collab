// scripts/codex-client.mjs
import fs from "node:fs";
import { parseArgs } from "./lib/args.mjs";
import { CodexAppServerClient } from "./lib/app-server.mjs";

function serverOverride() {
  const command = process.env.CODEX_COLLAB_COMMAND;
  if (!command) return {};
  let args = ["app-server"];
  if (process.env.CODEX_COLLAB_ARGS) { try { args = JSON.parse(process.env.CODEX_COLLAB_ARGS); } catch {} }
  return { command, args };
}

function turnErrorMarker(error) {
  return JSON.stringify({ threadId: null, text: "", structured: null, status: "error", error }, null, 2);
}

async function cmdTurn(opts) {
  // Write a pending marker BEFORE doing anything else, so every death mode —
  // local input error, crash, SIGKILL, or the caller's timeout killing us —
  // leaves a truthful failure record at --out. A downstream reader must never
  // find a prior run's result there. Overwritten on success or handled error.
  fs.writeFileSync(opts.out, turnErrorMarker("turn did not complete: process was killed or crashed before a result was written"));
  let client;
  try {
    const sandbox = opts.sandbox ?? "read-only";
    if (sandbox !== "read-only" && sandbox !== "workspace-write") throw new Error(`invalid sandbox: ${sandbox}`);
    const prompt = fs.readFileSync(opts["prompt-file"], "utf8");
    const outputSchema = opts.schema ? JSON.parse(fs.readFileSync(opts.schema, "utf8")) : null;
    client = await CodexAppServerClient.connect(process.cwd(), serverOverride());
    const threadId = opts.resume
      ? await client.resumeThread(opts.resume, { sandbox })
      : await client.startThread({ sandbox });
    const res = await client.runTurn(threadId, { prompt, outputSchema });
    fs.writeFileSync(opts.out, JSON.stringify({ threadId, ...res }, null, 2));
  } catch (e) {
    fs.writeFileSync(opts.out, turnErrorMarker(String(e.message ?? e)));
    process.exitCode = 1;
  } finally {
    if (client) await client.close();
  }
}

async function cmdCheck(opts) {
  let client;
  // Track how far the app-server handshake/turn got so the CI drift-canary can
  // tell a real protocol/handshake break (never reached "initialized") from a
  // mere turn-level auth failure (reached "initialized"/"thread-started").
  let phase = "spawned";
  // Same pending-marker-first rule as cmdTurn: a killed check must not leave a
  // prior check's result readable at --out.
  fs.writeFileSync(opts.out, JSON.stringify(
    { ok: false, phase: "not-started", error: "check did not complete: process was killed or crashed before a result was written" }, null, 2));
  try {
    client = await CodexAppServerClient.connect(process.cwd(), serverOverride());
    phase = "initialized";
    const threadId = await client.startThread({ sandbox: "read-only" });
    phase = "thread-started";
    const res = await client.runTurn(threadId, { prompt: "Reply with the single word: ready." });
    phase = "turn-completed";
    fs.writeFileSync(opts.out, JSON.stringify({ ok: true, phase, sample: res.text }, null, 2));
  } catch (e) {
    fs.writeFileSync(opts.out, JSON.stringify({ ok: false, phase, error: String(e.message ?? e) }, null, 2));
    process.exitCode = 1;
  } finally {
    if (client) await client.close();
  }
}

async function main() {
  const [sub, ...rest] = process.argv.slice(2);
  if (sub === "turn") {
    await cmdTurn(parseArgs(rest, { flags: [], values: ["sandbox", "prompt-file", "schema", "resume", "out"] }));
  } else if (sub === "check") {
    await cmdCheck(parseArgs(rest, { flags: [], values: ["out"] }));
  } else {
    console.error("usage: codex-client.mjs <turn|check> ...");
    process.exitCode = 2;
  }
}

main().catch((e) => { console.error(e.message ?? e); process.exitCode = 1; });
