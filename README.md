# Tern Software Factory

Agents, usage limits, technology news, AI model comparisons, and GitHub pull requests in one native Tern block.

## Install

From this directory, run:

```sh
tern plugin link .
```

Open the Tern command palette. Select **New Software Factory block**.

## Use

Use the **Agents**, **Limits**, **News**, **Models**, and **GitHub** tabs at the top
of the block, or **← / →** to cycle between pages. Each block remembers its active page across
reloads. Switching pages preserves filters and selection. Agent navigation keys
only act on Agents; arrows edit the caret while News or Models search is active.

### Agents

The list updates each second. It shows agents from all sessions on the block's
host. The columns are **Tern session**, **Status**, **Project**,
and **Agent task**. Columns shrink with the pane, with compact spacing; panes
narrower than the 420px table minimum scroll horizontally. Working, waiting, and idle
agents stay in the list. Exited agents leave the list. The plugin reads a
working agent's chat and subagents each second; a waiting or idle agent's chat
only when its state or latest message changes.

Each agent is one compact line. **Project** is the basename of the Git repository
root containing the agent's working directory, resolved with `git rev-parse
--show-toplevel` on that host. Starting in a subdirectory still shows the repository
name. Linked worktrees show their worktree root's name. Results refresh once a
minute; unresolved directories and directories outside Git show `—`.

The detail panel and row tooltip retain the directory of the file the agent changed
most recently, read from omp's structured chat: the target of its latest non-error
`edit`, `write`, or `ast_edit` call (omp's `file://` link when it has one, else
the target resolved against the working directory). Reads, failed edits, MCP
tool calls, and shell commands do not count. Paths inside the working directory
are relative (`./` is the working directory itself, `src/lib/` a subdirectory);
others start from `~` or `/`. Until the agent changes a file, this path is `./`.
The plugin remembers the latest path for each agent until the agent exits. When
it first sees an agent, including after a reload, it looks back over the last 200
chat messages for the newest change.

**Agent task** is a one-sentence summary of what the agent did in the last three
minutes; it shows the omp session title until the first summary arrives, and a
prompt delivery error when there is one. The row tooltip shows the session
title, model, full path, and working directory. Rows leave
out Nerd Font icons, such as the one omp puts before its session titles. A
pulsing dot marks working agents. Amber pulses mark agents that need input; red
pulses mark failed turns or prompt delivery.

To write the agent task, the plugin notes each chat step (requests, replies, and
tool calls) when it first appears in an agent's omp chat. When an agent has new
steps, at most once a minute, it sends the steps from the last three minutes (up
to 3,500 characters) to omp's fast model with `omp -p --model @smol`, without
tools or a saved
session, and shows the first sentence of the reply. One summary runs at a time,
for the agent whose summary is oldest. Idle agents keep their last summary, and
a failed summary keeps the previous one. Summaries reset when the plugin reloads.

While an omp task runs, each of its subagents gets a compact line under the
agent: the subagent type, name, current tool or
assignment, status, model, tokens, and run time. The agent's status notes how
many subagents are running.
Select a subagent row to see its context use, cost, requests, tool count,
thinking level, and assignment. Enter goes to the parent agent's pane.
Subagent rows leave when their task finishes.

Idle dots stay still. The pulses respect Tern's Reduce Motion setting and stop
when the pane is hidden. There is no sound.

| Control | Action |
| --- | --- |
| Up / Down or k / j | Select an agent |
| Enter | Go to the selected agent's pane |
| Click | Select an agent |
| Double-click | Go to the agent's pane |
| Home / End | Select the first or last agent |
| Page Up / Page Down | Move by ten agents |

The list uses Tern's native agent API. It includes agent blocks and omp sessions
that Tern recognizes in shell panes. Set omp as your agent command in Tern.
The plugin does not scan shell processes or require the `tern` executable at runtime.

The header counts working, waiting, and idle agents, and running subagents.
Select a row to open its panel: the agent task as its heading, the status, one
line with the Tern session, project, path (when it is not `./`), model, last
completed turn, and session title, then the latest assistant response from
omp's structured chat. A failed turn or prompt delivery error appears above the
response.

The panel updates each second while the selected agent works, and otherwise when
its state or latest message changes. It reads at most 32 recent messages and
limits text length. Long responses scroll inside the panel. If a native agent
has no structured chat, the panel shows its latest pane update.

#### Repositories and worktrees

