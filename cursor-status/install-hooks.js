#!/usr/bin/env node
/** Merge or remove Herdr cursor-status hooks in ~/.cursor/hooks.json */
const fs = require("fs");
const os = require("os");
const path = require("path");

const EVENTS = [
  "sessionStart",
  "beforeSubmitPrompt",
  "postToolUse",
  "stop",
  "sessionEnd",
];
const SCRIPT = path.join(__dirname, "status.js");
const MARK = "herdr-status";
const hooksFile = path.join(os.homedir(), ".cursor", "hooks.json");
const backup = hooksFile + ".herdr-status-backup";

const commandFor = (event) =>
  `node "${SCRIPT.replace(/\\/g, "\\\\")}" hook ${event}`.replace(
    /\\\\/g,
    "\\"
  );

// Prefer native path separators in the command string Cursor will run.
const hookCommand = (event) => `node "${SCRIPT}" hook ${event}`;

const isOurs = (h) =>
  typeof h?.command === "string" &&
  (h.command.includes("herdr-status") || h.command.includes("cursor-status")) &&
  h.command.includes("status.js") &&
  h.command.includes("hook");

function readDoc() {
  if (!fs.existsSync(hooksFile)) return { version: 1, hooks: {} };
  const text = fs.readFileSync(hooksFile, "utf8");
  if (!text.trim()) return { version: 1, hooks: {} };
  return JSON.parse(text);
}

function save(doc) {
  fs.mkdirSync(path.dirname(hooksFile), { recursive: true });
  if (fs.existsSync(hooksFile) && !fs.existsSync(backup)) {
    fs.copyFileSync(hooksFile, backup);
  }
  fs.writeFileSync(hooksFile, JSON.stringify(doc, null, 2) + "\n");
}

function install(remove) {
  const doc = readDoc();
  doc.version ??= 1;
  doc.hooks ??= {};
  for (const event of EVENTS) {
    const list = (doc.hooks[event] ?? []).filter((h) => !isOurs(h));
    if (!remove) list.push({ command: hookCommand(event), timeout: 5 });
    if (list.length) doc.hooks[event] = list;
    else delete doc.hooks[event];
  }
  if (!Object.keys(doc.hooks).length) delete doc.hooks;
  save(doc);
  console.log(`${remove ? "Removed hooks from" : "Updated"}: ${hooksFile}`);
}

const mode = process.argv[2] || "install";
if (mode === "uninstall") install(true);
else if (mode === "install") install(false);
else {
  console.error("usage: install-hooks.js [install|uninstall]");
  process.exit(2);
}
