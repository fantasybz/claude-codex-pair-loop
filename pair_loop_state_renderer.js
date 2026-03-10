#!/usr/bin/env node

const fs = require("fs");

function readFileSafe(path) {
  if (!path || !fs.existsSync(path)) {
    return "";
  }
  return fs.readFileSync(path, "utf8").trimEnd();
}

function readJsonl(path) {
  if (!path || !fs.existsSync(path)) {
    return [];
  }

  const raw = fs.readFileSync(path, "utf8").trim();
  if (!raw) {
    return [];
  }

  const lines = raw
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);

  try {
    return lines.map((line) => JSON.parse(line));
  } catch {
    return raw
      .split(/\n\s*\n/)
      .map((block) => block.trim())
      .filter(Boolean)
      .map((block) => JSON.parse(block));
  }
}

function renderAgent(agent) {
  const changed = Array.isArray(agent.changedFiles) && agent.changedFiles.length > 0
    ? agent.changedFiles.join(", ")
    : "none";
  const resolvedModel = agent.resolvedModel || agent.model || "default";
  const resolvedEffort = agent.resolvedEffort || agent.effort || "default";
  const configuredModel = agent.configuredModel || agent.model || resolvedModel;
  const configuredEffort = agent.configuredEffort || agent.effort || resolvedEffort;
  return [
    `- ${agent.name}: ${agent.status}`,
    `  resolved model=${resolvedModel}, resolved effort=${resolvedEffort}, duration=${agent.durationSeconds}s, exit=${agent.exitStatus}`,
    `  configured model=${configuredModel}, configured effort=${configuredEffort}`,
    `  changed files: ${changed}`,
    agent.reason ? `  note: ${agent.reason}` : "",
  ].filter(Boolean).join("\n");
}

function summarizeArchived(entries) {
  if (entries.length === 0) {
    return "";
  }

  const completed = entries.filter((entry) =>
    entry.agents.some((agent) => agent.status === "completed")
  ).length;
  const failed = entries.filter((entry) =>
    entry.agents.some((agent) => agent.status === "failed")
  ).length;
  const skipped = entries.filter((entry) =>
    entry.agents.every((agent) => agent.status === "skipped")
  ).length;

  return [
    `- Archived iterations: ${entries.length}`,
    `- Iterations with at least one completed turn: ${completed}`,
    `- Iterations with a failed turn: ${failed}`,
    `- Iterations where all turns were skipped: ${skipped}`,
  ].join("\n");
}

function renderEntry(entry) {
  const stopChecks = Object.entries(entry.stopChecks || {})
    .map(([key, value]) => `${key}=${value ? "met" : "pending"}`)
    .join(", ");

  const lines = [
    `### Iteration ${entry.iteration}`,
    `- Timestamp: ${entry.timestamp}`,
    `- Mode: ${entry.mode}`,
    `- Validation: ${entry.validation.status}${entry.validation.reason ? ` (${entry.validation.reason})` : ""}`,
    `- Stop checks: ${stopChecks || "none"}`,
    `- Checkpoint: ${entry.checkpoint.status}${entry.checkpoint.ref ? ` (${entry.checkpoint.ref})` : ""}${entry.checkpoint.reason ? ` - ${entry.checkpoint.reason}` : ""}`,
    renderAgent(entry.agents[0]),
    renderAgent(entry.agents[1]),
  ];

  if (entry.nextHandoff) {
    lines.push(`- Next handoff: ${entry.nextHandoff}`);
  }

  return lines.join("\n");
}

