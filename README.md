# SwarmTool

A Bash CLI that orchestrates multiple Claude Code agents to work on a goal in parallel. Built on the principle of **dumb workers, smart orchestration**.

SwarmTool decomposes a high-level goal into isolated tasks, dispatches them to Claude Code subprocesses running in separate git worktrees, evaluates the results, and merges everything back together.

## Architecture

```
                  ┌─────────┐
                  │  Goal    │
                  └────┬─────┘
                       │
                ┌──────▼──────┐
                │   Planner   │  Claude Code (opus) analyzes the codebase
                │             │  and decomposes the goal into tasks
                └──────┬──────┘
                       │
                ┌──────▼──────┐
                │   Review    │  You approve, edit, or re-plan
                └──────┬──────┘
                       │
          ┌────────────┼────────────┐
          │            │            │
    ┌─────▼─────┐┌────▼─────┐┌────▼─────┐
    │  Worker 1 ││ Worker 2 ││ Worker N │  Claude Code (sonnet)
    │ worktree  ││ worktree ││ worktree │  isolated git worktrees
    └─────┬─────┘└────┬─────┘└────┬─────┘
          │            │            │
          └────────────┼────────────┘
                       │
                ┌──────▼──────┐
                │    Judge    │  Automated checks + Claude Code evaluation
                └──────┬──────┘
                       │
                ┌──────▼──────┐
                │    Merge    │  Auto-merge + Claude conflict resolution
                └──────┬──────┘
                       │
                  ┌────▼─────┐
                  │  Result   │
                  └──────────┘
```

Workers are **isolated and ignorant**. They receive only the specific task, the relevant files, and success criteria. They don't know about each other, the broader project goals, or the system architecture. This eliminates coordination overhead and enables true parallelism.

## Prerequisites

- **git** -- version control (worktrees require git 2.5+)
- **claude** -- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- **jq** -- JSON processor (`brew install jq` on macOS)

## Installation

### Option 1: Clone and symlink

```bash
git clone https://github.com/anons191/SwarmTool.git
ln -s "$(pwd)/SwarmTool/swarmtool" /usr/local/bin/swarmtool
```

### Option 2: Clone and add to PATH

```bash
git clone https://github.com/anons191/SwarmTool.git
export PATH="$PATH:$(pwd)/SwarmTool"
```

Add the export line to your `~/.zshrc` or `~/.bashrc` to persist it.

### Verify installation

```bash
swarmtool --help
```

## Usage

### Basic usage

Navigate to any git repository and run:

```bash
swarmtool "Add user authentication with JWT"
```

Or use the `--goal` flag:

```bash
swarmtool --goal "Refactor the database layer to use connection pooling"
```

If you omit the goal, SwarmTool will prompt you interactively.

### Interactive flow

1. **You provide a goal** -- what you want accomplished
2. **Planner analyzes your codebase** -- Claude Code (opus) reads the repo and decomposes the goal into isolated tasks
3. **You review the plan** -- approve, edit tasks, delete tasks, add tasks, or send feedback to re-plan
4. **Workers execute in parallel** -- each task runs in its own git worktree with a dedicated Claude Code process
5. **Judge evaluates results** -- automated checks (tests, lint, type checking) followed by Claude Code review
6. **Merge combines everything** -- auto-merge where possible, Claude Code resolves conflicts
7. **You get a summary** -- what was done, what passed, what failed

### Plan review options

During the interactive review, you can:

| Key | Action |
|-----|--------|
| `a` | Approve and execute all tasks |
| `v` | View full details of a task |
| `e` | Edit a task spec in your `$EDITOR` |
| `d` | Delete a task |
| `n` | Add a new task manually |
| `r` | Re-plan with feedback |
| `p` | View the full plan |
| `q` | Quit without executing |

### Resume interrupted runs

If a run is interrupted (Ctrl+C, crash, etc.), resume it:

```bash
swarmtool --resume <run-id>
```

SwarmTool persists state to disk at every phase transition. Resuming picks up exactly where it left off -- interrupted workers are reset to pending and re-executed.

### List previous runs

```bash
swarmtool --list
```

### Dry run

Preview the plan without executing:

```bash
swarmtool --dry-run "Add dark mode support"
```

## Configuration

Configuration follows this precedence (highest wins):

```
CLI flags > Environment variables > .swarmtool/config > defaults.conf
```

### CLI flags

```bash
swarmtool "goal" \
  --max-workers 3 \
  --planner-model opus \
  --worker-model sonnet \
  --judge-model sonnet \
  --budget 10.00
```

### Environment variables

```bash
export SWARMTOOL_MAX_WORKERS=5
export SWARMTOOL_WORKER_MODEL=sonnet
export SWARMTOOL_TOTAL_BUDGET=15.00
swarmtool "goal"
```

### Project config file

Create `.swarmtool/config` in your project root:

```bash
SWARMTOOL_PLANNER_MODEL=opus
SWARMTOOL_WORKER_MODEL=sonnet
SWARMTOOL_TOTAL_BUDGET=25.00
SWARMTOOL_MAX_WORKERS=5
```

### All settings

