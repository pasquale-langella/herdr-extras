#!/usr/bin/env node
// Cursor → Herdr status bridge (Windows): hooks write a state file; the
// cursor-herdr wrapper injects OSC 7501 into the pane PTY Herdr reads.
const fs = require("fs");
const path = require("path");
const os = require("os");

const APP = "cursor";
const DIR = path.join(os.homedir(), ".cursor", "herdr-status");

function statePath() {
  const id = process.env.HC_TERMINAL_ID || "unknown";
  return path.join(DIR, `state-${id}.txt`);
}

function stateFor(event, payload) {
  switch (event) {
    case "sessionStart":
      return "idle";
    case "beforeSubmitPrompt":
    case "postToolUse":
      return "working";
    case "stop":
      return payload?.status === "error" ? "error" : "idle";
    case "sessionEnd":
      return "clear";
    default:
      return null;
  }
}

function readPayload() {
  return new Promise((done) => {
    if (process.stdin.isTTY) return done({});
    let text = "";
    const finish = () => {
      try {
        done(JSON.parse(text || "{}"));
      } catch {
        done({});
      }
    };
    const t = setTimeout(finish, 1000);
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (c) => (text += c));
    process.stdin.on("end", () => {
      clearTimeout(t);
      finish();
    });
    process.stdin.on("error", () => {
      clearTimeout(t);
      finish();
    });
  });
}

function writeState(state) {
  fs.mkdirSync(DIR, { recursive: true });
  const file = statePath();
  fs.writeFileSync(file, state + "\n");
  fs.writeFileSync(
    path.join(DIR, "last-write.log"),
    JSON.stringify({
      at: Date.now(),
      hc: process.env.HC_TERMINAL_ID || null,
      state,
      file,
    }) + "\n"
  );
}

function conversationId(payload) {
  if (!payload || typeof payload !== "object") return null;
  const id =
    payload.conversation_id ||
    payload.session_id ||
    payload.conversationId ||
    payload.sessionId ||
    null;
  return typeof id === "string" && id.trim() ? id.trim() : null;
}

// The resume watcher reads these. One file per terminal, overwritten each hook.
function writeInbox(event, payload) {
  const id = process.env.HC_TERMINAL_ID || "";
  if (!/^t[0-9a-z]+$/i.test(id)) return;
  const inbox = path.join(os.homedir(), ".config", "herdr-extras", "session-resume", "inbox");
  fs.mkdirSync(inbox, { recursive: true });
  const cwd = typeof payload?.cwd === "string" ? payload.cwd.slice(0, 1024) : "";
  const note = {
    at: Date.now(),
    event,
    conversationId: conversationId(payload),
    cwd,
  };
  fs.writeFileSync(path.join(inbox, `${id}.json`), JSON.stringify(note) + "\n");
}

async function main() {
  const [mode, event] = process.argv.slice(2);
  if (mode !== "hook") process.exit(0);
  if (!process.env.HC_TERMINAL_ID) process.exit(0);
  const payload = await readPayload();
  try {
    writeInbox(event, payload);
  } catch {
    // Status reporting still matters if the inbox disk write fails.
  }
  const state = stateFor(event, payload);
  if (state) writeState(state);
  process.exit(0);
}

main();
