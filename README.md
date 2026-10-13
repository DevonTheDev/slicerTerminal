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
   while submitting. If the reply is lost, **Check setup result** manually checks
   the original submission without sending setup again. A rejection keeps the
   draft available with a status message; an acceptance closes that form.
   Each new form starts without previous values.
3. Accepted `tools` setup selects that terminal for its creator. Look at the
   intended console and type `!setEntity`; check the named selection confirmation.
   Then look at a `func_door` or `func_door_rotating` and type `!setEntity` again
   to link it before anyone uses it. This explicit selection keeps the choice
   clear when several consoles have been configured.
   To choose another of your configured tools terminals, look at that terminal
   and type `!setEntity`; the confirmation names your selection. Then look at
   its intended door and type `!setEntity` again. This also recovers an older
   terminal after you set up or remove a newer one. Selection requires a
   terminal that is **unlinked** and not in use. A prior link remains ineligible
   after its door is removed until you explicitly clear it with `!resetLink`.
   Invalid choices preserve your pending selection so you can retry. Type
   `!cancelLink` to clear your pending choice; select a console again before
   linking a door. Each terminal has its own door;
   a door cannot be attached to two live terminals. Using an unlinked terminal
   only gives guidance and does not select it.
4. Equip **Devons Hacking Tool** and use the console. Primary and secondary
   attack are disabled; right-click must not fire the inherited base weapon. Its
   callable `ShouldDropOnDie` hook returns false, overriding the base weapon
   policy without replacing the method with a boolean.

### Find chat commands in-game

Type `!slicerHelp` for a private command directory, then use one of its exact
lowercase topics: `!slicerHelp browse`, `!slicerHelp setup`, `!slicerHelp links`
or `!slicerHelp hacking`. Any valid player can read it, alive or dead, without
a hacking tool, eye target or owned console. The listed actions retain their
own living-player, creator, tool and eligibility requirements. Admin status
does not grant authority over another creator's consoles.

Use exactly one ASCII space before a topic. The exact help command followed by
whitespace but malformed arguments gets one private usage line; case changes
and prefix near matches remain ordinary chat. Replies are fixed, have at most
10 lines of at most 240 bytes each, and never echo input or read console data.
Help does not open forms, execute commands, change pending links or hacking
sessions, or replace/renew the 60-second row lease from list/find/near pages.
For the current terminal screen's contextual commands, use **Commands (/help)**
inside that terminal instead.

### Select a listed console for a door

After `!listConsoles`, `!findConsoles`, `!findConsoleFiles` or `!nearConsoles`, type exactly
`!setEntity 1` through `!setEntity 5` to select that row of your most recent page,
including filtered pages. You can stay near the intended door: check the named confirmation, then
look at a `func_door` or `func_door_rotating` and type bare `!setEntity` to link it.
The row command needs a living creator and a currently configured, idle tools
console with no door pointer or active hacking reservation. A removed former
door still needs explicit `!resetLink <row>` (or aimed `!resetLink`) first.
Reset does not select the recovered console. No hacking tool or eye target is
required to select a row. Near matches, extra spaces and trailing text remain
ordinary chat; the existing look-at-console command still works.

Rows refer to the exact entities printed for 60 seconds, not creation IDs.
Selection does not refresh that deadline. A new catalogue request replaces the page,
and invalid or empty requests clear it. Unavailable rows give private relisting
guidance; ineligible consoles must become eligible before selection. Either
refusal preserves your previous pending choice. Renaming or changing a filter
state does not replace a row's entity, but current selection checks still apply.
Once accepted, your pending choice survives later list expiry or replacement.
Final linking keeps its existing checks and retry behavior; `!cancelLink` clears
the choice. Selection leaves saved settings, setup/edit forms, locator markers,
existing links and other hacking sessions unchanged.

### Check a pending door selection

Type exactly `!pendingLink` in chat to privately check your current pending
door-link choice. You must be a living player; no eye target or hacking tool
is needed. A live console that you still own is described by its current safe,
bounded saved name and numeric creation ID when those display fields are
available. Names and IDs are informational labels, not authority for linking.
Duplicate names or IDs never substitute a different entity for your choice.

The one-line reply reports no pending choice, the current owned console, or an
unavailable choice with `!cancelLink` / `!setEntity` guidance. A console remains
inspectable after configuration, busy state or saved door changes; the reply
does not promise it can link. Final linking rechecks its existing eligibility
rules. Unsafe or missing display fields are omitted, without a name/ID search.
Other casing, whitespace or arguments remain ordinary chat.

Inspection changes no selection, configuration, link, setup/edit form, locator,
listing lease or hacking session. An accepted choice has no timeout and survives
catalogue expiry/replacement and death; it can be inspected after respawning.
Existing successful linking, cancellation, disconnect and removed-console
cleanup keep their clearing behavior. A newer choice made during feedback is
preserved. Obsolete replies are suppressed after the checked synchronous
accessors replace, cancel, remove or change ownership of the captured choice.

To find that exact selected console, use `!locateConsole pending`. The private
15-second location snapshot remains available after catalogue replacement or
expiry and after respawning, while the selected console is live and still yours.
It does not promise that the console can currently link; final linking keeps its
existing checks. Cancellation after a successful locate leaves the location
snapshot until its ordinary clear, expiry or death behavior dismisses it.

### Cancel a pending door selection

Type exactly `!cancelLink` in chat to clear your own pending door-link selection.
The private reply confirms cancellation or explains that no selection is pending.
You must be a living player, but need no eye target or hacking tool. This also
clears a stale choice if its console was removed, changed owner or became busy.
To resume, look at your configured, unlinked tools console and type `!setEntity`,
then look at its intended door and type `!setEntity` again.

Cancellation only clears your pending choice. It keeps saved door links and
locks, other players' selections, active hacks and their deadlines, setup/edit
forms, and console listing/location leases intact. Use `!unlinkConsole` for a
live door assignment or `!resetLink` for a removed door through their separate
creator-only workflows below. Case changes, extra arguments and whitespace are
not accepted as `!cancelLink`.

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

### Recover after a linked door is removed

Look at your configured tools console and type `!resetLink` in chat. Or, after
`!listConsoles`, `!findConsoles`, `!findConsoleFiles` or `!nearConsoles`, use exactly `!resetLink 1`
through `!resetLink 5` to recover that row without aiming at the console. If its
previous door is no longer valid, the private reply confirms that the old link
was cleared. Explicitly select it with `!setEntity <row>` from the same current
page, or look at the console and type bare `!setEntity`. Then look at a replacement
`func_door` or `func_door_rotating` and type `!setEntity` to link and lock that door.

