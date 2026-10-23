#!/usr/bin/env python3
"""megalooper as a tool for an AI app: an MCP server over stdio.

An AI app that speaks MCP starts this script and asks it things; it asks
the running megalooper and hands the answers back. It knows no music: what
the drums, the synth and the effects are, and what their settings mean,
megalooper says itself (classes/MegaRemote.sc). The tools it offers are in
mcp-tools.json beside it, which the Claude Desktop extension's bridge
(tools/mcpb/server/index.js) reads too.

For Claude Desktop the extension is the easier way (docs/ai.md). For any
other app, or by hand, add this script to the app's MCP servers, e.g. in
claude_desktop_config.json:

    {"mcpServers": {"megalooper": {
        "command": "/usr/bin/python3",
        "args": ["/path/to/megalooper/tools/megalooper-mcp.py"]}}}

megalooper must be running with AI APPS switched on in its Setup view: it
then writes where it listens, and a token, to remote.json in its folder
(MEGALOOPER_REMOTE names another file). Only this Mac can ask, and only
with that token. MEGALOOPER_REPLY_TIMEOUT (seconds) is for the tests.

Python 3.9 or later, standard library only.
"""
import json
import os
import socket
import sys
import time
import uuid

with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "mcp-tools.json"), encoding="utf-8") as _f:
    SPEC = json.load(_f)

SERVER_NAME = SPEC["serverName"]
SERVER_VERSION = SPEC["serverVersion"]
# MCP revisions whose tools part is all this server uses; a client asking for
# one of them gets it, any other gets the newest.
PROTOCOL_VERSIONS = SPEC["protocolVersions"]
INSTRUCTIONS = SPEC["instructions"]
TOOLS = SPEC["tools"]
# The tools that hand their arguments to megalooper as they are.
PASSED_ON = set(SPEC["passedOn"])
# Parts get_context always keeps, whatever `parts` asks.
ALWAYS_KEPT = {"format", "version", "profile", "standalone", "tempo", "aiChanges"}
REPLY_TIMEOUT = float(os.environ.get("MEGALOOPER_REPLY_TIMEOUT") or 10.0)
POLL = 0.02


class NotReachable(Exception):
    """megalooper could not be asked, or did not answer; the text says why."""


# ---- megalooper's side --------------------------------------------------------

def user_root():
    if sys.platform == "darwin":
        base = os.path.expanduser("~/Library/Application Support/SuperCollider")
    else:
        base = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"),
                            "SuperCollider")
    return os.path.join(base, "megalooper")


def handshake_path():
    return os.environ.get("MEGALOOPER_REMOTE") or os.path.join(user_root(), "remote.json")


def read_handshake():
    path = handshake_path()
    try:
        with open(path, encoding="utf-8") as f:
            hs = json.load(f)
    except FileNotFoundError:
        raise NotReachable("megalooper is not running, or AI apps are not let in (no %s). Start megalooper, "
                           "switch AI APPS on in its Setup view, then ask again." % path)
    except (OSError, ValueError) as e:
        raise NotReachable("megalooper's handshake %s can't be read (%s)." % (path, e))
    if hs.get("format") != "megalooper remote" or not isinstance(hs.get("port"), int) \
            or not hs.get("token") or not hs.get("dir"):
        raise NotReachable("%s is not megalooper's handshake." % path)
    return hs


def pid_alive(pid):
    if not isinstance(pid, int):
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True
    return True


def osc_string(s):
    b = s.encode("utf-8") + b"\0"
    return b + b"\0" * (-len(b) % 4)


def osc_message(address, *strings):
    return osc_string(address) + osc_string("," + "s" * len(strings)) + b"".join(osc_string(s) for s in strings)


