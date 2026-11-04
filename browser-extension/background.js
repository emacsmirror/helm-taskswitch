// helm-taskswitch browser extension, background service worker.
//
// Connects out to Emacs at ws://127.0.0.1:PORT (the server is in
// helm-taskswitch-browser.el), sends it the list of tabs whenever tabs
// change, and runs a fixed set of tab commands that Emacs sends.
//
// Messages are JSON objects with a "type":
//   to Emacs:   hello, tabs, ping, reply
//   from Emacs: welcome (hello accepted), error (refused), cmd
//
// PORT and TOKEN come from config.js, which M-x helm-taskswitch-browser-install
// writes.  It is not in git because the token is a secret.

try {
    importScripts("config.js");
} catch (e) {
    console.error("[helm-taskswitch] config.js is missing. " +
                  "Run M-x helm-taskswitch-browser-install in Emacs, " +
                  "then reload this extension.", e);
}

const CONFIG = self.HELM_TASKSWITCH_CONFIG || {};
const PORT = CONFIG.port || 62841;
const TOKEN = CONFIG.token || "";
const SERVER_URL = `ws://127.0.0.1:${PORT}`;
const PROTOCOL = 1;

// Chrome stops an idle service worker after about 30 s.  Since Chrome
// 116, WebSocket traffic resets that timer, so ping more often than that.
const PING_MS = 20 * 1000;

// Retry delays double from 1 s up to 60 s while Emacs is unreachable.
// Each failed attempt makes Chrome log an error for this extension, so
// do not retry faster than needed.
const RETRY_MIN_MS = 1000;
const RETRY_MAX_MS = 60 * 1000;

// While Emacs is unreachable nothing keeps this service worker alive, so
// Chrome stops it and this alarm starts it again.  30 s is the shortest
// period Chrome allows.
const ALARM_NAME = "helm-taskswitch-reconnect";

// Collect bursts of tab events into one tab list message.
const TABS_PUSH_DELAY_MS = 250;

// Lets Emacs tell when Chrome restarted this service worker.
const STARTED_AT = Date.now();

let ws = null;
let connecting = false;
let pingTimer = null;
let retryTimer = null;
let pushTimer = null;

function log(...args) {
    console.log("[helm-taskswitch]", ...args);
}

function send(message) {
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(message));
    }
}

// Connecting and retrying
// ------------------------------------------------------------------------
//
// The retry state lives in chrome.storage.session, not in variables,
// because Chrome restarts this service worker between attempts when
// Emacs is down.

// minDelayMs: wait at least this long, e.g. the longest delay when Emacs
// refused us, since retrying soon would only be refused again.
async function noteFailure(minDelayMs = 0) {
    const {failures = 0} = await chrome.storage.session.get("failures");
    const n = failures + 1;
    const delay = Math.max(minDelayMs,
                           Math.min(RETRY_MIN_MS * 2 ** (n - 1), RETRY_MAX_MS));
    await chrome.storage.session.set({failures: n,
                                      nextAttemptAt: Date.now() + delay});
    log(`connection failed ${n} time(s), next attempt in ${delay / 1000} s`);
    // Short delays: retry while this worker is still alive.  Longer ones:
    // the alarm will call connect(), which waits for nextAttemptAt.
    if (delay < 30 * 1000 && !retryTimer) {
        retryTimer = setTimeout(() => {
            retryTimer = null;
            connect();
        }, delay + 50);
    }
}

async function noteSuccess() {
    await chrome.storage.session.set({failures: 0, nextAttemptAt: 0});
}

async function connect() {
    if (connecting || (ws && (ws.readyState === WebSocket.OPEN ||
                              ws.readyState === WebSocket.CONNECTING))) {
        return;
    }
    if (!TOKEN) {
        log("no token in config.js, not connecting");
        return;
    }
    connecting = true;
    try {
        const {nextAttemptAt = 0} =
              await chrome.storage.session.get("nextAttemptAt");
        if (Date.now() < nextAttemptAt) {
            return;
        }
        openSocket();
    } finally {
        connecting = false;
    }
}

function openSocket() {
    log("connecting to", SERVER_URL);
    let sock;
    try {
        sock = new WebSocket(SERVER_URL);
    } catch (e) {
        log("could not create WebSocket:", e);
        noteFailure();
        return;
    }
    ws = sock;
    // Set from Emacs's messages on this socket: "welcome" accepts the
    // hello, "error" refuses it (wrong token or protocol).
    sock.welcomed = false;
    sock.refused = false;

    sock.onopen = () => {
        log("connected, sending hello");
        send({type: "hello", protocol: PROTOCOL, browser: "chrome",
              token: TOKEN, startedAt: STARTED_AT,
              extensionVersion: chrome.runtime.getManifest().version});
        clearInterval(pingTimer);
        pingTimer = setInterval(() => send({type: "ping"}), PING_MS);
    };

    sock.onmessage = (event) => {
        handleMessage(event.data, sock);
    };

    // An error is always followed by close, so only close retries.
    sock.onerror = () => {};

    // Only a welcome resets the retry delay.  Opening the socket is not
    // enough: if Emacs then refuses the hello, resetting would make the
    // extension reconnect in a tight loop.
    sock.onclose = (event) => {
        log("closed", event.code, event.reason);
        clearInterval(pingTimer);
        pingTimer = null;
        if (ws === sock) {
            ws = null;
        }
        noteFailure(sock.refused ? RETRY_MAX_MS : 0);
    };
}