Row recovery uses the exact console on your most recent page and its original
60-second deadline. A new page replaces it; an expired or unavailable row needs
a fresh list/find/near request. Reset never refreshes that deadline or falls back
to your eye target. Use one ASCII space and one digit from 1–5; near matches,
extra spaces and trailing text remain ordinary chat. No hacking tool is required.

Only the living creator can reset an idle console. A busy flag or an actual
hacking session blocks recovery, and every live door pointer blocks reset,
including an unsupported or unregistered entity shown as `unconfirmed`. A fresh
unlinked console just receives selection guidance. Reset keeps the saved
configuration, open setup/edit forms and pending selections intact, so you
must explicitly select the recovered console before choosing its new door.
It clears only the unavailable door association and its matching registration;
it does not unlock doors or change other consoles' links or sessions, locator
markers, or catalogue leases.

### Correct a live door assignment

Look at your configured, idle tools console and type `!unlinkConsole` to clear
its current registered live door link and send that previous door one `Unlock`
input. Or use exactly `!unlinkConsole 1` through `!unlinkConsole 5` for a row on
your latest `!listConsoles`, `!findConsoles`, `!findConsoleFiles` or `!nearConsoles` page, including
filtered pages. This preserves the same console, its saved settings, pending
selections and open edit form. The hacking tool is not required for unlinking.

For example, use `!nearConsoles 1 linked`, then `!unlinkConsole <row>` to clear
that exact console's live link. Explicitly select it with `!setEntity <row>`
from the same page, then look at the intended `func_door` or
`func_door_rotating` and type bare `!setEntity` to link the replacement. You can
also select the console by looking at it and using bare `!setEntity`.

Rows use the exact entity on your private page and its original 60-second
expiry. Unlink does not refresh that deadline or automatically select a console.
A new page replaces it; an expired or unavailable row needs a fresh list/find/near
request. Listed unlink never reads or falls back to your eye target. Use one
ASCII space and one digit from 1–5; near matches, extra spaces and trailing text
remain ordinary chat.

Only the living creator can unlink. A busy flag or an actual hacking session
blocks it. The server must confirm the exact current registration; unsupported,
foreign or unregistered pointers are refused without repair. Repeating unlink
on an unlinked console sends no further input. A removed former door still uses
`!resetLink`, which continues to refuse live doors. There is no admin override,
map persistence or automatic repair after a live Lua refresh.

The private reply reports the previous association and whether sending `Unlock`
succeeded, not physical movement or protection-addon acceptance. If input fails,
the old association stays cleared; check that previous door before relinking.
Native input that removes a console or establishes a newer link is not undone.

### Inspect an existing door link

Look at one of your consoles or its registered brush door and type
`!inspectLink` in chat. The private reply identifies the console by its configured
name and current creation ID, and identifies its registered door when the
server can confirm both sides of that relationship. This helps distinguish
several consoles or copies with the same name. Only the console's creator can
inspect it; the hacking tool is not required, and inspection remains available
during a hack.

The reply distinguishes an unlinked tools console, an unavailable former
door and a relationship that is no longer registered in the current server
session. Unconfigured consoles get setup guidance; data/server consoles report
their configured folder. Inspection leaves pending selections,
saved configuration, edit forms and hacking deadlines intact. Door selection
still follows the existing `!setEntity` workflow. An unavailable former door
includes `!resetLink` guidance; recovery must be requested separately while idle.

