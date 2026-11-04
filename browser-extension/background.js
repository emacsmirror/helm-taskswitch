// helm-taskswitch browser extension, background service worker.
//
// Connects out to Emacs at ws://127.0.0.1:PORT (the server is in
// helm-taskswitch-browser.el), sends it the list of tabs whenever tabs
// change, and runs a fixed set of tab commands that Emacs sends.
//
// Messages are JSON objects with a "type":
//   to Emacs:   hello, tabs, ping, reply
//   from Emacs: challenge, welcome (hello accepted), error (refused), cmd
//
// Neither side sends the token.  Emacs sends a challenge with a random
// nonce; the hello answers with our own nonce and an HMAC of both,
// keyed with the token; the welcome carries Emacs's HMAC of them under
// another label.  Until that checks out, nothing else is sent and no
// command is run, so a program that took the port while Emacs was not
// running gets neither the token nor the tabs.
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
const PROTOCOL = 2;

// How long Emacs has to send its challenge and welcome after we connect.
const HANDSHAKE_MS = 10 * 1000;

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

// Only to an Emacs that has proved it knows the token.
function send(message) {
    if (ws && ws.welcomed && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(message));
    }
}

// Proving the token
// ------------------------------------------------------------------------

const encoder = new TextEncoder();
let hmacKey = null;

function toHex(bytes) {
    return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function randomHex(nbytes) {
    return toHex(crypto.getRandomValues(new Uint8Array(nbytes)));
}

// HMAC-SHA256 of "helm-taskswitch ROLE\nSERVER-NONCE\nCLIENT-NONCE",
// keyed with the token.  helm-taskswitch-browser--proof in Emacs
// computes the same.
async function proof(role, serverNonce, clientNonce) {
    if (!hmacKey) {
        hmacKey = await crypto.subtle.importKey(
            "raw", encoder.encode(TOKEN), {name: "HMAC", hash: "SHA-256"},
            false, ["sign"]);
    }
    const message = `helm-taskswitch ${role}\n${serverNonce}\n${clientNonce}`;
    const mac = await crypto.subtle.sign("HMAC", hmacKey, encoder.encode(message));
    return toHex(new Uint8Array(mac));
}

// Compare without stopping at the first difference.
function secretEqual(a, b) {
    if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) {
        return false;
    }
    let diff = 0;
    for (let i = 0; i < a.length; i++) {
        diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
    }
    return diff === 0;
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
    // Set from Emacs's messages on this socket: a welcome with a good
    // proof accepts us, "error" refuses us (wrong token or protocol).
    sock.welcomed = false;
    sock.refused = false;
    sock.serverNonce = null;
    sock.clientNonce = null;
    sock.handshakeTimer = null;

    sock.onopen = () => {
        log("connected, waiting for the challenge");
        // Whatever is listening must prove it is Emacs, and soon.
        sock.handshakeTimer = setTimeout(() => {
            if (!sock.welcomed) {
                console.error("[helm-taskswitch] no valid welcome from",
                              SERVER_URL, "- is it Emacs?");
                sock.refused = true;
                sock.close();
            }
        }, HANDSHAKE_MS);
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
        clearTimeout(sock.handshakeTimer);
        if (ws === sock) {
            clearInterval(pingTimer);
            pingTimer = null;
        }
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
    if (!ws || !ws.welcomed || ws.readyState !== WebSocket.OPEN) {
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
    if (msg.type === "challenge") {
        if (sock.serverNonce || typeof msg.nonce !== "string" ||
            !/^[0-9a-f]{32,128}$/.test(msg.nonce)) {
            log("bad challenge, closing");
            sock.close();
            return;
        }
        if (msg.protocol !== PROTOCOL) {
            console.error("[helm-taskswitch] Emacs speaks protocol",
                          msg.protocol, "and this extension", PROTOCOL,
                          "- run M-x helm-taskswitch-browser-install and" +
                          " reload this extension.");
            sock.refused = true;
            sock.close();
            return;
        }
        sock.serverNonce = msg.nonce;
        sock.clientNonce = randomHex(16);
        const hello = {
            type: "hello", protocol: PROTOCOL, browser: "chrome",
            nonce: sock.clientNonce,
            proof: await proof("client", sock.serverNonce, sock.clientNonce),
            startedAt: STARTED_AT,
            extensionVersion: chrome.runtime.getManifest().version,
        };
        if (sock.readyState === WebSocket.OPEN) {
            log("sending hello");
            sock.send(JSON.stringify(hello));
        }
        return;
    }
    if (msg.type === "welcome") {
        if (sock.welcomed || !sock.clientNonce) {
            return;
        }
        const expected = await proof("server", sock.serverNonce,
                                     sock.clientNonce);
        if (!secretEqual(msg.proof, expected)) {
            console.error("[helm-taskswitch] the server on", SERVER_URL,
                          "did not prove it knows the token; not trusting it.");
            sock.refused = true;
            sock.close();
            return;
        }
        log("Emacs accepted the connection and proved itself");
        clearTimeout(sock.handshakeTimer);
        sock.welcomed = true;
        clearInterval(pingTimer);
        pingTimer = setInterval(() => send({type: "ping"}), PING_MS);
        await noteSuccess();
        await sendTabs();
        return;
    }
    if (msg.type === "error") {
        if (!sock.serverNonce) {
            // Emacs refused us without sending a challenge first, so it
            // speaks protocol 1 and timed out waiting for a hello.
            console.error("[helm-taskswitch] Emacs is running an older " +
                          "helm-taskswitch. Load the new " +
                          "helm-taskswitch-browser.el and helm-taskswitch.el " +
                          "in Emacs (or restart it), then turn " +
                          "helm-taskswitch-browser-mode off and on. " +
                          `(Emacs said: ${msg.message})`);
        } else {
            console.error("[helm-taskswitch] Emacs refused the connection:",
                          msg.message);
        }
        sock.refused = true;
        return;
    }
    // Commands only from an Emacs that proved itself on this socket.
    if (msg.type !== "cmd" || !sock.welcomed || sock !== ws) {
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
