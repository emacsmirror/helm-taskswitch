# helm-taskswitch
Helm source for switching between desktop windows, browser tabs and
Emacs buffers.

You know how some times looking for the program or browser tab is like
rummaging through a drawer of unmatched socks? This is a solution to
that problem.

![helm-taskswitch screenshot](/screenshot.png)

`M-x helm-taskswitch` opens one Helm list with these sections:

| Section | Where it comes from |
|---|---|
| Windows | `wmctrl` on X11, or KWin over D-Bus on KDE Plasma under Wayland |
| Browser tabs | Every Chrome tab, sent to Emacs by the extension in `browser-extension/` |
| Buffers, recent files | Helm's own sources |

## How I use this

### Hot key to activate helm-taskswitch
I map the win-a key to be globally handled by the window manager to
run ``` emacsclient -n -e '(helm-taskswitch)' ```

On KDE Plasma this is a custom shortcut in System Settings → Shortcuts.

### Browser tabs
A lot of tasks are done in browser tabs. But they are not accessable
to task switchers. I definitly need to switch between browser tabs to
get my work done.

The browser extension in `browser-extension/` sends every Chrome tab to
Emacs, so tabs show up in helm-taskswitch next to windows and buffers.
The most recently used tabs come first, and the URL is shown and
searchable. See [Browser tabs](#browser-tabs-1) below for setup.

### Example 
With this setup, when I hit win-a, Emacs comes up and I get the task
switcher, from there I type in the first thing that comes to mind
related to the tool I want, the title, the URL or host, .js to get all
my JavaScript buffers. Helm handles all the auto-complete and
filtering. Hitting return brings the window/tab/buffer to the
foreground.

Lets say I want a chrome tab with the an AWS ElasticSearch console.

I hit win-a, type 'chr' (that filters to Chrome windows and tabs)
SPACE 'ela' (all of those with 'ela' in the title or URL) SPACE 'con'
(those with 'ela' and 'con'). Then I usually just hit return without
looking since I'm confident it will be right.

This works great for me. I still use alt-tab for most recently used
program. And if I have my hand on the mouse I use it for task
switching. 

## Why?

When working on a computer I'm working on tasks. Usually each task is
serviced by a program that is running, a tab in a browser or a buffer
in Emacs.

When I switch between one task and another it goes something like
this: 

1) Something triggers a mental need to switch to another task in
my mind 

2) I think of which program/tab/buffer is servicing this task. I
personally, the first thing I think of about the program/tab/buffer is
some sort of word such as 'inbox' 'terminal to server-dev-23'
'ItemAction.js'. 

3) I do something with the computer to bring the program I
need to do that task to a state where I can use it.

Mainstream UIs for switching between tasks almost always use a visual
UI to offer the options of which running programs can be switched
between. This does not work with my step 2 since I'm thinking of
something like "google chrome with AWS lambda console". I don't think
of how it looks, I don't think of how many times back in a stack that
might be. 

I find these deficient because I usually have a large number of
programs/tabs/buffers running, each servicing a task. They focus on a
visual search of open program windows. As the number of windows grows
these become illegible. 

Web browser tabs are a huge difficulty. If I have three browser
windows open each with a dozen tabs there is no way I'm going to find
the tab I want efficiently.  Mainstream UIs don't service tabs/buffers
so they don't cover all of the things I want to bring forward.

The setup I use with this package achieves: 

1) Symbolic searching of title, program etc for programs/tabs/buffers
that service tasks. I just hit win-a and type something. I touch type
so this works well for me. I'm never rummaging around.

2) Combines the program window search space, tab search space and
Emacs buffer search space. These are the most common types of tools
I'm looking for.

3) I never have to find which browser window has which tab. All the
tabs are exposed.

## Requirements

