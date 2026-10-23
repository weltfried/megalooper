#!/usr/bin/env python3
"""Checks tools/megalooper-mcp.py, the bridge between an AI app and megalooper.

    python3 tools/test-megalooper-mcp.py

The MCP side (initialize, the tools, errors) and the asking side against a
stand-in megalooper in this process; then, when sclang is there, the real
round trip: scripts/tests/remote-peer.scd runs a MegaRemote in a scratch
folder of its own, on a UDP port far from megalooper's, and the bridge asks
it over OSC. A megalooper playing beside it is never asked: the peer's
handshake is not yours, and the bridge is pointed at it.

MEGALOOPER_SCLANG_CONF names an sclang configuration file (sclang -l) when
the classes to check are not the ones linked into Extensions, as
tools/run-checks.sh has it.
"""
import importlib.util
import io
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

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

spec = importlib.util.spec_from_file_location("megalooper_mcp", os.path.join(HERE, "megalooper-mcp.py"))
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)


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


def call(method, params=None, mid=1):
    msg = {"jsonrpc": "2.0", "id": mid, "method": method}
    if params is not None:
        msg["params"] = params
    return mcp.handle(msg)


def tool(name, arguments=None):
    r = call("tools/call", {"name": name, "arguments": arguments or {}})["result"]
    return r["content"][0]["text"], r["isError"]


class Protocol(unittest.TestCase):
    def test_initialize_answers_the_clients_revision_when_it_has_it(self):
        r = call("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                "clientInfo": {"name": "t", "version": "1"}})["result"]
        self.assertEqual(r["protocolVersion"], "2025-03-26")
        self.assertEqual(r["serverInfo"]["name"], "megalooper")
        self.assertIn("tools", r["capabilities"])
        self.assertIn("get_context", r["instructions"])

    def test_initialize_offers_its_newest_for_one_it_does_not_know(self):
        r = call("initialize", {"protocolVersion": "1999-01-01"})["result"]
        self.assertEqual(r["protocolVersion"], mcp.PROTOCOL_VERSIONS[0])

    def test_tools_are_listed_with_schemas_and_say_which_change_things(self):
        tools = call("tools/list")["result"]["tools"]
        self.assertEqual([t["name"] for t in tools],
                         ["get_context", "describe", "set_drum_pattern", "set_synth", "revert",
                          "save_synth_preset", "save_drum_preset"])
        for t in tools:
            self.assertEqual(t["inputSchema"]["type"], "object")
        self.assertEqual({t["name"] for t in tools if t["annotations"]["readOnlyHint"]}, {"get_context", "describe"})
        self.assertEqual({t["name"] for t in tools if t["annotations"].get("destructiveHint")}, {"save_drum_preset", "save_synth_preset"})

    def test_notifications_get_no_answer_and_ping_an_empty_one(self):
        self.assertIsNone(mcp.handle({"jsonrpc": "2.0", "method": "notifications/initialized"}))
        self.assertEqual(call("ping")["result"], {})

    def test_unknown_methods_and_tools_are_errors(self):
        self.assertEqual(call("resources/list")["error"]["code"], -32601)
        self.assertEqual(call("tools/call", {"name": "play_louder"})["error"]["code"], -32602)
        self.assertEqual(mcp.handle({"id": 3})["error"]["code"], -32600)

    def test_serve_reads_lines_and_survives_bad_ones(self):
        lines = "\n".join([
            "not json",
            json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}),
            "",
            json.dumps({"jsonrpc": "2.0", "id": 7, "method": "ping"}),
        ]) + "\n"
        out = io.StringIO()
        mcp.serve(io.StringIO(lines), out)
        got = [json.loads(x) for x in out.getvalue().splitlines()]
        self.assertEqual([g.get("id") for g in got], [None, 7])
        self.assertEqual(got[0]["error"]["code"], -32700)

    def test_osc_strings_are_padded_to_four_bytes(self):
        m = mcp.osc_message("/a", "xyz", "")
        self.assertEqual(m, b"/a\0\0" + b",ss\0" + b"xyz\0" + b"\0\0\0\0")
        self.assertEqual(osc_strings(mcp.osc_message("/megalooper/remote", "tok", "id-1")),
                         ("/megalooper/remote", ["tok", "id-1"]))