The **Repositories** section on Agents lists repositories beneath a configurable
root folder, with linked worktrees nested under their repository. Click **Root
folder**, enter an absolute host path or `~/…`, and Save. Leave the field empty
to clear it. The root is persisted once per host and inherited by new Software
Factory blocks; existing blocks pick up changes when Agents is opened. Each
block remembers its selected directory and keyboard section across reloads.
An existing per-block root migrates automatically when no shared root has been
saved yet. Clearing the shared root also prevents older blocks from restoring it.

Discovery includes the root itself, nested repositories, and bare repositories.
Repositories are deduplicated by Git's common directory; registered worktrees
outside the root still appear beneath their repository. Worktrees show their
branch, detached/locked state, and missing-directory status. Missing worktrees
cannot be opened.

| Control | Repository action |
| --- | --- |
| Tab | Switch keyboard navigation between Agents and Repositories |
| Click | Select a repository or worktree |
| Up / Down or k / j | Select a directory |
| Enter or double-click | Open a shell block beside Software Factory in that directory |
| Cmd+Enter | Create and switch to a new Tern session in that directory |
| Home / End; Page Up / Page Down | Move to an end or by ten directories |
| Refresh or r | Rescan the configured root |

Scanning runs on the block's host when Agents is opened and on demand, using Git
and `uv` (Python 3.11+, standard library only). It does not modify repositories.
Directory symlinks are not followed; Git metadata and common generated folders
(`.cache`, `node_modules`, `.venv`, `venv`, `target`, `dist`, `build`,
`__pycache__`) are skipped. Individual failures are shown as warnings; a scan
deadline reports an error rather than presenting a silently incomplete list.
Repositories sits below the selected agent's summary. Long agent, repository,
and activity sections scroll independently.

### GitHub

GitHub lists repositories under the **same saved root folder as Agents**, with
their open pull requests nested underneath. It is a view of local GitHub
checkouts, not every repository your GitHub account can access. Repositories
without open PRs remain visible.