- Linux, Emacs 28.1 or later, [helm](https://github.com/emacs-helm/helm) 3.0 or later.
- Windows, one of:
  - **X11:** [wmctrl](https://sites.google.com/site/tstyblo/wmctrl).
  - **KDE Plasma on Wayland:** nothing extra. Windows are listed
    through KWin's D-Bus interface. Tested on Plasma 5.27.
- Browser tabs (optional): [websocket.el](https://github.com/ahyatt/emacs-websocket)
  1.15 or later, and Chrome. Tested on Chrome 156.

## Installation

```elisp
(add-to-list 'load-path "~/src/helm-taskswitch")
(require 'helm-taskswitch)          ; also loads helm-taskswitch-browser
```

Loading `helm-taskswitch.el` with `load-file` also works; it loads
`helm-taskswitch-browser.el` from beside itself. If websocket.el is
missing, the browser tabs section is just empty. Browser tabs need no
other line in your init file (see [Browser tabs](#browser-tabs-1)).

### Window backend

`helm-taskswitch-backend` picks how windows are listed and focused. It
is `kwin` when `XDG_SESSION_TYPE` is `wayland`, otherwise `wmctrl`.

| Backend | Lists | Focus | Close |
|---|---|---|---|
| `wmctrl` | X11 windows (on Wayland, only XWayland ones) | yes, switching desktops too | yes |
| `kwin` | All windows, through KWin's window runner on D-Bus | yes, KWin switches desktops itself | not yet |

**Other Wayland desktops (GNOME, Sway and so on):** the default picks
`kwin` for every Wayland session, but the `kwin` backend only works on
KDE Plasma. Elsewhere the Windows section is empty and focusing a
window fails with a D-Bus `ServiceUnknown` error. Set the backend to
`wmctrl` there, which lists the XWayland windows:

```elisp
(setq helm-taskswitch-backend 'wmctrl)
```

## Browser tabs

```
Chrome ── extension (browser-extension/) ── ws://127.0.0.1:62841 ── Emacs (helm-taskswitch-browser.el)
```

The extension connects out to a small WebSocket server that Emacs runs,
sends the list of tabs, and sends it again whenever tabs change. Emacs
keeps the latest list, so Helm opens instantly. No native messaging
helper program is needed.

Emacs starts the server the first time you run `M-x helm-taskswitch`,
once the install command below has been run. Until then nothing
listens, so people who don't use browser tabs get no server.

### Setup

1. `M-x helm-taskswitch-browser-install`. This copies the extension to
   `~/.local/share/helm-taskswitch/browser-extension/`
   (`helm-taskswitch-browser-extension-dir`), writes its `config.js`
   there with the port and a secret token, and shows these steps.
2. In Chrome, open `chrome://extensions` and turn on **Developer mode**.
3. Click **Load unpacked** and choose that directory. The extension ID
   must be `iofbocbifodmmplkphnmicpokfpgiodh` (the key in
   `manifest.json` fixes it).
4. `M-x helm-taskswitch-browser-status` should show Chrome as
   authenticated, with a tab count, within about a minute. The install
   command starts the server, so this works right away.

The extension is copied out of the package because package.el deletes
the package directory on every upgrade. **After upgrading
helm-taskswitch**, run `M-x helm-taskswitch-browser-install` again and
click the extension's reload button in `chrome://extensions`. Emacs
tells you when the connected extension is older than the package's
copy.

To work on the extension itself, set
`helm-taskswitch-browser-extension-dir` to the `browser-extension/`
directory of your git checkout and load it from there. The install
command then only writes `config.js` (which is git-ignored), and
changes take effect when you reload the extension.

### Actions on tabs

| Action | What it does |
|---|---|
| Switch to tab (default) | Activates the tab and brings its window to the front (on Wayland through KWin if Chrome cannot) |
| Close tab(s) | Closes the marked tabs, or the selected one |
| Copy URL | Puts the URL in the kill ring |
| Reload, Duplicate, Mute/unmute | As in Chrome |
| Open URL in eww | Opens the tab's URL in Emacs |

`M-x helm-taskswitch-browser-open-url` opens a URL (the one at point by
default) in a new Chrome tab.

### Security

The tab list includes every URL you have open, and Emacs can control
the browser, so the connection is locked down:

- The server only listens on 127.0.0.1.
- Connections from any origin other than the extension's
  (`chrome-extension://iofbocbifodmmplkphnmicpokfpgiodh`) are closed.
  Web pages cannot fake this header.
- Both sides then prove they know a secret token, which only your user
  can read (`~/.config/helm-taskswitch/token`, mode 600). `config.js`
  holds a copy, is mode 600, and is git-ignored for checkouts. The
  token itself is never sent: Emacs sends a random challenge, and each
  side answers with an HMAC-SHA256 of both sides' nonces, keyed with
  the token.
- The extension sends no tabs and runs no commands until Emacs has
  proved itself. So a program that takes the port while Emacs is not
  running gets neither the token nor your tabs, and cannot control the
  browser.
- Emacs only sends a fixed set of tab commands, and never runs anything
  the browser sends.

### Troubleshooting

- **No tabs the first time after starting Emacs.** The server starts
  when you first run `M-x helm-taskswitch`. While nothing listens, the
  extension only tries to connect about once a minute (each failed try
  adds an error to its entry in `chrome://extensions`; that is
  expected), so tabs show up within about 90 seconds of that. After
  that it reconnects within a second or two. To have tabs ready
  sooner, start the server from your init file:
  `(helm-taskswitch-browser-ensure-started)`.
- **Check the connection:** `M-x helm-taskswitch-browser-status` lists
  connected browsers, the extension version, and when the tab list was
  last updated.
- **"Emacs refused the connection: wrong token"** in the extension's
  service worker console: the token file was recreated. Run
  `M-x helm-taskswitch-browser-install` again and reload the extension.
- **"connected with extension X, but this package has Y"**, or
  **"protocol 1, Emacs speaks 2"**: run
  `M-x helm-taskswitch-browser-install` and reload the extension.
- **"Emacs is running an older helm-taskswitch"** in the extension's
  service worker console: the extension was updated but Emacs still
  has the old code loaded. Load the new `helm-taskswitch-browser.el`
  and `helm-taskswitch.el`, or restart Emacs.
- **"did not prove it knows the token; not trusting it"** in the
  extension's service worker console: something other than this Emacs
  answered on the port, or it has a different token file.
- **Port in use:** only one Emacs can run the server. In a second
  Emacs, `M-x helm-taskswitch` says once that there are no browser
  tabs and why, then works without them; `M-x
  helm-taskswitch-browser-status` shows the reason too. To use a
  different port, change `helm-taskswitch-browser-port`, then run the
  install command again and reload the extension.
- **Upgrading from 2.1.0:** `(helm-taskswitch-browser-mode 1)` in an
  init file still works but is no longer needed; you can remove it.
- **"no window matches tab ...":** with the `kwin` backend, Emacs
  raises the window whose title is the tab's title plus a browser
  ending such as ` - Google Chrome`. If your browser's window titles
  end differently, add the ending to
  `helm-taskswitch-tab-window-title-suffixes`.
- **Log messages:** set `helm-taskswitch-browser-log` to `t`.

## Tests

With helm and websocket.el installed through package.el:

```sh
emacs --batch --eval '(package-initialize)' -L . \
      -l test/helm-taskswitch-test.el -f ert-run-tests-batch-and-exit
emacs --batch --eval '(package-initialize)' -L . \
      -l test/helm-taskswitch-browser-test.el -f ert-run-tests-batch-and-exit
```

The browser tests run the server and a fake extension in one Emacs, on
port 62899, so a running browser cannot interfere. The other tests
fake KWin and the browser.

## TODO 
- Windows are not ordered by how recently they were used (tabs are).
- Closing windows with the `kwin` backend.
- Firefox support for the browser extension.
