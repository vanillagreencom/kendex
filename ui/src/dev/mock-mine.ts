// The Mine tab against canned data: rows, import inventory, submit.
import type {
  ImportCandidate,
  ImportSelection,
  MineListRow,
  MineRow,
  SubmitPreflight,
} from "@/bindings";
import { callRefusal } from "./mock-account";
import type { Handler } from "./mock-state";

function row(overrides: Partial<MineRow>): MineRow {
  return {
    path: "/home/jane/dev/team-skills",
    name: "team-skills",
    description: "Skills for the whole team",
    license: "MIT",
    counts: { skill: 4, agent: 2 },
    bundles: 1,
    declared: true,
    breakage: 0,
    advisory: 0,
    safetyFindings: 0,
    findings: [],
    git: {
      repository: true,
      clean: true,
      remote: "git@github.com:jane/team-skills.git",
      candidate: "jane/team-skills",
      ahead: 0,
    },
    ...overrides,
  };
}

let rows: MineListRow[] = [
  { state: "ready", row: row({}) },
  {
    state: "ready",
    row: row({
      path: "/home/jane/dev/scratch-skills",
      name: "scratch-skills",
      description: null,
      license: null,
      counts: { skill: 1 },
      bundles: 0,
      declared: false,
      advisory: 1,
      safetyFindings: 1,
      findings: [
        {
          file: "skills/gh/SKILL.md",
          kind: "skill",
          name: "gh",
          pass: "safety",
          severity: "medium",
          message: "Names a credential file (~/.aws/credentials)",
          fix: "Read configuration through the tool's own auth instead",
        },
      ],
      git: {
        repository: false,
        clean: null,
        remote: null,
        candidate: null,
        ahead: null,
      },
    }),
  },
];

const candidates: ImportCandidate[] = [
  {
    kind: "skill",
    name: "review",
    nameProblem: null,
    origins: [
      {
        group: { group: "own" },
        locations: ["/home/jane/.kendex-local/skills/review"],
        hash: "aaaa1111aaaa1111",
      },
    ],
  },
  {
    kind: "skill",
    name: "gh",
    nameProblem: null,
    origins: [
      {
        group: {
          group: "marketplace",
          source: "agent-kit",
          repo: "acme/agent-kit",
          license: "MIT",
          licenseRecognized: true,
        },
        locations: ["acme/agent-kit:skills/gh"],
        hash: "bbbb2222bbbb2222",
      },
    ],
  },
  {
    kind: "agent",
    name: "Stray Helper",
    nameProblem: "`Stray Helper` holds a space, which some loaders refuse",
    origins: [
      {
        group: { group: "unmanaged" },
        locations: ["/home/jane/.claude/agents/Stray Helper.md"],
        hash: "cccc3333cccc3333",
      },
    ],
  },
];

const safetyLabel = ({ safetyFindings: n }: MineRow) =>
  n ? `${n} safety finding(s), advisory` : "No safety findings";

function preflightFor(path: string): SubmitPreflight {
  const entry = rows.find((k) => k.state === "ready" && k.row.path === path);
  const mine = entry && entry.state === "ready" ? entry.row : row({});
  return {
    row: mine,
    candidate: mine.git.candidate,
    ready: mine.git.candidate !== null,
    checks: [
      { ok: true, label: "Passes the check", fix: null },
      { ok: true, label: safetyLabel(mine), fix: null },
      { ok: true, label: "Has a name and description", fix: null },
      {
        ok: mine.license !== null,
        label: "Has a licence",
        fix:
          mine.license !== null
            ? null
            : 'add license = "<SPDX id>" to kendex.toml — submission needs one',
      },
      { ok: mine.git.repository, label: "Is a git repository", fix: null },
      {
        ok: mine.git.candidate !== null,
        label: mine.git.candidate
          ? `Has a GitHub remote: github.com/${mine.git.candidate}`
          : "Has a GitHub remote",
        fix: mine.git.candidate
          ? null
          : "push the repository to GitHub and add it as `origin`",
      },
      {
        ok: null,
        label: "Repository is public",
        fix: "could not reach GitHub to check — the submit itself will verify",
      },
    ],
  };
}

const SUBMISSION = {
  repo: "jane/team-skills",
  status: "pending",
  status_reason: null,
  head_commit: null,
  indexed_at: null,
};

const underSignIn = <T>(answer: T) => {
  const refused = callRefusal();
  return refused ? Promise.reject(refused) : answer;
};

export const mineHandlers: Record<string, Handler> = {
  mine_submit_preflight: (args: { path: string }) => preflightFor(args.path),
  mine_submit: (args: { repo: string }) =>
    underSignIn({ repo: args.repo, status: "pending" }),
  mine_submissions: () => underSignIn([SUBMISSION]),
  mine_authoring_doc: () =>
    "# How a marketplace repo works\n\nA kendex marketplace is a git repository.\n",
  mine_list: () => rows,
  mine_use_existing: (args: { path: string }) => {
    const added = row({
      path: args.path,
      name: args.path.split("/").at(-1) ?? "folder",
      declared: false,
      counts: { skill: 2 },
      bundles: 0,
    });
    rows = [...rows, { state: "ready", row: added }];
    return added;
  },
  mine_create: (args: {
    request: { name: string; dir: string; description: string };
  }) => {
    const made = row({
      path: args.request.dir,
      name: args.request.name,
      description: args.request.description || null,
      counts: {},
      bundles: 0,
    });
    rows = [...rows, { state: "ready", row: made }];
    return made;
  },
  mine_forget: (args: { path: string }) => {
    rows = rows.filter(
      (entry) => entry.state !== "ready" || entry.row.path !== args.path,
    );
    return null;
  },
  mine_import_inventory: () => candidates,
  mine_import_apply: (args: { selections: ImportSelection[] }) => {
    const refused = args.selections.find(
      (chosen) => chosen.name === "gh" && !chosen.licenseConfirmed,
    );
    if (refused) {
      return Promise.reject(
        "'gh' comes from marketplace 'agent-kit' under licence MIT — confirm the licence permits republishing, or pick another origin",
      );
    }
    return {
      written: args.selections.map((chosen) =>
        chosen.kind === "skill"
          ? `skills/${chosen.destination}`
          : `agents/${chosen.destination}.md`,
      ),
      alreadyPresent: [],
    };
  },
  mine_offer_manifest: () => ({
    rel: "kendex.toml",
    bytes: '[marketplace]\nname = "scratch-skills"\n',
  }),
  mine_offer_workflow: () => ({
    rel: ".github/workflows/kendex-check.yml",
    bytes: "name: kendex check\n",
  }),
  mine_accept_manifest: (args: { path: string }) => acceptInto(args.path),
  mine_accept_workflow: (args: { path: string }) => acceptInto(args.path),
};

function acceptInto(path: string): MineRow {
  const entry = rows.find(
    (kept) => kept.state === "ready" && kept.row.path === path,
  );
  if (entry && entry.state === "ready") {
    entry.row.declared = true;
    return entry.row;
  }
  return row({});
}