function main() {
  const [
    stateFile,
    stateJsonFile,
    historyFile,
    successCriteriaFile,
    fileFocusFile,
    openDecisionsFile,
    risksFile,
  ] = process.argv.slice(2);

  const entries = readJsonl(historyFile);
  const maxEntries = Number(process.env.STATE_MAX_LEDGER_ENTRIES || "12");
  const archivedEntries = entries.slice(0, Math.max(entries.length - maxEntries, 0));
  const recentEntries = entries.slice(-maxEntries);
  const boolOrNull = (value) => {
    if (value === "1") {
      return true;
    }
    if (value === "0") {
      return false;
    }
    return null;
  };

  const successCriteria = readFileSafe(successCriteriaFile) || [
    "- [ ] Core implementation works",
    "- [ ] Validation or tests pass",
    "- [ ] Usage notes or documentation are updated",
  ].join("\n");
  const fileFocus = readFileSafe(fileFocusFile) || "- (update as needed)";
  const openDecisions = readFileSafe(openDecisionsFile) || "- (none recorded)";
  const risks = readFileSafe(risksFile) || "- (none recorded)";

  const data = {
    task: process.env.TASK || "",
    session: {
      name: process.env.SESSION_NAME || "",
      mode: process.env.MODE || "",
      startedAt: process.env.RUN_STARTED_AT || "",
      firstAgent: process.env.FIRST_AGENT || "",
      rolePreset: process.env.ROLE_PRESET || "",
      workspace: process.env.WORKSPACE || "",
      logDir: process.env.ACTIVE_LOG_DIR || "",
    },
    successCriteria,
    currentStatus: {
      phase: process.env.CURRENT_PHASE || "running",
      health: process.env.CURRENT_HEALTH || "yellow",
      mainBlocker: process.env.CURRENT_BLOCKER || "none recorded",
      currentOwner: process.env.CURRENT_OWNER || "unassigned",
      validationStatus: process.env.CURRENT_VALIDATION_STATUS || "not-run",
      validationReason: process.env.CURRENT_VALIDATION_REASON || "No validation has run yet.",
    },
    fileFocus,
    openDecisions,
    nextHandoff: process.env.NEXT_HANDOFF_CONTENT || "- Waiting for the next completed turn.",
    risks,
    stopConditions: {
      configured: {
        untilTestsPass: process.env.UNTIL_TESTS_PASS === "1",
        untilChecklistComplete: process.env.UNTIL_CHECKLIST_COMPLETE === "1",
        untilCleanGit: process.env.UNTIL_CLEAN_GIT === "1",
      },
      current: {
        untilTestsPass: boolOrNull(process.env.STOP_TESTS_PASS_MET),
        untilChecklistComplete: boolOrNull(process.env.STOP_CHECKLIST_COMPLETE_MET),
        untilCleanGit: boolOrNull(process.env.STOP_CLEAN_GIT_MET),
      },
      summary: process.env.STOP_CHECKS_SUMMARY || [
        "- until-tests-pass: not-configured",
        "- until-checklist-complete: not-configured",
        "- until-clean-git: not-configured",
      ].join("\n"),
    },
    validationCommand: process.env.VALIDATION_COMMAND_USED || "",
    iterations: entries,
    archivedSummary: summarizeArchived(archivedEntries),
  };

  const markdown = [
    "# Pair Loop State",
    "",
    "## Task",
    data.task,
    "",
    "## Session",
    `- Name: ${data.session.name || "(default)"}`,
    `- Mode: ${data.session.mode}`,
    `- Started at: ${data.session.startedAt || "unknown"}`,
    `- First agent: ${data.session.firstAgent}`,
    `- Role preset: ${data.session.rolePreset}`,
    `- Workspace: ${data.session.workspace}`,
    `- Log dir: ${data.session.logDir}`,
    "",
    "## Success Criteria",
    data.successCriteria,
    "",
    "## Current Status",
    `- Phase: ${data.currentStatus.phase}`,
    `- Health: ${data.currentStatus.health}`,
    `- Main blocker: ${data.currentStatus.mainBlocker}`,
    `- Current owner: ${data.currentStatus.currentOwner}`,
    `- Validation: ${data.currentStatus.validationStatus} (${data.currentStatus.validationReason})`,
    "",
    "## File Focus",
    data.fileFocus,
    "",
    "## Open Decisions",
    data.openDecisions,
    "",
    "## Next Handoff",
    data.nextHandoff,
    "",
    "## Risks",
    data.risks,
    "",
    "## Iteration Ledger",
    recentEntries.length > 0
      ? recentEntries.map(renderEntry).join("\n\n")
      : "- No iterations recorded yet.",
    "",
    "## Archived Iteration Summary",
    data.archivedSummary || "- No archived iterations yet.",
    "",
    "## Stop Conditions",
    data.stopConditions.summary,
  ].join("\n");

  fs.writeFileSync(stateFile, `${markdown}\n`);
  fs.writeFileSync(stateJsonFile, `${JSON.stringify(data, null, 2)}\n`);
}

main();
