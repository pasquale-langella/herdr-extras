"use strict";

// Remember agent chats while Herdr is open. When herdr-core comes back and a
// pane is a shell again, type that agent's resume command into the shell.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");
const {
  isShell,
  kindFromAgent,
  validSessionId,
  samePath,
  resumeLine,
  claudeProjectKey,
  copilotIdsForCwd,
  applyInbox,
  chooseShell,
  assignNewest,
} = require("./logic");

const HOME = os.homedir();
const DIR = path.join(HOME, ".config", "herdr-extras", "session-resume");
const STATE = path.join(DIR, "session-resume-state.json");
const INBOX = path.join(DIR, "inbox");
const LOCK = path.join(DIR, "session-resume.lock");
const LOG = path.join(DIR, "session-resume.log");
const ONCE = process.argv.includes("--once");
const INTERVAL_MS = 5000;

const PATHS = {
  cursor: path.join(HOME, ".cursor", "herdr-status", "cursor-herdr.exe"),
  claude: which("claude") || "claude",
  copilot: which("copilot") || "copilot",
};

function which(cmd) {
  const r = spawnSync("where.exe", [cmd], { encoding: "utf8", windowsHide: true });
  const line = String(r.stdout || "")
    .split(/\r?\n/)
    .map((s) => s.trim())
    .find(Boolean);
  return line || null;
}

function log(message) {
  const line = `${new Date().toISOString()} ${message}\n`;
  try {
    fs.mkdirSync(DIR, { recursive: true });
    if (fs.existsSync(LOG) && fs.statSync(LOG).size > 512 * 1024) {
      fs.renameSync(LOG, LOG + ".old");
    }
    fs.appendFileSync(LOG, line);
  } catch {
    // Logging must not stop the watcher.
  }
  console.error(line.trim());
}

function pidAlive(pid) {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function takeLock() {
  fs.mkdirSync(DIR, { recursive: true });
  if (fs.existsSync(LOCK)) {
    const pid = Number(fs.readFileSync(LOCK, "utf8"));
    if (pid && pid !== process.pid && pidAlive(pid)) {
      log(`already running as pid ${pid}`);
      process.exit(0);
    }
  }
  fs.writeFileSync(LOCK, String(process.pid));
  const release = () => {
    try {
      if (fs.existsSync(LOCK) && fs.readFileSync(LOCK, "utf8").trim() === String(process.pid)) {
        fs.unlinkSync(LOCK);
      }
    } catch {
      // The next start replaces a stale lock.
    }
  };
  process.on("exit", release);
  process.on("SIGINT", () => process.exit(0));
  process.on("SIGTERM", () => process.exit(0));
}

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

function loadState() {
  const data = readJson(STATE, null);
  if (!data || typeof data !== "object" || !data.terminals) {
    return { version: 1, terminals: {} };
  }
  data.version = 1;
  data.terminals ??= {};
  return data;
}

function saveState(state) {
  fs.mkdirSync(DIR, { recursive: true });
  const tmp = STATE + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2) + "\n");
  fs.renameSync(tmp, STATE);
}

