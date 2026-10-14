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
host. The columns are **Tern session**, **Agent session**, **Status**, and **Path**.
The path is the full working directory. Scroll horizontally in narrow panes.
Working, waiting, and idle agents stay in the list. Exited agents leave the list.

Each row also shows the model, a short latest-update preview, and the project
folder above its full path. A pulsing dot marks working agents. Amber pulses
mark agents that need input; red pulses mark failed turns or prompt delivery.
Idle dots stay still. The pulses respect Tern's Reduce Motion setting and stop
when the pane is hidden. There is no sound.

Lists with more than 200 agents use compact rows to match Tern's virtual scroll
height. The row tooltip and activity panel keep the extra details available.

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

The header counts working, waiting, and idle agents. Select a row to see:

- The model and any prompt delivery error.
- The latest request and assistant response from omp's structured chat.
- The last completed or failed turn, and how long ago Tern reported it.

Activity updates each second for the selected agent. It reads at most 32 recent
messages and limits text length. Long responses scroll inside the activity panel.
If a native agent has no structured chat, the panel shows its latest pane update.
This is recent activity, not an AI-generated summary of the full session.

Completion tracking starts when the plugin loads and resets on reload. Closed and
exited agents leave the list. The plugin reads activity through Tern only. It does
not send prompts, interrupt agents, call a model, or save transcripts to disk.
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