Install [GitHub CLI](https://cli.github.com/) on the host running the block and
authenticate there:

```sh
gh auth login --hostname github.com
```

The worker also uses Git and uv/Python 3.11+. It reuses repository discovery,
chooses a GitHub `origin` remote first, then `upstream`, then the first other
GitHub remote alphabetically. Multiple clones and worktrees pointing to the same
GitHub repository appear once. HTTPS, SSH, and `git@github.com:owner/repo.git`
remotes are supported; GitHub Enterprise hosts are not included.

Repository names sort alphabetically. PRs sort by latest update, with their
number, title, author, draft/open state, and source/target branches. Hover for
the full details. All pages of open PRs are fetched; closed and merged PRs are
not included.

| Control | GitHub action |
| --- | --- |
| Up / Down or j / k | Select a repository or PR |
| Enter / o or double-click | Open the selected repository or PR on GitHub |
| Home / End; Page Up / Page Down | Move to an end or by ten rows |
| Refresh or r | Rescan the root and reload open PRs |

Data loads on the first visit and when the configured root changes. Blocks on
one host share a serialized worker and in-memory snapshot; switching pages
does not refetch unchanged roots. Refresh manually for newer PR activity.
Failures are shown per repository, retaining its last loaded PRs when available.
An inaccessible repository is never presented as successfully having no PRs.
This page only reads GitHub data and opens links; it does not modify repositories
or pull requests, and does not copy or store your gh credentials.

### Limits

The **Limits** page shows Claude and Codex usage limits for every account
omp is signed in to: each limit window, a usage meter, the amount used, and when
the window resets. It also shows saved resets and marks a service when omp has
no account for it. Narrow panes hide the account column first.

The plugin runs `omp usage --json` once a minute while a Software Factory block
is open. It uses the omp that Tern installs, or `omp` on your PATH. omp caches
provider reports, so the update time can be older than a minute. If a refresh
fails, the block keeps the last limits and shows the error.

### Models

Models compares Artificial Analysis's free-tier Intelligence, Coding, and Agentic
indices alongside median output tokens/second and input/output prices in USD per
million tokens. Default order is Intelligence descending. Sort tabs switch to
other scores, speed, or lowest input/output price. Missing metrics show `—` and
sort last; zero remains a real measurement.

Search matches model names, creators, and model slugs; there are no separate
creator filters or selected-model metadata panels.
**Enter**, `o`, or activating a row opens its Artificial Analysis model page,
preserving versioned model slugs such as `glm-4.5`.
`/` edits search, `s` cycles sort modes, and `r` refreshes.
The table fills the available height; narrow panes scroll horizontally with
the column headings and values together.

#### Free API setup

1. [Create a free Artificial Analysis API key](https://artificialanalysis.ai/api-key-management-redirect).
2. Open Models and click the **key icon** beside Refresh.
3. Paste the key into the masked input and choose **Save** (or press **Enter**).
   The key is saved privately on the host and model data refreshes automatically.
   Escape or Cancel discards an unsubmitted key.

The saved file is `artificial-analysis-api-key` under the plugin data directory,
written atomically with owner-only permissions (`0600`). You can also provision
that file manually, or set `AA_API_KEY` in the Tern host's environment. The saved
file takes precedence over the environment variable; an already-running daemon
does not inherit later shell environment changes.

The key is not rendered in plaintext or included in saved page state, model cache
data, or worker command-line arguments. Keep it out of the repository and do not
paste it into the page's search field. Saving a key does not reset API cooldowns.

Models uses only `/api/v2/language/models/free`, follows pagination, and caches
the complete result outside the checkout. Blocks on one host share requests.
Automatic refresh is every six hours while subscribed, including when another
page is selected. Manual refresh bypasses ordinary cache freshness, but not an
API rate-limit cooldown. Failures retain the last complete snapshot.

The [free API quota](https://artificialanalysis.ai/data-api/docs) is 100 requests
per 24-hour window; each page counts as a request and other clients using the
same quota also consume it. Displayed data is attributed to
[Artificial Analysis](https://artificialanalysis.ai/). Scores should be compared
within the same benchmark version, not combined into a custom universal score.

### News

News combines Anthropic, Hacker News, Hugging Face, Lobsters, OpenAI Engineering,
PVLDB, Simon Willison, TechCrunch, and The Verge into a newest-first headline list.
Filter by source or headline/source text. Hacker News uses Algolia's top 100 stories
by points from the rolling last
seven days, rather than only the current front page. Its source tab is ranked by
points; **All sources** stays newest-first. Source tabs are alphabetical, with
**All sources** pinned first; keyboard source cycling follows the same order.

**Anthropic** combines the [engineering blog](https://www.anthropic.com/engineering)
and [claude.dev](https://claude.dev/), retaining each article's original source label.
Engineering articles come from the official index's published CMS metadata;
claude.dev uses its official RSS feed. **OpenAI Engineering** uses
[OpenAI's official RSS](https://openai.com/news/rss.xml), filtered to the
Engineering category—not company announcements.

Both tabs show the rolling **last 90 days**, including claude.dev. Expired
memberships also leave **All sources**, but a headline remains if another eligible
feed carries it. Cached editions expire without waiting for another fetch.
Articles without a valid publication date or dated in the future are excluded
from these time-limited feeds. Other sources keep their existing windows.

New arrivals appear behind a **new stories · Show** button rather than moving
the list under your selection. Weekly ranking changes offer **Updated stories ·
Show** when no new stories arrive. Click Show or press `n` to adopt that edition.

Select a headline and press **Enter** (or `o`) to open its original link.
Activating a row opens that link too. The headline list, selection, and filters
stay in place; there is no inline reader or read/unread tracking.
The compact table caps Source at 100px and gives the remaining width to headlines.
The headline list fills the remaining pane height and scrolls independently,
without per-source update tickers below it.

| Key | News action |
| --- | --- |
| ↑ / ↓ or j / k | Select headline |
| Enter | Open the selected story's link |
| Esc | Clear search when not editing |
| / | Edit search; Enter or Esc finishes editing |
| s | Cycle sources |
| r | Refresh feeds |
| n | Adopt new stories and updated weekly rankings |
| o | Open the original article |

#### Runtime and cache

Install [uv](https://docs.astral.sh/uv/getting-started/installation/) on the
**host running the block**. The plugin checks `~/.local/bin/uv`, then `PATH`.
Opening News launches `uv run --script news/worker.py`; uv provides Python 3.11+
and the declared `feedparser` dependency in an isolated cache.
The first launch needs network access to install dependencies. The worker supports
macOS and Linux hosts (its deadlines use POSIX signals). Agent discovery and Limits
do not depend on this runtime; repository scanning and Models also use uv.

News starts lazily when first opened, then refreshes every hour while
at least one subscribed block remains open, even if another page is selected.
Blocks on one host share a serialized worker queue and feed cache, but keep their
own filters and selection. Feed failures retain cached headlines.
**Refresh** (or `r`) forces an immediate fetch without waiting for the hourly schedule.

Headlines live in `news.sqlite3` under `tern.plugin.data`, not in the checkout.
The cache retains up to 2,000 stories and shows up to 1,000, preserving the active
HN weekly selection. News filters and the selected headline are saved per block.
Existing caches migrate without losing headline IDs or source attribution.

The worker fetches feeds and Anthropic's engineering index; it does not fetch or
cache article bodies.
Requests and redirects are restricted to public HTTP(S) addresses, with size/deadline
limits; authenticated feeds and private-network feeds are not supported.

#### Adding feeds

Edit `news/sources.luau` and reload the plugin. Each entry has a stable
`id`, display `name`, `url`, `enabled`, and `interval_seconds` (minimum 60).
Sources default to RSS/Atom; Hacker News uses `kind = "hn_weekly"` with the
Algolia search API. A successful weekly refresh replaces HN membership without
removing headlines attributed to other sources.
Anthropic engineering uses `kind = "anthropic_engineering"`. RSS entries can set a
`category` filter; matching happens before the per-feed article cap. Optional
`tab` and `tab_name` group multiple feeds under one source tab. `window_days`
limits a feed to a rolling publication window.
Keep the id when renaming a source. Up to ten feeds are supported per refresh;
disabled or removed feeds stop contributing to the headline list.

The worker normalizes article URLs and combines source attribution when feeds
link to the same URL. It does not merge articles merely because titles resemble
each other. `news/page.luau` owns presentation, `news/controller.luau` owns host
lifecycle and worker jobs, and `news/worker.py` owns network access and SQLite.


Completion tracking starts when the plugin loads and resets on reload. Closed and
exited agents leave the list. The plugin reads activity and subagents through
Tern only, and limits and task summaries through omp. It does not send prompts
to your agents, interrupt them, or save transcripts to disk.
The desktop window half must be loaded to update the list and open panes.

## Develop

Tested with Tern 0.9.0.

After you edit the plugin, run:

```sh
tern plugin reload
```

Tern stops a plugin's window timer until reload once one call runs past 50 ms,
which stops every block from updating. The plugin splits each refresh into
short steps across timer calls. A step that alone takes 25 ms or more is logged
as `Slow refresh step: <step> took <n> ms` in `~/Library/Logs/Tern/tern.log`.

The window half sends each block its agent list and details through the
plugin's key/value store (`snapshot:<id>` and `details:<id>` in the plugin data
directory's `kv.json`), and the block reads them each second. Tern's window API
keeps only the low 44 bits of a pane id, and `cx.session:event` fails for a
shortened id, so `<id>` is the block's pane id modulo 2^44. Entries leave the
store when their block closes.

### Adding a page

Add an entry to the `pages` registry in `host.luau` with a unique stable `id`,
a `label`, and `view(state, cx)`. A view returns `{ main, dock?, layer? }`;
each region must be a container node. Return a fresh view tree on each call.
The shell inserts the native tab strip into `main`, applies shared page spacing,
and forwards the other regions unchanged. Keep `main.pages` reserved for navigation.

Optional `key(state, key, cx)` and `event(state, event, cx)` handlers receive
input only while that page is active. Left/right arrows are reserved for page
switching unless `capture_key(state, key, cx)` consumes the input first.
`init(savedPageState)` creates `state[page.id]`; `save(state)` persists that
page's settings. `enter(state, cx)` runs when a page becomes active, including
restoration after reload. The shell saves these page values alongside the active
page id. A removed saved page falls back to the first registry entry.


To generate the API definitions for your installed Tern version, run:

```sh
tern plugin types .
```

Run the behavior tests with Python 3 and the Luau interpreter:

```sh
python3 tests/run.py
```

Run the worker's isolated local-HTTP/SQLite tests with:

```sh
uv run --with 'feedparser>=6.0.11,<7' \
  python -m unittest discover -s tests -p test_news_worker.py
```

Run Models worker tests (Python standard library only) with:

```sh
python3 -m unittest discover -s tests -p test_models_worker.py
```

Run repository discovery tests against temporary real Git repositories with:

```sh
python3 -m unittest discover -s tests -p test_repositories_worker.py
```

Run GitHub worker tests (temporary Git repositories; no network requests) with:

```sh
python3 -m unittest discover -s tests -p test_github_worker.py
```

Set `LUAU` to the interpreter path if `luau` is not on your PATH.

To unlink the plugin, run:

```sh
tern plugin unlink tern-software-factory
```
