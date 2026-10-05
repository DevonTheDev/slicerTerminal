# Devon's Slicing Terminal

A Garry's Mod addon with a hacking-tool SWEP, configurable terminal entities,
and terminal-driven downloads or door unlocking.

## Install and use

1. Copy `devonsSlicing` into the server's `garrysmod/addons` directory and restart
   the server. Clients need the included materials, fonts and sounds too.
2. Spawn **Devons Console Entity** and fill out its setup form. Only its spawner
   may submit its initial configuration. Console/file names must be nonblank,
   at most 128 bytes, and are normalized to lowercase. The delay must be a
   finite positive number of seconds; the folder is `data`, `server`, or `tools`.
   **Done** reads the current fields, including the active text entry. Invalid
   fields keep the form open so they can be corrected; each new form starts
   without values from previous setups.
3. Setting up a `tools` terminal selects it for its creator. Look at a
   `func_door` and type `!setEntity` in chat to link it before anyone uses it.
   To choose another of your configured tools terminals, look at that terminal
   and type `!setEntity`; the confirmation names your selection. Then look at
   its intended door and type `!setEntity` again. This also recovers an older
   terminal after you set up or remove a newer one. Selection requires a
   terminal that has **never been linked** and is not in use. A prior link
   remains ineligible even if its door was removed. Invalid choices preserve
   your pending selection so you can retry. Each terminal has its own door;
   a door cannot be attached to two live terminals. Using an unlinked terminal
   only gives guidance and does not select it.
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

Click **Quit terminal** on any terminal page to leave immediately, including
during a login or download countdown. It closes Commands too, cancels the
pending local countdown, and asks the server to release your reservation. The
terminal remains available for another attempt, and a linked door stays locked.
Starting again begins a fresh login; there is no saved partial progress. Quitting
cannot undo a completion request that was already sent.

### Command assistance

Click **Commands (/help)** or enter `/help` to open a scrollable reference for
the current terminal screen. The reference fills in that terminal's real name
and filename. A folder only offers a download or tool command when it contains
the target file; every folder includes its return command. Help can be closed
without quitting, and it does not submit an action or bypass a countdown.

Choose **Insert command** beneath a reference entry to replace the current
draft with that exact command. Help closes and the command entry receives focus
with its caret at the end. You can edit the draft before pressing Enter; only
Enter submits it or adds it to history. Insertion is unavailable during a login
or download countdown, while the reference remains readable. Closed or retired
help windows cannot insert into a later terminal screen or session.

Use the Up and Down arrows in the command entry to recall recent submissions
and correct a typo. The last 20 distinct submissions are shared across the
current terminal's screens and cleared for a new terminal session. Blank entries
and entries longer than 512 bytes are not retained. This uses Garry's Mod's
documented [text-entry history](https://wiki.facepunch.com/gmod/DTextEntry%3ASetHistoryEnabled)
and [AddHistory](https://wiki.facepunch.com/gmod/DTextEntry%3AAddHistory) support.

The Commands window belongs to its terminal page and closes when that page or
session closes. Commands still run through the existing command handlers and
server checks; help and history do not automatically execute a recalled command.

If you submit the target file's download or tool command from a folder that does
not contain it, the entry shows **[ERROR] - FILE NOT HERE (/help)**. The draft is
cleared, the entry stays editable, and the submission remains in history. Use
Help and its Return command to choose another folder. The refusal starts no
countdown and sends no completion request; it does not reveal the correct folder
or run another command for you.

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
Lua 5.1 and newer. This pass was checked with Lua 5.3 via `texlua`, plus Lua 5.1
and LuaJIT 2.1 through Lupa 2.6.

Coverage includes malicious/malformed network requests, concurrent users,
creator-only setup, stale/deleted entities, independent door links, session
release, all three successful client command flows, death during countdowns, rejected-completion recovery, authoritative success
feedback, replayed requests and late feedback while another console is open,
repeated folder navigation, setup validation and independent/repeated setup
forms, weapon hold-type initialization, disabled primary/secondary attacks,
the callable death-drop hook, single completion feedback with 1, 2,
and 12 connected players, and compilation of all five addon Lua
files.

Command-assistance tests run the actual client callbacks for every folder/target
combination, bounded per-terminal history, help dismissal/retirement and the
unchanged client-to-server completion flows. They check the documented history
API and data contract, not native arrow-key dispatch or Derma rendering.

Insertion tests cover exact contextual commands, long and multibyte names,
caret/focus requests, draft replacement without submission, countdown guards,
hidden/deletion-marked panels and stale callbacks after a page is reused. They
also run the inserted-command paths through the actual client/server handlers.
The host doubles do not certify native focus transfer, caret placement or layout.

Quit-control tests exercise actual client callbacks and server reservation
release on every page and during countdowns. They cover help/timer cleanup,
repeated clicks and retired page/session callbacks, including reopening the
same terminal. These client guards prevent stale local controls from quitting a
later session; they do not add session tokens or network replay protection to
the existing quit protocol. Native button input and rendering still need the
smoke checks below.

Reselection tests relay actual client setup packets into the server callbacks
and exercise `!setEntity`, Use and completion. They cover same-creator terminals
linked in either order, removal recovery, independent creators, invalid targets,
retry, immutable configuration, prior door assignments and final-link eligibility
changes. Active hacks cannot be redirected, including after their door is removed.
The doubles do not certify native chat delivery or eye-trace targeting.

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
- Click Quit terminal before login, during each countdown, from folder selection
  and from all three folders, with Commands both open and closed. Confirm the
  button remains reachable, no success appears, the linked door stays locked,
  and reopening starts a fresh login
- Strip or switch away from the hacking tool during each completion flow;
  confirm no success is printed, the terminal remains available and another
  player can use it. Re-equip and retry normally
- Enter a folder, return, and re-enter several times; check for Lua errors
- Open Commands or type `/help` at each stage; close help and finish normally.
  Recall and edit a command with Up/Down, then quit and open a new terminal to
  verify history is fresh. Check help wrapping and scrolling with long names
- Insert a command from help, edit it and press Enter. Check the caret with
  multibyte names, confirm insertion is disabled during countdowns, and finish
  each terminal type normally
- Link two tools terminals to different doors; finishing one must leave the
  other door locked, and using unrelated entities must still work
- With one creator, set up Alpha and Beta before linking either. Look at Alpha
  and type `!setEntity`, then look at its door and type it again; repeat for Beta
  and reverse the order. Remove pending Beta and reselect Alpha in a fresh pair
- Try another creator's terminal, a linked terminal (including one whose door
  was removed), a non-tools terminal and an already-claimed door; confirm no
  selection or door changes, then retry with an eligible terminal and door
- Check fonts, sounds and layouts at the clients' screen resolutions

Use a fresh server session when deploying server-logic changes; live Lua
refresh of an occupied terminal is not covered by the harness.
