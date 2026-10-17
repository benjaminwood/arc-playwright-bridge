# arc-playwright-bridge

Drive a real, logged-in [Arc](https://arc.net) profile on a Mac with
[Playwright MCP](https://github.com/microsoft/playwright-mcp), from another
machine over SSH. Made for an AI agent supervisor
([eldar-os](https://github.com/benjaminwood/eldar-os)): the supervisor decides
*whether* an agent may drive a profile (asking a human), then runs this bridge
over SSH and pipes Playwright MCP's stdio to the agent.

Nothing here listens on the network. Everything is a command run over SSH:

```
browser-bridge profiles                      JSON: profiles, spaces, readiness (never tokens)
browser-bridge mcp <profile> [<space>|-] [--blocked-origins "a;b"]
                                             Playwright MCP on stdio, attached to that profile
browser-bridge new-tab <profile> <space> <url, base64url>
                                             open a tab in a space of the profile
browser-bridge init-token <profile>          one-time setup per profile
```

A **profile** is Arc's profile directory (`Default`, `Profile 4`): its own
logins, cookies and extensions. A **space** is Arc's sidebar section (a UUID);
a profile can have several. Connect pages and new tabs open in the space you
pass (default: the profile's first in the sidebar).

## How it works

Chromium won't expose the debugging port on a default profile anymore, so this
uses Playwright MCP's **extension mode**: Playwright starts a loopback relay,
then "launches the browser" with a `chrome-extension://…/connect.html` URL.
`lib/arc-open` hands that URL to the running Arc via AppleScript, as a new tab
in a space of the chosen profile, so that profile's copy of the extension
answers. The extension compares the URL's token with the one in its own
storage, connects to the relay, and attaches `chrome.debugger` to tabs.
`lib/arc-profiles` reads each profile's token from Arc's Local Storage (so a
reloaded extension needs no follow-up) and caches it (mode 600).

## Setup (on the Mac)

1. Node 20+ (Homebrew, mise, …). Clone this repo, then `./install.sh`. The
   first run writes `bridge.env` from `bridge.env.example`: set
   `BRIDGE_HIDDEN_ORIGINS` (pages the agent must never drive, e.g. where you
   approve its actions) and `BRIDGE_NODE` if `node` isn't on SSH's PATH, then
   run `./install.sh` again.
2. In Arc, in **each** profile the agent may drive: `arc://extensions` →
   Developer mode → **Load unpacked** → this repo's `extension/` (remove the
   store version first if it's installed). `arc://extensions` shows the
   profile of the space in front.
3. `bin/browser-bridge init-token '<profile dir>'` for each (a tab flashes up
   and closes), then check `bin/browser-bridge profiles` shows it `ready`.
4. Give the calling machine SSH access (a key, ideally restricted to this
   host's address) and have it run `bin/browser-bridge`.

## The patched extension

`extension/` is the Playwright Extension 0.4.0 (store id
`mmlmfjhmonkocbjadbfplnigmagldckm`, which Playwright MCP hardcodes; the
manifest `key` is kept so the id stays) with these changes:

- **Tab groups.** In Arc, `chrome.tabGroups.query` and friends never settle,
  and upstream awaits them before every connection, so it hangs with an empty
  tab list in the connect dialog. A shim at the top of `lib/background.mjs`
  stands in: no groups exist, and `tabs.group` returns a stable fake id (tab
  tracking keys off it).
- **Every tab in the profile.** Upstream shares only tabs it opened and tabs
  you drag into its tab group, which Arc can't make. The copy announces every
  tab in the profile when a connection starts, and any tab that gets a URL
  later, skipping tabs another connection holds, pending connect pages,
  discarded tabs and hidden origins. Marked `// Eldar:` in `background.mjs`.
- **Hidden origins** come from `extension/hidden-origins.json` (written by
  `install.sh`; not in git), plus the Tailscale admin console always.
- Manifest: name "Playwright Extension (Arc)", no `update_url`, store
  signature (`_metadata/`) removed.

**Re-patching** for a newer extension (the connect page reports a protocol or
version mismatch after a Playwright MCP upgrade): copy the new store build
from a profile's `Extensions/mmlmfjhmonkocbjadbfplnigmagldckm/<version>/`,
remove `_metadata`, edit the manifest as above, prepend the shim, and re-apply
the `// Eldar:` changes next to three anchors: the
`attachTab(selectedTab); didInitialize();` pair, the
`_groupTabIds.has(tabId) && !isNonDebuggableUrl(changeInfo.url)` branch, and
the final `new PlaywrightExtension()` (kept as `globalThis.__eldarExtension`).
Check `grep -n "tabGroups\|tabs.group\|tabs.ungroup\|^import"` first: new
imports must still run after the shim, and new group APIs need stubs. Then
reload it in every profile (each gets a new token; nothing else to do).

## Security notes

- **The caller is the gate.** Whoever can run `browser-bridge mcp` over SSH
  drives that profile, with all its logins. Put the decision (a human approval,
  a time limit) in the caller, and restrict the SSH key.
- **A driven page sees every tab in the profile**, by design.
- **Hidden origins aren't a security boundary**: `--blocked-origins` and the
  extension's skip list are defense in depth. Playwright MCP's
  `browser_run_code_unsafe` runs arbitrary Playwright code and could lift them,
  so the caller should withhold it (and review new tools on upgrades). If a
  hidden origin approves the agent's actions, also make that page refuse the
  Mac while a session is open.
- Tokens never leave the Mac's disk and Arc's storage; nothing here prints one
  except `lib/arc-profiles --token`, which `mcp` uses internally.

## Failure guide

| Symptom | Cause |
|---|---|
| Connect dialog in Arc, **empty tab list** | The store extension (unpatched) is loaded, or a new version needs re-patching |
| Connect dialog **with** a tab list | Token missing or mismatched for that profile: `init-token` |
| "Invalid token provided." | Cached token stale and Local Storage unreadable: open a token-less connect page in that profile, delete the cached token |
| Profile not `ready` | Extension not loaded there (or disabled), or loaded but no token yet: `init-token` |
| Tab opens in the wrong profile | The space→profile mapping changed; check `profiles` |
| "Arc is already open" errors | Something launched the Arc binary over SSH; only AppleScript (`lib/arc-open`) may be used |
| Exit 69 | Arc isn't running |

Gotchas: closing an Arc tab through `tell space …` silently does nothing; close
through the window. `pkill -f` over SSH can match its own shell; `pgrep` first.
Playwright writes snapshots to `output/`; trim it now and then.
