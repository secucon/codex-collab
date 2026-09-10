// scripts/lib/app-server.mjs
import { spawn } from "node:child_process";
import readline from "node:readline";
import fs from "node:fs";

const CLIENT_INFO = { title: "codex-collab", name: "codex-collab", version: JSON.parse(fs.readFileSync(new URL("../../package.json", import.meta.url))).version };
const CAPABILITIES = { experimentalApi: false, requestAttestation: false };

function timeout(value, fallback) {
  const n = Number(value ?? fallback);
  if (!Number.isSafeInteger(n) || n <= 0 || n > 2_147_483_647) throw new Error("timeout must be a positive integer <= 2147483647");
  return n;
}

function protocolError(error, fallback) {
  return Object.assign(new Error(error?.message ?? fallback), {
    code: error?.code, codexErrorInfo: error?.codexErrorInfo ?? error?.data?.codexErrorInfo,
    additionalDetails: error?.additionalDetails,
  });
}

export class CodexAppServerClient {
  constructor(cwd) {
    this.cwd = cwd;
    this.pending = new Map();
    this.nextId = 1;
    this.stderr = "";
    this.closed = false;
    this.exitError = null;
    this._turnWaiter = null; // { resolve, reject, threadId, text }
    this.exitPromise = new Promise((r) => (this._resolveExit = r));
  }

  static async connect(cwd, { command = "codex", args = ["app-server"], env, requestTimeoutMs } = {}) {
    const client = new CodexAppServerClient(cwd);
    client.requestTimeoutMs = timeout(requestTimeoutMs ?? process.env.CODEX_COLLAB_REQUEST_TIMEOUT_MS, 30_000);
    client.proc = spawn(command, args, { cwd, env: env ?? process.env, stdio: ["pipe", "pipe", "pipe"] });
    client.proc.stdout.setEncoding("utf8");
    client.proc.stderr.setEncoding("utf8");
    client.proc.stderr.on("data", (c) => (client.stderr = (client.stderr + c).slice(-65536)));
    client.proc.stdin.on("error", (e) => { client._rejectWork(e); client.proc.kill("SIGTERM"); });
    client.proc.on("error", (e) => client._handleExit(e));
    client.proc.on("exit", (code, signal) => {
      const err = code === 0 && !signal ? null
        : new Error(`codex app-server exited (${signal ? "signal " + signal : "code " + code}).${client.stderr ? "\n" + client.stderr.trim() : ""}`);
      client._handleExit(err);
    });
    client.rl = readline.createInterface({ input: client.proc.stdout });
    client.rl.on("line", (line) => client._handleLine(line));
    try {
      await client._request("initialize", { clientInfo: CLIENT_INFO, capabilities: CAPABILITIES });
      client._notify("initialized", {});
    } catch (e) {
      // A failed handshake must not leak the spawned process — the caller has
      // no client handle to close.
      await client.close().catch(() => {});
      throw e;
    }
    return client;
  }