function hc(args) {
  const r = spawnSync("hc", args, { encoding: "utf8", windowsHide: true });
  if (r.error) throw r.error;
  if (r.status !== 0) {
    throw new Error((r.stderr || r.stdout || `hc ${args[0]} failed`).trim());
  }
  const text = (r.stdout || "").trim();
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

function layoutPanes() {
  const r = spawnSync("herdr-app", ["ls"], { encoding: "utf8", windowsHide: true });
  const map = new Map();
  if (r.status !== 0) return map;
  let data = null;
  try {
    data = JSON.parse(r.stdout || "");
  } catch {
    return map;
  }
  for (const space of data.spaces || []) {
    for (const tab of space.tabs || []) {
      for (const term of tab.terminals || []) {
        if (term.terminal && term.pane) map.set(term.terminal, term.pane);
      }
    }
  }
  return map;
}

function listTerminals() {
  const data = hc(["ls", "--all"]);
  return Array.isArray(data?.terminals) ? data.terminals : [];
}

function coreInstance() {
  const status = hc(["server", "status"]);
  return status?.holder?.instance || status?.core?.id || null;
}

function terminalDetail(address) {
  try {
    return hc(["get", address]);
  } catch (err) {
    log(`get ${address}: ${err.message}`);
    return null;
  }
}

function tabOf(detail) {
  const labels = detail?.labels || {};
  return labels["herdr.tab"] || null;
}

function cwdOf(term, detail) {
  return detail?.foreground?.cwd || detail?.cwd || term.cwd || "";
}

function mergeInbox(state) {
  if (!fs.existsSync(INBOX)) return;
  for (const name of fs.readdirSync(INBOX)) {
    if (!name.endsWith(".json")) continue;
    const address = name.slice(0, -5);
    const note = readJson(path.join(INBOX, name), null);
    if (!note) continue;
    const record = (state.terminals[address] ??= { address });
    applyInbox(record, note);
    try {
      fs.unlinkSync(path.join(INBOX, name));
    } catch {
      // Left for the next tick.
    }
  }
}

function cursorChats(cwd) {
  const root = path.join(HOME, ".cursor", "chats");
  if (!fs.existsSync(root)) return [];
  const found = [];
  for (const bucket of fs.readdirSync(root, { withFileTypes: true })) {
    if (!bucket.isDirectory()) continue;
    const dir = path.join(root, bucket.name);
    for (const chat of fs.readdirSync(dir, { withFileTypes: true })) {
      if (!chat.isDirectory()) continue;
      const metaPath = path.join(dir, chat.name, "meta.json");
      const meta = readJson(metaPath, null);
      if (!meta || !samePath(meta.cwd, cwd)) continue;
      if (!validSessionId(chat.name)) continue;
      found.push({ id: chat.name, rank: Number(meta.updatedAtMs) || 0 });
    }
  }
  return found;
}

function claudeSessions(cwd) {
  let dir = cwd;
  const root = path.parse(dir).root;
  let project = null;
  while (dir && dir.length >= root.length) {
    const candidate = path.join(HOME, ".claude", "projects", claudeProjectKey(dir));
    if (fs.existsSync(candidate)) {
      project = candidate;
      break;
    }
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  if (!project) return [];
  const found = [];
  for (const name of fs.readdirSync(project)) {
    if (!/^[0-9a-f-]{36}\.jsonl$/i.test(name)) continue;
    const id = name.slice(0, -6);
    if (!validSessionId(id)) continue;
    const stat = fs.statSync(path.join(project, name));
    found.push({ id, rank: stat.mtimeMs });
  }
  return found;
}

function copilotSessions(cwd) {
  const db = path.join(HOME, ".copilot", "session-store.db");
  if (!fs.existsSync(db)) return [];
  const copy = path.join(os.tmpdir(), `herdr-copilot-sessions-${process.pid}.db`);
  try {
    fs.copyFileSync(db, copy);
  } catch (err) {
    log(`copilot session store copy failed: ${err.message}`);
    return [];
  }
  let text = "";
  try {
    text = fs.readFileSync(copy, "latin1");
  } finally {
    fs.rmSync(copy, { force: true });
  }
  const open = readJson(path.join(HOME, ".copilot", "open-sessions-state.json"), {});
  const ids = copilotIdsForCwd(text, cwd);
  return ids.map((id) => ({
    id,
    rank: Date.parse(open?.[id]?.refreshedAt || "") || 0,
  }));
}

function latchSessions(state, liveAgents) {
  const claimed = new Set(
    Object.values(state.terminals)
      .map((r) => r.sessionId)
      .filter(Boolean)
  );
  for (const kind of ["cursor", "claude", "copilot"]) {
    const groups = new Map();
    for (const term of liveAgents) {
      if (term.kind !== kind) continue;
      const record = state.terminals[term.address];
      if (record?.sessionSource === "hook" && validSessionId(record.sessionId)) continue;
      const key = term.cwd.toLowerCase();
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(term);
    }
    for (const group of groups.values()) {
      const cwd = group[0].cwd;
      const needing = group.filter((term) => !validSessionId(state.terminals[term.address]?.sessionId));
      if (!needing.length) continue;
      let candidates = [];
      try {
        if (kind === "cursor") candidates = cursorChats(cwd);
        else if (kind === "claude") candidates = claudeSessions(cwd);
        else candidates = copilotSessions(cwd);
      } catch (err) {
        log(`${kind} session lookup failed: ${err.message}`);
      }
      const assigned = assignNewest(needing, candidates, claimed);
      for (const [address, id] of assigned) {
        state.terminals[address].sessionId = id;
        state.terminals[address].sessionSource = kind;
        claimed.add(id);
      }
    }
  }
}

function kindOf(term, detail) {
  const reported = kindFromAgent(term.agent, []);
  if (reported) return reported;
  const argv = detail?.foreground?.argv || detail?.argv || [];
  return (
    kindFromAgent(detail?.foreground?.name, argv) ||
    kindFromAgent((detail?.argv || [])[0], argv) ||
    null
  );
}

function observe(state, terminals, currentCore, panes) {
  const now = Date.now();
  const liveAgents = [];
  const shells = [];
  for (const term of terminals) {
    if (term.state !== "live") continue;
    const shell = isShell(term.agent);
    const reported = kindFromAgent(term.agent, []);
    if (!shell && !reported) continue;
    const detail = terminalDetail(term.address);
    const cwd = cwdOf(term, detail);
    const tab = tabOf(detail);
    const pane = panes.get(term.address) || null;
    if (shell) {
      shells.push({
        address: term.address,
        agent: term.agent,
        state: term.state,
        turn: term.turn,
        cwd,
        tab,
        pane,
      });
      continue;
    }
    const kind = kindOf(term, detail);
    if (!kind) continue;
    const record = (state.terminals[term.address] ??= { address: term.address });
    record.address = term.address;
    record.kind = kind;
    record.cwd = cwd;
    record.tab = tab;
    record.pane = pane;
    record.core = currentCore;
    record.agentSeenAt = now;
    record.endedAt = null;
    record.restoredOn = null;
    record.attempts = 0;
    record.closed = false;
    liveAgents.push({ address: term.address, kind, cwd, tab });
  }
  latchSessions(state, liveAgents);
  return shells;
}

function restore(state, shells, currentCore) {
  const taken = new Set();
  for (const record of Object.values(state.terminals)) {
    if (!record || record.closed) continue;
    const shell = chooseShell(record, shells.filter((s) => !taken.has(s.address)), currentCore);
    if (!shell) continue;
    const line = resumeLine(record.kind, record.sessionId, PATHS);
    if (!line) continue;
    try {
      hc(["send", shell.address, line]);
      record.restoredOn = currentCore;
      record.address = shell.address;
      if (shell.pane) record.pane = shell.pane;
      record.attempts = (record.attempts || 0) + 1;
      taken.add(shell.address);
      log(`resumed ${record.kind} ${record.sessionId} in ${shell.address}`);
    } catch (err) {
      record.attempts = (record.attempts || 0) + 1;
      log(`resume ${shell.address} failed: ${err.message}`);
    }
  }
}

function prune(state) {
  const cutoff = Date.now() - 14 * 24 * 60 * 60 * 1000;
  for (const [address, record] of Object.entries(state.terminals)) {
    if (record.endedAt && record.endedAt < cutoff && record.agentSeenAt < cutoff) {
      delete state.terminals[address];
    }
  }
}

function tick() {
  const state = loadState();
  mergeInbox(state);
  let currentCore = null;
  let terminals = [];
  try {
    currentCore = coreInstance();
    terminals = listTerminals();
  } catch (err) {
    saveState(state);
    log(`waiting for herdr-core: ${err.message}`);
    return;
  }
  if (!currentCore) {
    saveState(state);
    log("waiting for herdr-core holder");
    return;
  }
  const shells = observe(state, terminals, currentCore, layoutPanes());
  restore(state, shells, currentCore);
  prune(state);
  saveState(state);
}

function main() {
  takeLock();
  log(`session resume watcher started (cursor=${PATHS.cursor}, claude=${PATHS.claude}, copilot=${PATHS.copilot})`);
  if (!fs.existsSync(PATHS.cursor)) {
    log("cursor-herdr.exe is not installed yet; Cursor panes will not resume until install.ps1 builds it");
  }
  const run = () => {
    try {
      tick();
    } catch (err) {
      log(`tick failed: ${err.stack || err.message}`);
    }
  };
  run();
  if (ONCE) return;
  setInterval(run, INTERVAL_MS);
}

main();