Replies fit the [native chat byte limit](https://wiki.facepunch.com/gmod/Player:ChatPrint),
with display-only control-character cleanup. Saved names are unchanged.
[Creation IDs](https://wiki.facepunch.com/gmod/Entity:GetCreationID) can wrap;
they are informational and are not persistent identifiers or lookup authority.
The reply describes the addon's registered link, not the door's physical lock
state under other map logic or protection addons. Native chat delivery,
targeting and long-name font readability still need an in-game smoke check.

### Inspect saved console settings

After `!listConsoles`, `!findConsoles`, `!findConsoleFiles` or `!nearConsoles`, type exactly
`!inspectConsole 1` through `!inspectConsole 5` to inspect that row. Use one
ASCII space and one digit; bare, malformed and near-match commands remain
ordinary chat. Rows refer to exact entities on your latest page for 60 seconds;
inspection does not renew that deadline. Relist when a row is unavailable.

Only the living current creator can inspect a console. No tool, eye target or
distance check is required, and busy consoles remain inspectable. Three private
lines show its saved name/current ID, folder, configured **base delay in seconds**
and saved filename without adding an extension. The delay is not remaining hack
time. Original spelling and edge spaces are preserved; controls are cleaned only
for display. Unconfigured consoles receive setup guidance; malformed saved data
is reported as invalid. Inspection changes no settings, forms, selection, marker,
door links or hacking session, and completes its reply from one captured snapshot.

### List your consoles

Type `!listConsoles` in chat for a private inventory of your current consoles,
including deferred setup, configured terminals and pasted copies. You must be
a living player; no hacking tool or eye-trace target is required. Listing remains
available while a console is being hacked or its setup/edit form is open.

Each page contains up to five numbered consoles and uses the same complete names
and link-state descriptions as `!inspectLink`. Use `!listConsoles 2` for page two,
or the next-page command in the reply. A page argument requires exactly one
ASCII space and 1–7 decimal digits beginning with 1–9. Leading zeros, signs,
unsupported arguments and trailing whitespace receive private usage feedback;
unavailable pages receive range feedback. Empty inventories get one clear reply.

To show one current state, use `!listConsoles <page> <state>`, for example
`!listConsoles 1 setup`. The only states are these exact lowercase words:

- `setup`: no saved configuration, including deferred or unconfigured pasted consoles
- `unlinked`: valid tools configuration with no door pointer, including deliberately unlinked consoles
- `unconfirmed`: valid tools configuration with a nonnil door pointer whose entity
  is unavailable, class is unsupported, or registered association does not match
- `linked`: valid tools configuration with a live supported door registered to
  that exact console in this server session; this does not report its physical lock state
- `reserved`: a current server-owned hacking reservation for that exact console,
  including data, server and tools terminals being hacked by another player

These are inventory categories, not a diagnosis or automatic repair. The existing
row descriptions still distinguish an unavailable former door from an unconfirmed
registration. Data/server consoles can match `reserved`, but do not enter the
setup or tools-link categories, even with a legacy door pointer. Malformed nonnil
configuration stays visible in the full inventory and can still be reserved;
it does not count as setup or inferred tools configuration.
Use one ASCII space before the page and before the state; the page is required
when filtering. Totals and pages count only matching consoles, and next/first-page
hints retain the state. Each request evaluates current entities afresh.
`!listConsoles` and `!listConsoles <page>` keep showing the full inventory.

`reserved` reports the existing server session, independently of the legacy
`inUse` flag. A flag alone does not match, and clearing it does not hide a
reservation. Only the console's creator can list it; the hacker's identity is
never shown. Listing does not clean up sessions, restart deadlines, change
selections or retire setup/edit forms. A reservation whose player is invalid or
dead remains visible until the existing lifecycle cleanup runs. The session's
completion time is a minimum wait, not an expiry: quit, death/disconnect hooks,
console removal and completion keep their existing cleanup behavior.

To narrow a state by saved name, use
`!listConsoles <page> <unlinked|unconfirmed|linked|reserved> <text>`, for example
`!listConsoles 1 linked reactor west`. Results must match both the current
state and the literal name fragment. Use exactly one ASCII space before the
page, state and first text byte; the remaining text follows the same 1–128-byte
literal search rules below. The complete command is limited to 162 bytes.
Numeric or state-prefixed text stays literal: `!listConsoles 1 unlinked 2 setup [a].%`
searches for `2 setup [a].%` among unlinked consoles. `setup` cannot take a text
tail because those consoles have no saved name; use `!listConsoles 1 setup`.

Combined headers and counts describe only the intersected matches. No matches
points to that state's full list; out-of-range pages retain the combined syntax.
Next/first-page commands retain both the state and exact text, with no added
punctuation. Copy the complete hint to repeat the search. Named but malformed
configuration can still match `!findConsoles` or a reserved name search when it
has a reservation, but cannot enter any combined tools-link state.
For example, `!listConsoles 1 reserved reactor west` finds reservations whose
saved names contain that literal fragment. Locating a listed row keeps pointing
to the same console if its reservation ends, until the original 60-second lease
expires or the console becomes unavailable. Plain `!findConsoles` never treats
any part of its text as a state:
`!findConsoles 1 unlinked reactor` searches for the literal `unlinked reactor`.

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


### List your nearest consoles

Type exactly `!nearConsoles` or `!nearConsoles <page>` for a private nearest-first
inventory of your own consoles. This includes setup-needed, data, server, tools
and currently reserved consoles. You must be a living player; no tool or eye
trace is needed, and being an admin does not grant access to another creator's
consoles. The page uses the same one-space, 1–7 ASCII digits, no-leading-zero
rules as the full inventory. To narrow proximity to a current state, use exactly
`!nearConsoles <page> <state>`, for example `!nearConsoles 1 unlinked`. The state
must be exactly `setup`, `unlinked`, `unconfirmed`, `linked` or `reserved`, with
one ASCII space before the page and state. State requires an explicit page.
To also narrow by saved name, use exactly
`!nearConsoles <page> <unlinked|unconfirmed|linked|reserved> <text>`, for example
`!nearConsoles 1 unlinked reactor west`. The entire remaining text is a literal
substring, using the same ASCII-only case folding as `!listConsoles` name
filtering: 1–128 bytes, no leading/trailing ASCII spaces or control characters.
Numeric names, state words, internal spaces and pattern punctuation stay literal;
Unicode bytes are not case-folded or normalized. `setup` with text is rejected
because unconfigured consoles have no saved name to search.
Malformed recognized arguments get private guidance; command near matches stay
ordinary chat.

State meanings are the same as `!listConsoles`: `setup` requires absent saved
configuration, the three link states require valid tools configuration, and
`reserved` reflects a server-owned active session, independently of a legacy
busy flag. Both state and name filtering happen before distance sampling and
pagination. The header names the requested state and counts only matching
consoles; empty and out-of-range replies describe that filtered set. Next/first-page,
range and retry guidance retain the state and literal query. Empty search replies
show the query and offer the same nearest state without the name restriction.
Link descriptions do not assert a physical lock state.

The header identifies a nearest-first request snapshot. The server samples your
position once and each matching owned console's position once, then sorts by 3D
straight-line distance. This is geometric proximity, not a pathfinding or travel
distance. Equal distances use current creation ID, then entity index. Consoles
with unavailable/nonfinite positions or overflowing squared distances remain
after measured consoles, ordered by those same IDs. If your own position is
unavailable/nonfinite, the command clears your previous rows and asks you to
try again.

Each page has up to five rows with the existing inspection names and link states.
Use the reply's `!nearConsoles` next/first-page hint to request another page.
Every request samples positions again, so movement can shift pages. Previously
printed rows keep their exact console references for 60 seconds until another
catalogue request replaces them; locating, editing and selecting those rows use
the existing creator and eligibility checks. A console changing state does not
remap an already printed row or bypass a later action's eligibility checks.
Malformed, empty or out-of-range requests clear the previous page. Listing changes
no saved configuration, doors,
pending selection, setup/edit records, active hacks, deadlines or locator marker.
The default `!listConsoles` and `!findConsoles` ordering and replies stay unchanged.

### Find a console by its saved name

Type `!findConsoles 1 reactor west` for a private first page of your consoles
whose saved names contain `reactor west`. Always include the page:
`!findConsoles <page> <text>`. Use the full next-page command in the reply to
repeat the same search. Results contain up to five numbered matches, with the
same complete names, link descriptions, ordering and locate controls as the full
inventory. Each request searches afresh, so additions, removals and renames can
shift pages. `!listConsoles` always shows the full inventory.

Search is literal and folds only ASCII A–Z to a–z. Internal spaces, numbers,
punctuation, quotes and backslashes are part of the name to match; there are no
wildcards or quote/escape rules. For example, `!findConsoles 1 2` searches for
the digit `2`, and `!findConsoles 1 [a].%` searches for those exact characters.
Non-ASCII bytes stay distinct: `É` and `é`, or composed and decomposed accents,
are not equivalent. Matching uses saved names, not their display-only cleanup.

Use exactly one ASCII space before the page and before the first text byte.
The page requires 1–7 decimal digits beginning with 1–9; the text requires
1–128 bytes, no leading/trailing ASCII spaces and no ASCII controls, UTF-8 C1
controls or Unicode line/paragraph separators. Malformed requests receive one
private usage reply, without echoing the input. Unavailable pages receive range
feedback; no matches directs you to `!listConsoles`, including setup-needed
consoles with no saved name. A valid saved name remains searchable even if other
settings or a door link are broken.

Only your current live consoles' saved names are searched. Internal IDs, file
names, folder/state descriptions and other owners' consoles are not searched.
Search needs a living player but no tool or target; it preserves settings,
pending links, setup/edit forms, active hacks and deadlines. It sends private
chat only and leaves any existing location marker alone.

### Find consoles by saved filename or folder

Type `!findConsoleFiles 1 reactor` to find your consoles whose saved filename
or folder contains `reactor`. Always use `!findConsoleFiles <page> <text>`.
Folders are `data`, `server` and `tools`; a fragment such as `erv` matches
`server`. This searches saved configuration metadata, without reading disk
files. The filename is the saved base name, without an appended extension.

Only valid saved configurations match. Unset or malformed configurations stay
available through `!listConsoles`. Matching uses a captured copy of the raw saved
filename and folder, with the same literal ASCII-only folding as name search.
Display cleanup, Unicode normalization, wildcard patterns and path/escape rules
do not participate. For example, `!findConsoleFiles 1 ../` matches those exact
characters in a saved filename. Console names, IDs and state descriptions are
not searched; `!findConsoles` continues to search only saved console names.

Use exactly one ASCII space before the page and text. The page is 1–7 digits,
beginning with 1–9. The text is 1–128 bytes, with no edge spaces, ASCII controls,
UTF-8 C1 controls or Unicode line/paragraph separators; the whole command is at
most 154 bytes. Internal spaces and punctuation remain literal. Malformed
recognized requests give fixed private usage feedback; command near matches
remain ordinary chat. Copy the complete next/first-page hint to repeat a search.

Pages retain the full inventory's ordering, complete console names and link
descriptions, with at most five rows. Use `!inspectConsole <row>` for the full
saved metadata. Rows share the existing exact-entity 60-second lease and all its
creator/eligibility checks. A new list, name search, file search or nearest
request replaces the rows; malformed, empty and unavailable-page requests clear
them. Metadata edits do not remap existing rows or renew their deadline.

Search requires a living creator but no tool or eye target. It changes no saved
configuration, door, pending selection, setup/edit form or ticket, active hack,
deadline or location marker. Replies are private; a newer catalogue request or
loss of ownership/liveness during a file-search reply suppresses obsolete output.
An interrupted file reply retires its own unfinished page without clearing a
newer catalogue request.

### Locate a listed, found or pending console

After `!listConsoles`, `!findConsoles`, `!findConsoleFiles` or `!nearConsoles`, type `!locateConsole 2`
to mark row 2 of your most recently shown catalogue page. Rows 1–5 refer to the
exact consoles from that page for 60 seconds; they are not creation IDs. A fresh
catalogue request replaces those rows, and a malformed, empty or unavailable-page
request clears them. Request another page if a row expires,
its console is removed, or ownership changes. Death and disconnect clear the rows.
State-only and combined name/state pages use these same rows and expiry. Locating does not rerun a name
search or state filter: later renaming, setup or link changes leave an otherwise
eligible live console as the same row, using its current name and position.
Locating does not confirm that the previously displayed state still applies.
Clearing the marker leaves unexpired rows usable.

Type exactly `!locateConsole pending` to mark your existing pending door-link
choice instead of a row. It uses that exact live console only while you still
own it, without consulting a catalogue, eye target, weapon, name or creation ID.
Catalogue replacement and the exact row deadline do not expire this choice.
Configuration, busy/reservation state and a live or removed saved door do not
block location; the normal link command still rechecks its own requirements.
No choice or an unavailable choice gives one private line without clearing the
choice, previous marker or current rows. Read failures or non-finite/unavailable
positions send no location packet. Saved names are cleaned only for display,
and only finite integral numeric IDs from 0 through 10000000 are shown as labels.
If checked synchronous accessors replace/cancel the choice, remove it, change
its ownership/class or retire the requester, the obsolete result is suppressed.

A successful request sends only you a 15-second location marker with the console's
label, sampled position, distance in Source units and above/below guidance. Offscreen
or behind-you locations get an edge cue. This is a location snapshot: it does not
follow a console moved afterward or confirm that it still exists. Another successful
locate replaces the marker; `!locateConsole clear`, expiry or death dismisses it.
Use exactly one ASCII space followed by one row digit, `pending`, or `clear`.

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
**Close** and cannot undo a setup already accepted by the server. After sending,
Done becomes **Check setup result** in the same button slot; the four inputs
remain locked. Delayed replies cannot close a later form or another console's draft. Rejected
setup never gives door-link guidance or changes a different pending selection.

Once the server accepts initial setup, Use follows the normal hacking flow.
Correct saved values through the separate edit command below; initial setup
cannot overwrite them. Updated client files are required for the acknowledged
form flow. Legacy five-field setup packets retain their original server
validation and do not receive a correlated acknowledgement.

### Open initial setup from a listed row

After `!listConsoles`, `!findConsoles`, `!findConsoleFiles` or `!nearConsoles`, type exactly
`!setupConsole 1` through `!setupConsole 5` to open the existing initial form
for that exact row. Use one ASCII space and one digit. Bare commands, extra
spaces or arguments, different case and other row spellings remain ordinary
chat. The command works at a distance without an eye target or hacking tool.

You must be the living creator of an unconfigured console with no active hack
on that console. Configured consoles, including an accepted setup whose reply
is still pending, are refused. Use the separate saved editor for configured
consoles. The current raw runtime name must be nonempty, at most 256 bytes,
without a NUL byte, and unique among your live consoles, including configured
ones. A same-name console owned by another creator does not cause ambiguity.

This uses the same private five-row page and 60-second deadline as locating,
listed editing and listed link selection. A new recognized list/find/near
request replaces the page, even when invalid or empty. Opening neither consumes
nor renews it; a row expires at exactly 60 seconds. Current entity, creator,
configuration and reservation checks run again before opening. A removed row
cannot select a replacement by name or numeric ID. Request a new page after an
unavailable-row refusal.

Repeated listed opening or physical Use raises the same current initial form
and retains its typed draft or locked pending submission. Different targets
keep separate forms. Dismissal discards a draft; reopening starts blank. Opening
does not configure anything, reserve a hack, choose a door, change an editor or
receipt, move the locator marker, or disturb another session or its deadline.
Page replacement or expiry does not revoke a form already opened. Saving keeps
the existing creator, configuration and name-ambiguity admission; the page is
an opening reference, not a save ticket. Initial save still has its existing
valid-player admission and does not add a living-player requirement at save time.

If setup was accepted but its reply was lost, `!setupConsole <row>` refuses the
now configured target and leaves its pending form locked. Choose that form's
**Check setup result** to query the original receipt. An unconfirmed result
does not unlock or resend the submission.

### Keep an initial draft bound to its console

With current server and client files, each opening carries a server-issued target
token. The draft can configure only that exact console for its original creator.
Removing A and assigning A's runtime name to a new console B cannot make A's
old draft configure B or make B raise A's draft. B opens a separate blank form.
Ordinary removal and spawn already use distinct `GetCreationID()` names; the
regression uses the supported server-side `SetName` API to reuse a name. Native
creation-ID wrap is a documented potential naming boundary, not a reproduced
engine event in these tests.

A rename, observed owner/identity change or intervening configuration makes the
old target ticket unavailable. Close that form and open an eligible console
again. Repeated opening keeps the same current draft; closing and reopening
starts blank with a new submission identity. Tickets have no elapsed-time expiry,
so a long draft survives listing expiry, relisting and ordinary death. Removal,
copied-state reset, disconnect and server config reinclude retire authority.
The server keeps at most one pending ticket and one historical receipt per live
console. Its target serial survives config reinclude and stops at exhaustion.

Mixed versions intentionally retain a compatibility boundary. An old two-field
opening creates a legacy name-based form. Old clients and deliberately string-
shaped five/six-field callers keep their original admission and name-reuse limit.
A current opening appends `slicer-initial-v2:<targetToken>` to the existing player
and runtime-name prefix; a present malformed or unavailable suffix opens no
writable form. Modern saves put a tagged descriptor in field 5, which the
published old server rejects before mutation. A modern form never retries as a
legacy save. An unbound old-server response leaves its draft uncertain and
explains that bound result confirmation is unavailable. Use a fresh server
restart for rollout; recovery across occupied-session live refresh is not promised.

### Check a missing initial setup reply

While the original form is still pending, choose **Check setup result** to ask
whether that exact submission was accepted. Checks use its frozen original
fields and token, with at most one manual query every two seconds. There is no
automatic polling or retry, and checking never resends setup, rewrites settings,
selects a console or links a door. If a check's reply is also lost, you can check
again after the cooldown. Close still dismisses only the local form.

A confirmed result closes that pending form and reports historical acceptance.
Saved settings may have changed since then. For tools, the guidance identifies
the original setup: look at the intended console and type `!setEntity` first,
then look at its intended door and type `!setEntity` again. Checking does not
restore an earlier pending selection; `!cancelLink` remains available.

An unconfirmed result leaves the form and its draft locked. It does **not** mean
the setup was rejected or can safely be sent again. You can close the form and
use the console to check its current state. A later genuine initial reply can
still accept the form or unlock a rejected draft normally. Older servers that
cannot start the new query show an unavailable status and retain this same
uncertainty; they receive no replacement setup request.

The server keeps one private receipt per live console for correlated acceptance,
matched to the authenticated creator, request token and all five original scalar
fields. Modern receipts also require the exact target token and entity; modern
and legacy queries cannot confirm each other's acceptance.
Missing, ambiguous or mismatched evidence is unconfirmed. Removal, copied-state
reset, disconnect or a server config reinclude retires receipts; changed owner,
class, creation ID or entity index also invalidates them. Legacy tokenless setup
and target identity strings over 256 bytes create no receipt, without changing
existing setup admission. Receipts are not persisted or copied. Ordinary death,
saved edits and hacking/link changes do not erase historical acceptance. A
server-side reset followed by tokenless legacy setup also keeps any historical
receipt; a later correlated acceptance replaces it. Confirmation describes the
original acceptance, never a reconstruction from current settings.

Callback tests cover dropped/reordered replies, exact binding, lifecycle cleanup,
reentrant callbacks, simultaneous forms, older-server query-start failure and
unchanged hacks/door choices. The six-row layout and 72-pixel status area stay
unchanged. Native font wrapping for checking, unconfirmed and unavailable text,
Derma focus/clicks and mixed-version multiplayer delivery still need a game check.

### Correct a saved console setup

Look at one of your configured, idle consoles and type `!editConsole` in chat.
You can also use `!editConsole 1` through `!editConsole 5` to edit that exact row
from your latest `!listConsoles`, `!findConsoles`, `!findConsoleFiles` or `!nearConsoles` page, including
filtered pages.
The row command requires one space and one digit, with no trailing whitespace;
other edit-like text stays ordinary chat. The row is private to you and lasts
60 seconds from the listing. Opening an editor or locating a row does not extend
or consume that time, and clearing the locator marker keeps the page available.
A new catalogue request replaces the page; an invalid or empty request clears
it. Unavailable rows ask you to list again and never select what you are looking
at. Setup-needed or busy consoles must become configured and idle before editing.
The saved row follows the same console even if its name or filter state changes.
Listing expiry or replacement does not revoke an already-open editor; the normal
creator, setup and reservation checks still apply when you save.

The editor shows its saved name, filename and slice delay. Its title identifies
the target as **Edit console #123 (entity 45)** using the server's current
creation ID and entity index, so same-name copies and colliding creation IDs
remain distinguishable. The title stays fixed for that draft, including while
renaming, resizing or awaiting a save. These are transient display identifiers,
not saved IDs or edit authority. Older servers or invalid optional identity
metadata retain the generic **Edit console settings** title.
Change the values and choose **Save changes**. The folder stays fixed,
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

### Locked-door notice

Using a linked sliding or rotating brush door shows the using player the same
private notice: “This door is locked. Find a console to open it.” The bottom
notice uses the existing compact heading font and wrapping so the complete
message has room at supported sizes, starting at 640×480. An open notice moves
with the current screen size; it keeps the same label and its original
four-second expiry. Repeated Use during that interval does not replace it or
restart the timer. It requests no focus and changes no door permission,
creator draft, hacking session or completion deadline.

A smaller or invalid transient viewport retains the last supported notice
geometry until a supported size returns. A notice first opened during that
transient uses the 640×480 budget; fit below the supported minimum is not promised.
Local tests relay real PlayerUse packets into the client receiver and check
rectangle containment, wrapping/font configuration, duplicate suppression,
expiry and coexistence with an active hack and creator form. They do not verify
native font fit, Derma wrapping, input pass-through or multiplayer delivery.

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

Starting a login or download immediately locks its command input. Repeated
submissions cannot restart the wait or leave the current page. During the
countdown, use **Commands (/help)** to read the reference or **Quit terminal**
to cancel. Commands and folder navigation work normally outside a countdown.

Click **Quit terminal** on any terminal page to leave immediately, including
during a login or download countdown. It closes Commands too, cancels the
pending local countdown, and asks the server to release your reservation. The
terminal remains available for another attempt, and a linked door stays locked.
Starting again begins a fresh login; there is no saved partial progress. Quitting
cannot undo a completion request that was already sent.

### Check your hacking session

Type exactly `!hackStatus` in chat for a private report on your own current
server reservation. You must be alive, but need no equipped tool, eye target,
listing or console ownership. The command accepts no arguments; case changes,
extra spaces and near matches remain ordinary chat.

For a current session, the report shows its console's saved name when usable
and the remaining **server minimum wait**, rounded up to whole seconds. The
deadline is the one set when you opened the terminal: one configured delay for
`tools`, two for `data` or `server`. At or after that deadline, it says the minimum
wait has elapsed. This does **not** mean the hack is complete: the server does
not track your client screen, entered commands or local countdown stage.
Finish the steps in the terminal, or use `!quitConsole` to leave the session.
The ordinary tool, target and completion checks still apply.

If you have no session, you get one private notice. An unavailable console or
invalid timing gets recovery guidance without clearing the reservation. Status sends no network
packets and does not open, renew, cancel or complete a hack, change saved data or
links, or refresh listing/edit authority. Replies have at most three lines of
240 bytes each; names retain literal spelling and display controls are replaced.
A quit, removal, replacement or nested status request stops the old reply's
remaining lines. Native chat delivery and interaction with other chat addons
still need an in-game check.

### Recover a missing terminal screen

If your terminal screen disappears but the console or hacking tool is still
busy, enter exactly `!quitConsole` in chat. This private command releases only
your own current hacking session and closes its remaining terminal UI and
countdowns. You must be alive; you do not need the hacking tool equipped or a
target under your crosshair. It accepts no arguments.

The terminal and its saved setup survive, and a linked door stays locked.
Another player can use the terminal, and your next attempt starts with a fresh
login and deadline. Your separate setup/edit drafts, pending door selection and
console locator stay intact. If you have no active hacking session, the command
only prints a private notice, so repeating it does not close unrelated UI.
Like the Quit button, it cannot undo a completion the server already accepted.

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
Lua 5.1 and newer. Earlier changes were checked with Lua 5.1, LuaJIT 2.1 and
Lua 5.3 through the installed Lupa runtimes.

Coverage includes malicious/malformed network requests, concurrent users,
creator-only setup, stale/deleted entities, independent door links, session
release, all three successful client command flows, death during countdowns, rejected-completion recovery, authoritative success
feedback, replayed requests and late feedback while another console is open,
repeated folder navigation, setup validation and independent/repeated setup
forms, weapon hold-type initialization, disabled primary/secondary attacks,
the callable death-drop hook, single completion feedback with 1, 2,
and 12 connected players, and compilation of all five addon Lua
files.

Pending-selection tests exercise the real chat callbacks for exact grammar,
living callers, private failures, automatic/bare/listed choices, changed names,
same-label entities, stale/foreign/wrong-class references, byte-bounded Unicode
and control cleanup, malformed IDs, and explicitly controlled synchronous
accessor/feedback reentry. Workflows retain pending setup/edit replies, drafts,
locator leases, another player's choice and an active hack, and link both brush
door classes after catalogue expiry/replacement and death/respawn. These doubles
model ordinary native accessors and the declared reentry controls; they do not
establish safety against arbitrary hostile metamethods or native multiplayer
chat/door behavior.

Command-assistance tests run the actual client callbacks for every folder/target
combination, bounded per-terminal history, help dismissal/retirement and the
unchanged client-to-server completion flows. They check the documented history
API and data contract, not native arrow-key dispatch or Derma rendering.

Insertion tests cover exact contextual commands, long and multibyte names,
caret/focus requests, draft replacement without submission, countdown guards,
hidden/deletion-marked panels and stale callbacks after a page is reused. They
also run the inserted-command paths through the actual client/server handlers.
The host doubles do not certify native focus transfer, caret placement or layout.

Countdown-submission tests invoke the real login, data and server callbacks
twice before Think, try returning during a download, and check immediate input
locking without extra history, sounds or timer replacement. They also verify
help/quit availability, retired callbacks after quit/reopen, one completion
request and the server's original minimum deadline. Passing controls exercise
ordinary completion, early rejection and navigation outside a countdown.

Quit-control tests exercise actual client callbacks and server reservation
release on every page and during countdowns. They cover help/timer cleanup,
repeated clicks and retired page/session callbacks, including reopening the
same terminal. These client guards prevent stale local controls from quitting a
later session; they do not add session tokens or network replay protection to
the existing quit protocol. Native button input and rendering still need the
smoke checks below.

Command-directory tests exercise real chat hooks for all four static topics,
alive/dead access without creator or admin checks, exact syntax, fixed malformed
guidance, input non-echo, private reply bounds, and forward/reverse existing-hook
order. The modified recovery hook retains nil for non-string nonmatches;
recognized help stays consumed if requester validation or a private reply throws,
with later reply lines stopped and existing authority preserved. These controls
do not claim exception handling for unrelated hooks. Tests verify unchanged row
identity and expiry, plus pending setup/edit
submissions, locator, door selection/locks and both players' original hacking
deadlines through the real form and completion callbacks. The feature-absence
control fails against the unchanged source before the directory is added.
Native chat visibility and compatibility with other chat addons need GMod.

Session-recovery tests cover lost pages for all three file types, chat cleanup
before/after the first countdown update, retained callbacks after reopening,
and fresh minimum deadlines. They verify exact private command handling,
living-player checks, idle/repeated requests without cleanup packets, no tool
or target requirement, and preserved setup/edit/listing/marker/link state and
other players' original sessions. These are host callback tests; native chat
accessibility and compatibility with chat addons remain unverified.

Hack-status tests execute real `PlayerSay` and reservation callbacks for absent
and current data/server/tools sessions, before/at/after the original deadline,
per-player privacy, exact grammar, living-player admission and bounded literal
names. They inject invalid clock/deadline values and cover overflow, unchanged
session state and authority, ordinary lifecycle cleanup, same-console session
replacement and reentrant feedback. Callback failures stay privately consumed.
These targeted reentry checks assume ordinary engine getters are observational;
they do not claim atomicity against arbitrary hostile accessor side effects.

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

State-filter tests cover strict bounded grammar, exact nil versus malformed
configuration, both supported door classes, deliberate unlinking, unconfirmed
associations and exact registered `linked` associations. They verify ownership
before private reads, unregistered copies, same-name/ID ordering, filtered totals,
shared row replacement/expiry and nested
requests during prepared output. A real-handler workflow locates filtered rows,
completes deferred setup and recovers a removed link while preserving unrelated
acknowledgements, selection and an active hack's original deadline. Native chat,
door I/O and multiplayer behavior remain unverified without Garry's Mod.

Nearest-catalogue tests exercise the actual PlayerSay hooks for one-time 3D
position samples, deterministic ties, unavailable origins/console coordinates,
overflow, private ownership, pagination after movement, and exact-reference row
actions with the shared 60-second lease. They check reentrant listing replacement,
inspection byte budgets, state preservation and exact default list/search replies
without position calls. Nearest-state tests combine all five existing predicates
with filtering before pagination, strict syntax, retained hints, snapshot ordering,
and existing setup/edit/link row authority. Nearest-name tests add the four
state/name intersections, literal byte and Unicode boundaries, bounded query-aware
guidance, exact row actions and output-callback replacement. A real-handler
workflow keeps pending setup/edit replies, selections and a live hack's original
deadline usable while locating matching nearest rows. These API doubles do not
verify native engine accessor atomicity, vectors, rendering, chat delivery or
network behavior; those still need an in-game smoke check.

Console-search tests exercise actual PlayerSay callbacks for byte limits,
literal ASCII folding, Unicode distinctions, private ownership filtering,
fresh pagination and shared exact-reference locate snapshots. A workflow checks
pending setup/edit acknowledgements, deferred copies, pending links and an
unrelated hack's original deadline. Native maximum command entry length,
multibyte rendering and multiplayer privacy still require an in-game check.

Filename/folder-search tests cover captured raw metadata, invalid/unset
configuration exclusion, literal matching and byte limits, private bounded
pages, exact row leases, and nested metadata/accessor/feedback replacement.
A real-callback workflow relays accepted setup/edit replies and duplication
while retaining pending selection, open forms and an unrelated hack's original
deadline. Native chat entry length, delivery and rendering remain unverified.

Rotating-door tests relay real client setup and tools commands into the server,
then check linking, reservations, minimum delay, completion and cleanup against
both supported classes. They also cover mixed links, refused prop/arbitrary
targets, pending-selection recovery and copy isolation. Engine I/O is recorded
by doubles; the tests do not emulate a moving door.

Link-recovery tests exercise exact creator chat commands, removed sliding and
rotating doors, unchanged configuration/selection/edit records, and independent
busy-flag and active-session guards. They relay real setup, editing, relinking,
Use and tool completion, including early requests, late former senders, copies
and removal cleanup. Exact state snapshots check that only the obsolete binding
and its owned registry entry change. Native eye traces, chat delivery and brush
door behavior still need the smoke checks below.

Listed-live-unlink tests cover exact row grammar, private exact-entity leases,
filtered list/find/near pages, duplicate names and IDs, stale/changed ownership,
page replacement and expiry during callbacks, all unlink refusal checks,
protected Unlock reentry/failure, and the original 60-second deadline. Listed
nearest-page workflows explicitly unlink, select the same row, link a replacement
and complete the existing hack in both supported door-class directions.

Live-unlink tests relay real setup, link A, explicit unlink, selection, link B
and actual client completion at the original server deadline in both brush-door
class directions. They check exact preservation of settings, pending selection,
edit tickets and unrelated reservations; creator/session/registry refusals;
bounded private replies; repeated requests; and native-input reentry, removal
and failure without clearing a newer link. Input recording does not certify
native unlocking, map outputs or protection behavior.

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

Listed-initial-setup tests use the real public chat callbacks and relay the
existing initial form's submissions and acknowledgement/result requests. They
cover exact row grammar, private current pages, strict expiry, current eligibility
and name ambiguity, callback-driven context changes, removed references, normal
CreationID-based paste names, repeated/dismissed/pending forms, legacy saves and
unchanged unrelated hacks, editors, receipts, markers and door choices. Their
Entity/String call recording and Derma substitutes do not establish native wire
encoding, visual focus or multiplayer behavior. The identity server/client/workflow
entries additionally cover real Remove/Spawn/SetName reuse, immutable nested
payloads, bound replies, one-time reentrant cleanup, serial exhaustion and
historical receipt isolation. A verbatim attributed baseline handler proves that
modern descriptors are rejected by the old server before mutation. Remaining
opening bits are modeled only for suffix branch behavior, not native padding or
a general network codec. No test claims to reproduce native creation-ID wrap.

The original client source uses CRLF line endings, which this change preserves.
To check whitespace without treating CRLF as trailing whitespace:

```sh
git -c core.whitespace=cr-at-eol diff --check
```

### Real-engine smoke checklist

These tests do **not** replace a Garry's Mod server/client smoke test. Rendering,
assets, physics/Use reach, engine networking and multiplayer timing are not
emulated. Before a live rollout, use a test server to check:

- Use `!nearConsoles 1 linked`, unlink a chosen row with `!unlinkConsole <row>`,
  select that same row with `!setEntity <row>`, and aim/link a replacement door.
  Confirm private replies, the intended old door's Unlock, both supported door
  classes, native protection-addon behavior, and expiry after 60 seconds.

- Select console A, replace its catalogue with B, then run `!locateConsole pending`
  from outside A's PVS. Confirm only the requester sees A's safe label and sampled
  position while row 1 still locates B. Repeat at the exact 60-second row deadline
  and after death/respawn, then link and hack A through each supported brush-door
  class. Verify only A's door unlocks. Try removed/foreign selections and unavailable
  coordinates with a prior marker; refusal must preserve the marker and selection.
  Keep initial/edit acknowledgements, an unsaved draft and another hack active;
  verify original deadlines, forms, focus and other players' choices survive.
  Check the unchanged packet's native vector encoding and requester privacy,
  15-second replacement/expiry, clear/death, HUD-addon compatibility and font fit.
  Native GMod transport, projection, rendering, focus and actual door inputs remain
  unavailable and unverified by the Lua API-double tests.

- Ask for `!slicerHelp` and each topic alive and dead with another player nearby.
  Check requester-only replies, readable complete lines, malformed usage and
  ordinary near-match chat. Keep a draft, pending link, locator and hacking
  countdown open; requesting help must preserve each, including row expiry.
- Check the mixed-version opening prefix: an old receiver must safely ignore the
  appended suffix, and a new receiver must recognize an actually absent suffix.
  Verify native remaining-bit boundaries, empty/truncated/unsupported suffixes,
  descriptor table serialization and bound replies without any fallback save
- Open A's draft, remove A, spawn B and use the supported server-side `SetName`
  API to assign A's old name to B. A's save must refuse and B must open blank.
  Repeat after accepting A and dropping its reply; its removed receipt must not
  confirm B. Check distant/out-of-PVS listed setup and actual Derma draft/focus
  preservation and pending resize at 640×480 and normal desktop size
- With two players, defer an ordinary console and paste an unconfigured copy.
  From a distance list/find/near them, open the intended row with
  `!setupConsole <row>`, and check private delivery and one existing initial form.
  Try every exact row, near-match chat text, another creator, configured targets,
  a removed row, relisting and the exact 60-second boundary without waiting for
  cleanup. Verify native PlayerSay consumption and Entity/String wire delivery
- Type a listed initial draft, repeat its command and physical Use, dismiss and
  reopen it, then submit and repeat while pending. Check actual Derma focus,
  typing, locked fields and no duplicate submission. Lose an accepted reply:
  reopening must refuse the configured target while Check setup result confirms
  its original receipt. Unconfirmed checks must remain uncertain without replay
- Keep an unrelated active hack, saved editor, locator and pending door choice
  open while doing listed setup. Check their deadlines, drafts and link choice
  survive. Repeat native death/disconnect and paste lifecycles, and verify physical
  creator Use still opens unconfigured setup while configured Use follows hacking
- List or search two same-name consoles, open row 2 with `!editConsole 2`, type a
  draft, then repeat the row command and bare eye-trace command for that console.
  Verify one form retains the draft, save it, and hack the renamed console using
  its updated filename and delay. Relist or wait 60 seconds before saving an open
  draft, and confirm unavailable rows never open the console in your eye trace
- Spawn/configure one terminal of each type and complete their command flows
- Rapidly submit login and each download before the first visible countdown
  update; try recalling/submitting return at download start. Confirm the input
  locks immediately, the original countdown continues, help and Quit terminal
  still work, and a completed download produces only one success notice
- Edit the final setup field and click Done directly; repeat with a new console
  and confirm the new form cannot submit values from the previous one
- Open setup at 640×480, 800×600, 1024×600, 1280×720, 1366×768 and 1920×1080.
  Check that all four inputs and both actions are visible and clickable, the
  folder dropdown opens within reach, and placeholders and text fit the fonts.
  Reopen an already visible form and check its draft and focus are retained
- Choose Set up later, then use the unconfigured console without the hacking
  tool and finish a fresh setup. Confirm another player cannot reopen it; reopen
  an already visible setup and check its typing and focus are retained
- Deliberately delay/drop the first accepted setup reply for data, server and
  tools. Choose Check setup result, confirm the pending form closes once, and
  verify no setup resend or changed pending door choice. Lose a status reply,
  check again manually after two seconds, and deliver a late original reply.
  Check unconfirmed and unavailable status text at 640×480 and 1920×1080,
  including after a live resize; verify complete wrapping, readable controls
  and retained locked fields. Try an older server and two simultaneous forms
- Try a blank name/file, missing folder, and nonpositive delay; correct each
  rejected form and verify it can still configure its terminal
- Equip the hacking tool and verify its pistol hold animation in multiplayer;
  with ammunition available, check that left/right-click do not fire or consume it
- In a test gamemode that enables weapon drops on death, verify the hacking tool
  is not dropped and its death hook raises no Lua error
- With two players, confirm only one can enter a terminal at a time
- Link separate sliding and rotating brush doors. Check native Lock, blocked Use,
  timed tool completion, Unlock and removal, including each map's door outputs
- Use each linked brush-door class at 640×480 and 1920×1080. Read the complete
  private locked-door notice, resize down and back up while it is visible, and
  confirm repeated Use does not extend its four-second expiry. Trigger another
  notice after expiry; check current-size placement and input pass-through.
  Repeat with a creator draft and unrelated hacking countdown/Commands open;
  check typing, focus, drafts, the original countdown and the still-locked door
- Inspect each console and door with `!inspectLink` as its creator, including
  while another player is hacking. Check private replies, unchanged deadlines,
  same-name copy IDs, and readability of long and multibyte console names
- Use `!inspectConsole 1` after list/find/near pages, including during a hack.
  Check the three private saved-setting lines, long/multibyte filenames, original
  draft and hack timing, and refusal when ownership changes or the row expires
- Place owned consoles at different heights and distances, then use
  `!nearConsoles` and its page hints. Move before requesting another page and
  check the snapshot order, private replies and exact locate/edit/select rows
  Repeat with `!nearConsoles 1 setup`, `unlinked`, `unconfirmed`, `linked` and
  `reserved`; check filtered counts and state-preserving page hints. Change a
  listed console's state and verify the old row retains that exact console while
  actions enforce its current eligibility. Repeat with a literal name tail, such as
  `!nearConsoles 1 unlinked reactor west`, in each named state. Check that closer
  nonmatching names do not take page slots, hints preserve the query, and an old
  row stays bound after renaming or moving the console
- With more than five owned consoles, use `!listConsoles` and its next-page
  commands. Check private replies, full-length ASCII/multibyte names, deferred
  setup and same-name copies. List while setup/edit forms or a live hack are
  open; verify pending choices, forms, original deadlines and doors are intact
- Use `!listConsoles 1 setup`, `!listConsoles 1 unlinked`,
  `!listConsoles 1 unconfirmed` and `!listConsoles 1 linked` with deferred/pasted
  consoles, deliberate unlinking, unavailable or unregistered links, and exact
  registered links for both door classes. Check
  private totals and complete page hints. Locate a filtered row, then configure,
  rename or relink its console before locating the same row again; check that
  the exact live console remains locatable until expiry without promising its
  old state. Switch among full lists, name searches and filtered pages while
  other players' hacks and pending setup/edit replies remain usable
- Use `!findConsoles 1 <text>` with mixed ASCII case, numeric names, literal
  punctuation and 128-byte ASCII/multibyte text. Check what the native chat
  entry accepts, private filtered pages and repeatable page hints. Locate a
  search row, rename/remove its console, then switch back to the full list;
  verify current ownership, exact rows, expiry and the existing marker lifecycle
- Use `!findConsoleFiles 1 <text>` with saved filenames and each folder,
  including mixed ASCII case, punctuation, internal spaces and 128-byte text.
  Verify private results, complete page hints and `!inspectConsole <row>`
  metadata. Check native chat's 154-byte command boundary, invalid/unset
  configuration exclusion, and locate the original row after editing its
  filename. Switch catalogue families while forms and another player's hack
  remain active; verify the shared row lease and unchanged marker lifecycle
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
- Lose or hide a terminal page without clicking Quit, then enter exactly
  `!quitConsole` in chat. Check private delivery with the server's chat addons,
  cleanup during each countdown, retry with a fresh delay, and recovery without
  an equipped tool or crosshair target. Repeat while another player is hacking
  and while your setup/edit drafts and locator are open; verify they stay intact
  and both linked brush-door classes remain locked. Try idle/repeated requests,
  near-match text and a dead player; confirm no unrelated cleanup or release
- Enter `!hackStatus` during login and downloads, at/after the minimum deadline,
  and with a missing terminal page. Check requester-only delivery, useful name
  wrapping, no UI change or success claim, and unchanged normal completion.
  Repeat without a tool and while another player hacks; after quitting, confirm
  it reports no session. Check its entry in `!slicerHelp hacking`
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
- Remove a linked sliding or rotating door and use `!inspectLink` or
  `!listConsoles` to find the recovery guidance. As its living creator, use
  `!resetLink` on the idle console, explicitly select it with `!setEntity`,
  link a replacement of either brush class, and complete the normal tools flow.
  Check private replies, retained setup/edit drafts and other pending choices.
  Try reset during a hack, on a live door link, as another player and on an
  unconfigured/data/server console; verify no link changes or door unlocks
- Link an idle tools console to live door A, use `!unlinkConsole` on the console,
  and verify A can be used. Explicitly select the same console and link door B;
  complete the hack and verify only B receives the later unlock. Repeat with
  sliding and rotating doors, another linked console and an open edit form.
  Check private feedback and protection/map-output behavior. Try unlink during
  a hack, as another player and after a lost registry; confirm no unauthorized
  unlock or automatic repair
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
