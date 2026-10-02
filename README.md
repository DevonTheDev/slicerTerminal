# Devon's Slicing Terminal

A Garry's Mod addon with a hacking-tool SWEP, configurable terminal entities,
and terminal-driven downloads or door unlocking.

## Install and use

1. Copy `devonsSlicing` into the server's `garrysmod/addons` directory and restart
   the server. Clients need the included materials, fonts and sounds too.
2. Spawn **Devons Console Entity** and fill out its setup form. Only its spawner
   may submit its initial configuration. Console/file names must be nonblank,
   at most 128 characters, and are normalized to lowercase. The delay must be a
   finite positive number of seconds; the folder is `data`, `server`, or `tools`.
   **Done** reads the current fields, including the active text entry. Invalid
   fields keep the form open so they can be corrected; each new form starts
   without values from previous setups.
3. For a `tools` terminal, its creator should look at a `func_door` and type
   `!setEntity` in chat before anyone uses that terminal. Each terminal has its
   own door; a door cannot be attached to two live terminals. Set up and link
   tools terminals one at a time for each creator.
4. Equip **Devons Hacking Tool** and use the console. Primary and secondary
   attack are disabled; right-click must not fire the inherited base weapon. Its
   callable `ShouldDropOnDie` hook returns false, overriding the base weapon
   policy without replacing the method with a boolean.

For a terminal named `terminal` and file named `secret`:

| Action | Command |
| --- | --- |
| Log in | `/a[terminal]` |
| Open a folder | `/a[terminal]/{_data}` (or `{_server}`, `{_tools}`) |
| Return from a folder | `//[terminal]/{_data}` (use the current folder) |
| Download a data file | `/d{_data}/secret.data` |
| Download a server file | `/d{_server}/secret.sys` |
| Run a door tool | `/r{_tools}/secret.exe` |
| Quit from login/folder selection | `/q[terminal]` |

Downloads take the configured login delay plus a second download delay. Tools
require the login delay. Successful completion consumes the terminal. Removing
or completing a linked terminal unlocks its own door. Completion feedback appears
once in the local player's chat after the server accepts completion, regardless
of the number of connected players. Sending a request alone never announces
success. If that player's matching session fails its tool, timing or terminal-type
check, the terminal remains intact, its reservation is released and the player
receives a failure notice. Re-equip the tool and use the console again to retry.

## Session and network safety

The server reserves a terminal when it is used and permits one session per
player. Quit, death, disconnect, and terminal removal release that reservation.
The server authenticates the sender of completion messages and verifies the
active terminal, hacking tool, file type, and minimum elapsed time before
removing anything or unlocking a door. Client-supplied player identities and
legacy reservation/link packets no longer grant permissions.

The elapsed-time check starts when the server opens the terminal. It is a
minimum-duration check, **not proof that a client typed each command or waited
at each UI stage**. This addon is not an anti-cheat system.

## Automated tests

From the repository root, run either:

```sh
lua tests/run.lua
# Or, if a TeX Live Lua interpreter is available:
texlua tests/run.lua
```

The suite needs no downloaded dependencies. It runs the actual addon code with
small Garry's Mod API doubles. Its loader translates GLua `!`, `!=`, and `//`
comments for stock Lua without modifying command strings. The harness supports
Lua 5.1 and newer; the current pass was verified with Lua 5.3 via `texlua`.

Coverage includes malicious/malformed network requests, concurrent users,
creator-only setup, stale/deleted entities, independent door links, session
release, all three successful client command flows, death during countdowns, rejected-completion recovery, authoritative success
feedback, replayed requests and late feedback while another console is open,
repeated folder navigation, setup validation and independent/repeated setup
forms, weapon hold-type initialization, disabled primary/secondary attacks,
the callable death-drop hook, single completion feedback with 1, 2,
and 12 connected players, and compilation of all five addon Lua
files.

The original client source uses CRLF line endings, which this change preserves.
To check whitespace without treating CRLF as trailing whitespace:

```sh
git -c core.whitespace=cr-at-eol diff --check
```

### Real-engine smoke checklist

These tests do **not** replace a Garry's Mod server/client smoke test. Rendering,
assets, physics/Use reach, engine networking and multiplayer timing are not
emulated. Before a live rollout, use a test server to check:

- Spawn/configure one terminal of each type and complete their command flows
- Edit the final setup field and click Done directly; repeat with a new console
  and confirm the new form cannot submit values from the previous one
- Try a blank name/file, missing folder, and nonpositive delay; correct each
  rejected form and verify it can still configure its terminal
- Equip the hacking tool and verify its pistol hold animation in multiplayer;
  with ammunition available, check that left/right-click do not fire or consume it
- In a test gamemode that enables weapon drops on death, verify the hacking tool
  is not dropped and its death hook raises no Lua error
- With two players, confirm only one can enter a terminal at a time
- Quit, die during login/download, disconnect, and remove an occupied terminal;
  confirm its UI closes and another player can use any surviving terminal
- Strip or switch away from the hacking tool during each completion flow;
  confirm no success is printed, the terminal remains available and another
  player can use it. Re-equip and retry normally
- Enter a folder, return, and re-enter several times; check for Lua errors
- Link two tools terminals to different doors; finishing one must leave the
  other door locked, and using unrelated entities must still work
- Check fonts, sounds and layouts at the clients' screen resolutions

Use a fresh server session when deploying server-logic changes; live Lua
refresh of an occupied terminal is not covered by the harness.
