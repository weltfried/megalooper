// Megalooper SA's chain edits (docs/dev/device-chains.md, phase 2): insert, copy,
// remove, move and rename, as MegaSA sends them to a recording stub, and undo
// and redo: a removed built-in freed and built anew, empty, a removed plugin
// parked in limbo, still open. What each edit sends
// and when (the stamps that ride the device's cross-fade), the tree a server
// would hold after every edit and every undo, the ids from the high-water
// mark, what limbo keeps, the memory budget and the CPU check, and what a
// footswitch pressed during an edit does. How an edit sounds is
// scripts/sa/nrt-chains.scd's to check.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megasa-edits");

{
var vst = \VSTPlugin.asClass;
var fade = MegaSA.fadeTime;
var stub, sa, l, t, d, d2, r, ok, bundles, since, last, heard, said, ids, kids, before, n, m, srv, at, shape;
var g, lp, want, plug, refused, sat, satNode, reduxNode, undoNews, c, got, late, job, again;

// What MegaSA said while `fn` ran: [what, args...] per notification.
heard = { |obj, fn|
    var got = List.new, f = { |o, what ... more| got.add([what] ++ more) };
    obj.addDependant(f);
    protect { fn.value } { obj.removeDependant(f) };
    got.asArray
};
// The bundles sent since the stub held `n` of them, as [time, msgs].
since = { |n| stub[\bundles].copyToEnd(n).asArray };
// A chain's synths in the order a server would run them, by SynthDef name.
shape = { |chain|
    var tree = ~tNodeTree.(stub);
    (tree[\children][chain.group.nodeID] ? []).asArray.collect { |x| tree[\defs][x] }
};
// ...and by node: what the model says the order is.
kids = { |chain| (~tNodeTree.(stub)[\children][chain.group.nodeID] ? []).asArray };
want = { |chain| [chain.source.nodeID] ++ chain.devices.select { |x| x.node.notNil }.collect { |x| x.node.nodeID } };

MegaSA.loadSynthDefs;
stub = ~tStubServer.();
sa = ~tMegaSA.(stub, if(vst.notNil) { ~tFakePlugin.(\open) });
Synth.tail(stub[\defaultGroup], \looperMaster);
l = ~tLooper.();
Routine { sa.attachLooper(l) }.next;
g = sa.guitarChain;
lp = sa.loopChain;

// ---- insert ---------------------------------------------------------------
sa.setFx(\saturator, true);
n = stub[\bundles].size;
said = heard.(sa, { d = sa.insertDevice(\loop, 1, \delay) });
bundles = since.(n);
~tEq.("an insert makes a device of the type, its id and name from its number",
    d !? { [d.id, d.type, d.name, d.on] }, [\delay2, \delay, "Dual Delay 2", true]);
~tEq.("...in the model where asked", lp.ids, [\echo, \delay2, \saturator, \redux]);
~tEq.("...said once, as \\chain (track, op, id, index)", said, [[\chain, \loop, \insert, \delay2, 1]]);
~tEq.("...sent as two bundles", bundles.size, 2);
~tAssert.("...stamped ahead, so it lands on time", bundles[0][0] > thisThread.seconds);
~tEq.("...an s_new switched off, after the device before it, on the chain's bus",
    bundles[0][1].collect { |x| x.keep(5) ++ [x[x.indexOf(\bus) + 1], x[x.indexOf(\delayOn) + 1]] },
    [[9, \megaSADevDelay, d.node.nodeID, 3, lp.devices[0].node.nodeID, lp.bus.index, 0]]);
// A synth's UGens start at its first block, after the bundle that made it:
// a switch in that bundle would start its Lag on, wet from the first sample.
~tEq.("...then its switch on, in a bundle of its own", bundles[1][1], [[15, d.node.nodeID, \delayOn, 1]]);
~tAssert.("...more than a control block later, so the two never land in one block",
    (bundles[1][0] - bundles[0][0]) > ((stub[\options].blockSize ? 64) / sa.sampleRate),
    (bundles[1][0] - bundles[0][0]).asString);
~tEq.("...the server's chain in the model's order", kids.(lp), want.(lp));
~tAssert.("...its settings the type's own", MegaSAFx.paramsOf(\delay).every { |p| d.param(p[\name]) == p[\spec].default });
~tAssert.("it can be undone", sa.canUndo);
n = stub[\bundles].size;
d2 = sa.insertDevice(\guitar, 0, \redux, (reduxBits: 3), false);
bundles = since.(n);
~tEq.("at the head of a chain it goes after the input; switched off it is made and nothing more",
    bundles.collect { |b| b[1].collect { |x| x.keep(5) } }, [[[9, \megaSADevRedux, d2.node.nodeID, 3, g.source.nodeID]]]);
~tEq.("...with the settings it was given on top of its type's", [d2.param(\reduxBits), d2.param(\reduxMix), d2.on],
    [3, MegaSAFx.param(\reduxMix)[\spec].default, false]);
~tEq.("...and its synth the first after the input", kids.(g), want.(g));

// ---- remove -----------------------------------------------------------------
sat = lp.device(\saturator);
satNode = sat.node.nodeID;
n = stub[\bundles].size;
said = heard.(sa, { ok = sa.removeDevice(\saturator) });
bundles = since.(n);
~tEq.("a remove takes the device out of the model", [ok, lp.ids, sa.device(\saturator)], [true, [\echo, \delay2, \redux], nil]);
~tEq.("...said once", said, [[\chain, \loop, \remove, \saturator, 2]]);
~tEq.("...switched off first, then, once it has faded, its synth freed",
    bundles.collect { |b| b[1] }, [[[15, satNode, \saturatorOn, 0]], [[11, satNode]]]);
~tNear.("...the free a fade after the switch", bundles[1][0] - bundles[0][0], fade, 1e-9);
~tEq.("...nothing parked: a built-in comes back empty, built anew", [sat.node, sa.limboDevices, sa.limboGroup], [nil, [], nil]);
~tEq.("...and the chain on the server is the model's again", kids.(lp), want.(lp));
before = stub[\msgs].size + stub[\bundles].size;
~tCheck.("a removed device's footswitch warns rather than throws", { sa.setFx(\saturator, false); sa.toggleFx(\saturator) });
~tEq.("...and reaches nothing, stamped or not", (stub[\msgs].size + stub[\bundles].size) - before, 0);
n = stub[\bundles].size;
reduxNode = lp.device(\redux).node.nodeID;
sa.removeDevice(\redux);
~tEq.("a device that is off is freed at once: one bundle", since.(n).collect { |b| b[1] }, [[[11, reduxNode]]]);

// ---- move -------------------------------------------------------------------
n = stub[\bundles].size;
said = heard.(sa, { ok = sa.moveDevice(\echo, \guitar, 2) });
bundles = since.(n);
d = g.device(\echo);
~tEq.("a move to the other chain puts the device there in the model", [ok, g.ids, lp.ids],
    [true, [\redux2, \shifter, \echo, \delay, \filter, \pitchLoop] ++ if(vst.notNil) { [\plugin1] } { [] }, [\delay2]]);
~tEq.("...said once, with where it went", said, [[\chain, \guitar, \move, \echo, 2]]);
~tEq.("...an off device moves at once: after its new neighbour, onto that chain's bus",
    bundles.collect { |b| b[1] }, [[[19, d.node.nodeID, g.devices[1].node.nodeID], [15, d.node.nodeID, \bus, g.bus.index]]]);
~tEq.("...the server's chains the model's", [kids.(g), kids.(lp)], [want.(g), want.(lp)]);
sa.setFx(\echo, true);
n = stub[\bundles].size;
sa.moveDevice(\echo, \guitar, 0);
bundles = since.(n);
~tEq.("an on device: switched off, then once faded moved and switched back on",
    bundles.collect { |b| b[1] }, [[[15, d.node.nodeID, \echoOn, 0]],
        [[19, d.node.nodeID, g.source.nodeID], [15, d.node.nodeID, \echoOn, 1]]]);
~tNear.("...the move a fade after the switch", bundles[1][0] - bundles[0][0], fade, 1e-9);
~tEq.("...within its chain, no bus", [kids.(g), g.ids.first], [want.(g), \echo]);
n = stub[\bundles].size;
~tEq.("a move to where it is changes nothing and sends nothing", [sa.moveDevice(\echo, \guitar, 0), since.(n)], [true, []]);
~tEq.("a move past the end goes to the end", [sa.moveDevice(\echo, \guitar, 99), g.ids.last], [true, \echo]);
sa.moveDevice(\echo, \loop, 0);

// ---- copy -------------------------------------------------------------------
sa.setFxParam(\filterFreq, 900);
sa.setFx(\filter, true);
n = stub[\bundles].size;
d = sa.copyDevice(\filter);
~tEq.("a copy is a new device of the type, its settings and switch, right after the original",
    d !? { [d.id, d.name, d.param(\filterFreq), d.on, g.indexOf(d) - g.indexOf(g.device(\filter))] },
    [\filter2, "Envelope Filter 2", 900, true, 1]);
~tEq.("...fading in as an insert does: its synth, then its switch", since.(n).collect { |b| b[1].collect(_.first) }, [[9], [15]]);
~tEq.("...in the server's chain", kids.(g), want.(g));
~tAssert.("...its settings its own: moving the original's leaves it",
    { sa.setFxParam(\filterFreq, 500); d.param(\filterFreq) == 900 }.value);

// ---- rename -----------------------------------------------------------------
said = heard.(sa, { sa.renameDevice(\filter2, "Wah") });
~tEq.("a rename names the device, said as \\chain", [d.name, said], ["Wah", [[\chain, \guitar, \rename, \filter2, g.indexOf(d)]]]);
n = sa.instVarAt(\undoList).size;
sa.renameDevice(\filter2, "Envelope Filter 2");
~tEq.("...which is no edit to undo: the undo list as long as before", sa.instVarAt(\undoList).size, n);

// ---- undo and redo ------------------------------------------------------------
// Every edit so far undone, newest first, the server's chains checked against
// the model after each; then all done again. At most as many as undo keeps,
// so an undo that is refused shows as a failure, not a loop for ever.
ids = List.new;
n = stub[\bundles].size;
(MegaSA.undoMax + 1).do { if(sa.canUndo) {
    ok = sa.undo;
    ids.add([ok, g.ids, lp.ids]);
    if(kids.(g) != want.(g) or: { kids.(lp) != want.(lp) }) { ids.add(\mismatch) };
} };
undoNews = since.(n).collect { |b| b[1] }.flatten(1).select { |x| x[0] == 9 }.collect { |x| x[2] };
~tEq.("undoing every edit gives the chains back as they were built",
    [g.ids, lp.ids], [MegaSAFx.guitarKeys ++ if(vst.notNil) { [\plugin1] } { [] }, MegaSAFx.loopKeys]);
~tAssert.("...the server's chains the model's after every undo, every undo done",
    ids.includes(\mismatch).not and: { ids.every { |x| x[0] == true } } and: { sa.canUndo.not }, ids.asString);
~tEq.("...the removed ones built anew, each in a new synth",
    [lp.device(\saturator).node.nodeID != satNode, lp.device(\redux).node.nodeID != reduxNode,
        undoNews.includes(lp.device(\saturator).node.nodeID), undoNews.includes(lp.device(\redux).node.nodeID)],
    [true, true, true, true]);
~tAssert.("...with its settings, made switched off, then switched on as it was",
    { var x = lp.device(\saturator), a = ~tStartArgs.(stub, x.node);
      (a[\saturatorOn] == 0) and: { a[\saturatorDrive] == x.param(\saturatorDrive) } and: { x.on }
        and: { ~tLastSet.(sa, x.node, \saturatorOn) == 1 } }.value);
~tEq.("nothing more to undo", [sa.canUndo, sa.undo], [false, false]);
before = [g.ids, lp.ids];
n = 0;
(MegaSA.undoMax + 1).do { if(sa.canRedo) {
    if(sa.redo.not) { n = -999 };
    n = n + 1;
    if(kids.(g) != want.(g) or: { kids.(lp) != want.(lp) }) { n = -99 } } };
~tEq.("redoing every one gives the edited chains back", [g.ids, lp.ids],
    [[\redux2, \shifter, \delay, \filter, \filter2, \pitchLoop] ++ if(vst.notNil) { [\plugin1] } { [] }, [\echo, \delay2]]);
~tAssert.("...the server's chains the model's after every redo, every redo done", (n > 0) and: { sa.canRedo.not }, n.asString);
// The copy and the last move undone (the copy freed), the tempo moved, both
// done again: the copy, built anew, starts at the beat of now.
sa.undo;
sa.undo;
sa.setTempo(150);
n = stub[\bundles].size;
sa.redo;
sa.redo;
~tEq.("a device built anew starts at the beat of now if it follows the tempo",
    since.(n).collect { |b| b[1] }.flatten(1).detect { |x| (x[0] == 9) and: { x[2] == g.device(\filter2).node.nodeID } }
        !? { |x| x[x.indexOf(\beatDur) + 1] }, 60 / 150);

// ---- ids: the high-water mark -----------------------------------------------
sa.free;
stub = ~tStubServer.();
sa = ~tMegaSA.(stub);
Routine { sa.attachLooper(~tLooper.()) }.next;
sa.insertDevice(\guitar, nil, \delay);
sa.removeDevice(\delay2);
d = sa.insertDevice(\guitar, nil, \delay);
~tEq.("a removed delay2 is never reborn: the next is delay3", d.id, \delay3);
sa.undo;
sa.undo;
d = sa.insertDevice(\guitar, nil, \delay);
~tEq.("...not even once undone", [d.id, d.name], [\delay4, "Dual Delay 4"]);
~tEq.("the first plugin, with none configured, would be plugin1", sa.nextIds[\plugin], 1);

// ---- removed built-ins, built anew ---------------------------------------------
// Limbo holds plugins only: an undone insert frees its synth once it has
// faded, and a redo builds it anew; removed devices undone come back, each
// in a new synth, in order.
d = sa.device(\delay4);
before = d.node.nodeID;
n = stub[\bundles].size;
sa.undo;   // the insert of delay4
~tEq.("an undone insert frees its synth: nothing parked", [sa.device(\delay4), d.node, sa.limboDevices], [nil, nil, []]);
~tAssert.("...on the server, after its switch off", {
    var off = since.(n).detect { |b| b[1].includesEqual([15, before, \delayOn, 0]) };
    var free = since.(n).detect { |b| b[1].includesEqual([11, before]) };
    off.notNil and: { free.notNil } and: { (free[0] - off[0]) >= (fade - 1e-9) } }.value, since.(n).asString);
sa.redo;
~tAssert.("...and a redo builds it anew, in a synth of its own",
    d.node.notNil and: { d.node.nodeID != before } and: { sa.device(\delay4) === d });
ids = (1..10).collect { sa.insertDevice(\loop, nil, \redux).id };
ids.do { |x| sa.removeDevice(x) };
~tEq.("ten removed: none parked", sa.limboDevices.size, 0);
n = stub[\bundles].size;
10.do { sa.undo };
~tEq.("undo brings every one back", sa.loopChain.ids.select { |x| ids.includes(x) }.asArray, ids);
~tEq.("...each in a synth in the server's chain, in order", kids.(sa.loopChain), want.(sa.loopChain));
~tEq.("...each a new synth (s_new)",
    since.(n).collect { |b| b[1] }.flatten(1).count { |x| x[0] == 9 }, ids.size);

// ---- the memory budget and the CPU check ---------------------------------------
sa.free;
stub = ~tStubServer.();
sa = ~tMegaSA.(stub);
Routine { sa.attachLooper(~tLooper.()) }.next;
~tAssert.("the budget is the pool less the reserve for the Looper and the drums",
    sa.memoryBudget == ((65536 * 1024) - MegaSA.memReserve));
~tEq.("...and the default chains take their devices' memory", sa.memoryUsed,
    sa.devices.sum { |x| x.memBytes(48000) });
stub[\options].memSize = ((sa.memoryUsed + MegaSA.memReserve) / 1024).ceil.asInteger + 1;
n = stub[\msgs].size + stub[\bundles].size;
said = heard.(sa, { d = sa.insertDevice(\guitar, nil, \delay) });
~tEq.("an insert past the budget is refused, with its reason, and sends nothing",
    [d, said.collect(_.first), (stub[\msgs].size + stub[\bundles].size) - n], [nil, [\refused], 0]);
~tAssert.("...the reason says how much it needs", said.first[2].contains("MB"), said.first[2]);
~tEq.("...and a type that takes no memory still goes in", sa.insertDevice(\guitar, nil, \saturator) !? (_.id), \saturator2);
stub[\options].memSize = 65536;
sa.insertDevice(\guitar, nil, \delay);
before = sa.memoryUsed;
sa.removeDevice(\delay2);
~tEq.("a removed built-in's memory goes with its synth", before - sa.memoryUsed, MegaSAFx.type(\delay)[\memBytes].value(48000));
stub[\options].memSize = ((sa.memoryUsed + MegaSA.memReserve) / 1024).ceil.asInteger + 1;
said = heard.(sa, { ok = sa.undo });
~tEq.("...so an undo that no longer fits is refused, with its reason, and stays to be tried again",
    [ok, said.collect(_.first), sa.canUndo], [false, [\refused], true]);
stub[\options].memSize = 65536;
~tEq.("...with room, it goes", [sa.undo, sa.guitarChain.ids.last], [true, \delay2]);
stub[\peakCPU] = 90;
said = heard.(sa, { d = sa.insertDevice(\guitar, nil, \redux) });
~tEq.("with the server's CPU peaking past the mark an insert is refused", [d, said.collect(_.first)], [nil, [\refused]]);
stub[\peakCPU] = 50;
stub[\avgCPU] = 70;
~tEq.("...busy but under it, it goes in, said in the post window", sa.insertDevice(\guitar, nil, \redux) !? (_.id), \redux2);
stub[\peakCPU] = nil;
stub[\avgCPU] = nil;

// ---- refusals ---------------------------------------------------------------------
n = stub[\msgs].size + stub[\bundles].size;
refused = List.new;
sa.addDependant({ |o, what ... more| if(what == \refused) { refused.add(more[0]) } });
sa.insertDevice(\guitar, nil, \wah);
sa.insertDevice(\bass, nil, \delay);
sa.insertDevice(\guitar, nil, \plugin);
sa.removeDevice(\nothing);
sa.moveDevice(\nothing, \loop, 0);
sa.moveDevice(\delay, \bass, 0);
sa.copyDevice(\nothing);
sa.renameDevice(\nothing, "x");
~tEq.("every refusal is said, and none sends anything",
    [refused.asArray, (stub[\msgs].size + stub[\bundles].size) - n],
    [[\insert, \insert, \insert, \remove, \move, \move, \copy, \rename], 0]);
sa.releaseDependants;
srv = ~tCountIds.(~tStubServer.());
m = MegaSA(srv, 0, 0);
m.instVarAt(\builder) !? { |x| x.stop };
srv[\defaultGroup] = Group.basicNew(srv, 1);
srv[\options].memSize = 65536;
Routine { m.prBuild }.next;
~tEq.("the loop chain takes no edit before a Looper is attached", m.insertDevice(\loop, nil, \delay), nil);
~tEq.("...the guitar's does", m.insertDevice(\guitar, nil, \delay) !? (_.id), \delay2);
m.free;

// ---- a footswitch during an edit ---------------------------------------------------
sa.setFx(\delay, true);
n = stub[\bundles].size;
sa.moveDevice(\delay, \guitar, 0);
last = stub[\bundles].last[0];
before = stub[\msgs].size;
sa.setFx(\delay, false);
bundles = since.(n);
~tEq.("a footswitch pressed while its device is moved is not lost under the edit's own switch",
    [bundles.size, bundles.last[1], stub[\msgs].size - before], [3, [[15, sa.fxNode(\delay).nodeID, \delayOn, 0]], 0]);
~tAssert.("...it lands after the edit's switch back on", bundles.last[0] > last);
sa.setFx(\shifter, true);
~tEq.("a device with no edit under way switches at once, as ever", stub[\msgs].last, [15, sa.fxNode(\shifter).nodeID, \shifterOn, 1]);
// The next edit of that device waits for the press, so the press is not
// taken for the edit's own switch.
n = stub[\bundles].size;
sa.moveDevice(\delay, \guitar, 2);
~tAssert.("...and the next edit of it starts once that press has landed", since.(n)[0][0] > bundles.last[0],
    [since.(n)[0][0], bundles.last[0]].asString);
// While its synth is still to be made, a press goes after it, in a block of
// its own, and fades the new device in.
n = stub[\bundles].size;
before = stub[\msgs].size;
d = sa.insertDevice(\guitar, nil, \delay, nil, false);
sa.setFx(d.id, true);
bundles = since.(n);
~tEq.("a footswitch pressed while its device is being made goes after the synth, not with it",
    [bundles.collect { |b| b[1].collect(_.first) }, bundles.last[1], stub[\msgs].size - before],
    [[[9], [15]], [[15, d.node.nodeID, \delayOn, 1]], 0]);
~tAssert.("...a birthGap after it at least", (bundles.last[0] - bundles[0][0]) >= MegaSA.birthGap);
// A setting moved and a tempo read then go after the synth too: sent at once
// they would reach no synth yet.
n = stub[\bundles].size;
before = stub[\msgs].size;
sa.setParam(d.id, \delayMix, 0.25);
c = sa.insertDevice(\guitar, nil, \filter);
sa.setTempo(150);
bundles = since.(n);
~tAssert.("a setting moved while its device is being made is stamped after its synth", {
    var made = stub[\bundles].detect { |b| b[1].any { |x| (x[0] == 9) and: { x[2] == d.node.nodeID } } };
    var set = bundles.detect { |b| b[1].includesEqual([15, d.node.nodeID, \delayMix, 0.25]) };
    made.notNil and: { set.notNil } and: { set[0] > made[0] }
        and: { stub[\msgs].copyToEnd(before).every { |x| x[1] != d.node.nodeID } } }.value,
    bundles.asString);
~tAssert.("...so is a tempo, for a device that follows it",
    bundles.any { |b| b[1].includesEqual([15, c.node.nodeID, \beatDur, 0.4]) },
    bundles.asString);
d.pendingUntil = thisThread.seconds - 1;   // as once its edit has landed
sa.setParam(d.id, \delayMix, 0.3);
~tEq.("...and once the edit has landed, at once", stub[\msgs].last, [15, d.node.nodeID, \delayMix, 0.3]);
n = stub[\bundles].size;
c = sa.copyDevice(\filter);
~tEq.("a copy made after a tempo starts with its beat", since.(n)[0][1][0] !? { |x| x[x.indexOf(\beatDur) + 1] }, 0.4);

// ---- edits in a row ----------------------------------------------------------------
n = stub[\bundles].size;
sa.setFx(\filter, true);
sa.moveDevice(\filter, \guitar, 0);
sa.moveDevice(\shifter, \loop, 0);
bundles = since.(n);
~tAssert.("an edit begins only once the one before has landed, so the places it sends are the places there are",
    (bundles.size == 4) and: { bundles[2][0] > bundles[1][0] }, bundles.collect(_.first).asString);
~tEq.("...and the server's chains end as the model's", [kids.(sa.guitarChain), kids.(sa.loopChain)],
    [want.(sa.guitarChain), want.(sa.loopChain)]);

// ---- a setting of any device ----------------------------------------------------------
d = sa.insertDevice(\guitar, nil, \delay);
d.pendingUntil = thisThread.seconds - 1;   // its insert landed
said = heard.(sa, { sa.setParam(d.id, \delayMix, 0.25) });
~tEq.("a further device's setting goes to its own synth", stub[\msgs].last, [15, d.node.nodeID, \delayMix, 0.25]);
~tEq.("...said by the device, not as \\fxParam, whose names are the default devices'", said, []);
~tEq.("...the default Delay's own untouched", sa.fxParam(\delayMix), MegaSAFx.param(\delayMix)[\spec].default);
said = heard.(sa, { sa.setParam(\delay, \delayMix, 0.5) });
~tEq.("a default device's, by id, is said as \\fxParam, as setFxParam's", said, [[\fxParam, \delayMix, 0.5]]);
before = stub[\msgs].size;
~tCheck.("a setting the device has not, or no number, warns", {
    sa.setParam(d.id, \echoMix, 0.5); sa.setParam(d.id, \delayMix, "loud"); sa.setParam(\nothing, \delayMix, 0.5) });
~tEq.("...and sends nothing", stub[\msgs].size, before);
~tEq.("...it reads back", [sa.param(d.id, \delayMix), sa.param(\nothing, \delayMix)], [0.25, nil]);

// ---- a new Looper while an edit lands ------------------------------------------------
// attachLooper builds the loop chain again: it waits for the edits on their
// way, whose bundles name the synths it frees.
d = sa.insertDevice(\loop, nil, \redux);
again = Routine { sa.attachLooper(~tLooper.()) };
n = sa.loopChain.group.nodeID;
~tAssert.("a new Looper while an edit is on its way: the loop chain waits for it",
    again.next.isNumber and: { sa.loopChain.group.nodeID == n });
again.next;
~tEq.("...then is built again, the inserted device in it", [sa.loopChain.group.nodeID != n, sa.loopChain.ids.last], [true, d.id]);

// ---- the plugin's device --------------------------------------------------------------
if(vst.isNil) { ~tSkip.("the plugin's device in edits", "VSTPlugin is not installed here") } {
    sa.free;
    stub = ~tStubServer.();
    plug = ~tFakePlugin.(\open);
    sa = ~tMegaSA.(stub, plug);
    Routine { sa.attachLooper(~tLooper.()) }.next;
    ~tEq.("a plugin is not copied yet", sa.copyDevice(\plugin1), nil);
    ~tEq.("...but it moves to the other chain, as any device does",
        [sa.moveDevice(\plugin1, \loop, 0), sa.guitarChain.ids.includes(\plugin1), sa.loopChain.ids.first], [true, false, \plugin1]);
    sa.undo;
    ~tEq.("...and undo brings it back to its own", [sa.guitarChain.ids.last, sa.loopChain.ids], [\plugin1, MegaSAFx.loopKeys]);
    ~tEq.("...but within its chain it moves", [sa.moveDevice(\plugin1, \guitar, 0), sa.guitarChain.ids.first], [true, \plugin1]);
    sa.undo;
    n = sa.fxNode(\plugin1).nodeID;
    sa.removeDevice(\plugin1);
    ~tEq.("removed, it is parked with its plugin open: no guitar plugin while it is out",
        [sa.limboDevices.collect(_.id), sa.limboDevices[0].plugin === plug, sa.guitarPlugin], [[\plugin1], true, nil]);
    t = ~tNodeTree.(stub);
    ~tAssert.("...in the limbo group, made at its removal after the record group, and paused",
        sa.limboGroup.notNil and: { t[\parent][sa.limboGroup.nodeID] == 0 }
            and: { t[\children][0].indexOf(sa.limboGroup.nodeID) == (t[\children][0].indexOf(sa.recordGroup.nodeID) + 1) }
            and: { t[\paused].includes(sa.limboGroup.nodeID) }
            and: { (t[\children][sa.limboGroup.nodeID] ? []).asArray == [n] });
    plug[\tempo] = nil;
    sa.setTempo(150);
    ~tEq.("...a tempo meanwhile does not reach it", plug[\tempo], nil);
    sa.undo;
    ~tEq.("...and undo brings it back in its own synth, its plugin with it, told the tempo it missed",
        [sa.guitarChain.ids.last, sa.fxNode(\plugin1).nodeID, sa.guitarPlugin === plug, plug[\tempo]], [\plugin1, n, true, 150]);
    // A bank job asked for before an edit removes the plugin: the one under
    // way answers as the plugin does, the one waiting false, and the guitar
    // is let go. The job's routine is stepped here by hand; its clock finds
    // it done.
    plug[\loadBank] = { |self, file, action| late = action };
    got = List.new;
    sa.loadGuitarBank("/x/a.fxb", { |ok| got.add([\a, ok]) });
    sa.loadGuitarBank("/x/b.fxb", { |ok| got.add([\b, ok]) });
    job = sa.instVarAt(\bankRoutine);
    job.next;   // the strip's fade
    job.next;   // a.fxb asked for; waiting for the answer
    sa.removeDevice(\plugin1);
    late.value(plug, true);
    job.next;   // a.fxb answered; b.fxb next, after the fade
    job.next;   // b.fxb finds no plugin
    ~tEq.("a bank job waiting when the plugin is removed answers false; the guitar is let go",
        [got.asArray, sa.instVarAt(\bankBusy), sa.held(\guitar).includes(\bank)], [[[\a, true], [\b, false]], false, false]);
    sa.undo;
    // Parked, then so many edits that undo can reach it no more: it stays
    // parked, still open. It cannot be opened anew before phase 5, and a
    // recall may want it back.
    sa.removeDevice(\plugin1);
    d = sa.limboDevices.first;
    n = d.node.nodeID;
    MegaSA.undoMax.do { sa.insertDevice(\loop, nil, \saturator) };
    ~tEq.("a parked plugin stays parked, undo or no undo: still open, still MegaSA's",
        [sa.limboDevices.collect(_.id), d.node.nodeID, plug.dependants.includes(sa), plug[\state]], [[\plugin1], n, true, \open]);
    ~tAssert.("...its synth never freed on the server",
        stub[\bundles].any { |b| b[1].any { |x| (x[0] == 11) and: { x[1] == n } } }.not);
};
sa.free;
~tAssert.("free takes limbo with it", sa.limboDevices.isEmpty and: { sa.canUndo.not });
}.value;