chrome.alarms.create(ALARM_NAME, {periodInMinutes: 0.5});
chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === ALARM_NAME) {
        connect();
    }
});

chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);

// Tab list
// ------------------------------------------------------------------------

async function sendTabs() {
    if (!ws || ws.readyState !== WebSocket.OPEN) {
        return;
    }
    const tabs = await chrome.tabs.query({});
    send({
        type: "tabs",
        tabs: tabs
            .filter((t) => !t.incognito)
            .map((t) => ({
                id: t.id,
                windowId: t.windowId,
                index: t.index,
                title: t.title,
                url: t.url,
                active: t.active,
                pinned: t.pinned,
                audible: Boolean(t.audible),
                muted: Boolean(t.mutedInfo && t.mutedInfo.muted),
                lastAccessed: t.lastAccessed,
            })),
    });
}

function scheduleTabsPush() {
    if (pushTimer) {
        return;
    }
    pushTimer = setTimeout(() => {
        pushTimer = null;
        sendTabs();
    }, TABS_PUSH_DELAY_MS);
}

// Only these changes matter to Emacs; "status" and "favIconUrl" changes
// while pages load would otherwise send the list many times.
const INTERESTING_TAB_CHANGES = ["title", "url", "pinned", "audible",
                                 "mutedInfo"];

chrome.tabs.onCreated.addListener(scheduleTabsPush);
chrome.tabs.onRemoved.addListener(scheduleTabsPush);
chrome.tabs.onActivated.addListener(scheduleTabsPush);
chrome.tabs.onMoved.addListener(scheduleTabsPush);
chrome.tabs.onAttached.addListener(scheduleTabsPush);
chrome.tabs.onDetached.addListener(scheduleTabsPush);
chrome.tabs.onReplaced.addListener(scheduleTabsPush);
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
    if (INTERESTING_TAB_CHANGES.some((key) => key in changeInfo)) {
        scheduleTabsPush();
    }
});
chrome.windows.onFocusChanged.addListener(scheduleTabsPush);

// Commands from Emacs
// ------------------------------------------------------------------------
//
// Emacs sends {type: "cmd", id, cmd, ...arguments}.  Every command gets
// {type: "reply", id, ok, result} or {type: "reply", id, ok: false, error}.

async function focusWindow(windowId) {
    await chrome.windows.update(windowId, {focused: true});
}

const COMMANDS = {
    async activate({tabId}) {
        const tab = await chrome.tabs.update(tabId, {active: true});
        await focusWindow(tab.windowId);
    },
    async close({tabIds}) {
        await chrome.tabs.remove(tabIds);
    },
    async open({url, active = true}) {
        const tab = await chrome.tabs.create({url, active});
        if (active) {
            await focusWindow(tab.windowId);
        }
        return {tabId: tab.id};
    },
    async reload({tabId}) {
        await chrome.tabs.reload(tabId);
    },
    async duplicate({tabId}) {
        const tab = await chrome.tabs.duplicate(tabId);
        return {tabId: tab ? tab.id : null};
    },
    async setMuted({tabId, muted}) {
        await chrome.tabs.update(tabId, {muted: Boolean(muted)});
    },
    async refresh() {
        await sendTabs();
    },
};

async function handleMessage(data, sock) {
    let msg;
    try {
        msg = JSON.parse(data);
    } catch (e) {
        log("bad JSON from Emacs:", data);
        return;
    }
    if (msg.type === "welcome") {
        log("Emacs accepted the connection");
        sock.welcomed = true;
        await noteSuccess();
        await sendTabs();
        return;
    }
    if (msg.type === "error") {
        console.error("[helm-taskswitch] Emacs refused the connection:",
                      msg.message);
        sock.refused = true;
        return;
    }
    if (msg.type !== "cmd") {
        return;
    }
    const fn = Object.hasOwn(COMMANDS, msg.cmd) ? COMMANDS[msg.cmd] : null;
    if (!fn) {
        send({type: "reply", id: msg.id, ok: false,
              error: `unknown command: ${msg.cmd}`});
        return;
    }
    try {
        const result = await fn(msg);
        send({type: "reply", id: msg.id, ok: true, result: result || null});
    } catch (e) {
        send({type: "reply", id: msg.id, ok: false,
              error: String((e && e.message) || e)});
    }
}

// Connect whenever the service worker starts, whatever woke it.
connect();
