// megalooper — assertion harness for the headless test suite.
//
// Loaded by run-tests.scd, and auto-loaded by each test file, so any single
// test file can also just be evaluated on its own from the IDE.
//
// Two sclang facts shape everything here:
//
//   1. An unhandled throw means the script's `0.exit` is never reached, and
//      sclang then IDLES FOREVER. Its stdout is block-buffered when redirected,
//      so a headless run that throws produces a hang and NO OUTPUT AT ALL —
//      not a stack trace. That is why ~tCheck wraps every call into the code
//      under test, and why the runner protects each file.
//   2. `var` declarations must precede every other statement in a block, so
//      nothing here declares one at file level; the harness is all ~globals.

// ------------------------------------------------- the default server -------
// Code under test that names no server reaches Server.default: Group.tail(nil),
// Synth(\x) with no target, Buffer.alloc(nil, ...). In sclang the default is
// 127.0.0.1:57110, which is a RUNNING megalooper's scsynth whenever one plays on
// this Mac; running sclang on a far -u port or with another class path changes
// nothing about where those messages go. A test that built the drums on a nil
// group freed nodes 1000-1004 there, the meters, the guitar chain with its
// plugin, the mixer and the drum group, and silenced the instrument mid-set
// (2026-10-10). So the default server of every test run is one at an address
// nothing listens on (the discard port, 9), and run-tests.scd fails, by name,
// any test file that makes a node on it. A test file evaluated on its own in
// the IDE gets the same; ~tRestoreServer.() gives the IDE its server back.
if(~tTrapServer.isNil or: { Server.default !== ~tTrapServer }) {
    ~tServerBefore = ~tServerBefore ? Server.default;
    ~tTrapServer = Server.named[\megalooperTestTrap] ?? {
        Server(\megalooperTestTrap, NetAddr("127.0.0.1", 9), ServerOptions.new)
    };
    Server.default = ~tTrapServer;
    ~tRestoreServer = { ~tServerBefore !? { |srv| Server.default = srv } };
};

// --------------------------------------------------- the user's files -------
// Code under test that names no folder reaches MegaFiles.userRoot: your
// Application Support folder, with your MIDI maps and your kept sound. So
// every test run moves it to a scratch folder of this process's own, and
// test-megafiles.scd asserts that it did. A test file evaluated on its own in
// the IDE gets the same; ~tRestoreServer.() gives the IDE its folder back
// too.
if(MegaFiles.rootOverride.isNil or: { MegaFiles.rootOverride != ~tTrapRoot }) {
    ~tRootBefore = MegaFiles.rootOverride;
    ~tTrapRoot = ~tTrapRoot ?? { PathName.tmp +/+ ("megalooper-test-root-" ++ thisProcess.pid) };
    MegaFiles.rootOverride = ~tTrapRoot;
};
~tRestoreServer = {
    ~tServerBefore !? { |srv| Server.default = srv };
    MegaFiles.rootOverride = ~tRootBefore;
};

// ---------------------------------------------------------------- state ------

// failures/xpasses keep their lines so the summary can repeat them at the end,
// after a long run has scrolled the detail off the top.
~tState = (
    pass: 0, fail: 0, xfail: 0, xpass: 0, skip: 0,
    file: "-", failures: List.new, xpasses: List.new, skips: List.new
);

~tReset = {
    ~tState[\pass] = 0; ~tState[\fail] = 0;
    ~tState[\xfail] = 0; ~tState[\xpass] = 0; ~tState[\skip] = 0;
    ~tState[\file] = "-";
    ~tState[\failures] = List.new;
    ~tState[\xpasses] = List.new;
    ~tState[\skips] = List.new;
};

~tFile = { |name|
    ~tState[\file] = name;
    ("== " ++ name).postln;
};

// ----------------------------------------------------------- assertions -----

~tPass = { |label|
    ~tState[\pass] = ~tState[\pass] + 1;
    ("  ok    " ++ label).postln;
};

