"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  isShell,
  kindFromAgent,
  validSessionId,
  claudeProjectKey,
  copilotIdsForCwd,
  pickFreshest,
  applyInbox,
  shouldRestore,
  chooseShell,
  assignNewest,
  resumeLine,
} = require("./logic");

const CORE_A = "core-before-reboot";
const CORE_B = "core-after-reboot";
const CHAT = "ad272b5f-7f2d-46a3-9bef-26e03066a21a";

test("claude project key matches Claude's on-disk folder", () => {
  assert.equal(
    claudeProjectKey("C:\\GitEpam\\ai-migration-assistant"),
    "c--GitEpam-ai-migration-assistant"
  );
  assert.equal(
    claudeProjectKey("C:/Users/Pasquale_Langella/Documents/GitHub/trd/"),
    "c--Users-Pasquale-Langella-Documents-GitHub-trd"
  );
});

test("shells and agents are told apart", () => {
  assert.equal(isShell("C:\\Program Files\\PowerShell\\7\\pwsh.exe"), true);
  assert.equal(isShell("cursor"), false);
  assert.equal(kindFromAgent("cursor"), "cursor");
  assert.equal(kindFromAgent("claude"), "claude");
  assert.equal(kindFromAgent("copilot"), "copilot");
  assert.equal(kindFromAgent("C:\\tools\\cursor-herdr.exe"), "cursor");
  assert.equal(kindFromAgent("pwsh.exe"), null);
});

test("resume line is a single PowerShell command", () => {
  const line = resumeLine("cursor", CHAT, {
    cursor: "C:\\Users\\me\\.cursor\\herdr-status\\cursor-herdr.exe",
  });
  assert.equal(
    line,
    "& 'C:\\Users\\me\\.cursor\\herdr-status\\cursor-herdr.exe' --resume 'ad272b5f-7f2d-46a3-9bef-26e03066a21a'"
  );
  assert.equal(resumeLine("cursor", "bad id", { cursor: "agent" }), null);
  assert.equal(validSessionId("a"), false);
});

test("copilot session id sits immediately before its cwd", () => {
  const cwd = "C:\\GitEpam\\ai-migration-assistant\\integration-migration\\me-s705b";
  const text =
    "noise bff33b4f-8519-41d4-bf2d-c6ea8384cd82" +
    cwd +
    "feature/S7 later 06744d69-e1dd-47bd-9e79-db27abee5aebC:\\somewhere-else";
  assert.deepEqual(copilotIdsForCwd(text, cwd), ["bff33b4f-8519-41d4-bf2d-c6ea8384cd82"]);
  assert.equal(
    pickFreshest(["bff33b4f-8519-41d4-bf2d-c6ea8384cd82", "06744d69-e1dd-47bd-9e79-db27abee5aeb"], {
      "bff33b4f-8519-41d4-bf2d-c6ea8384cd82": { refreshedAt: "2026-11-14T18:00:00.000Z" },
      "06744d69-e1dd-47bd-9e79-db27abee5aeb": { refreshedAt: "2026-11-14T23:00:00.000Z" },
    }),
    "06744d69-e1dd-47bd-9e79-db27abee5aeb"
  );
});

test("a hook session id sticks and a later session end is remembered", () => {
  const record = { agentSeenAt: 100, sessionId: null };
  applyInbox(record, { event: "sessionStart", at: 200, conversationId: CHAT });
  assert.equal(record.sessionId, CHAT);
  assert.equal(record.sessionSource, "hook");
  applyInbox(record, { event: "sessionEnd", at: 50, conversationId: CHAT });
  assert.equal(record.endedAt, null);
  applyInbox(record, { event: "sessionEnd", at: 300 });
  assert.equal(record.endedAt, 300);
});

test("after a new core, the untouched shell in that tab is resumed once", () => {
  const record = {
    address: "t13",
    tab: "tab-driver",
    cwd: "C:\\GitEpam\\ai-migration-assistant",
    core: CORE_A,
    sessionId: CHAT,
    attempts: 0,
  };
  const recovered = {
    address: "t22",
    agent: "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
    state: "live",
    turn: 1,
    cwd: "C:\\GitEpam\\ai-migration-assistant",
    tab: "tab-driver",
  };
  const busy = { ...recovered, address: "t1j", turn: 36 };
  assert.equal(shouldRestore(record, recovered, CORE_A), false);
  assert.equal(chooseShell(record, [busy, recovered], CORE_B).address, "t22");
  record.restoredOn = CORE_B;
  assert.equal(chooseShell(record, [recovered], CORE_B), null);
});

test("the same pane is resumed when the terminal address changed", () => {
  const record = {
    address: "t1g",
    pane: "pane-cursor",
    tab: "tab-driver",
    cwd: "C:\\repo",
    core: CORE_A,
    sessionId: CHAT,
  };
  const cursorShell = {
    address: "t40",
    pane: "pane-cursor",
    agent: "pwsh.exe",
    state: "live",
    turn: 1,
    cwd: "C:\\repo",
    tab: "tab-driver",
  };
  const other = { ...cursorShell, address: "t41", pane: "pane-copilot" };
  assert.equal(chooseShell(record, [other, cursorShell], CORE_B).address, "t40");
});

test("two shells in the same tab are not guessed between", () => {
  const record = {
    address: "t13",
    tab: "tab-driver",
    cwd: "C:\\repo",
    core: CORE_A,
    sessionId: CHAT,
  };
  const a = { address: "t30", agent: "pwsh.exe", state: "live", turn: 0, cwd: "C:\\repo", tab: "tab-driver" };
  const b = { address: "t31", agent: "pwsh.exe", state: "live", turn: 0, cwd: "C:\\repo", tab: "tab-driver" };
  assert.equal(chooseShell(record, [a, b], CORE_B), null);
  assert.equal(chooseShell(record, [{ ...a, address: "t13" }, b], CORE_B).address, "t13");
});

test("newest unclaimed session is assigned one-to-one", () => {
  const assigned = assignNewest(
    [{ address: "t2" }, { address: "t1" }],
    [
      { id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", rank: 10 },
      { id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", rank: 20 },
    ],
    ["bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"]
  );
  assert.equal(assigned.get("t1"), "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
  assert.equal(assigned.get("t2"), undefined);
});
