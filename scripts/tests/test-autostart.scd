// Autostart (Looper.autostart, 2026-11-12): with no loop, a take starts on the
// first note, for playing without a footswitch. The recorder that waits is
// heard offline by scripts/sa/nrt-autostart.scd (the start, to the sample);
// this is the Looper around it, on the harness's Looper (a stub server that
// records what it is sent): when it waits and when it doesn't, what it is
// made with and told while it waits, the take it hands over, a press or a
// late reply while it waits, Clear, Cmd-period and free. Then the settings
// (setup-model.scd) and the two controls (setup-miditargets.scd).

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-autostart");

{
var dir = thisProcess.nowExecutingPath.dirname;
var scripts = dir.dirname;
var make, heard, sent, news, frees, sets, zeros, named, l, srv, id, got, said, s0, saved;
var kept, keptLog, wasSaved, wasSave, wasLooper, wasTargets;

// A looper with no loop, ready, its buffers objects on the stub (none
// allocated), nodes numbered apart; the analysis on a tap (channel 3) so its
// input shows apart from the recorded one.
make = { |count = 1|
    var lp = ~tLooper.(), sv = ~tGet.(lp, \server);
    ~tCountIds.(sv);
    ~tPut.(lp, \buffer, Buffer.new(sv, 96000, 2, 0));
    ~tPut.(lp, \undoBuffer, Buffer.new(sv, 96000, 2, 1));
    ~tPut.(lp, \tapGainBus, Bus.control(sv, 1));
    ~tPut.(lp, \inChannelCount, count);
    ~tPut.(lp, \analysisChannel, 3);
    ~tPut.(lp, \ready, true);
    lp
};
// What the looper said while `fn` ran: [what, args...] per notification.
heard = { |model, fn|
    var out = List.new;
    var f = { |obj, what ... args| out.add([what] ++ args) };
    model.addDependant(f);
    protect { fn.value } { model.removeDependant(f) };
    out.asArray
};
sent = { |lp| ~tGet.(lp, \server)[\msgs].asArray };
news = { |lp| sent.(lp).select { |m| m[0] == 9 } };
frees = { |lp| sent.(lp).select { |m| m[0] == 11 }.collect { |m| m[1] } };
sets = { |lp, node| sent.(lp).select { |m| (m[0] == 15) and: { m[1] == node } } };
// A command by name, with or without its slash (Buffer sends \b_zero).
named = { |m, name| m[0].isKindOf(Symbol) or: { m[0].isString } and: { m[0].asString.replace("/", "") == name } };
zeros = { |lp| sent.(lp).select { |m| named.(m, "b_zero") }.collect { |m| m[1] } };
// An s_new's controls as an Event.
s0 = { |m| var e = (); m.copyToEnd(5).pairsDo { |k, v| e[k.asSymbol] = v }; e };

// ---- off: nothing waits -------------------------------------------------------------------
l = make.();
l.prAutostartFollow;
~tEq.("off by default: nothing waits, no synth", [l.autostart, l.autostartWaiting, news.(l).size], [false, false, 0]);
~tEq.("the start level is -40 dB by default", l.startLevelDb, -40);

// ---- on, with no loop: it waits ----------------------------------------------------------------
l = make.();
said = heard.(l, { l.autostart = true });
got = news.(l);
~tEq.("switched on with no loop: it waits, one recorder made", [l.autostartWaiting, got.size], [true, 1]);
~tEq.("...the mono one for a mono input", got[0] !? { |m| m[1] }, \looperRecAutoMono);
~tAssert.("...and it says so: the switch, then that it waits",
    said == [[\autostart, true], [\autostartWaiting, true]], said.asString);
got = got[0] !? { |m| s0.(m) } ? ();
~tEq.("...made with the buffer, the input, the tap, the quiet and the lead (the seam's fade + 2 ms)",
    [got[\bufnum], got[\in], got[\ana], got[\quiet], got[\lead]], [0, 0, 3, 0.2, 0.005]);
~tNear.("...and the start level as a gain", got[\startLevel] ? 0, -40.dbamp, 1e-6);
~tAssert.("...the buffer zeroed before it is made",
    { var m = sent.(l), z = m.detectIndex { |x| named.(x, "b_zero") }, n = m.detectIndex { |x| x[0] == 9 };
        z.notNil and: { n.notNil } and: { z < n } }.value);
said = heard.(l, { l.autostart = true });
~tEq.("on again: nothing new said or made", [said, news.(l).size], [[], 1]);

l = make.(2);
l.autostart = true;
~tEq.("a stereo input waits with the stereo recorder", news.(l)[0] !? { |m| m[1] }, \looperRecAuto);

// ---- when it does not wait --------------------------------------------------------------------
l = make.();
~tPut.(l, \ready, false);
l.autostart = true;
~tEq.("on before the looper is ready: nothing made", [l.autostartWaiting, news.(l).size], [false, 0]);
~tPut.(l, \ready, true);
l.prAutostartFollow;
~tEq.("...and it waits once ready (init's end asks)", [l.autostartWaiting, news.(l).size], [true, 1]);

l = make.();
~tPut.(l, \state, \playing);
l.autostart = true;
~tEq.("on with a loop playing: it does not wait", [l.autostartWaiting, news.(l).size], [false, 0]);
said = heard.(l, { l.prSetState(\empty) });
~tEq.("...and waits once there is no loop (Clear, an undo of the take)", [l.autostartWaiting, news.(l).size], [true, 1]);
~tAssert.("...saying the state, then that it waits",
    said == [[\state, \empty], [\autostartWaiting, true]], said.asString);

// ---- told while it waits ------------------------------------------------------------------------
l = make.();
l.autostart = true;
id = l.instVarAt(\autostartSynth).nodeID;
said = heard.(l, { l.startLevelDb = -30 });
~tNear.("a new start level reaches the waiting recorder as a gain", ~tLastSet.(l, l.instVarAt(\autostartSynth), \startLevel) ? 0,
    -30.dbamp, 1e-6);
~tEq.("...and is said", said, [[\startLevelDb, -30]]);
l.startLevelDb = -80;
~tEq.("the level stays on the meter's scale: -80 is -60", l.startLevelDb, -60);
l.startLevelDb = 6;
~tEq.("...and 6 is 0", l.startLevelDb, 0);
said = heard.(l, { l.startLevelDb = 0 });
~tEq.("the same level again says nothing", said, []);
l.onsetThreshold = 0.7;
~tNear.("the onset threshold reaches it", ~tLastSet.(l, l.instVarAt(\autostartSynth), \onsetThreshold) ? 0, 0.7, 1e-6);
l.analysisChannel = 5;
~tEq.("a new analysis input reaches it", ~tLastSet.(l, l.instVarAt(\autostartSynth), \ana), 5);
l.declickMs = 10;
~tNear.("a longer seam fade moves the lead with it", ~tLastSet.(l, l.instVarAt(\autostartSynth), \lead) ? 0, 0.012, 1e-6);

// ---- the first note -------------------------------------------------------------------------------
l = make.();
l.autostart = true;
got = l.instVarAt(\autostartSynth);
l.instVarAt(\onsets).add([0.5, 0.3]);
l.prAutostartStarted(got.nodeID + 1);
~tEq.("a reply from another node is no first note", [l.state, l.autostartWaiting], [\empty, true]);
said = heard.(l, { l.prAutostartStarted(got.nodeID) });
~tEq.("the first note: the take records", l.state, \recording);
~tAssert.("...on the recorder that waited, now the take's", ~tGet.(l, \recSynth) === got);
~tEq.("...nothing waits, no other recorder made", [l.autostartWaiting, news.(l).size], [false, 1]);
~tAssert.("...it says it no longer waits, then the state",
    said.select { |x| #[\autostartWaiting, \state].includes(x[0]) } == [[\autostartWaiting, false], [\state, \recording]],
    said.asString);
~tAssert.("...the take's clock started", l.recStartTime.notNil);
~tEq.("...the onsets of before cleared", l.instVarAt(\onsets).size, 0);
~tAssert.("...undo goes back to no loop: a snapshot of it, its audio zeroed rather than copied mid-take",
    l.canUndo and: { l.instVarAt(\undoState)[\state] == \empty } and: { zeros.(l).includes(1) }
        and: { sent.(l).every { |m| named.(m, "b_gen").not } },
    [l.instVarAt(\undoState) !? { |u| u[\state] }, zeros.(l), sent.(l).select { |m| named.(m, "b_gen") }].asString);
said = heard.(l, { l.prAutostartStarted(got.nodeID) });
~tEq.("the same reply again changes nothing", [l.state, said], [\recording, []]);

// ---- a press while it waits: a take by hand ------------------------------------------------------------
l = make.();
l.autostart = true;
got = l.instVarAt(\autostartSynth);
l.trigger;
~tEq.("R while it waits: a take by hand", [l.state, l.autostartWaiting], [\recording, false]);
~tAssert.("...the waiting recorder freed before the press's recorder is made",
    { var m = sent.(l), f = m.detectIndex { |x| (x[0] == 11) and: { x[1] == got.nodeID } },
        n = m.detectIndex { |x| (x[0] == 9) and: { x[1] == \looperRecMono } };
        f.notNil and: { n.notNil } and: { f < n } }.value, sent.(l).asString);
~tAssert.("...and the press's recorder is the take's", ~tGet.(l, \recSynth) !== got);
got = ~tGet.(l, \recSynth);
l.prAutostartStarted(news.(l)[0][2]);
~tAssert.("a reply from the freed recorder, late: ignored", (~tGet.(l, \recSynth) === got) and: { l.state == \recording });

// ---- switched off, Cmd-period, free ---------------------------------------------------------------------
l = make.();
l.autostart = true;
id = l.instVarAt(\autostartSynth).nodeID;
said = heard.(l, { l.autostart = false });
~tEq.("switched off while it waits: freed, and said", [frees.(l), said, l.autostartWaiting],
    [[id], [[\autostart, false], [\autostartWaiting, false]], false]);

l = make.();
l.autostart = true;
said = heard.(l, { l.cmdPeriod });
~tEq.("Cmd-period while it waits: it no longer waits, nothing freed (Cmd-period freed it), nothing made again",
    [l.autostartWaiting, frees.(l), news.(l).size, said.any { |x| x == [\autostartWaiting, false] }], [false, [], 1, true]);

l = make.();
l.autostart = true;
id = l.instVarAt(\autostartSynth).nodeID;
l.free;
~tAssert.("free frees the waiting recorder", frees.(l).includes(id) and: { l.autostartWaiting.not }, frees.(l).asString);

// ---- the settings (setup-model.scd) -----------------------------------------------------------------------
if(~autostartApply.isNil) { (scripts +/+ "setup-model.scd").load };
if(~startLevelSpec.isNil) { (scripts +/+ "setup-laws.scd").load };
wasSaved = ~prefSaved; wasSave = ~prefSave; wasLooper = ~looper; wasTargets = ~midiTargets;
protect {
    kept = Dictionary.new;
    keptLog = List.new;
    ~prefSaved = { |key| kept[key] };
    ~prefSave = { |key, value| keptLog.add([key, value]); kept[key] = value };
    // No write half a second on: a knob's level is kept by ~startLevelKeep,
    // called here; one scheduled now would land after the stubs are gone.
    ~startLevelSaving = true;
    ~looper = l = make.();
    kept["autostart"] = "on"; kept["startLevelDb"] = "-33";
    ~autostartApply.();
    ~tEq.("kept on at -33: on at -33, and waiting", [l.autostart, l.startLevelDb, l.autostartWaiting], [true, -33.0, true]);
    ~looper = l = make.();
    ~autostartApply.();
    kept["autostart"] = "off";
    ~autostartApply.();
    ~tEq.("kept off: off", l.autostart, false);
    [["loud", -33.0], ["", -33.0], ["-12.5", -12.5], ["5", 0], ["--3", 0]].do { |c|
        kept["startLevelDb"] = c[0];
        ~autostartApply.();
        ~tEq.("a kept level of " ++ c[0].asCompileString ++ " leaves it at " ++ c[1], l.startLevelDb, c[1]);
    };
    kept.removeAt("startLevelDb"); kept.removeAt("autostart");
    ~looper = l = make.();
    ~autostartApply.();
    ~tEq.("nothing kept: off at -40", [l.autostart, l.startLevelDb], [false, -40]);
    keptLog.clear;
    ~autostartSet.(true);
    ~tEq.("switched on: on, and kept", [l.autostart, keptLog.asArray], [true, [["autostart", "on"]]]);
    keptLog.clear;
    ~autostartSet.(false);
    ~tEq.("switched off: off, and kept", [l.autostart, keptLog.asArray], [false, [["autostart", "off"]]]);
    keptLog.clear;
    ~startLevelSet.(-27.4);
    ~tEq.("a level set: at once on the looper, not kept yet (it waits for the knob to rest)",
        [l.startLevelDb, keptLog.size], [-27.4, 0]);
    ~startLevelKeep.();
    ~tEq.("...kept as whole dB", keptLog.asArray, [["startLevelDb", "-27"]]);

    // ---- the controls (setup-miditargets.scd) ----------------------------------------------------------
    if(~routingProfiles.isNil) { (scripts +/+ "setup-routing.scd").load };
    if(~saGuitarBank.isNil) { (scripts +/+ "setup-sa.scd").load };
    if(~midiTargetsBuild.isNil) { (scripts +/+ "setup-miditargets.scd").load };
    if(~midiApply.isNil) { (scripts +/+ "setup-midimap.scd").load };
    // setup-midimap.scd defines the real ~prefSave and ~prefSaved: the stubs again.
    ~prefSaved = { |key| kept[key] };
    ~prefSave = { |key, value| keptLog.add([key, value]); kept[key] = value };
    ~midiTargets = ~midiTargetsBuild.();
    keptLog.clear;
    ~controlDo.('looper.autostart', \press, nil, \gui);
    ~tEq.("the Autostart control pressed: on, and kept", [l.autostart, keptLog.asArray], [true, [["autostart", "on"]]]);
    ~controlDo.('looper.autostart', \press, nil, \gui);
    ~tEq.("...pressed again: off", l.autostart, false);
    ~controlDo.('looper.startLevel', \position, 0.5, \gui);
    ~tEq.("the start level control halfway: -30 dB", l.startLevelDb, -30);
    ~controlDo.('looper.startLevel', \position, 1, \gui);
    ~tEq.("...at its end: 0 dB", l.startLevelDb, 0);
    ~tEq.("...and reads in dB", ~midiTargets['looper.startLevel'][\format].(-12), "-12 dB");
} {
    ~prefSaved = wasSaved; ~prefSave = wasSave; ~looper = wasLooper; ~midiTargets = wasTargets;
    ~startLevelSaving = nil;
};
}.value;