class Asking(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="megalooper-mcp-test-")
        self.fake = None
        self.was = os.environ.get("MEGALOOPER_REMOTE")
        self.timeout = mcp.REPLY_TIMEOUT
        mcp.REPLY_TIMEOUT = 0.5

    def tearDown(self):
        if self.fake:
            self.fake.close()
        mcp.REPLY_TIMEOUT = self.timeout
        if self.was is None:
            os.environ.pop("MEGALOOPER_REMOTE", None)
        else:
            os.environ["MEGALOOPER_REMOTE"] = self.was
        shutil.rmtree(self.root, ignore_errors=True)

    def start(self, answers, **kw):
        self.fake = FakeMegalooper(self.root, answers, **kw)
        os.environ["MEGALOOPER_REMOTE"] = self.fake.handshake
        return self.fake

    def test_context_comes_back_whole_or_in_the_parts_asked_for(self):
        ctx = {"format": "megalooper context", "version": 1, "profile": "sa", "standalone": True,
               "tempo": 120, "loop": {"state": "playing"}, "drums": {"on": True}, "synth": {}, "chains": []}
        self.start({"context": {"ok": True, "result": ctx}})
        text, err = tool("get_context")
        self.assertFalse(err)
        self.assertEqual(json.loads(text), ctx)
        text, err = tool("get_context", {"parts": ["drums"]})
        self.assertEqual(sorted(json.loads(text)), sorted(["format", "version", "profile", "standalone", "tempo", "drums"]))
        ctx["aiChanges"] = 2
        self.assertEqual(json.loads(tool("get_context", {"parts": ["loop"]})[0])["aiChanges"], 2)

    def test_describe_hands_over_the_topic(self):
        self.start({"describe": lambda args: {"ok": True, "result": {"asked": args["topic"]}}})
        text, err = tool("describe", {"topic": "drums"})
        self.assertEqual((json.loads(text), err), ({"asked": "drums"}, False))

    def test_the_request_goes_with_the_handshakes_token_and_its_files_are_cleared(self):
        fake = self.start({"context": {"ok": True, "result": {}}})
        tool("get_context")
        self.assertEqual(fake.heard[0][0], "/megalooper/remote")
        self.assertEqual(fake.heard[0][1][0], "t0ken")
        self.assertTrue(fake.heard[0][1][1].startswith("mcp-"))
        self.assertEqual(os.listdir(fake.dir), [])

    def test_changes_hand_their_arguments_over_as_they_are(self):
        self.start({c: (lambda c: lambda args: {"ok": True, "result": {"cmd": c, "args": args}})(c)
                    for c in mcp.PASSED_ON})
        given = {"which": "break", "pattern": {"steps": {"chance": [None, [6]]}}, "kit": "core-808"}
        text, err = tool("set_drum_pattern", given)
        self.assertEqual((json.loads(text), err), ({"cmd": "set_drum_pattern", "args": given}, False))
        self.assertEqual(json.loads(tool("revert", {"count": 2})[0])["args"], {"count": 2})
        self.assertEqual(json.loads(tool("revert")[0])["args"], {})
        self.assertEqual(json.loads(tool("save_drum_preset", {"name": "x"})[0])["args"], {"name": "x"})
        given = {"notes": {"root": 2}, "wave": {"x": 1}, "on": True}
        self.assertEqual(json.loads(tool("set_synth", given)[0])["args"], given)
        self.assertEqual(json.loads(tool("save_synth_preset", {"name": "y", "overwrite": True})[0])["args"],
                         {"name": "y", "overwrite": True})

    def test_a_refusal_is_the_tools_error(self):
        self.start({"describe": {"ok": False, "error": "no such topic"}})
        self.assertEqual(tool("describe", {"topic": "x"}), ("no such topic", True))

    def test_no_handshake_says_megalooper_is_not_running(self):
        os.environ["MEGALOOPER_REMOTE"] = os.path.join(self.root, "none.json")
        text, err = tool("get_context")
        self.assertTrue(err)
        self.assertIn("not running", text)

    def test_a_handshake_left_by_a_megalooper_that_quit_says_so(self):
        dead = subprocess.Popen([sys.executable, "-c", "pass"])
        dead.wait()
        self.start({}, pid=dead.pid)
        text, err = tool("get_context")
        self.assertTrue(err)
        self.assertIn("quit", text)

    def test_no_answer_in_time_says_so_and_leaves_no_files(self):
        fake = self.start({"context": None})
        text, err = tool("get_context")
        self.assertTrue(err)
        self.assertIn("did not answer", text)
        self.assertEqual(os.listdir(fake.dir), [])

    def test_a_file_that_is_no_handshake_is_refused(self):
        path = os.path.join(self.root, "remote.json")
        with open(path, "w") as f:
            f.write('{"format": "something else"}')
        os.environ["MEGALOOPER_REMOTE"] = path
        text, err = tool("get_context")
        self.assertTrue(err)
        self.assertIn("not megalooper's handshake", text)


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


