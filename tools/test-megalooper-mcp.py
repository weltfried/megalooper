#!/usr/bin/env python3
"""Checks the bridges between an AI app and megalooper.

    python3 tools/test-megalooper-mcp.py

Both bridges, tools/megalooper-mcp.py and the Claude Desktop extension's
tools/mcpb/server/index.js (when node is here), are run as an app runs
them: a process spoken to over stdio, each call after initialize. Each
answers the same: the MCP side (initialize, the tools, errors), and asking a
stand-in megalooper in this process. Then the real round trip, when sclang
is there: scripts/tests/remote-peer.scd runs a MegaRemote in a scratch
folder of its own, on a UDP port far from megalooper's, and each bridge asks
it over OSC. A megalooper playing beside it is never asked: the peer's
handshake is not yours, and the bridges are pointed at it. Last, the
extension: its manifest against the tool list, and the bundle
tools/make-mcpb.sh makes, its bridge run from inside it.

MEGALOOPER_SCLANG_CONF names an sclang configuration file (sclang -l) when
the classes to check are not the ones linked into Extensions, as
tools/run-checks.sh has it.
"""
import importlib.util
import json
import os
import random
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SPEC = json.load(open(os.path.join(HERE, "mcp-tools.json"), encoding="utf-8"))

spec = importlib.util.spec_from_file_location("megalooper_mcp", os.path.join(HERE, "megalooper-mcp.py"))
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)

NODE = shutil.which("node")
BRIDGES = {
    "python": [sys.executable, os.path.join(HERE, "megalooper-mcp.py")],
    "node": [NODE, os.path.join(HERE, "mcpb", "server", "index.js")] if NODE else None,
}


def osc_strings(data):
    """The address and the string arguments of an OSC message."""
    out, i = [], 0
    while i < len(data):
        j = data.index(b"\0", i)
        out.append(data[i:j].decode("utf-8"))
        i = (j + 4) & ~3
    address, tags, args = out[0], out[1], out[2:]
    assert tags == "," + "s" * len(args), tags
    return address, args


def run_bridge(cmd, messages, env=None, timeout=30):
    """Every line a bridge answers to `messages`, sent one a line, as JSON."""
    proc = subprocess.run(cmd, input="".join(m if isinstance(m, str) else json.dumps(m) + "\n" for m in messages),
                          capture_output=True, text=True, env=env, timeout=timeout)
    return [json.loads(x) for x in proc.stdout.splitlines() if x.strip()]


class FakeMegalooper:
    """A stand-in megalooper: a handshake, a UDP port, and an answer per command."""

    def __init__(self, root, answers, token="t0ken", pid=None):
        self.root, self.answers, self.token = root, answers, token
        self.dir = os.path.join(root, "remote")
        os.makedirs(self.dir, exist_ok=True)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.settimeout(0.05)
        self.port = self.sock.getsockname()[1]
        self.heard, self.running = [], True
        self.handshake = os.path.join(root, "remote.json")
        with open(self.handshake, "w") as f:
            json.dump({"format": "megalooper remote", "version": 1, "port": self.port, "token": token,
                       "pid": pid if pid is not None else os.getpid(), "oscPath": "/megalooper/remote",
                       "dir": self.dir}, f)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while self.running:
            try:
                data, _ = self.sock.recvfrom(65536)
            except socket.timeout:
                continue
            address, args = osc_strings(data)
            self.heard.append((address, args))
            if args[0] != self.token:
                continue
            with open(os.path.join(self.dir, args[1] + ".request.json")) as f:
                req = json.load(f)
            answer = self.answers.get(req["command"])
            reply = answer(req.get("args")) if callable(answer) else answer
            if reply is None:
                continue
            tmp = os.path.join(self.dir, args[1] + ".tmp")
            with open(tmp, "w") as f:
                json.dump(reply, f)
            os.replace(tmp, os.path.join(self.dir, args[1] + ".reply.json"))

    def close(self):
        self.running = False
        self.thread.join()
        self.sock.close()


