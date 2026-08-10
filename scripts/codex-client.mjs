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

async function cmdTurn(opts) {
  const sandbox = opts.sandbox ?? "read-only";
  if (sandbox !== "read-only" && sandbox !== "workspace-write") throw new Error(`invalid sandbox: ${sandbox}`);
  const prompt = fs.readFileSync(opts["prompt-file"], "utf8");
  const outputSchema = opts.schema ? JSON.parse(fs.readFileSync(opts.schema, "utf8")) : null;
  const client = await CodexAppServerClient.connect(process.cwd(), serverOverride());
  try {
    const threadId = opts.resume
      ? await client.resumeThread(opts.resume, { sandbox })
      : await client.startThread({ sandbox });
    const res = await client.runTurn(threadId, { prompt, outputSchema });
    fs.writeFileSync(opts.out, JSON.stringify({ threadId, ...res }, null, 2));
  } finally { await client.close(); }
}

async function cmdCheck(opts) {
  try {
    const client = await CodexAppServerClient.connect(process.cwd(), serverOverride());
    const threadId = await client.startThread({ sandbox: "read-only" });
    const res = await client.runTurn(threadId, { prompt: "Reply with the single word: ready." });
    await client.close();
    fs.writeFileSync(opts.out, JSON.stringify({ ok: true, sample: res.text }, null, 2));
  } catch (e) {
    fs.writeFileSync(opts.out, JSON.stringify({ ok: false, error: String(e.message ?? e) }, null, 2));
    process.exitCode = 1;
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