~tFail = { |label, detail|
    var line = ~tState[\file] ++ ": " ++ label
        ++ (detail !? { |d| " — " ++ d } ? "");
    ~tState[\fail] = ~tState[\fail] + 1;
    ~tState[\failures].add(line);
    ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
};

~tAssert = { |label, cond, detail|
    if(cond == true) { ~tPass.(label) } { ~tFail.(label, detail) };
};

~tEq = { |label, got, want|
    ~tAssert.(label, got == want, "got " ++ got ++ ", want " ++ want);
};

~tNear = { |label, got, want, tol = 1e-9|
    var ok = got.isNumber and: { (got - want).abs <= tol };
    ~tAssert.(label, ok,
        "got " ++ got ++ ", want " ++ want ++ " +/- " ++ tol);
};

// Deep-ish comparison for the nested [[time, strength], ...] arrays: == on
// Arrays of Arrays is elementwise in sclang, but a size mismatch or a nil
// would compare false with no hint of WHY, so this reports both sides.
~tEqArray = { |label, got, want, tol = 1e-9|
    var ok = got.isArray and: { got.size == want.size };
    if(ok) {
        ok = got.flat.size == want.flat.size and: {
            got.flat.every { |v, i| (v - want.flat[i]).abs <= tol }
        };
    };
    ~tAssert.(label, ok, "got " ++ got ++ ", want " ++ want);
};

// Runs `fn` and asserts it does NOT throw. Returns fn's value, or nil if it
// did — so a test can keep going and report one failure rather than taking the
// whole file down with it.
~tCheck = { |label, fn|
    var out, threw = false, why;
    out = try { fn.value } { |err|
        threw = true;
        why = err.class.asString ++ ": " ++ (err.errorString ? "?");
        nil
    };
    ~tAssert.(label, threw.not, why);
    out
};

// The mirror image: asserts `fn` DOES throw. Used where refusing bad input is
// the documented behaviour and quietly accepting it would be the bug.
~tThrows = { |label, fn|
    var threw = false;
    try { fn.value } { threw = true };
    ~tAssert.(label, threw, "expected a throw, got none");
};

// A defect we know about and have decided not to fix yet. `stillBroken` states
// the CURRENT (wrong) behaviour, so the suite stays green while the bug is on
// the record. If it ever stops being true the run says so loudly — an accident-
// ally fixed bug should not keep a stale test — but does NOT fail the build,
// because "something got better" must never block a commit before a gig.
~tXfail = { |label, stillBroken, note|
    if(stillBroken == true) {
        ~tState[\xfail] = ~tState[\xfail] + 1;
        ("  known " ++ label ++ (note !? { |n| " — " ++ n } ? "")).postln;
    } {
        ~tState[\xpass] = ~tState[\xpass] + 1;
        ~tState[\xpasses].add(~tState[\file] ++ ": " ++ label);
        ("  XPASS " ++ label ++ " — known issue no longer reproduces, "
            ++ "update the test").postln;
    };
};

// A part that could not run here, and why: neither a pass nor a failure, but
// counted and said again in the summary, so a run that skipped a test can't
// read as one that passed it. Where skipping would be a bug (a headless run,
// say), the test fails instead.
~tSkip = { |label, why|
    ~tState[\skip] = (~tState[\skip] ? 0) + 1;
    ~tState[\skips] = (~tState[\skips] ? List.new).add(~tState[\file] ++ ": " ++ label
        ++ (why !? { |w| " — " ++ w } ? ""));
    ("  skip  " ++ label ++ (why !? { |w| " — " ++ w } ? "")).postln;
};

// ------------------------------------------------------------- fixtures -----