| Setting | Default | Description |
|---------|---------|-------------|
| `SWARMTOOL_PLANNER_MODEL` | `opus` | Model for the planner |
| `SWARMTOOL_WORKER_MODEL` | `sonnet` | Model for workers |
| `SWARMTOOL_JUDGE_MODEL` | `sonnet` | Model for the judge |
| `SWARMTOOL_MERGE_MODEL` | `sonnet` | Model for merge conflict resolution |
| `SWARMTOOL_PLANNER_BUDGET` | `2.00` | Max USD per planner invocation |
| `SWARMTOOL_WORKER_BUDGET` | `1.00` | Max USD per worker task |
| `SWARMTOOL_JUDGE_BUDGET` | `0.50` | Max USD per judge evaluation |
| `SWARMTOOL_MERGE_BUDGET` | `0.50` | Max USD per merge resolution |
| `SWARMTOOL_TOTAL_BUDGET` | `20.00` | Total budget cap per run |
| `SWARMTOOL_MAX_WORKERS` | `0` (auto) | Max concurrent workers (0 = auto-detect) |
| `SWARMTOOL_API_CONCURRENCY` | `5` | Max concurrent Claude API calls |
| `SWARMTOOL_HARD_MAX_WORKERS` | `10` | Absolute ceiling on workers |
| `SWARMTOOL_WORKER_MAX_RETRIES` | `2` | Retry attempts per worker |
| `SWARMTOOL_RETRY_DELAY` | `10` | Initial retry delay in seconds (doubles each retry) |
| `SWARMTOOL_AUTO_MERGE` | `true` | Attempt auto-merge before Claude resolution |
| `SWARMTOOL_FINAL_VALIDATION` | `true` | Run validation after merge |

### Auto-scaling

When `SWARMTOOL_MAX_WORKERS=0` (the default), SwarmTool auto-detects:

- **CPU cores** -- allows 2x cores (workers are I/O bound, not CPU bound)
- **Available memory** -- reserves 4GB for the system, budgets 500MB per worker
- **API concurrency** -- respects the configured API limit
- **Task count** -- never more workers than tasks

The minimum of all limits is used, capped at `SWARMTOOL_HARD_MAX_WORKERS`.

## How it works

### State machine

Every run progresses through these states:

```
initialized -> planning -> approved -> executing -> judging -> merging -> complete
```

Any state can transition to `failed`. The current state is persisted to `.swarmtool/runs/<run-id>/run.state`, which is how resumability works.

### Task specs

Tasks are stored as flat text files (`.spec`) using a key-value format:

```
TASK_ID=task-001
TASK_TITLE=Add auth middleware
TASK_PRIORITY=1
TASK_BRANCH=swarmtool/<run-id>/task-001

TASK_DESCRIPTION<<ENDBLOCK
Add JWT validation middleware to protected routes.
ENDBLOCK

TASK_INPUT_FILES<<ENDBLOCK
src/server.ts
src/routes/index.ts
ENDBLOCK

TASK_SUCCESS_CRITERIA<<ENDBLOCK
- Middleware validates JWT tokens
- Returns 401 for invalid tokens
- Existing tests pass
ENDBLOCK

TASK_BOUNDARIES<<ENDBLOCK
- Do NOT modify the user model
- Do NOT add new dependencies
ENDBLOCK
```

These files are human-readable and editable. You can modify them directly during the review phase.

### Worker isolation

Each worker gets its own [git worktree](https://git-scm.com/docs/git-worktree) -- a separate working directory with its own branch, all backed by the same git repository. Workers:

- Execute in their own filesystem copy
- Have no knowledge of other workers
- Receive only the files listed in their task spec
- Cannot run git commands
- Are terminated after completing their task

### Merge pipeline

1. **Order** -- tasks are merged in topological order (respecting dependencies), then by priority
2. **Auto-merge** -- clean merges are applied automatically
3. **Conflict resolution** -- Claude Code reads conflict markers and resolves them
4. **Validation** -- tests/build run on the integration branch
5. **Confirmation** -- you approve the final merge into your base branch

## Run directory structure

Each run creates state files in `.swarmtool/runs/<run-id>/`:

```
.swarmtool/runs/<run-id>/
  run.state          # Current phase
  run.meta           # Goal, base branch, base commit, timestamps
  run.log            # Event log
  plan.md            # Human-readable plan
  tasks/
    task-001.spec    # Task specification
    task-001.status  # pending | running | done | failed
    task-001.result  # Worker output
    task-001.log     # Worker stderr/stdout
    task-001.judge   # Judge verdict
  merge/
    merge.log        # Merge operations log
    merge.order      # Task merge order
    merge.status     # Merge phase status
  summary.md         # Final report
```

## Design philosophy

SwarmTool is built on research showing that multi-agent coordination overhead grows superlinearly (O(n^2)) with agent count. The solution is to eliminate coordination entirely:

- **Workers don't coordinate** -- they don't know other workers exist
- **Workers stay ignorant** -- minimal context prevents scope creep
- **Workers are ephemeral** -- run, capture results, terminate
- **Complexity lives in orchestration** -- task distribution, merge queues, evaluation
- **Prompts are API contracts** -- inputs, outputs, boundaries, success criteria

For the full rationale, see [agent-swarm-coordination-notes.md](agent-swarm-coordination-notes.md).

## License

MIT
