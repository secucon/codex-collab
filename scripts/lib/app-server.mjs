// scripts/lib/app-server.mjs
import { spawn } from "node:child_process";
import readline from "node:readline";

const CLIENT_INFO = { title: "codex-collab", name: "Claude Code", version: "3.0.2" };
const CAPABILITIES = { experimentalApi: false, requestAttestation: false };

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
    client.requestTimeoutMs = requestTimeoutMs ?? Number(process.env.CODEX_COLLAB_REQUEST_TIMEOUT_MS ?? 30_000);
    client.proc = spawn(command, args, { cwd, env: env ?? process.env, stdio: ["pipe", "pipe", "pipe"] });
    client.proc.stdout.setEncoding("utf8");
    client.proc.stderr.setEncoding("utf8");
    client.proc.stderr.on("data", (c) => (client.stderr += c));
    client.proc.on("error", (e) => client._handleExit(e));
    client.proc.on("exit", (code, signal) => {
      const err = code === 0 || code === null ? null
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
    if (!this.proc?.stdin) throw new Error("codex app-server stdin unavailable");
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
      this._send({ id, method, params });
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
    if (msg.id !== undefined && !msg.method) {
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      clearTimeout(p.timer);
      if (msg.error) p.reject(new Error(msg.error.message ?? `${p.method} failed`));
      else p.resolve(msg.result ?? {});
      return;
    }
    if (msg.method) this._handleNotification(msg);
  }

  _handleNotification(msg) {
    const w = this._turnWaiter;
    if (!w) return;
    if (msg.method === "item/completed" && msg.params?.item?.type === "agentMessage") {
      if (typeof msg.params.item.text === "string") w.text = msg.params.item.text;
    } else if (msg.method === "error") {
      const waiter = this._turnWaiter; this._turnWaiter = null;
      waiter.reject(new Error(msg.params?.error?.message ?? "codex error"));
    } else if (msg.method === "turn/completed") {
      const waiter = this._turnWaiter; this._turnWaiter = null;
      waiter.resolve({ text: waiter.text ?? "", status: msg.params?.turn?.status ?? "completed" });
    }
  }

  _handleExit(err) {
    if (this._exited) return;
    this._exited = true;
    this.exitError = err ?? null;
    for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(err ?? new Error("app-server closed")); }
    this.pending.clear();
    if (this._turnWaiter) { const w = this._turnWaiter; this._turnWaiter = null; w.reject(err ?? new Error("app-server closed")); }
    this._resolveExit();
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
    const timeoutMs = turnTimeoutMs ?? Number(process.env.CODEX_COLLAB_TURN_TIMEOUT_MS ?? 600_000);
    let w;
    const done = new Promise((resolve, reject) => { w = this._turnWaiter = { resolve, reject, threadId, text: null }; });
    // Ensure a mid-flight rejection of `done` (e.g. the child exiting between
    // turn/start being sent and its response arriving) is always considered
    // handled. The real `await done` below still surfaces the rejection on the
    // normal path; this only guards the window before we reach it.
    done.catch(() => {});
    try {
      await this._request("turn/start", {
        threadId, input: [{ type: "text", text: prompt, text_elements: [] }], model: null, effort, outputSchema
      });
    } catch (e) {
      this._turnWaiter = null;
      throw e;
    }
    // The turn was acked; from here the only completion signal is a
    // turn/completed (or error) notification. Guard against it never arriving.
    const timer = setTimeout(() => {
      if (this._turnWaiter === w) this._turnWaiter = null;
      w.reject(new Error(`turn timed out after ${timeoutMs}ms without turn/completed`));
    }, timeoutMs);
    timer.unref?.();
    let result;
    try { result = await done; }
    finally { clearTimeout(timer); }
    let structured = null;
    if (outputSchema) { try { structured = JSON.parse(result.text); } catch { structured = null; } }
    return { text: result.text, structured, status: result.status };
  }
  async close() {
    if (this.closed) { await this.exitPromise; return; }
    this.closed = true;
    if (this.rl) this.rl.close();
    if (this.proc && !this.proc.killed) {
      this.proc.stdin.end();
      setTimeout(() => { if (this.proc && this.proc.exitCode === null) this.proc.kill("SIGTERM"); }, 50).unref?.();
    }
    await this.exitPromise;
  }
}