// A Looper with NO server, NO buffers, NO OSCdefs and NO SynthDefs.
//
// newCopyArgs builds the instance without running init, and sclang still
// applies the class's declared instance-variable defaults — so this is a real
// Looper carrying exactly the values it boots with, minus everything that needs
// scsynth. That is what makes the pure half of the class unit-testable at all.
//
// The collections init would have created are made here because several methods
// append to them, and initBBCut is called because it only builds the proc-spec
// tables (no server contact) and every BBCut method reads them.
~tLooper = { |sampleRate = 48000|
    var l = Looper.newCopyArgs;
    l.instVarPut(\server, ~tStubServer.(sampleRate));
    l.instVarPut(\state, \empty);
    l.instVarPut(\onsets, List.new);
    l.instVarPut(\pitchSamples, List.new);
    l.instVarPut(\overdubOnsets, List.new);
    l.initBBCut;
    l
};

// Events answer any selector by key lookup, so a one-key Event is the whole
// stub the sample-rate-only methods need — and `server.notNil` still holds,
// which several guards test before dividing by the rate.
//
// It also RECORDS. `Node:set` and `Node:free` are nothing but
// `server.sendMsg(15|11, nodeID, …)`, so a Synth bound to this stub is a REAL
// Synth whose every write is captured in `[\msgs]` instead of going to scsynth.
// That is what makes the levels the model applies — and the master break gate,
// which test-break.scd had to call unobservable — readable with no server. See
// ~tStubSynth / ~tLastSet below and test-gesture-fuzz.scd for the use.
//
// Timestamped sends are recorded too, for Megalooper SA's drum scheduler, which
// sends everything it plays as bundles: `[\bundles]` holds [absolute time,
// [msg, msg, ...]] per sendBundle, the time being the SENDER's logical time
// (thisThread.seconds) plus the bundle's delta, exactly what scsynth would
// play it at. A nil delta (Bus:set sends one) records at the sender's time.
// Every test that asserts on bundles must first assert there are some: an
// Event answers nil to any selector it has no key for, so a scheduler talking
// to a stub that lacked one would pass every check on nothing.
//
// For the same scheduler: `latency` (0.2, Server's default); `sync`, which
// returns at once, so code that syncs runs straight through in a Routine
// stepped with .next; `options`, a default ServerOptions (blockSize 64 and
// the bus counts); real allocators, so Bus.control(stub, n) and
// Bus.audio(stub, n) answer distinct indices (audio from 4, past the default
// hardware busses), and nextBufferNumber, for Buffer.alloc. listSendMsg and
// listSendBundle record like their siblings. nextNodeID stays 1000, as the
// fixtures below expect; voices a test needs apart are sent with node -1.
//
// And `[\writes]`: every message of both kinds, in the order sent, as [the
// time scsynth would carry it out, msg] (a message at its sender's time, a
// bundle's at its stamp), for what a server would hold once all are carried
// out (~tLastSet): the Looper's break gate reopens on a bundle 20 ms on.
~tStubServer = { |sampleRate = 48000|
    var msgs = List.new, bundles = List.new, writes = List.new;
    var srv  = (sampleRate: sampleRate, msgs: msgs, bundles: bundles, writes: writes, latency: 0.2,
        options: ServerOptions.new,
        controlBusAllocator: ContiguousBlockAllocator(16384),
        audioBusAllocator: ContiguousBlockAllocator(1020, 0, 4),
        bufferAllocator: ContiguousBlockAllocator(1024));
    srv[\sendMsg]    = { |self ... args| msgs.add(args); writes.add([thisThread.seconds, args]); self };
    srv[\listSendMsg] = { |self, msg| msgs.add(msg); writes.add([thisThread.seconds, msg]); self };
    srv[\sendBundle] = { |self, time ... args|
        var at = thisThread.seconds + (time ? 0);
        bundles.add([at, args]);
        args.do { |m| writes.add([at, m]) };
        self };
    srv[\listSendBundle] = { |self, time, list|
        var at = thisThread.seconds + (time ? 0);
        bundles.add([at, list.asArray]);
        list.do { |m| writes.add([at, m]) };
        self };
    srv[\sync] = { |self| self };
    srv[\nextNodeID] = { |self| 1000 };
    srv[\nextBufferNumber] = { |self, n = 1| self[\bufferAllocator].alloc(n) };
    srv
};