@unittest.skipIf(find_sclang() is None, "sclang is not installed")
class RoundTrip(unittest.TestCase):
    """The bridge against a real MegaRemote, over OSC."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="megalooper-mcp-peer-")
        cls.stop = os.path.join(cls.tmp, "stop")
        ready = os.path.join(cls.tmp, "ready")
        cmd = native() + [find_sclang(), "-u", str(58100 + random.randrange(800))]
        if os.environ.get("MEGALOOPER_SCLANG_CONF"):
            cmd += ["-l", os.environ["MEGALOOPER_SCLANG_CONF"]]
        cmd += [os.path.join(REPO, "scripts", "tests", "remote-peer.scd"), cls.stop, ready]
        cls.log = open(os.path.join(cls.tmp, "sclang.log"), "w")
        cls.peer = subprocess.Popen(cmd, stdout=cls.log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        deadline = time.monotonic() + 120
        cls.handshake = None
        while time.monotonic() < deadline and cls.peer.poll() is None:
            if os.path.exists(ready):
                with open(ready) as f:
                    text = f.read()
                if text.endswith("remote.json") and os.path.exists(text):
                    cls.handshake = text
                    break
            time.sleep(0.1)
        cls.was = os.environ.get("MEGALOOPER_REMOTE")
        if cls.handshake:
            os.environ["MEGALOOPER_REMOTE"] = cls.handshake

    @classmethod
    def tearDownClass(cls):
        open(cls.stop, "w").close()
        try:
            cls.peer.wait(30)
        except subprocess.TimeoutExpired:
            print("the peer sclang (pid %d) did not exit; it was left running" % cls.peer.pid, file=sys.stderr)
        cls.log.close()
        if cls.was is None:
            os.environ.pop("MEGALOOPER_REMOTE", None)
        else:
            os.environ["MEGALOOPER_REMOTE"] = cls.was
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def setUp(self):
        if not self.handshake:
            with open(os.path.join(self.tmp, "sclang.log")) as f:
                self.fail("the peer did not come up:\n" + f.read()[-3000:])

    def test_the_handshake_is_the_peers_not_yours(self):
        self.assertNotEqual(os.path.realpath(self.handshake), os.path.realpath(
            os.path.join(mcp.user_root(), "remote.json")))
        with open(self.handshake) as f:
            hs = json.load(f)
        self.assertEqual(hs["pid"], self.peer.pid)

    def test_context_over_osc(self):
        text, err = tool("get_context")
        self.assertFalse(err, text)
        ctx = json.loads(text)
        self.assertEqual(ctx["loop"]["reading"]["signature"], "7+7+7+8/8")
        self.assertEqual(ctx["loop"]["reading"]["bars"], [7, 7, 7, 8])
        self.assertEqual(len(ctx["drums"]["patterns"]["main"]["steps"]["chance"]), 4)
        self.assertEqual(ctx["chains"][0]["track"], "guitar")
        self.assertIn("lanes", ctx["synth"]["notes"])

    def test_describe_over_osc(self):
        for topic in ["drums", "synth", "effects"]:
            text, err = tool("describe", {"topic": topic})
            self.assertFalse(err, text)
            self.assertIn("about", json.loads(text))

    def test_a_drum_change_over_osc_and_back(self):
        before = json.loads(tool("get_context", {"parts": ["drums"]})[0])["drums"]["patterns"]["main"]
        text, err = tool("set_drum_pattern", {"pattern": {"steps": {"chance": [None, [6, 0, 6, 9]]}}})
        self.assertFalse(err, text)
        got = json.loads(text)
        self.assertEqual(got["pattern"]["steps"]["chance"][1][:4], [6, 0, 6, 6])
        self.assertEqual(len(got["corrections"]), 1)
        self.assertEqual(got["pattern"]["steps"]["chance"][0], before["steps"]["chance"][0])
        text, err = tool("revert")
        self.assertFalse(err, text)
        after = json.loads(tool("get_context", {"parts": ["drums"]})[0])["drums"]["patterns"]["main"]
        self.assertEqual(after, before)

    def test_a_synth_change_over_osc_and_back(self):
        before = json.loads(tool("get_context", {"parts": ["synth"]})[0])["synth"]
        text, err = tool("set_synth", {"notes": {"lanes": {"pitch": {"values": [0, 3, 7]}}, "swing": 5}, "on": True})
        self.assertFalse(err, text)
        got = json.loads(text)
        self.assertEqual(got["notes"]["lanes"]["pitch"]["values"][:3], [0, 3, 7])
        self.assertEqual((got["notes"]["swing"], got["on"]), (1.0, True))
        self.assertEqual(len(got["corrections"]), 1)
        self.assertFalse(tool("revert")[1])
        after = json.loads(tool("get_context", {"parts": ["synth"]})[0])["synth"]
        self.assertEqual(after, before)

    def test_several_asks_in_a_row(self):
        for _ in range(5):
            self.assertFalse(tool("describe", {"topic": "drums"})[1])


if __name__ == "__main__":
    unittest.main(verbosity=2)
