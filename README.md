# pr-babysitter

AI-powered PR babysitter that runs locally on your Mac. Automatically fixes merge conflicts, failing CI, and unresolved review comments using [Claude Code](https://claude.ai/code).

Runs every 5 minutes via macOS launchd. No GitHub Actions minutes burned — uses your own Claude tokens.

## How it works

1. Scans your open PRs on GitHub
2. For each PR with issues (merge conflicts, failing checks, unresolved reviews):
   - Clones the repo into a temp directory
   - Invokes Claude Code CLI to diagnose and fix the issues
   - Runs your project's verify/test/lint commands before pushing
   - Pushes fixes and resolves review threads
3. Tracks attempts via GitHub labels (`babysitter-attempt-N`)
4. Gives up after 10 attempts (`babysitter-gave-up` label)

## Prerequisites

- macOS (uses launchd for scheduling)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated
- `jq` installed (`brew install jq`)

## Install

```bash
git clone https://github.com/mstuart/pr-babysitter.git
cd pr-babysitter
./install.sh
```

This copies `babysitter` and `pr-babysitter.sh` to `~/.local/bin/`.

## Setup

```bash
cd /path/to/your/repo
babysitter init          # creates .babysitterrc
# edit .babysitterrc with your repo and username
babysitter start         # starts the launchd agent
```

## Configuration

Place a `.babysitterrc` in your repo root. See [.babysitterrc.example](.babysitterrc.example) for all options.

Required settings:

```bash
BABYSITTER_REPO="owner/repo"        # GitHub repo
BABYSITTER_AUTHOR="your-username"   # Only watch your PRs
```

Optional settings:

```bash
BABYSITTER_MAX_ATTEMPTS=10          # Give up after N attempts
BABYSITTER_MODEL=sonnet             # Claude model
BABYSITTER_INTERVAL=300             # Seconds between runs
BABYSITTER_VERIFY_CMD="npm run verify"
BABYSITTER_TEST_CMD="npm test"
BABYSITTER_LINT_CMD="npm run lint:fix"
BABYSITTER_INSTALL_CMD="npm ci --prefer-offline --no-audit --no-fund"
```

### Custom prompts

For full control over what Claude does, point to a prompt template file:

```bash
BABYSITTER_PROMPT_FILE=".babysitter-prompt.txt"
```

The file supports variable substitution via `envsubst`: `$REPO`, `$NUMBER`, `$TITLE`, `$ATTEMPT`, `$MAX`, `$MERGEABLE`, `$FAILING`, `$UNRESOLVED`, `$VERIFY_CMD`, `$TEST_CMD`, `$LINT_CMD`.

Or append extra rules to the default prompt:

```bash
BABYSITTER_EXTRA_RULES="- This is a monorepo with Turborepo
- NEVER run 'npm run seed' (destroys all data)"
```

### Config resolution

Config is loaded from the first match:

1. `$BABYSITTER_CONFIG` env var (explicit path)
2. `.babysitterrc` (walking up from cwd to `/`)
3. `~/.config/pr-babysitter/config`

## CLI

```
babysitter <command>

COMMANDS
  init         Create a .babysitterrc config in the current directory
  start        Load and start the launchd agent
  stop         Unload and stop the launchd agent
  status       Show agent status and current PR overview
  dashboard    Live-updating dashboard (refreshes every 30s)
  run          Run one babysitter cycle immediately (foreground)
  logs         Tail the babysitter log
  logs clear   Clear the log file
  reset <pr>   Remove all babysitter labels from a PR
  reset-all    Remove all babysitter labels from all open PRs
```

### Dashboard

```bash
babysitter dashboard       # refreshes every 30s
babysitter dashboard 10    # refreshes every 10s
```

Shows: agent status, each PR's health (conflicts, failing checks, unresolved threads), attempt counts, and recent log activity.

## What it fixes

| Issue | How |
|-------|-----|
| Merge conflicts | `git merge origin/main` + AI conflict resolution |
| TypeScript errors | Runs verify command, fixes reported errors |
| Test failures | Runs test command, fixes failing tests |
| Lint errors | Runs lint command with auto-fix |
| Review comments | Reads unresolved threads, makes requested code changes, resolves threads |

The babysitter will **not**:
- Force-push
- Guess at answers to discussion questions in reviews
- Push code that fails verification
- Touch PRs by other authors

## Labels

| Label | Meaning |
|-------|---------|
| `babysitter-attempt-N` | The babysitter has made N fix attempts on this PR |
| `babysitter-gave-up` | Exceeded max attempts — babysitter will no longer touch this PR |

Use `babysitter reset <pr-number>` to clear labels and let it try again.

## License

MIT
