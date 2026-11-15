"use strict";

// Pure decisions for restarting a Herdr agent in the shell Herdr leaves behind
// after herdr-core comes back (reboot, or the core process ending).

const SHELLS = new Set([
  "pwsh.exe",
  "pwsh",
  "powershell.exe",
  "powershell",
  "cmd.exe",
  "cmd",
  "bash.exe",
  "bash",
  "sh.exe",
  "sh",
  "nu.exe",
  "nu",
]);

const MAX_SHELL_TURN = 3;

function baseName(value) {
  return String(value || "")
    .replace(/\\/g, "/")
    .split("/")
    .pop()
    .toLowerCase();
}

function isShell(agent) {
  return SHELLS.has(baseName(agent));
}

function kindFromAgent(agent, argv) {
  const name = baseName(agent);
  const parts = [name, ...(argv || []).map(baseName)];
  const blob = parts.join(" ");
  if (name === "cursor" || blob.includes("cursor-agent") || blob.includes("cursor-herdr")) {
    return "cursor";
  }
  if (name === "claude" || name === "claude.exe") return "claude";
  if (name === "copilot" || name === "copilot.exe") return "copilot";
  return null;
}

function validSessionId(id) {
  return typeof id === "string" && /^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$/.test(id);
}

function samePath(a, b) {
  if (!a || !b) return false;
  const norm = (p) => String(p).replace(/\//g, "\\").replace(/\\+$/, "").toLowerCase();
  return norm(a) === norm(b);
}

function psQuote(value) {
  return `'${String(value).replace(/'/g, "''")}'`;
}

function resumeLine(kind, sessionId, paths) {
  if (!validSessionId(sessionId)) return null;
  const exe =
    kind === "cursor" ? paths.cursor : kind === "claude" ? paths.claude : kind === "copilot" ? paths.copilot : null;
  if (!exe) return null;
  return `& ${psQuote(exe)} --resume ${psQuote(sessionId)}`;
}

// Claude's project folder is the path in lowercase with ":" and separators as "-".
// C:\GitEpam\ai-migration-assistant -> c--GitEpam-ai-migration-assistant
function claudeProjectKey(cwd) {
  let s = String(cwd || "").replace(/\//g, "\\").replace(/\\+$/, "");
  s = s.replace(/^([A-Za-z]):/, (_, d) => `${d.toLowerCase()}-`);
  s = s.replace(/\\/g, "-");
  // Claude also turns "_", spaces, and other punctuation into "-".
  return s.replace(/[^A-Za-z0-9-]/g, "-");
}

function copilotIdsForCwd(text, cwd) {
  const needle = String(cwd || "").replace(/\//g, "\\");
  if (needle.length < 3) return [];
  const hay = String(text || "");
  const lower = hay.toLowerCase();
  const n = needle.toLowerCase();
  const ids = [];
  let from = 0;
  while (from < lower.length) {
    const at = lower.indexOf(n, from);
    if (at < 0) break;
    const before = hay.slice(Math.max(0, at - 36), at);
    const m = before.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
    if (m) ids.push(m[0].toLowerCase());
    from = at + n.length;
  }
  return ids;
}

function pickFreshest(ids, openState) {
  let best = null;
  let bestAt = "";
  for (const id of ids) {
    const at = openState?.[id]?.refreshedAt || "";
    if (!best || at >= bestAt) {
      best = id;
      bestAt = at;
    }
  }
  return best;
}

function applyInbox(record, note) {
  if (!note || typeof note !== "object") return record;
  const at = Number(note.at) || 0;
  if (note.event === "sessionEnd" && at >= (record.agentSeenAt || 0)) {
    record.endedAt = at;
    return record;
  }
  if (note.event !== "sessionEnd" && validSessionId(note.conversationId)) {
    record.sessionId = note.conversationId;
    record.sessionSource = "hook";
    record.endedAt = null;
  }
  return record;
}

function shouldRestore(record, shell, currentCore) {
  if (!record || !shell || !currentCore) return false;
  if (!validSessionId(record.sessionId)) return false;
  if (!record.core || record.core === currentCore) return false;
  if (record.restoredOn === currentCore) return false;
  if ((record.attempts || 0) >= 3) return false;
  if (shell.state && shell.state !== "live") return false;
  if (!isShell(shell.agent)) return false;
  if (typeof shell.turn === "number" && shell.turn > MAX_SHELL_TURN) return false;
  if (!samePath(record.cwd, shell.cwd)) return false;
  if (record.tab && shell.tab && record.tab !== shell.tab) return false;
  return true;
}

// Prefer the same terminal address. Otherwise the single untouched shell in
// that tab and folder. Never guess between two shells.
function chooseShell(record, shells, currentCore) {
  const usable = (shells || []).filter((shell) => shouldRestore(record, shell, currentCore));
  const same = usable.find((shell) => shell.address === record.address);
  if (same) return same;
  if (record.pane) {
    const samePane = usable.filter((shell) => shell.pane === record.pane);
    if (samePane.length === 1) return samePane[0];
    if (samePane.length > 1) return null;
  }
  const inTab = usable.filter((shell) => !record.tab || shell.tab === record.tab);
  return inTab.length === 1 ? inTab[0] : null;
}

function assignNewest(unassigned, candidates, claimed) {
  const used = new Set(claimed || []);
  const pool = (candidates || [])
    .filter((c) => c && validSessionId(c.id) && !used.has(c.id))
    .sort((a, b) => (b.rank || 0) - (a.rank || 0));
  const terms = [...(unassigned || [])].sort((a, b) => String(a.address).localeCompare(String(b.address)));
  const out = new Map();
  terms.forEach((term, i) => {
    if (pool[i]) out.set(term.address, pool[i].id);
  });
  return out;
}

module.exports = {
  MAX_SHELL_TURN,
  isShell,
  kindFromAgent,
  validSessionId,
  samePath,
  psQuote,
  resumeLine,
  claudeProjectKey,
  copilotIdsForCwd,
  pickFreshest,
  applyInbox,
  shouldRestore,
  chooseShell,
  assignNewest,
};
