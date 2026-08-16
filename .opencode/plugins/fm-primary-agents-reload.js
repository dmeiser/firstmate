import { existsSync, readFileSync, statSync } from "node:fs";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

const AGENTS_FILE = "AGENTS.md";
const RELOAD_MARKER = "<!-- FIRSTMATE_AGENTS_RELOAD -->";

function runProcess(command, args) {
  return new Promise((resolvePromise) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolvePromise({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolvePromise({ code: code ?? 0, stdout, stderr }));
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

function isPrimaryRoot(root) {
  if (!root) return false;
  return existsSync(`${root}/${AGENTS_FILE}`) && existsSync(`${root}/bin`);
}

class AgentsReloadCache {
  constructor(root) {
    this.root = root;
    this.path = `${root}/${AGENTS_FILE}`;
    this.content = "";
    this.mtimeMs = 0;
    this.size = 0;
  }

  read() {
    try {
      const stats = statSync(this.path);
      if (stats.mtimeMs === this.mtimeMs && stats.size === this.size) {
        return this.content;
      }
      this.content = readFileSync(this.path, "utf8");
      this.mtimeMs = stats.mtimeMs;
      this.size = stats.size;
      return this.content;
    } catch {
      return "";
    }
  }
}

function hasAgentsContent(system, content) {
  if (!content) return true;
  const needle = content.slice(0, 240);
  return system.some((entry) => typeof entry === "string" && entry.includes(needle));
}

function reloadBlock(content) {
  return `${RELOAD_MARKER}\n\n# Firstmate operational contract\n\n${content}\n\n${RELOAD_MARKER}`;
}

export const FmPrimaryAgentsReload = async ({ directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);
  if (!isPrimaryRoot(root)) return {};

  const cache = new AgentsReloadCache(root);

  return {
    "experimental.session.compacting": async (_input, output) => {
      const content = cache.read();
      if (!content) return;

      if (typeof output?.prompt === "string" && output.prompt) {
        return;
      }

      const context = output?.context;
      if (!Array.isArray(context)) return;

      if (context.some((entry) => typeof entry === "string" && entry.includes(RELOAD_MARKER))) {
        return;
      }

      context.push(reloadBlock(content));
    },

    "experimental.chat.system.transform": async (_input, output) => {
      const content = cache.read();
      if (!content) return;

      const system = output?.system;
      if (!Array.isArray(system)) return;

      if (hasAgentsContent(system, content)) return;

      const block = reloadBlock(content);
      if (system.length === 0) {
        system.push(block);
        return;
      }

      if (typeof system[0] === "string") {
        system[0] = `${block}\n\n${system[0]}`;
      } else {
        system.push(block);
      }
    },
  };
};