def ask(command, args=None, timeout=None):
    """megalooper's answer to `command`: its result, or NotReachable."""
    timeout = REPLY_TIMEOUT if timeout is None else timeout
    hs = read_handshake()
    rid = "mcp-" + uuid.uuid4().hex
    req = os.path.join(hs["dir"], rid + ".request.json")
    rep = os.path.join(hs["dir"], rid + ".reply.json")
    body = {"command": command}
    if args is not None:
        body["args"] = args
    try:
        tmp = req + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(body, f)
        os.replace(tmp, req)
    except OSError as e:
        raise NotReachable("the request could not be written to %s (%s)." % (hs["dir"], e))
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.sendto(osc_message(hs.get("oscPath") or "/megalooper/remote", hs["token"], rid),
                        ("127.0.0.1", hs["port"]))
        finally:
            sock.close()
        deadline = time.monotonic() + timeout
        while not os.path.exists(rep):
            if time.monotonic() > deadline:
                if not pid_alive(hs.get("pid")):
                    raise NotReachable("megalooper is not running (it quit without removing %s). "
                                       "Start it, switch AI APPS on in its Setup view, then ask again."
                                       % handshake_path())
                raise NotReachable("megalooper did not answer in %g s. Is it busy, or stuck? "
                                   "Restarting it writes a new handshake." % timeout)
            time.sleep(POLL)
        with open(rep, encoding="utf-8") as f:
            reply = json.load(f)
    finally:
        for p in (req, rep):
            try:
                os.remove(p)
            except OSError:
                pass
    if not isinstance(reply, dict):
        raise NotReachable("megalooper's answer was not understood.")
    if not reply.get("ok"):
        raise NotReachable(reply.get("error") or "megalooper refused the request.")
    return reply.get("result")


# ---- the tools ------------------------------------------------------------------

def call_tool(name, arguments):
    """The text of a tool's answer, and whether it is an error."""
    arguments = arguments or {}
    try:
        if name == "get_context":
            ctx = ask("context")
            parts = arguments.get("parts")
            if parts and isinstance(ctx, dict):
                keep = ALWAYS_KEPT | set(parts)
                ctx = {k: v for k, v in ctx.items() if k in keep}
            return json.dumps(ctx, ensure_ascii=False), False
        if name == "describe":
            return json.dumps(ask("describe", {"topic": arguments.get("topic")}), ensure_ascii=False), False
        if name in PASSED_ON:
            return json.dumps(ask(name, arguments), ensure_ascii=False), False
        return "There is no tool %r." % name, True
    except NotReachable as e:
        return str(e), True


# ---- MCP: JSON-RPC 2.0, one message a line ------------------------------------------

def handle(msg):
    """The response to one message, or None for a notification."""
    if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0" or not isinstance(msg.get("method"), str):
        return error_response(msg.get("id") if isinstance(msg, dict) else None, -32600, "Invalid Request")
    method, mid, params = msg["method"], msg.get("id"), msg.get("params") or {}
    if "id" not in msg:
        return None
    if method == "initialize":
        asked = params.get("protocolVersion")
        return result_response(mid, {
            "protocolVersion": asked if asked in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0],
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            "instructions": INSTRUCTIONS,
        })
    if method == "ping":
        return result_response(mid, {})
    if method == "tools/list":
        return result_response(mid, {"tools": TOOLS})
    if method == "tools/call":
        name = params.get("name")
        if name not in [t["name"] for t in TOOLS]:
            return error_response(mid, -32602, "Unknown tool: %s" % name)
        text, is_error = call_tool(name, params.get("arguments"))
        return result_response(mid, {"content": [{"type": "text", "text": text}], "isError": is_error})
    return error_response(mid, -32601, "Method not found: %s" % method)


def result_response(mid, result):
    return {"jsonrpc": "2.0", "id": mid, "result": result}


def error_response(mid, code, message):
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": message}}


def serve(stdin=sys.stdin, stdout=sys.stdout):
    for line in stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            out = error_response(None, -32700, "Parse error")
        else:
            try:
                out = handle(msg)
            except Exception as e:  # a bug here must not end the session
                print("megalooper-mcp: %r" % e, file=sys.stderr)
                out = error_response(msg.get("id") if isinstance(msg, dict) else None, -32603, "Internal error")
        if out is not None:
            stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
            stdout.flush()


if __name__ == "__main__":
    serve()
