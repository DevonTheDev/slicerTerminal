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
   **Done** reads the current fields, including the active text entry, and waits
   for the server's matching acknowledgement. Fields stay visible and locked
   while submitting. A rejection keeps the draft available with a status message;
   an acceptance closes that form. Each new form starts without previous values.
3. Accepted `tools` setup selects that terminal for its creator. Look at the
   intended console and type `!setEntity`; check the named selection confirmation.
   Then look at a `func_door` or `func_door_rotating` and type `!setEntity` again
   to link it before anyone uses it. This explicit selection keeps the choice
   clear when several consoles have been configured.
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

### Link sliding or rotating brush doors

Tools terminals can link to sliding brush doors (`func_door`) and rotating brush
doors (`func_door_rotating`). The same selection, hacking and cleanup workflow
applies to both: a link locks that exact door, and accepted completion or removal
of its registered terminal unlocks it. Sliding and rotating links can coexist
independently. A copied tools terminal still needs an explicit fresh link.

Support follows Valve's [shared brush-door implementation](https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/server/doors.cpp)
and Facepunch's [map-input API](https://wiki.facepunch.com/gmod/Entity:Fire).
`prop_door_rotating` remains unsupported; its separate master/slave behavior
needs native paired-door checks. Actual GMod lock/use behavior, map outputs and
protection-addon compatibility still require the smoke checks below.

### Inspect an existing door link

Look at one of your consoles or its registered brush door and type
`!inspectLink` in chat. The private reply identifies the console by its configured
name and current creation ID, and identifies its registered door when the
server can confirm both sides of that relationship. This helps distinguish
several consoles or copies with the same name. Only the console's creator can
inspect it; the hacking tool is not required, and inspection remains available
during a hack.

The reply distinguishes a never-linked tools console, an unavailable former
door and a relationship that is no longer registered in the current server
session. Unconfigured consoles get setup guidance; data/server consoles report
their configured folder. Inspection leaves pending selections,
saved configuration, edit forms and hacking deadlines intact. Door selection
still follows the existing `!setEntity` workflow and its never-linked rule.