class BridgeCase(unittest.TestCase):
    """Calls to one bridge, as an app makes them: initialize first."""
    bridge = None
    remote = None
    reply_timeout = "0.5"

    @classmethod
    def setUpClass(cls):
        if BRIDGES.get(cls.bridge) is None:
            raise unittest.SkipTest("node is not installed")

    def env(self):
        env = dict(os.environ, MEGALOOPER_REPLY_TIMEOUT=self.reply_timeout)
        if self.remote:
            env["MEGALOOPER_REMOTE"] = self.remote
        return env

    def session(self, *messages):
        hello = [{"jsonrpc": "2.0", "id": 0, "method": "initialize",
                  "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                             "clientInfo": {"name": "test", "version": "1"}}},
                 {"jsonrpc": "2.0", "method": "notifications/initialized"}]
        got = run_bridge(BRIDGES[self.bridge], hello + list(messages), self.env())
        self.assertEqual(got[0]["id"], 0, got)
        return got[1:]

    def call(self, method, params=None, mid=1):
        msg = {"jsonrpc": "2.0", "id": mid, "method": method}
        if params is not None:
            msg["params"] = params
        return self.session(msg)[0]

    def tool(self, name, arguments=None):
        r = self.call("tools/call", {"name": name, "arguments": arguments or {}})["result"]
        return r["content"][0]["text"], r["isError"]


class Protocol:
    def test_initialize_answers_the_clients_revision_when_it_has_it(self):
        got = run_bridge(BRIDGES[self.bridge], [{"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                 "params": {"protocolVersion": "2025-03-26"}}], self.env())
        r = got[0]["result"]
        self.assertEqual(r["protocolVersion"], "2025-03-26")
        self.assertEqual(r["serverInfo"], {"name": "megalooper", "version": SPEC["serverVersion"]})
        self.assertIn("tools", r["capabilities"])
        self.assertEqual(r["instructions"], SPEC["instructions"])

    def test_initialize_offers_its_newest_for_one_it_does_not_know(self):
        got = run_bridge(BRIDGES[self.bridge], [{"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                 "params": {"protocolVersion": "1999-01-01"}}], self.env())
        self.assertEqual(got[0]["result"]["protocolVersion"], SPEC["protocolVersions"][0])

    def test_tools_are_the_tool_lists_and_say_which_change_things(self):
        tools = self.call("tools/list")["result"]["tools"]
        self.assertEqual(tools, SPEC["tools"])
        self.assertEqual([t["name"] for t in tools],
                         ["get_context", "describe", "set_drum_pattern", "set_synth", "set_chain", "revert",
                          "save_synth_preset", "save_sound", "save_drum_preset"])
        for t in tools:
            self.assertEqual(t["inputSchema"]["type"], "object")
        self.assertEqual({t["name"] for t in tools if t["annotations"]["readOnlyHint"]}, {"get_context", "describe"})
        self.assertEqual({t["name"] for t in tools if t["annotations"].get("destructiveHint")},
                         {"save_drum_preset", "save_synth_preset", "save_sound"})

    def test_notifications_get_no_answer_and_ping_an_empty_one(self):
        got = self.session({"jsonrpc": "2.0", "method": "notifications/cancelled"},
                           {"jsonrpc": "2.0", "id": 5, "method": "ping"})
        self.assertEqual(got, [{"jsonrpc": "2.0", "id": 5, "result": {}}])

    def test_unknown_methods_and_tools_are_errors(self):
        self.assertEqual(self.call("resources/list")["error"]["code"], -32601)
        self.assertEqual(self.call("tools/call", {"name": "play_louder"})["error"]["code"], -32602)
        self.assertEqual(self.session({"id": 3})[0]["error"]["code"], -32600)

    def test_answers_come_in_order_and_a_bad_line_is_survived(self):
        got = self.session("not json\n", "\n", {"jsonrpc": "2.0", "id": 7, "method": "ping"},
                           {"jsonrpc": "2.0", "id": 8, "method": "tools/call",
                            "params": {"name": "get_context", "arguments": {}}},
                           {"jsonrpc": "2.0", "id": 9, "method": "ping"})
        self.assertEqual([g.get("id") for g in got], [None, 7, 8, 9])
        self.assertEqual(got[0]["error"]["code"], -32700)


class Asking:
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="megalooper-mcp-test-")
        self.fake = None
        self.remote = os.path.join(self.root, "remote.json")

    def tearDown(self):
        if self.fake:
            self.fake.close()
        shutil.rmtree(self.root, ignore_errors=True)

    def start(self, answers, **kw):
        self.fake = FakeMegalooper(self.root, answers, **kw)
        return self.fake

    def test_context_comes_back_whole_or_in_the_parts_asked_for(self):
        ctx = {"format": "megalooper context", "version": 1, "profile": "sa", "standalone": True,
               "tempo": 120, "loop": {"state": "playing"}, "drums": {"on": True}, "synth": {}, "chains": [],
               "aiChanges": 2}
        self.start({"context": {"ok": True, "result": ctx}})
        text, err = self.tool("get_context")
        self.assertEqual((json.loads(text), err), (ctx, False))
        text, err = self.tool("get_context", {"parts": ["drums"]})
        self.assertEqual(sorted(json.loads(text)),
                         sorted(["format", "version", "profile", "standalone", "tempo", "aiChanges", "drums"]))

    def test_describe_hands_over_the_topic(self):
        self.start({"describe": lambda args: {"ok": True, "result": {"asked": args["topic"]}}})
        text, err = self.tool("describe", {"topic": "drums"})
        self.assertEqual((json.loads(text), err), ({"asked": "drums"}, False))

    def test_changes_hand_their_arguments_over_as_they_are(self):
        self.start({c: (lambda c: lambda args: {"ok": True, "result": {"cmd": c, "args": args}})(c)
                    for c in SPEC["passedOn"]})
        cases = [
            ("set_drum_pattern", {"which": "break", "pattern": {"steps": {"chance": [None, [6]]}}, "kit": "core-808"}),
            ("set_synth", {"notes": {"root": 2}, "wave": {"x": 1}, "on": True}),
            ("set_chain", {"insert": [{"track": "loop", "type": "echo"}], "on": {"echo": False}}),
            ("revert", {"count": 2}), ("revert", {}),
            ("save_drum_preset", {"name": "x"}), ("save_synth_preset", {"name": "y", "overwrite": True}),
            ("save_sound", {"name": "z"}),
        ]
        for name, args in cases:
            text, err = self.tool(name, args)
            self.assertEqual((json.loads(text), err), ({"cmd": name, "args": args}, False), name)

    def test_the_request_goes_with_the_handshakes_token_and_its_files_are_cleared(self):
        fake = self.start({"context": {"ok": True, "result": {}}})
        self.tool("get_context")
        self.assertEqual(fake.heard[0][0], "/megalooper/remote")
        self.assertEqual(fake.heard[0][1][0], "t0ken")
        self.assertTrue(fake.heard[0][1][1].startswith("mcp-"))
        self.assertEqual(os.listdir(fake.dir), [])

    def test_a_refusal_is_the_tools_error(self):
        self.start({"describe": {"ok": False, "error": "no such topic"}})
        self.assertEqual(self.tool("describe", {"topic": "x"}), ("no such topic", True))

    def test_no_handshake_says_megalooper_is_not_running_or_shuts_apps_out(self):
        self.remote = os.path.join(self.root, "none.json")
        text, err = self.tool("get_context")
        self.assertTrue(err)
        self.assertIn("not running", text)
        self.assertIn("AI APPS", text)

    def test_a_handshake_left_by_a_megalooper_that_quit_says_so(self):
        dead = subprocess.Popen([sys.executable, "-c", "pass"])
        dead.wait()
        self.start({}, pid=dead.pid)
        text, err = self.tool("get_context")
        self.assertTrue(err)
        self.assertIn("quit", text)

    def test_no_answer_in_time_says_so_and_leaves_no_files(self):
        fake = self.start({"context": None})
        text, err = self.tool("get_context")
        self.assertTrue(err)
        self.assertIn("did not answer", text)
        self.assertEqual(os.listdir(fake.dir), [])

    def test_a_file_that_is_no_handshake_is_refused(self):
        with open(self.remote, "w") as f:
            f.write('{"format": "something else"}')
        text, err = self.tool("get_context")
        self.assertTrue(err)
        self.assertIn("not megalooper's handshake", text)


class PythonProtocol(Protocol, BridgeCase):
    bridge = "python"


class NodeProtocol(Protocol, BridgeCase):
    bridge = "node"


class PythonAsking(Asking, BridgeCase):
    bridge = "python"


class NodeAsking(Asking, BridgeCase):
    bridge = "node"


class Osc(unittest.TestCase):
    def test_osc_strings_are_padded_to_four_bytes(self):
        m = mcp.osc_message("/a", "xyz", "")
        self.assertEqual(m, b"/a\0\0" + b",ss\0" + b"xyz\0" + b"\0\0\0\0")
        self.assertEqual(osc_strings(mcp.osc_message("/megalooper/remote", "tok", "id-1")),
                         ("/megalooper/remote", ["tok", "id-1"]))

    @unittest.skipIf(NODE is None, "node is not installed")
    def test_the_node_bridge_makes_the_same_bytes(self):
        out = subprocess.run([NODE, "-e", "process.stdout.write(require(process.argv[1]).oscMessage("
                              "'/megalooper/remote', 'tok', 'id-1', '').toString('hex'))",
                              os.path.join(HERE, "mcpb", "server", "index.js")],
                             capture_output=True, text=True, check=True).stdout
        self.assertEqual(bytes.fromhex(out), mcp.osc_message("/megalooper/remote", "tok", "id-1", ""))


# ---- the extension ------------------------------------------------------------------------

class Extension(unittest.TestCase):
    def test_the_manifest_offers_the_tool_lists_tools_and_runs_the_bridge_with_claude_desktops_node(self):
        m = json.load(open(os.path.join(HERE, "mcpb", "manifest.json")))
        self.assertEqual(m["manifest_version"], "0.3")
        for key in ["name", "version", "description", "author", "server"]:
            self.assertIn(key, m)
        self.assertEqual(m["version"], SPEC["serverVersion"])
        self.assertEqual([t["name"] for t in m["tools"]], [t["name"] for t in SPEC["tools"]])
        self.assertEqual(m["server"]["type"], "node")
        self.assertEqual(m["server"]["entry_point"], "server/index.js")
        self.assertEqual(m["server"]["mcp_config"], {"command": "node", "args": ["${__dirname}/server/index.js"]})
        self.assertTrue(os.path.exists(os.path.join(HERE, "mcpb", m["icon"])))

    def test_the_bundle_holds_the_manifest_at_its_root_and_its_bridge_runs_from_inside_it(self):
        tmp = tempfile.mkdtemp(prefix="megalooper-mcpb-test-")
        try:
            out = os.path.join(tmp, "x.mcpb")
            subprocess.run([os.path.join(HERE, "make-mcpb.sh"), out], check=True, capture_output=True)
            with zipfile.ZipFile(out) as z:
                names = sorted(z.namelist())
                z.extractall(os.path.join(tmp, "x"))
            self.assertEqual([n for n in names if not n.endswith("/")],
                             ["icon.png", "manifest.json", "server/index.js", "server/mcp-tools.json"])
            if NODE:
                got = run_bridge([NODE, os.path.join(tmp, "x", "server", "index.js")],
                                 [{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}])
                self.assertEqual(got[0]["result"]["tools"], SPEC["tools"])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


# ---- the round trip against a real MegaRemote ----------------------------------------------

def find_sclang():
    for c in ["/Applications/SuperCollider.app/Contents/MacOS/sclang",
              os.path.expanduser("~/Applications/SuperCollider.app/Contents/MacOS/sclang"),
              shutil.which("sclang")]:
        if c and os.access(c, os.X_OK):
            return c
    return None


def native():
    """What runs SuperCollider natively. On Apple Silicon a child inherits its
    parent's architecture, and a python3 built for Intel would start sclang
    under Rosetta, where it never came up (as tools/make-app.sh found)."""
    if sys.platform == "darwin" and os.path.exists("/usr/bin/arch"):
        try:
            arm = subprocess.run(["/usr/sbin/sysctl", "-n", "hw.optional.arm64"], capture_output=True,
                                 text=True).stdout.strip() == "1"
        except OSError:
            arm = False
        if arm:
            return ["/usr/bin/arch", "-arm64"]
    return []


PEER = {}


def peer():
    """The peer's handshake, started once for every round trip; or why not."""
    if "handshake" in PEER or "why" in PEER:
        return PEER.get("handshake"), PEER.get("why")
    PEER["tmp"] = tmp = tempfile.mkdtemp(prefix="megalooper-mcp-peer-")
    PEER["stop"] = os.path.join(tmp, "stop")
    ready = os.path.join(tmp, "ready")
    cmd = native() + [find_sclang(), "-u", str(58100 + random.randrange(800))]
    if os.environ.get("MEGALOOPER_SCLANG_CONF"):
        cmd += ["-l", os.environ["MEGALOOPER_SCLANG_CONF"]]
    cmd += [os.path.join(REPO, "scripts", "tests", "remote-peer.scd"), PEER["stop"], ready]
    PEER["log"] = open(os.path.join(tmp, "sclang.log"), "w")
    PEER["proc"] = subprocess.Popen(cmd, stdout=PEER["log"], stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline and PEER["proc"].poll() is None:
        if os.path.exists(ready):
            with open(ready) as f:
                text = f.read()
            if text.endswith("remote.json") and os.path.exists(text):
                PEER["handshake"] = text
                return text, None
        time.sleep(0.1)
    with open(os.path.join(tmp, "sclang.log")) as f:
        PEER["why"] = "the peer did not come up:\n" + f.read()[-3000:]
    return None, PEER["why"]


def tearDownModule():
    if "proc" in PEER:
        open(PEER["stop"], "w").close()
        try:
            PEER["proc"].wait(30)
        except subprocess.TimeoutExpired:
            print("the peer sclang (pid %d) did not exit; it was left running" % PEER["proc"].pid, file=sys.stderr)
        PEER["log"].close()
        shutil.rmtree(PEER["tmp"], ignore_errors=True)


class RoundTrip:
    """A bridge against a real MegaRemote, over OSC."""
    reply_timeout = "10"

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        if find_sclang() is None:
            raise unittest.SkipTest("sclang is not installed")

    def setUp(self):
        handshake, why = peer()
        if why:
            self.fail(why)
        self.remote = handshake

    def test_the_handshake_is_the_peers_not_yours(self):
        self.assertNotEqual(os.path.realpath(self.remote),
                            os.path.realpath(os.path.join(mcp.user_root(), "remote.json")))
        with open(self.remote) as f:
            self.assertEqual(json.load(f)["pid"], PEER["proc"].pid)

    def test_context_over_osc(self):
        text, err = self.tool("get_context")
        self.assertFalse(err, text)
        ctx = json.loads(text)
        self.assertEqual(ctx["loop"]["reading"]["signature"], "7+7+7+8/8")
        self.assertEqual(ctx["loop"]["reading"]["bars"], [7, 7, 7, 8])
        self.assertEqual(len(ctx["drums"]["patterns"]["main"]["steps"]["chance"]), 4)
        self.assertEqual(ctx["chains"][0]["track"], "guitar")
        self.assertIn("lanes", ctx["synth"]["notes"])
        take = ctx["loop"]["take"]
        self.assertEqual(take["sixteenthsPerBar"], [14, 14, 14, 16])
        self.assertEqual([b["grid"][0] for b in take["bars"]], ["X", "x", ".", "."])

    def test_describe_over_osc(self):
        for topic in ["drums", "synth", "effects"]:
            text, err = self.tool("describe", {"topic": topic})
            self.assertFalse(err, text)
            self.assertIn("about", json.loads(text))

    def test_a_drum_change_over_osc_and_back(self):
        before = json.loads(self.tool("get_context", {"parts": ["drums"]})[0])["drums"]["patterns"]["main"]
        text, err = self.tool("set_drum_pattern", {"pattern": {"steps": {"chance": [None, [6, 0, 6, 9]]}}})
        self.assertFalse(err, text)
        got = json.loads(text)
        self.assertEqual(got["pattern"]["steps"]["chance"][1][:4], [6, 0, 6, 6])
        self.assertEqual(len(got["corrections"]), 1)
        self.assertEqual(got["pattern"]["steps"]["chance"][0], before["steps"]["chance"][0])
        self.assertFalse(self.tool("revert")[1])
        after = json.loads(self.tool("get_context", {"parts": ["drums"]})[0])["drums"]["patterns"]["main"]
        self.assertEqual(after, before)

    def test_a_synth_change_over_osc_and_back(self):
        before = json.loads(self.tool("get_context", {"parts": ["synth"]})[0])["synth"]
        text, err = self.tool("set_synth", {"notes": {"lanes": {"pitch": {"values": [0, 3, 7]}}, "swing": 5}, "on": True})
        self.assertFalse(err, text)
        got = json.loads(text)
        self.assertEqual(got["notes"]["lanes"]["pitch"]["values"][:3], [0, 3, 7])
        self.assertEqual((got["notes"]["swing"], got["on"]), (1.0, True))
        self.assertEqual(len(got["corrections"]), 1)
        self.assertFalse(self.tool("revert")[1])
        self.assertEqual(json.loads(self.tool("get_context", {"parts": ["synth"]})[0])["synth"], before)

    def test_a_chain_change_over_osc_and_back(self):
        before = json.loads(self.tool("get_context", {"parts": ["chains"]})[0])["chains"]
        guitar = before[0]["devices"][0]
        text, err = self.tool("set_chain", {"settings": {guitar["id"]: {"shifterCoarse": 99}},
                                            "on": {guitar["id"]: not guitar["on"]}})
        self.assertFalse(err, text)
        got = json.loads(text)
        self.assertEqual(got["chains"][0]["devices"][0]["settings"]["shifterCoarse"], 24)
        self.assertEqual(got["chains"][0]["devices"][0]["on"], not guitar["on"])
        self.assertEqual(len(got["corrections"]), 1)
        self.assertRegex(got["corrections"][0], r"^%s\.shifterCoarse 99 -> 24(\.0)?$" % guitar["id"])
        text, err = self.tool("set_chain", {"remove": ["nothing"]})
        self.assertTrue(err)
        self.assertIn("no device nothing", text)
        self.assertFalse(self.tool("revert")[1])
        self.assertEqual(json.loads(self.tool("get_context", {"parts": ["chains"]})[0])["chains"], before)

    def test_several_asks_in_a_row(self):
        got = self.session(*[{"jsonrpc": "2.0", "id": i, "method": "tools/call",
                              "params": {"name": "describe", "arguments": {"topic": "drums"}}} for i in range(5)])
        self.assertEqual([(g["id"], g["result"]["isError"]) for g in got], [(i, False) for i in range(5)])


class PythonRoundTrip(RoundTrip, BridgeCase):
    bridge = "python"


class NodeRoundTrip(RoundTrip, BridgeCase):
    bridge = "node"


if __name__ == "__main__":
    unittest.main(verbosity=2)