// A Synth object bound to a looper's stub server. `Synth.basicNew` builds the
// language-side object WITHOUT sending an s_new — the same trick newCopyArgs
// plays on Looper itself — so this needs no booted server and no SynthDef.
~tStubSynth = { |looper, defName = \stub|
    var srv = ~tGet.(looper, \server);
    var id  = (srv[\lastNodeID] ? 1000) + 1;
    srv[\lastNodeID] = id;
    Synth.basicNew(defName, srv, id)
};

// The value the model left `key` at on `synth`, as the server holds it once
// every write sent is carried out: the last by the time scsynth carries it out
// (of two at one time, the later sent), from the stub's `writes`; or nil if it
// never wrote one. 15 is /n_set; the pairs after the node ID are the key/value
// list. A stub whose sendMsg a test replaced keeps no `writes` for those
// messages: then `msgs`, in the order sent.
~tLastSet = { |looper, synth, key|
    var srv   = ~tGet.(looper, \server);
    var log   = srv[\writes] ?? { srv[\msgs].collect { |m| [0, m] } };
    var id    = synth !? { |s| s.nodeID };
    var found = nil, foundAt = inf.neg;
    if(id.notNil) {
        log.do { |w|
            var m = w[1];
            if((m[0] == 15) and: { m[1] == id } and: { w[0] >= foundAt }) {
                m.copyToEnd(2).pairsDo { |k, v| if(k == key) { found = v; foundAt = w[0] } };
            };
        };
    };
    found
};

// ------------------------------------------------------ MegaSA fixtures -----

// Make a stub number its nodes in order, from `from` up, so the tree it was
// sent can be rebuilt (~tNodeTree) and two synths are never mistaken for one.
// The stub as it comes keeps nextNodeID at 1000 for the fixtures above.
~tCountIds = { |srv, from = 2000|
    srv[\lastNodeID] = from - 1;
    srv[\nextNodeID] = { |self|
        var id = (self[\lastNodeID] ? (from - 1)) + 1;
        self[\lastNodeID] = id;
        id
    };
    srv
};

// The node commands by name, for messages sent with a Symbol ('/n_set',
// \n_free) rather than scsynth's number.
~tOscNum = (s_new: 9, n_free: 11, n_run: 12, n_set: 15, n_before: 18, n_after: 19,
    g_new: 21, g_head: 22, g_tail: 23, g_freeAll: 24, g_deepFree: 50);