Replies fit the [native chat byte limit](https://wiki.facepunch.com/gmod/Player:ChatPrint),
with display-only control-character cleanup. Saved names are unchanged.
[Creation IDs](https://wiki.facepunch.com/gmod/Entity:GetCreationID) can wrap;
they are informational and are not persistent identifiers or lookup authority.
The reply describes the addon's registered link, not the door's physical lock
state under other map logic or protection addons. Native chat delivery,
targeting and long-name font readability still need an in-game smoke check.

### List your consoles

Type `!listConsoles` in chat for a private inventory of your current consoles,
including deferred setup, configured terminals and pasted copies. You must be
a living player; no hacking tool or eye-trace target is required. Listing remains
available while a console is being hacked or its setup/edit form is open.

Each page contains up to five numbered consoles and uses the same complete names
and link-state descriptions as `!inspectLink`. Use `!listConsoles 2` for page two,
or the next-page command in the reply. A page argument requires exactly one
ASCII space and 1–7 decimal digits beginning with 1–9. Leading zeros, signs,
extra arguments and trailing whitespace receive private usage feedback;
unavailable pages receive range feedback. Empty inventories get one clear reply.

The list sorts by current creation ID, then entity index when IDs collide.
Same-name consoles and colliding IDs remain separate entries. Both identifiers are
transient: the list is a fresh snapshot on every request, so additions/removals
can shift pages. IDs cannot select, link or otherwise authorize an action.
Rows use the existing display-only control cleanup and fit the 255-byte chat
limit, retaining supported names of up to 128 bytes. The reply describes the
registered relationship in this server session; it makes no physical lock claim.

Listing preserves saved configuration, pending door choices, edit tickets,
active sessions and their deadlines. It does not repair links or change doors.
All lines for the requested page are prepared before chat delivery. Local
callback tests verify paging, privacy, filtering and these state boundaries;
native chat delivery, chat-addon compatibility and long/multibyte-name
readability remain unverified and need the in-game smoke check below.


### Locate a listed console

After `!listConsoles`, type `!locateConsole 2` to mark row 2 of your most recently
shown page. Rows 1–5 refer to the exact consoles from that page for 60 seconds;
they are not creation IDs. A fresh listing replaces those rows, and a malformed,
empty or unavailable-page listing clears them. Refresh the list if a row expires,
its console is removed, or ownership changes. Death and disconnect clear the rows.

A successful request sends only you a 15-second location marker with the console's
label, sampled position, distance in Source units and above/below guidance. Offscreen
or behind-you locations get an edge cue. This is a location snapshot: it does not
follow a console moved afterward or confirm that it still exists. Another successful
locate replaces the marker; `!locateConsole clear`, expiry or death dismisses it.
Use exactly one ASCII space followed by one row digit, or `clear`.

Walk to the marker and use the normal setup, edit or linking controls. Locating
works without looking at the console and preserves pending links, edit forms,
active hacking sessions and their original deadlines. It does not change saved
settings or door state. Local callback and geometry tests cover the request and
marker lifecycle; native projection, HUD-addon compatibility, font fit and
multiplayer delivery still need the smoke check below.

### Set up a console later

Choose **Set up later** to close a console's setup without configuring or removing
it. Its unsaved fields are discarded. When you're ready, use that unconfigured
console to open a fresh setup; only its original spawner can do this, and the
hacking tool is not required for setup.

Reopening a setup that is already on screen brings that same form forward and
keeps its current fields. Different consoles keep separate forms. Closing one
does not submit another console's configuration, release an active hack or
change a pending door selection. While a submission is pending, dismissal reads
**Close** and cannot undo a setup already accepted by the server. A lost reply
may leave the form pending until you close it; no automatic retry is promised.
Delayed replies cannot close a later form or another console's draft. Rejected
setup never gives door-link guidance or changes a different pending selection.

Once the server accepts initial setup, Use follows the normal hacking flow.
Correct saved values through the separate edit command below; initial setup
cannot overwrite them. Updated client files are required for the acknowledged
form flow. Legacy five-field setup packets retain their original server
validation and do not receive a correlated acknowledgement.

### Correct a saved console setup

Look at one of your configured, idle consoles and type `!editConsole` in chat.
The **Edit console settings** form shows its saved name, filename and slice
delay. Change those values and choose **Save changes**. The folder stays fixed,
and an existing door assignment remains attached to the same console. The
hacking tool is not required to edit your own setup.

Names follow the original setup rules: nonblank, at most 128 bytes, trimmed and
normalized to lowercase. Delay must be a finite positive number of seconds.
Changing only a name keeps the exact saved numeric delay.
The server validates and acknowledges the save before the form closes. Invalid
fields leave the draft available for correction. Reopening the same current
edit brings its form forward and keeps its draft; different consoles have
independent forms.

Choose **Cancel** before submitting to discard the draft. While a save is
pending, the fields are locked and the dismissal button reads **Close**.
Closing cannot undo a save already accepted by the server. A delayed reply for
that closed form cannot close a newer edit or another console's form.

Only the creator can request and save an edit. A hack beginning on the console
retires its existing edit, even if that hack later quits. Removed consoles,
changed ownership or setup, retired forms and disconnected/dead creators cannot
reuse an old edit. A stale rejection keeps the draft visible and asks you to
close and reopen with `!editConsole`. Editing never releases a different live
hack or changes the creator's pending door selection.

A pasted copy can be edited by its new creator without changing the source.
Copied tools terminals still need their own fresh door link. Once saved, the
new values appear in later terminal commands, listings and completion messages,
and the server enforces the updated delay. Existing folder-specific timing
remains: tools use one delay; data/server access and completion use two.

Local callback tests cover creation, edit, acknowledgement, cancellation,
replay, copying and complete hacking workflows. The edit form's initial and
resize geometry fit the tested 640×480 and larger viewports. Native Garry's Mod fonts, focus,
mouse controls, chat targeting, packet timing and actual multiplayer/door
behavior still require an in-game smoke test.

### Setup screen size

The setup form lays out its four inputs and two buttons in one centered column,
with a wrapped status area underneath. At initial viewport sizes of 640×480 or
larger, the six controls retain 48-pixel heights and 12-pixel gaps; the status
area is 72 pixels high. The full 432-pixel group leaves 24-pixel vertical margins
at 640×480. The column is at most 400 pixels wide with at least 20-pixel horizontal
margins. This applies to newly spawned, deferred and copied unconfigured consoles.

Open setup and saved-edit forms now reflow when the display size changes, even
when no player terminal is open. Setup keeps the centered column described
above; the saved-edit frame keeps its 460×430 layout and is recentered within
the supported viewport. Each form retains its own controls, draft text, folder
selection, exact saved delay, status and pending acknowledgement. Resize also
works while fields are locked for a save. Its later reply still belongs to that
exact form and request.

Same-size notifications leave geometry alone. An invalid or smaller transient
viewport retains each form's last supported layout until a supported size
returns. A form opened during invalid dimensions uses the minimum 640×480
geometry budget; this does not promise fit on a genuinely smaller screen.

Creator forms resize independently of the current player terminal. Reflow keeps
input state and acknowledgement ownership, without submitting or retrying a
save, requesting focus, changing door selection or restarting a hack. Hidden,
retired and deletion-marked forms cannot resize a replacement through retained
callbacks. Existing initial-setup registry behavior also survives client
reinclude; this adds no saved-edit persistence or live-server reload guarantee.

Offline tests cover actual client/server callbacks, changing rectangles,
pending and stale replies, concurrent forms, deferred cleanup, and an unrelated
active hack. Native rendering, mouse hit-testing, focus/caret retention,
dropdown placement and font fit still need the Garry's Mod smoke checks below.

### Player browser screen size

The login, folder and file pages reserve separate areas for the console heading,
file objective, browser content, **Commands**, **Quit terminal** and command input.
The folder artwork scales with the supported viewport, keeping tools, data and
server in their existing left-to-right order. Explicit `{_tools}`, `{_data}` and
`{_server}` captions identify the commands even when the artwork is smaller.
Three file rows have space between them and stay above the controls.
File rows are read-only; use the command entry below them. In the target folder,
the two decoys have distinct basenames and exclude the target case-insensitively.
Other folders keep their distractors, which can share the objective's basename.
The scrolling **Commands** window uses the same content area, leaving the
heading, objective and footer uncovered while help is open.

Local geometry checks cover 640×480, 800×600, 1024×600, 1280×720, 1366×768 and
1920×1080. At 640×480 the three folder images are 192 pixels square; at 1920×1080
they retain their original 512-pixel size. Full console/file strings remain in
labels, file entries and inserted commands; long headings/objectives use a
smaller font and wrapping within their allotted areas.

An open player terminal now reflows its existing login, folder and file pages
when the display size changes. The same command entry keeps its draft and
history, and the current folder and Commands window remain open. Hidden folder
selection also gets the new geometry, so returning to it or opening another
page uses the same updated layout. Reflow does not submit a command, restart a
countdown or change the server's original completion deadline.

Supported sizes start at 640×480. A smaller or invalid transient viewport retains
the last supported layout until a supported size returns; a newly opened session
uses at least the minimum geometry budget. The login objective's obsolete queued
movement is stopped on a real resize so it cannot later overwrite the new
position. Same-size events leave the layout and animation alone. Setup and
saved-edit forms reflow through their own current records, independently of the
player session.

The client uses the documented
[screen-size change hook](https://wiki.facepunch.com/gmod/GM:OnScreenSizeChanged)
and reads the updated screen dimensions. Existing controls are resized in place;
the addon does not request focus or replace the input/help window during reflow.
Native help wrapping may clamp its scroll position.

Local checks execute actual client/server callbacks with GMod substitutes and
verify rectangle containment, separation, state retention, navigation, help,
return, quit and original completion timing. They do not establish native font
fit, animation rendering, typing/caret/focus, scrolling or pointer hit-testing.
Check resizing in Garry's Mod during login, open Commands and each countdown,
especially long names at the smallest resolution.

### Copy a configured console

Use the ordinary Garry's Mod Duplicator to copy and paste a configured terminal.
Each pasted copy keeps its validated name, filename, folder and delay, receives
a fresh engine identity, and belongs to the pasting player. It starts idle with
an independent configuration, even when the original is being hacked. Copying
does not close the original session or change anyone's pending door selection.

Data and server copies can be used normally. Every tools copy starts unlinked,
including when a door was included in the copied group. Follow the paste notice:
look at the new console and enter `!setEntity`, then look at the intended
`func_door` or `func_door_rotating` and enter it again. A door still linked to the original remains
unavailable. Removing, undoing or completing the unlinked copy cannot unlock
the original's registered door.

An unconfigured source, or invalid copied settings, produces an unconfigured
copy. Its new creator can Use it for fresh setup without a hacking tool. No
reservation, completion deadline, old creator authority or door link is restored.
Pasting without a valid player removes only the new copy; automatic save/map
restoration without a player is outside this workflow.

These hooks follow Facepunch's documented
[copy-table](https://wiki.facepunch.com/gmod/ENTITY:OnEntityCopyTableFinish),
[early duplication](https://wiki.facepunch.com/gmod/ENTITY:OnDuplicated) and
[post-paste](https://wiki.facepunch.com/gmod/ENTITY:PostEntityPaste) contracts.
The server's existing duplicator permissions and creator-only setup/linking
rules still apply. Third-party duplicators and protection addons need their own
native compatibility check.

Deploy server changes into a fresh server session. Door cleanup requires the
current server's registered link owner; an old or foreign pointer alone does
not grant unlock authority. Live Lua refresh can lose that registry while
retaining entity pointers, so this does not migrate old links or active sessions.

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
Lua 5.1 and newer. This change was checked with Lua 5.1, LuaJIT 2.1 and Lua 5.3
through the installed Lupa runtimes.

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

Console-inventory tests execute the real server chat handler for strict page
grammar, oversized input, creator-only live enumeration, deferred consoles,
current-ID collisions, five-row pagination and all existing inspection states.
They check full-length names, byte limits, display control cleanup, prepared
output during callback-driven removal and preserved setup/edit/session/door
state. The doubles establish callback and transport intent, not native chat
delivery or compatibility with other chat addons.

Rotating-door tests relay real client setup and tools commands into the server,
then check linking, reservations, minimum delay, completion and cleanup against
both supported classes. They also cover mixed links, refused prop/arbitrary
targets, pending-selection recovery and copy isolation. Engine I/O is recorded
by doubles; the tests do not emulate a moving door.

Deferred-setup tests follow spawn, local dismissal, creator Use, configuration and
the existing hack/door flows. They check duplicate-form focus, independent
terminals, retired callbacks and creator ownership. Native focus transfer,
button layout and world Use targeting still need a server/client smoke check.

Setup-layout tests execute the actual setup receiver with test-local rectangle
recording at 640×480, 800×600, 1024×600, 1280×720, 1366×768 and 1920×1080. They
check visible control heights, margins, centered row order and gaps without
overlap, plus duplicate-open draft retention, independent forms, deferral and
stale buttons. Deferred and unconfigured-copy submissions are relayed through
the actual server's creator and first-write validation. The geometry model does
not certify native rendering, mouse hit-testing, dropdowns, font dimensions,
tab order or display resizing; the shared panel doubles remain unchanged.

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
- Open setup at 640×480, 800×600, 1024×600, 1280×720, 1366×768 and 1920×1080.
  Check that all four inputs and both actions are visible and clickable, the
  folder dropdown opens within reach, and placeholders and text fit the fonts.
  Reopen an already visible form and check its draft and focus are retained
- Choose Set up later, then use the unconfigured console without the hacking
  tool and finish a fresh setup. Confirm another player cannot reopen it; reopen
  an already visible setup and check its typing and focus are retained
- Try a blank name/file, missing folder, and nonpositive delay; correct each
  rejected form and verify it can still configure its terminal
- Equip the hacking tool and verify its pistol hold animation in multiplayer;
  with ammunition available, check that left/right-click do not fire or consume it
- In a test gamemode that enables weapon drops on death, verify the hacking tool
  is not dropped and its death hook raises no Lua error
- With two players, confirm only one can enter a terminal at a time
- Link separate sliding and rotating brush doors. Check native Lock, blocked Use,
  timed tool completion, Unlock and removal, including each map's door outputs
- Inspect each console and door with `!inspectLink` as its creator, including
  while another player is hacking. Check private replies, unchanged deadlines,
  same-name copy IDs, and readability of long and multibyte console names
- With more than five owned consoles, use `!listConsoles` and its next-page
  commands. Check private replies, full-length ASCII/multibyte names, deferred
  setup and same-name copies. List while setup/edit forms or a live hack are
  open; verify pending choices, forms, original deadlines and doors are intact
- With two players, duplicate each configured terminal type, including while the
  original is occupied. Check independent configuration and new creator ownership;
  removing or undoing the copy must leave the original session and door intact
- Paste multiple tools copies, then select and relink each explicitly. Verify
  that copying a door in the same group does not link it automatically, and that
  the original's claimed door remains unavailable. Complete a newly linked copy
  and confirm only its own door unlocks
- Duplicate an unconfigured console and finish setup as the paster; check a
  copy-of-copy and native engine names/cleanup under the server's protection rules
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
- At 640×480 and a normal desktop resolution, log in and inspect all three
  folders. Confirm their artwork/captions and all file rows are visible above
  Commands/Quit/input; return, reopen help and complete each terminal type
- Repeat with maximum-length console/file names, checking actual wrapped text,
  caret/selection behavior and command insertion. Change resolution during login,
  each countdown and an open Commands window; confirm the current session reflows
  while its draft, history and countdown continue. Check a sub-minimum transient
  size followed by a supported size
- Resize open initial setup and saved-edit forms from 1920×1080 to 640×480 and
  back to 1366×768 while typing, after a validation error and while awaiting a
  reply. Check every field/button/status, raw draft, selected folder, exact delay,
  focus/caret and any open dropdown; a resize must not submit or retry the save
- Keep two creator forms and an unrelated hacking countdown/Commands window
  open during resizing. Close a pending form, reopen its replacement and deliver
  the delayed reply; the replacement and unrelated hack must remain current
- List several same-name consoles and locate a row on each page. Check locations
  outside your current PVS, behind you, above/below and off screen; walk to the
  sampled point and use its normal setup/edit/link flow. Confirm another player
  receives no marker and cannot locate your rows. Move/remove a console afterward
  to check the snapshot wording, then refresh, replace, clear and let markers expire
- At 640×480 and after a live resize, locate a console with a maximum-length
  multibyte name. Check direction, distance, label fit, death cleanup and coexistence
  with open forms and an unrelated active hacking countdown
- Check fonts, sounds and layouts at the clients' screen resolutions

Use a fresh server session when deploying server-logic changes; live Lua
refresh of an occupied terminal is not covered by the harness.