  _send(msg) {
    if (this._exited || !this.proc?.stdin || this.proc.stdin.destroyed) throw new Error("codex app-server stdin unavailable");
    this.proc.stdin.write(JSON.stringify(msg) + "\n");
  }
  _request(method, params) {
    if (this.closed) throw new Error("client closed");
    const id = this.nextId++;
    const timeoutMs = this.requestTimeoutMs ?? 30_000;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} timed out after ${timeoutMs}ms (codex app-server unresponsive)`));
      }, timeoutMs);
      timer.unref?.();
      this.pending.set(id, { resolve, reject, method, timer });
      try { this._send({ id, method, params }); }
      catch (e) { clearTimeout(timer); this.pending.delete(id); reject(e); }
    });
  }
  _notify(method, params = {}) { if (!this.closed) this._send({ method, params }); }

  _handleLine(line) {
    if (!line.trim()) return;
    let msg;
    // Skip non-JSON stdout lines (startup banners, warnings) instead of tearing
    // the client down — a single such line must not break every turn.
    try { msg = JSON.parse(line); }
    catch { return; }
    if (!msg || typeof msg !== "object" || Array.isArray(msg)) return;
    if (msg.id !== undefined && msg.method) {
      // This non-interactive client never grants extra permissions.
      let result;
      if (["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].includes(msg.method)) result = { decision: "decline" };
      else if (msg.method === "mcpServer/elicitation/request") result = { action: "decline", content: null };
      else if (msg.method === "item/permissions/requestApproval") result = { permissions: {}, scope: "turn" };
      try {
        this._send(result ? { id: msg.id, result } : { id: msg.id, error: { code: -32601, message: `Unsupported client request: ${msg.method}` } });
      } catch (e) { this._rejectWork(e); }
      return;
    }
    if (msg.id !== undefined && !msg.method) {
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      clearTimeout(p.timer);
      if (msg.error) p.reject(protocolError(msg.error, `${p.method} failed`));
      else p.resolve(msg.result ?? {});
      return;
    }
    if (msg.method) this._handleNotification(msg);
  }

  _handleNotification(msg) {
    const w = this._turnWaiter;
    if (!w) return;
    if (msg.params?.threadId !== w.threadId) return;
    // The server may flush notifications in the same chunk as the start ACK.
    if (!w.turnId) { w.events.push(msg); return; }
    const turnId = msg.params?.turnId ?? msg.params?.turn?.id;
    if (msg.method === "thread/tokenUsage/updated") { w.tokenUsage = msg.params.tokenUsage; return; }
    if (turnId !== w.turnId) return;
    if (msg.method === "item/completed" && msg.params?.item?.type === "agentMessage") {
      const item = msg.params.item;
      if (typeof item.text === "string" && item.phase !== "commentary") w.text = item.text;
    } else if (msg.method === "error") {
      if (msg.params.willRetry === true) return;
      const waiter = this._turnWaiter; this._turnWaiter = null;
      waiter.reject(protocolError(msg.params?.error, "codex error"));
    } else if (msg.method === "turn/completed") {
      const waiter = this._turnWaiter; this._turnWaiter = null;
      const turn = msg.params.turn;
      if (turn.status !== "completed") waiter.reject(protocolError(turn.error, `turn ${turn.status ?? "has no status"}`));
      else waiter.resolve({ text: waiter.text ?? "", status: turn.status, tokenUsage: waiter.tokenUsage ?? null });
    }
  }

  _handleExit(err) {
    if (this._exited) return;
    this._exited = true;
    this.exitError = err ?? null;
    this._rejectWork(err ?? new Error("app-server closed"));
    this._resolveExit();
  }

  _rejectWork(err) {
    for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(err ?? new Error("app-server closed")); }
    this.pending.clear();
    if (this._turnWaiter) { const w = this._turnWaiter; this._turnWaiter = null; w.reject(err ?? new Error("app-server closed")); }
  }

  async startThread({ sandbox = "read-only", model = null } = {}) {
    const res = await this._request("thread/start", {
      cwd: this.cwd, model, approvalPolicy: "never", sandbox, serviceName: "codex-collab", ephemeral: false
    });
    return res.thread.id;
  }
  async resumeThread(threadId, { sandbox = "read-only", model = null } = {}) {
    const res = await this._request("thread/resume", { threadId, cwd: this.cwd, model, approvalPolicy: "never", sandbox });
    return res.thread.id;
  }
  async runTurn(threadId, { prompt, outputSchema = null, effort = null, turnTimeoutMs = null }) {
    if (!prompt || !prompt.trim()) throw new Error("prompt required");
    if (this._turnWaiter) throw new Error("a turn is already running on this client");
    const timeoutMs = timeout(turnTimeoutMs ?? process.env.CODEX_COLLAB_TURN_TIMEOUT_MS, 600_000);
    let w;
    const done = new Promise((resolve, reject) => { w = this._turnWaiter = { resolve, reject, threadId, turnId: null, events: [], text: null }; });
    // Ensure a mid-flight rejection of `done` (e.g. the child exiting between
    // turn/start being sent and its response arriving) is always considered
    // handled. The real `await done` below still surfaces the rejection on the
    // normal path; this only guards the window before we reach it.
    done.catch(() => {});
    try {
      const ack = await this._request("turn/start", {
        threadId, input: [{ type: "text", text: prompt, text_elements: [] }], model: null, effort, outputSchema
      });
      if (!ack.turn?.id) throw new Error("turn/start response has no turn id");
      w.turnId = ack.turn.id;
      for (const event of w.events) this._handleNotification(event);
      w.events = [];
    } catch (e) {
      this._turnWaiter = null;
      throw e;
    }
    // The turn was acked; from here the only completion signal is a
    // turn/completed (or error) notification. Guard against it never arriving.
    const timer = setTimeout(() => {
      if (this._turnWaiter === w) this._turnWaiter = null;
      if (!this.closed && !this._exited) this._request("turn/interrupt", { threadId, turnId: w.turnId }).catch(() => {});
      w.reject(new Error(`turn timed out after ${timeoutMs}ms without turn/completed`));
    }, timeoutMs);
    timer.unref?.();
    let result;
    try { result = await done; }
    finally { clearTimeout(timer); }
    let structured = null;
    if (outputSchema) {
      try { structured = JSON.parse(result.text); }
      catch { throw new Error("structured output is not valid JSON"); }
      if (structured === null) throw new Error("structured output is null");
    }
    return { text: result.text, structured, status: result.status, tokenUsage: result.tokenUsage, turnId: w.turnId };
  }
  async close() {
    if (this.closed) { await this.exitPromise; return; }
    this.closed = true;
    if (this.rl) this.rl.close();
    if (this.proc && this.proc.exitCode === null && this.proc.signalCode === null) {
      this.proc.stdin.end();
      const term = setTimeout(() => this.proc.kill("SIGTERM"), 50);
      const kill = setTimeout(() => this.proc.kill("SIGKILL"), 1000);
      try { await this.exitPromise; }
      finally { clearTimeout(term); clearTimeout(kill); }
      return;
    }
    await this.exitPromise;
  }
}