// The node tree a server would hold once everything sent to the stub is
// carried out, in the order scsynth would carry it out (its `writes`: a
// message at its sender's time, a bundle's at its stamp, sent order breaking
// ties), or in the order sent when a test replaced the stub's sendMsg. Knows
// what MegaSA and the drums send: s_new and g_new with every add action
// (0 head, 1 tail, 2 before, 3 after, 4 replace), n_free, n_run, n_before,
// n_after, g_head, g_tail, g_freeAll and g_deepFree. The root is 0 and holds
// the default group, 1. Answers an Event:
//   children   node -> List of its children, in order (synths have none)
//   parent     node -> its group
//   paused     the nodes an n_run 0 left paused
//   defs       synth -> its SynthDef's name
//   order      { |group| } every node below `group`, in the order a block
//              runs them (depth first)
//   ancestors  { |node| } its groups, nearest first, up to the root
~tNodeTree = { |srv|
    var log = srv[\writes] ?? { srv[\msgs].collect { |m| [0, m] } };
    var children = IdentityDictionary[0 -> List[1], 1 -> List.new];
    var parent = IdentityDictionary[1 -> 0];
    var paused = IdentitySet.new, defs = IdentityDictionary.new;
    var numOf, detach, place, freeTree, sorted, order, ancestors;
    numOf = { |c| if(c.isNumber) { c } { ~tOscNum[c.asString.replace("/", "").asSymbol] } };
    detach = { |id|
        var p = parent[id];
        p !? { children[p] !? { |l| l.remove(id) } };
        parent.removeAt(id);
    };
    freeTree = { |id|
        var kids = (children[id] ? []).copy;
        kids.do { |c| freeTree.(c) };
        children.removeAt(id);
        detach.(id);
        paused.remove(id);
        defs.removeAt(id);
    };
    // Put `id` (already detached) where `action` says relative to `target`.
    place = { |id, action, target|
        var siblings, at, p;
        if(action < 2) {
            siblings = children[target] ?? { children.put(target, List.new); children[target] };
            if(action == 0) { siblings.insert(0, id) } { siblings.add(id) };
            parent.put(id, target);
        } {
            p = parent[target];
            siblings = p !? { children[p] };
            if(siblings.notNil) {
                at = siblings.indexOf(target) ? siblings.size;
                if(action == 4) {
                    siblings.insert(at, id);
                    parent.put(id, p);
                    freeTree.(target);
                } {
                    siblings.insert(at + (action - 2).clip(0, 1), id);
                    parent.put(id, p);
                };
            };
        };
    };
    sorted = log.asArray.collect { |w, i| [w[0] ? 0, i, w[1]] }
        .sort { |a, b| (a[0] < b[0]) or: { (a[0] == b[0]) and: { a[1] < b[1] } } };
    sorted.do { |row|
        var m = row[2], cmd = numOf.(m[0]);
        case
        { cmd == 9 } { defs.put(m[2], m[1].asSymbol); detach.(m[2]); place.(m[2], m[3], m[4]) }
        { cmd == 21 } { m.copyToEnd(1).clump(3).do { |t|
            children.put(t[0], List.new); detach.(t[0]); place.(t[0], t[1], t[2]) } }
        { cmd == 11 } { m.copyToEnd(1).do { |id| freeTree.(id) } }
        { cmd == 12 } { m.copyToEnd(1).pairsDo { |id, flag|
            if(flag == 0) { paused.add(id) } { paused.remove(id) } } }
        { (cmd == 18) or: { cmd == 19 } } { m.copyToEnd(1).pairsDo { |a, b|
            if(parent[b].notNil) { detach.(a); place.(a, cmd - 16, b) } } }
        { (cmd == 22) or: { cmd == 23 } } { m.copyToEnd(1).pairsDo { |g, n|
            if(children[g].notNil) { detach.(n); place.(n, cmd - 22, g) } } }
        { (cmd == 24) or: { cmd == 50 } } { m.copyToEnd(1).do { |g|
            (children[g] ? []).copy.do { |c| freeTree.(c) } } };
    };
    order = { |g|
        var out = List.new;
        var walk = { |n| (children[n] ? []).do { |c| out.add(c); walk.(c) } };
        walk.(g);
        out.asArray
    };
    ancestors = { |n|
        var out = List.new, p = parent[n];
        while { p.notNil } { out.add(p); p = parent[p] };
        out.asArray
    };
    (children: children, parent: parent, paused: paused, defs: defs, order: order, ancestors: ancestors)
};

