# Tern Software Factory

See the agents on your Tern host. Select an agent and press Enter to go to its pane.

## Install

From this directory, run:

```sh
tern plugin link .
```

Open the Tern command palette. Select **New Software Factory block**.

## Use

The list updates each second. It shows agents from all sessions on the block's
host. The columns are **Tern session**, **Project**, **Path**, **Agent task**,
and **Status**. Scroll horizontally in narrow panes. Working, waiting, and idle
agents stay in the list. Exited agents leave the list.

Each agent is one compact line. **Project** is the name of the agent's working
directory. **Path** is the directory of the file the agent changed most
recently, read from omp's structured chat: the target of its latest successful
`edit`, `write`, or `ast_edit` call (omp's `file://` link when it has one, else
the target resolved against the working directory). Reads, failed edits, MCP
tool calls, and shell commands do not count. Paths inside the working directory
are relative (`./` is the working directory itself, `src/lib/` a subdirectory);
others start from `~` or `/`. Until the agent changes a file, Path shows `./`.
The plugin remembers the latest path for each agent until the agent exits. When
it first sees an agent, including after a reload, it looks back over the last 200
chat messages for the newest change. A long path keeps its end: `…/tests/fixtures/`.

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
agent: the subagent type, name, the agent's path (muted), current tool or
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

The panel updates each second for the selected agent. It reads at most 32 recent
messages and limits text length. Long responses scroll inside the panel. If a
native agent has no structured chat, the panel shows its latest pane update.

### Limits

The bottom of the block shows Claude and Codex usage limits for every account
omp is signed in to: each limit window, a usage meter, the amount used, and when
the window resets. It also shows saved resets and marks a service when omp has
no account for it. Narrow panes hide the account column first.

The plugin runs `omp usage --json` once a minute while a Software Factory block
is open. It uses the omp that Tern installs, or `omp` on your PATH. omp caches
provider reports, so the update time can be older than a minute. If a refresh
fails, the block keeps the last limits and shows the error.

Completion tracking starts when the plugin loads and resets on reload. Closed and
exited agents leave the list. The plugin reads activity and subagents through
Tern only, and limits and task summaries through omp. It does not send prompts
to your agents, interrupt them, or save transcripts to disk.
The desktop window half must be loaded to update the list and open panes.

## Develop

Tested with Tern 0.8.3.

After you edit the plugin, run:

```sh
tern plugin reload
```

To generate the API definitions for your installed Tern version, run:

```sh
tern plugin types .
```

Run the behavior tests with Python 3 and the Luau interpreter:

```sh
python3 tests/run.py
```

Set `LUAU` to the interpreter path if `luau` is not on your PATH.

To unlink the plugin, run:

```sh
tern plugin unlink tern-software-factory
```