// A stand-in for MegaSAPlugin, for a MegaSA built on a stub (~tMegaSA): it
// opens at once into `state` (\failed, or \open) and answers bank jobs at
// once, a save writing a small file so a Keep can be seen to have written one.
// It holds no VSTPluginController, so nothing waits on a server.
~tFakePlugin = { |state = \failed, name = "BIAS FX 2"|
    (
        state: \closed, name: name, bank: nil, loadSec: nil, latency: 0, bypassed: nil, opened: 0, saves: 0,
        stateExtension: ".fxp",
        identity: (key: name, name: name, vendor: "Fake Audio", format: "vst2", uid: "46414B45", version: "1.0",
            path: "/x/" ++ name ++ ".vst"),
        // `given`: nil, a bank's path, or a state (kind:, path:), as
        // MegaSAPlugin.open takes it. A state whose file is not there does
        // not load: open, but not ok.
        open: { |self, given, action|
            var file = if(given.isString) { given } { given !? { |x| x[\path] } };
            var loads = given.isNil or: { given.isString } or: { File.exists(file) };
            self[\opened] = self[\opened] + 1;
            self[\openedWith] = given;
            self[\state] = state;
            self[\loadSec] = 0.1;
            if(state == \open and: { file.notNil } and: { loads }) { self[\bank] = file };
            self.changed(\state, state);
            action.value(self, (state == \open) and: { loads });
        },
        // A program's state: read if the file is there, written as a text
        // that says which save it was.
        loadState: { |self, kind, file, action|
            var ok = (self[\state] == \open) and: { File.exists(file) };
            if(kind == \bank) { self.loadBank(file, action) } {
                if(ok) { self[\bank] = file; self[\loaded] = file; self.changed(\bank, file) };
                action.value(self, ok);
            };
        },
        saveState: { |self, kind, file, action|
            var ok = (self[\state] == \open) and: { self[\saveFails] != true };
            if(kind == \bank) { self.saveBank(file, action) } {
                if(ok) {
                    self[\saves] = self[\saves] + 1;
                    File.use(file, "w", { |f| f.write("fake state " ++ self[\saves]) });
                    self[\bank] = file;
                    self.changed(\bank, file);
                };
                action.value(self, ok);
            };
        },
        loadBank: { |self, file, action|
            var ok = (self[\state] == \open) and: { File.exists(file) };
            if(ok) { self[\bank] = file; self.changed(\bank, file) };
            action.value(self, ok);
        },
        saveBank: { |self, file, action|
            var ok = self[\state] == \open;
            if(ok) { File.use(file, "w", { |f| f.write("fake bank") }); self[\bank] = file; self.changed(\bank, file) };
            action.value(self, ok);
        },
        bypass: { |self, flag| self[\bypassed] = flag },
        // As MegaSAPlugin: a tempo reaches only a plugin that is open.
        setTempo: { |self, bpm| if(self[\state] == \open) { self[\tempo] = bpm } },
        editor: { |self| },
        // What megalooper sent it as MIDI controllers, in order.
        sendControl: { |self, chan, num, val|
            if(self[\state] == \open) { self[\controls] = (self[\controls] ? []) ++ [[chan, num, val]]; true } { false }
        }
    )
};

// A real MegaSA on a recording stub, its server side built: the groups in
// their order, the guitar chain (with a plugin, if `plugin` is given: a
// ~tFakePlugin, or anything answering MegaSAPlugin's calls), the drums, the
// strips and the master, all of it in the stub's messages. The stub counts its
// nodes from 2000. Its own build routine is stopped, so nothing builds twice
// when a test waits, and the plugin's open, which MegaSA runs on a routine of
// its own after the build, is run here at once, so the plugin has answered by
// the time this returns. Attach a Looper with `Routine { sa.attachLooper(l) }.next`
// (~tLooper), which adds the loop's effects. Free it when done.
~tMegaSA = { |stub, plugin, pluginPath, sound, catalog, setup|
    var srv = stub ?? { ~tStubServer.() };
    var path = pluginPath ?? { plugin !? { "/Library/Audio/Plug-Ins/VST/BIAS FX 2.vst" } };
    var sa;
    if(srv[\lastNodeID].isNil) { ~tCountIds.(srv, 2000) };
    srv[\defaultGroup] = srv[\defaultGroup] ?? { Group.basicNew(srv, 1) };
    // The \sa profile's real-time pool, which the chains' memory budget
    // reads (a test of the budget lowers it afterwards).
    srv[\options] !? { |o| o.memSize = 65536 };
    sa = MegaSA(srv, 0, 0, path, nil, sound, catalog);
    sa.instVarAt(\builder) !? { |r| r.stop };
    // (`setup` gets the MegaSA before anything is built.)
    setup.value(sa);
    // (What the plugin was made for is kept on the stub: \pluginMadeWith.)
    // A function given as the plugin is the maker itself (a fake per device).
    plugin !? { |p| sa.pluginMaker = if(p.isFunction) { p } { { |synth, id, pth| srv[\pluginMadeWith] = pth; p } } };
    Routine { sa.prBuild }.next;
    sa.instVarAt(\opener) !? { |r| r.stop };
    Routine { sa.pluginDevices.do { |d| sa.prOpenPlugin(d) } }.next;
    sa
};

// A synth's starting controls, from the /s_new the stub was sent for it (an
// Event, empty if none was sent).
~tStartArgs = { |srv, node|
    var id = node !? { |n| n.nodeID };
    var msg = id !? { (srv[\writes] ?? { srv[\msgs].collect { |m| [0, m] } })
        .collect(_[1]).detect { |m| (m[0] == 9) and: { m[2] == id } } };
    (msg !? { |m| ().putPairs(m.copyToEnd(5)) }) ? ()
};

// Delete a folder ~tTempPath named, with everything in it. Only ever under
// PathName.tmp, so a slip in a path cannot take anything else with it.
~tRemoveTree = { |path|
    // The folder part with glob's own characters made literal, so a folder
    // named "Gigs [2026]" is listed too (LooperSessionRecorder.globQuote).
    var quote = { |p|
        var out = "";
        p.do { |c| if("[]*?\\".includes(c)) { out = out ++ "\\" }; out = out ++ c.asString };
        out
    };
    var rm = { |p|
        (quote.(p) +/+ "*").pathMatch.do { |x| if(x.last == $/) { rm.(x.drop(-1)) } { File.delete(x) } };
        File.delete(p);
    };
    if(path.notNil and: { path.beginsWith(PathName.tmp) } and: { File.exists(path) }) { rm.(path) };
};

// A temporary folder's path that no other run of the suite uses at the same
// time (two agents, a hook and a hand): UniqueID counts from 1000 again in
// every sclang, so it alone names the same folder in each. The process id,
// the time and a count of this process's own.
~tTempPath = { |prefix|
    var pid = try { thisProcess.pid } { 2147483647.rand };
    ~tTempCount = (~tTempCount ? 0) + 1;
    PathName.tmp +/+ (prefix ++ "-" ++ pid ++ "-" ++ Date.getDate.stamp ++ "-" ++ ~tTempCount)
};

// Private ivars (loopFrames, loopStartTime, lastResult, onsets…) have no
// getters, so tests reach them by name. Wrapped so the intent reads as "set up
// the fixture" rather than as reflection trickery.
~tPut = { |looper, key, val| looper.instVarPut(key, val); looper };
~tGet = { |looper, key| looper.instVarAt(key) };

// --------------------------------------------------------------- report -----

// Returns the number of REAL failures (xpasses deliberately excluded).
~tReport = {
    var s = ~tState;
    "".postln;
    if(s[\failures].notEmpty) {
        "failures:".postln;
        s[\failures].do { |l| ("  " ++ l).postln };
        "".postln;
    };
    if(s[\xpasses].notEmpty) {
        "known issues that no longer reproduce (update these tests):".postln;
        s[\xpasses].do { |l| ("  " ++ l).postln };
        "".postln;
    };
    if((s[\skips] ? []).notEmpty) {
        "skipped here:".postln;
        s[\skips].do { |l| ("  " ++ l).postln };
        "".postln;
    };
    (s[\pass].asString ++ " passed, " ++ s[\fail] ++ " failed"
        ++ (if(s[\xfail] > 0) { ", " ++ s[\xfail] ++ " known" } { "" })
        ++ (if(s[\xpass] > 0) { ", " ++ s[\xpass] ++ " unexpectedly fixed" } { "" })
        ++ (if((s[\skip] ? 0) > 0) { ", " ++ s[\skip] ++ " skipped" } { "" })
    ).postln;
    s[\fail]
};

// Each test file calls this so it works standalone in the IDE as well as under
// the runner. `.load` sets nowExecutingPath to the file being loaded and
// restores it afterwards, so this resolves correctly either way.
~tNeedHarness = { };   // already loaded if this file is what defined it
