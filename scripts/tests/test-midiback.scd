// Values and lights sent back to a controller (docs/dev/midi-map.md 5.7): what
// LooperMidiMap says a binding sends, and the router's side of it
// (setup-midimap.scd): which inputs are sent to, when a value goes and when
// it waits, a light kept right, an echo dropped. No MIDIClient, no server, no
// window: the outputs are Events that write down what they are sent, and the
// clock's tick is called by hand, at a time the test sets.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-midiback");

{
var dir = thisProcess.nowExecutingPath.dirname;
var scripts = dir.dirname;
var h = LooperMidiMap;
var keys, saved, vals, mk, targets, map, srcs, dests, sent, open, settings, now = 100;
var route, tick, sends, order, got, n, b, m, m2, m3, st, t0, many, before, lines, proxied, fn, v, more;
var said, fakeSrcs, fakeDests, calls, max, real, tk, ticks, w, scheduled, keep;

if(~setupMidiIO.isNil) { (scripts +/+ "setup-midi.scd").load };
if(~midiTargetsBuild.isNil) { (scripts +/+ "setup-miditargets.scd").load };
if(~midiRouteWith.isNil) { (scripts +/+ "setup-midimap.scd").load };
if(~saGuitarBank.isNil) { (scripts +/+ "setup-sa.scd").load };
if(~routingProfiles.isNil) { (scripts +/+ "setup-routing.scd").load };
if(~onsetThresholdSpec.isNil) { (scripts +/+ "gui-const.scd").load };
if(~granularParams.isNil) { (scripts +/+ "gui-granular.scd").load };

// ------------------------------------------------------ what is sent back --
~tEq.("a knob or a pedal on a level, a count or a choice is sent where its control is, from a CC or pitch bend",
    [\continuous, \step, \choice].collect { |k| [h.backKind((msg: \cc, num: 1), k), h.backKind((msg: \bend), k)] },
    [[\knob, \knob], [\knob, \knob], [\knob, \knob]]);
~tEq.("...a toggle on a note or a CC switch is sent its light; on a CC knob, its place",
    [h.backKind((msg: \note, num: 1), \toggle), h.backKind((msg: \cc, num: 1, switch: \oneMessage), \toggle),
        h.backKind((msg: \cc, num: 1, switch: \pressRelease), \toggle), h.backKind((msg: \cc, num: 1), \toggle)],
    [\light, \light, \light, \knob]);
~tEq.("...and what has nothing to show is sent nothing: a trigger, a program change, a level on a switch, a toggle on pitch bend",
    [h.backKind((msg: \cc, num: 1), \trigger), h.backKind((msg: \note, num: 1), \trigger),
        h.backKind((msg: \program, num: 1), \toggle), h.backKind((msg: \program, num: 1), \continuous),
        h.backKind((msg: \note, num: 1), \continuous), h.backKind((msg: \cc, num: 1, switch: \pressRelease), \choice),
        h.backKind((msg: \bend), \toggle)],
    [nil, nil, nil, nil, nil, nil, nil]);
b = (msg: \cc, num: 1);
~tEq.("a level is sent where a knob would put it: its place along the law, over 0-127",
    [0, 2.5, 5, 10].collect { |x| h.backValue(b, \continuous, x, { |y| y / 10 }) }, [0, 32, 64, 127]);
~tEq.("...between the binding's min and max, and turned round",
    [h.backValue(b.copy.putAll((min: 2, max: 4)), \continuous, 2.5, { |y| y / 10 }),
        h.backValue(b.copy.putAll((min: 4, max: 2)), \continuous, 2.5, { |y| y / 10 })], [32, 95]);
~tEq.("...in its input range, and at an end for a control beyond the binding's range",
    [h.backValue(b.copy.putAll((inLo: 10, inHi: 110)), \continuous, 5, { |y| y / 10 }),
        h.backValue(b.copy.putAll((min: 2, max: 4)), \continuous, 9, { |y| y / 10 }),
        h.backValue(b.copy.putAll((min: 2, max: 4)), \continuous, 1, { |y| y / 10 })], [60, 127, 0]);
~tEq.("...on pitch bend over 0-16383", h.backValue((msg: \bend), \continuous, 5, { |y| y / 10 }), 8192);
~tEq.("a count is sent its place, a choice its item's middle",
    [h.backValue(b, \step, 3, { |y| y / 4 }), h.backValue(b, \choice, 2, { |i| (i + 0.5) / 4 })], [95, 79]);
~tEq.("a toggle 127 on, 0 off; one not known, nothing",
    [true, false, nil].collect { |x| h.backValue((msg: \note, num: 1), \toggle, x) }, [127, 0, nil]);
~tEq.("...and nothing for what has nothing to send: a trigger, a level with no value or not a number, one on a program change",
    [h.backValue(b, \trigger, 1), h.backValue(b, \continuous, nil, { |y| y }), h.backValue(b, \continuous, "x", { |y| y }),
        h.backValue((msg: \program, num: 1), \continuous, 5, { |y| y / 10 })], [nil, nil, nil, nil]);
// What a knob sent its control's place does with it, as the router reads
// it: the same value back. A count and a choice exactly; a level within
// half a step, on a straight law and on the threshold's exponential one.
~tAssert.("a count sent its place comes back to the same count, of 8 and of 101",
    [7, 100].every { |top| (0..top).every { |x| var w = h.backValue(b, \step, x, { |y| y / top });
        h.valueAt(h.position(w), { |c| c * top }, { |y| y / top }).round == x } });
~tAssert.("...a choice to the same item, of 2, 4 and 13",
    [2, 4, 13].every { |size| (0..(size - 1)).every { |i| var w = h.backValue(b, \choice, i, { |y| (y + 0.5) / size });
        h.choiceIndex(h.position(w), size) == i } });
~tAssert.("...a level to within half a step of its place, on a straight law and on the threshold's",
    [[{ |c| c * 10 }, { |y| y / 10 }], [{ |c| ~onsetThresholdSpec.map(c) }, { |y| ~onsetThresholdSpec.unmap(y) }]].every { |law|
        (0, 0.01 .. 1).every { |p| var w = h.backValue(b, \continuous, law[0].(p), law[1]);
            (law[1].(h.valueAt(h.position(w), law[0], law[1])) - p).abs <= ((0.5 / 127) + 1e-9) } });
// What the router keeps of a knob it has just sent its place: the place,
// noted; whether the knob took it, its next message says.
st = h.sentBack((last: 70, dir: 1, k: 70 / 127, pos: 0.55, caught: true, readBack: 5.5, mode: \pickup), b, \continuous, 68, 5.36);
~tEq.("a knob sent its place: what the router kept of it stays, and the place sent is noted, with the control's value it was sent for",
    [st[\sent], st[\sentFor], st[\last], st[\dir], st[\k], st[\pos], st[\caught], st[\readBack], st[\mode]],
    [68, 5.36, 70, 1, 70 / 127, 0.55, true, 5.5, \pickup]);
~tEq.("...with nothing kept before too; a CC knob on a toggle keeps its side, the place noted beside it",
    [h.sentBack(nil, b, \continuous, 60)[\sent], h.sentBack(true, b, \toggle, 0), h.sentBack(false, b, \toggle, 127)],
    [60, (side: true, sent: 0), (side: false, sent: 127)]);
~tEq.("...and its next message near the place sent takes the place's side; further off, its old one",
    [h.decide(\toggle, b, \cc, 1, (side: true, sent: 0))[0], h.decide(\toggle, b, \cc, 70, (side: true, sent: 0))[0],
        h.decide(\toggle, b, \cc, 31, (side: false, sent: 127))[0], h.decide(\toggle, b, \cc, 126, (side: false, sent: 127))[0]],
    [nil, nil, nil, nil]);
~tEq.("...so it switches only once the knob has gone the other way from where it is",
    [h.decide(\toggle, b, \cc, 64, h.decide(\toggle, b, \cc, 1, (side: true, sent: 0))[1])[0],
        h.decide(\toggle, b, \cc, 56, h.decide(\toggle, b, \cc, 126, (side: false, sent: 127))[1])[0]],
    [[\set, true], [\set, false]]);
~tEq.("forgotten (the router didn't see the knob), the place sent goes too, and the hysteresis's last value stays",
    h.forget((sent: 64, sentFor: 5, last: 30, k: 0.2), \continuous), (last: 30));
// The mouse nudged the control two steps down, against the knob's last turn
// up, and the knob was sent 68: its first step either way takes it.
st = h.sentBack((last: 70, dir: 1, k: 70 / 127, caught: true, readBack: (70 / 127) * 10, mode: \pickup), b, \continuous, 68, 5.36);
~tEq.("pick-up: a knob sent its place after the mouse nudged the control against its last turn takes it at its first step, either way",
    [69, 67].collect { |x| h.decide(\continuous, b.copy.put(\takeover, \pickup), \cc, x, st,
        (hysteresis: 1, current: 0.536, value: 5.36))[0] }, [[\position, 69 / 127], [\position, 67 / 127]]);
// 68 is a hair below 0.536: three steps down at once stay on that side.
~tEq.("...and three steps at once (an encoder turned fast), even the way the place sent was rounded",
    [71, 65].collect { |x| h.decide(\continuous, b.copy.put(\takeover, \pickup), \cc, x, st,
        (hysteresis: 1, current: 0.536, value: 5.36))[0] }, [[\position, 71 / 127], [\position, 65 / 127]]);
~tEq.("...and jumping, its first step acts too, with the hysteresis",
    [69, 67].collect { |x| h.decide(\continuous, b, \cc, x, st, (hysteresis: 1))[0] }, [[\position, 69 / 127], [\position, 67 / 127]]);
~tEq.("...its second step too: the first was a move from the place sent, not a turn",
    h.decide(\continuous, b, \cc, 70, h.decide(\continuous, b, \cc, 69, st, (hysteresis: 1))[1], (hysteresis: 1))[0],
    [\position, 70 / 127]);
// A fader with no motor at 100 held the control; the mouse took the control
// to 0, then to 0.3: sent 0, then 38, the fader still at 100.
~tEq.("...but one that didn't take it (a fader with no motor) is held off as before, whichever way the place sent was rounded",
    [h.decide(\continuous, b.copy.put(\takeover, \pickup), \cc, 101,
        h.sentBack((last: 100, dir: 1, k: 100 / 127, caught: true, readBack: (100 / 127) * 10, mode: \pickup), b, \continuous, 0),
        (hysteresis: 1, current: 0, value: 0))[0],
    h.decide(\continuous, b.copy.put(\takeover, \pickup), \cc, 101,
        h.sentBack((last: 100, dir: 1, k: 100 / 127, caught: true, readBack: (100 / 127) * 10, mode: \pickup), b, \continuous, 38),
        (hysteresis: 1, current: 0.3, value: 3))[0]], [nil, nil]);
// Sent 64 while the mouse dragged the control past 5; it went on to 8 before
// the encoder was told.
st = h.sentBack((last: 25, dir: 1, k: 25 / 127, caught: true, readBack: 1.97, mode: \pickup), b, \continuous, 64, 5.0);
~tEq.("...and one near the place sent, its control moved again since, has to catch it: pick-up holds it off",
    h.decide(\continuous, b.copy.put(\takeover, \pickup), \cc, 65, st, (hysteresis: 1, current: 0.8, value: 8.0))[0], nil);
~tEq.("...and a pedal resting after a send still has its flicker left out",
    h.decide(\continuous, b, \cc, 99, h.sentBack((last: 100, dir: 1), b, \continuous, 38), (hysteresis: 1))[0], nil);
// Scale had the control at 0.6 with the knob at 20; the knob was sent 76.
st = h.sentBack((mode: \scale, k: 20 / 127, pos: 0.6, readBack: 6), b, \continuous, 76);
~tEq.("scale: a knob sent its place goes on from there by a step's share, up or down, not from where it was",
    [77, 75].collect { |x| h.decide(\continuous, b.copy.put(\takeover, \scale), \cc, x, st, (current: 0.6, value: 6))[0] !? { |a| a[1].round(1e-9) } },
    [(0.6 + (0.4 / 51)).round(1e-9), (0.6 - (0.6 / 76)).round(1e-9)]);
// The mouse took the control from 0.6 to 0.3, and the knob was sent 38.
st = h.sentBack((mode: \scale, k: 20 / 127, readBack: 6), b, \continuous, 38);
~tEq.("...also when it was sent its place because the mouse moved the control: its first step goes on from there",
    h.decide(\continuous, b.copy.put(\takeover, \scale), \cc, 39, st, (current: 0.3, value: 3))[0] !? { |a| a[1].round(1e-9) },
    (0.3 + (0.7 / 89)).round(1e-9));
st = h.sentBack((mode: \scale, k: 100 / 127, readBack: 3), b, \continuous, 38);
~tEq.("...and a pedal at 100 that didn't take it moves the control by its own step's share, as before: no slam",
    h.decide(\continuous, b.copy.put(\takeover, \scale), \cc, 101, st, (current: 0.3, value: 3))[0] !? { |a| a[1].round(1e-9) },
    (0.3 + (0.7 / 27)).round(1e-9));
// A map swapped in keeps where a binding's message came from (5.7), for a
// binding whose range changed.
m = h.new([(msg: \cc, num: 11, target: 'x')]);
m.slots[0][\states].put(\back, IdentityDictionary[1002 -> Array.newClear(16).put(3, (wire: 100, value: 7.8))]);
m2 = m.replacing(m.bindings[0], m.bindings[0].copy.putAll((min: 1, max: 0))).adopt(m);
~tEq.("a mapping whose range changed keeps the places its message came from, with what they show not known",
    [m2.slots[0][\states][\back] !? { |x| x[1002] !? { |y| y[3] } }, m2.slots[0][\states].size], [(), 1]);
m3 = m.replacing(m.bindings[0], m.bindings[0].copy.put(\num, 12)).adopt(m);
~tEq.("...one on another message, none", m3.slots[0][\states][\back], nil);

// ---------------------------------------------------------- the router --
// Stub controls whose values the test sets as the mouse would, a map on a
// controller "UC4" (channel 1, as learned), outputs that write down what they
// are sent, MIDIClient's lists of inputs and outputs, and a scratch folder of
// yours with settings.json in it.
keys = [\midiMap, \midiTargets, \midiSources, \midiDestinations, \midiBackOpen, \midiBackClock, \midiNow,
    \midiBackSrcs, \midiBackTo, \midiBackOuts, \midiBackSent, \midiBackFor, \midiBackStale, \midiBackMax,
    \midiWarned, \midiDefaults, \midiLearning, \midiDeaf, \midiLastSeen, \midiSweep, \midiLearnNote,
    \midiChanged, \midiUndo, \midiKept, \midiBackWarn, \midiBackOwners, \midiBackBySlot, \midiBackTickAt,
    \midiClientSources, \midiClientDestinations, \midiBackGen, \midiUserRootOverride, \midiSettings,
    \midiSettingsFrom, \midiWriteSync, \midiBackTick, \midiOut, \midiLog, \midiMonitorPush, \iacSources,
    \midiBackSched, \midiBackFree, \midiBackLastSent, \midiLearnClock, \midiLearnNote];
saved = keys.collect { |k| currentEnvironment.at(k) };
protect {
    ~midiUserRootOverride = ~tTempPath.("midiback-user");
    ~midiWriteSync = true;
    ~midiSettings = nil;
    vals = IdentityDictionary[\lvl -> 5, \cnt -> 2, \pick -> 1, \tog -> false, \tog2 -> false, \tog3 -> false,
        \tog4 -> false, \tog5 -> false, \lvl2 -> 5, \lvl3 -> 5, \lvl4 -> 5, \lvl5 -> 5, \lvl6 -> 6, \lay1 -> 2, \lay2 -> 8,
        \lay3 -> 5, \lay4 -> 5];
    mk = { |id, kind, extra|
        var t = (id: id, kind: kind, get: { vals[id] }, set: { |x| vals.put(id, x) },
            fromPos: { |c| c * 10 }, toPos: { |y| y / 10 });
        if(kind == \toggle) { t.put(\flip, { vals.put(id, (vals[id] == true).not) }) };
        extra !? { |x| t.putAll(x) };
        t
    };
    targets = IdentityDictionary.new;
    [\lvl, \lvl2, \lvl3, \lvl4, \lvl5, \lvl6, \lay1, \lay2, \lay3, \lay4].do { |id| targets.put(id, mk.(id, \continuous)) };
    [\tog, \tog2, \tog3, \tog4, \tog5].do { |id| targets.put(id, mk.(id, \toggle)) };
    targets.put(\cnt, mk.(\cnt, \step, (fromPos: { |c| c * 4 }, toPos: { |y| y / 4 })));
    targets.put(\pick, mk.(\pick, \choice, (items: ["a", "b", "c", "d"], fromPos: { |c| h.choiceIndex(c, 4) },
        toPos: { |i| (i + 0.5) / 4 })));
    targets.put(\go, (id: \go, kind: \trigger, fire: { }));
    map = h.new([
        (msg: \cc, num: 10, chan: 0, device: "UC4", target: \lvl),
        (msg: \cc, num: 11, chan: 0, device: "UC4", target: \cnt),
        (msg: \cc, num: 12, chan: 0, device: "UC4", target: \pick),
        (msg: \note, num: 60, chan: 0, device: "UC4", target: \tog),
        (msg: \cc, num: 13, chan: 0, device: "UC4", target: \tog2),
        (msg: \cc, num: 14, chan: 0, device: "UC4", target: \tog3, switch: \pressRelease),
        (msg: \cc, num: 17, chan: 0, device: "UC4", target: \tog4, switch: \oneMessage),
        (msg: \note, num: 62, chan: 0, device: "UC4", target: \tog5, mode: \hold),
        (msg: \program, num: 5, chan: 0, device: "UC4", target: \go),
        (msg: \cc, num: 15, chan: 0, device: "UC4", target: \go),
        (msg: \note, num: 61, chan: 0, device: "UC4", target: \lvl),
        (msg: \cc, num: 20, target: \lvl2),
        (msg: \bend, chan: 1, device: "UC4", target: \lvl3),
        (msg: \cc, num: 16, chan: 0, device: "UC4", target: \lvl4, takeover: \pickup),
        (msg: \cc, num: 18, chan: 0, device: "UC4", target: \lvl6, takeover: \scale),
        (msg: \cc, num: 21, chan: 0, device: "UC4", target: \lay1, layer: true),
        (msg: \cc, num: 21, chan: 0, device: "UC4", target: \lay2, layer: true),
        (msg: \cc, num: 23, chan: 0, device: "UC4", target: \lay3, layer: true, takeover: \pickup),
        (msg: \cc, num: 23, chan: 0, device: "UC4", target: \lay4, layer: true, takeover: \pickup),
        (msg: \cc, num: 22, chan: 0, device: "TSMEGA", target: \lvl),
        (msg: \cc, num: 30, chan: 0, device: "Pad", target: \lvl5)
    ], "back");
    srcs = IdentityDictionary[1001 -> ["TSMEGA", "TSMEGA"], 1002 -> ["UC4", "UC4"], 1003 -> ["Keys", "Keys"],
        1004 -> ["IAC Driver", "Bus 1"], 1005 -> ["Pad", "Pad"]];
    dests = IdentityDictionary[2001 -> ["TSMEGA", "TSMEGA"], 2002 -> ["UC4", "UC4"], 2004 -> ["IAC Driver", "Bus 1"],
        2005 -> ["Pad", "Pad"]];
    fakeSrcs = srcs.keys.asArray.sort.collect { |u| (uid: u, device: srcs[u][0], name: srcs[u][1]) };
    fakeDests = dests.keys.asArray.sort.collect { |u| (uid: u, device: dests[u][0], name: dests[u][1]) };
    ~midiClientSources = { fakeSrcs };
    ~midiClientDestinations = { fakeDests };
    // settings.json says what `settings` says, and is the one in memory.
    v = ~midiSettingsRead.();
    [["UC4", true], ["Keys", true], ["IAC Driver", true], ["Pad", false]].do { |x| v[\sendBack].put(x[0], x[1]) };
    ~midiSettingsWrite.(v);
    ~midiSettings = nil;
    settings = ~midiSettingsNow.();
    sent = List.new;
    said = List.new;
    open = { |uid|
        var o = (uid: uid);
        [\control, \bend, \noteOn, \noteOff].do { |sel| o.put(sel, { |self ... args| sent.add([uid, sel] ++ args); self }) };
        o
    };
    ~midiMap = map; ~midiTargets = targets; ~midiSources = srcs; ~midiDestinations = dests;
    ~midiBackOpen = open; ~midiNow = { now }; ~midiChanged = { };
    ~midiBackWarn = { |text| said.add(text) };
    // No clock: the tests tick by hand, and learning's clock doesn't run.
    real = ~midiBackClock;
    ~midiBackClock = { };
    ~midiLearnClock = { };
    ~midiWarned = IdentitySet.new; ~midiDefaults = ~midiKnobDefaults.copy; ~midiLearning = nil;
    ~midiDeaf = IdentitySet.new; ~midiLastSeen = Dictionary.new; ~midiSweep = nil; ~midiUndo = List.new;
    ~midiBackOuts = IdentityDictionary.new; ~midiBackSent = Dictionary.new; ~midiBackFor = nil;
    ~midiBackLastSent = Dictionary.new; ~midiBackFree = IdentityDictionary.new;
    route ={ |msg, chan, num, val, src = 1002| ~midiRoute.(msg, chan, num, val, src) };
    tick = { ~midiBackTick.(now) };
    sends = { var a = sent.asArray; sent.clear; a };
    order = { |list| list.copy.sort { |p, q| p.asString < q.asString } };

    // ---- which inputs
    ~tEq.("the map for these tests has no problems", map.problems.asArray, []);
    ~midiBackFrom.(settings);
    ~tEq.("sent back to: an input switched on and listened to, to its output of the same names; not one with no output, nor an IAC bus",
        [~midiBackSrcs.asArray.sort, ~midiBackTo[1002]], [[1002], 2002]);
    ~midiDeaf.add(1002);
    ~midiBackFrom.(settings);
    ~tEq.("...nor one not listened to", ~midiBackSrcs.size, 0);
    ~midiDeaf = IdentitySet.new;
    ~midiBackFrom.((sendBack: Dictionary["UC4" -> false]));
    n = ~midiBackSrcs.size;
    ~midiBackFrom.(());
    ~tEq.("...nor one switched off, and none at all by default", [n, ~midiBackSrcs.size], [0, 0]);
    ~midiSources = IdentityDictionary[11 -> ["Box", "Port 1"], 12 -> ["Box", "Port 2"], 13 -> ["Pad", "Pad In"]];
    ~midiDestinations = IdentityDictionary[21 -> ["Box", "Port 1"], 22 -> ["Box", "Port 2"], 23 -> ["Pad", "Pad Out"]];
    ~midiBackFrom.((sendBack: Dictionary["Box" -> true, "Pad" -> true]));
    ~tEq.("...each input to the output of its names, else, for a device of one input and one output, to that",
        [11, 12, 13].collect { |u| ~midiBackTo[u] }, [21, 22, 23]);
    ~midiDestinations = IdentityDictionary[21 -> ["Box", "Port 1"], 22 -> ["Box", "Port 3"], 24 -> ["Box", "Port 4"],
        23 -> ["Pad", "Pad Out"], 25 -> ["Pad", "Pad Thru"]];
    ~midiBackFrom.((sendBack: Dictionary["Box" -> true, "Pad" -> true]));
    ~tEq.("...and to none where its device has several and none of its names, of one input or of several",
        [11, 12, 13].collect { |u| ~midiBackTo[u] }, [21, nil, nil]);
    ~midiDestinations = IdentityDictionary[21 -> ["Box", "Out"]];
    ~midiBackFrom.((sendBack: Dictionary["Box" -> true]));
    ~tEq.("...nor to a device's only output when it has two inputs: one output to one input", ~midiBackSrcs.size, 0);
    ~midiDeaf.add(12);
    ~midiBackFrom.((sendBack: Dictionary["Box" -> true]));
    ~tEq.("...even with only one of them listened to: which input it is the output of isn't known", ~midiBackSrcs.size, 0);
    ~midiDeaf = IdentitySet.new;
    ~midiSources = IdentityDictionary[11 -> ["UC4", "UC4"], 12 -> ["UC4", "UC4"]];
    ~midiDestinations = IdentityDictionary[21 -> ["UC4", "UC4"], 22 -> ["UC4", "UC4"]];
    ~midiBackFrom.((sendBack: Dictionary["UC4" -> true]));
    ~tEq.("...nor two controllers alike: which output is whose isn't known", ~midiBackSrcs.size, 0);
    ~midiDestinations = IdentityDictionary[21 -> ["UC4", "UC4"]];
    ~midiBackFrom.((sendBack: Dictionary["UC4" -> true]));
    ~tEq.("...and two inputs of one name on one output (one gone, one new), neither", ~midiBackSrcs.size, 0);
    ~midiSources = srcs;
    ~midiDestinations = dests;
    ~tEq.("the Rig tab offers it for an input with an output only", ["UC4", "TSMEGA", "Keys", "Pad"].collect { |d| ~midiBackCan.(d) },
        [true, true, false, true]);
    ~midiBackFrom.(settings);

    // ---- the first tick, and in sync
    n = tick.();
    got = sends.();
    ~tEq.("the first tick sends each control bound on that controller where it is, all to its output",
        [n, got.every { |x| x[0] == 2002 }], [13, true]);
    ~tEq.("...a level, a count, a choice, pitch bend, a CC knob's toggle, and the lights of two notes' and two CC switches'; "
        "not a trigger, a program change, a level on a note, another input's, nor one of no channel not heard yet; "
        "and an encoder two layered bindings share, the first's",
        order.(got.collect(_.drop(1))),
        order.([[\control, 0, 10, 64], [\control, 0, 11, 64], [\control, 0, 12, 48], [\noteOff, 0, 60, 0],
            [\control, 0, 13, 0], [\control, 0, 14, 0], [\control, 0, 17, 0], [\noteOff, 0, 62, 0], [\bend, 1, 8192],
            [\control, 0, 16, 64], [\control, 0, 18, 76], [\control, 0, 21, 25], [\control, 0, 23, 64]]));
    ~tEq.("...and the next tick nothing: it shows what it was sent", [tick.(), sends.()], [0, []]);
    vals.put(\lay2, 3);
    ~tEq.("...nor for the second of the layered two when its control moves", [tick.(), sends.()], [0, []]);
    targets[\lay1].put(\available, { false });
    vals.put(\lay2, 6);
    now = now + 1;
    tick.();
    ~tEq.("...but while the first's control isn't there, the second shows on the encoder", sends.(), [[2002, \control, 0, 21, 76]]);
    targets[\lay1].removeAt(\available);
    now = now + 1;
    tick.();
    ~tEq.("...and back, the first is sent its own place again: what the encoder shows of it wasn't known", sends.(),
        [[2002, \control, 0, 21, 25]]);
    // Two layered pick-up knobs: a send for the first moves the encoder under
    // the second, which then has to catch its control again.
    now = now + 1;
    [65, 70, 80, 100].do { |x| route.(\cc, 0, 23, x) };
    ~tEq.("two layered pick-up knobs follow the encoder together", [vals[\lay3], vals[\lay4]], [(100 / 127) * 10, (100 / 127) * 10]);
    vals.put(\lay3, 2);
    now = now + 1;
    tick.();
    ~tEq.("...the mouse moves the first's control: the encoder is sent its place", sends.(), [[2002, \control, 0, 23, 25]]);
    route.(\cc, 0, 23, 26);
    ~tEq.("...and its next turn takes the first from there, and leaves the second where it was",
        [vals[\lay3], vals[\lay4]], [(26 / 127) * 10, (100 / 127) * 10]);
    targets[\lay3].put(\available, { false });
    now = now + 1;
    tick.();
    ~tEq.("...while the first's control isn't there, the second is sent its own place", sends.(), [[2002, \control, 0, 23, 100]]);
    targets[\lay3].removeAt(\available);
    now = now + 1;
    tick.();
    ~tEq.("...and back, the first its own again", sends.(), [[2002, \control, 0, 23, 26]]);

    // ---- a knob's own moves, the mouse's
    now = now + 1;
    route.(\cc, 0, 10, 100);
    ~tNear.("an encoder turned sets its control", vals[\lvl], (100 / 127) * 10, 1e-9);
    now = now + 1;
    ~tEq.("...and is sent nothing back: its control is where its own move put it", [tick.(), sends.()], [0, []]);
    route.(\cc, 0, 10, 99);
    now = now + 1;
    ~tEq.("...nor after a step back that the hysteresis leaves out: that is not undone",
        [vals[\lvl] == ((100 / 127) * 10), tick.(), sends.()], [true, 0, []]);
    // The mouse, while the encoder is touched.
    vals.put(\lvl, 2.5);
    route.(\cc, 0, 10, 99);
    ~tEq.("the mouse moves the control while its encoder is touched: nothing is sent yet", [tick.(), sends.()], [0, []]);
    now = now + 0.2;
    ~tEq.("...nor a moment later", tick.(), 0);
    now = now + 0.11;
    tick.();
    ~tEq.("...but once the encoder has been left alone for 0.3 s, it is sent the control's place", sends.(),
        [[2002, \control, 0, 10, 32]]);
    ~tEq.("...once", [tick.(), sends.()], [0, []]);
    now = now + 1;
    route.(\cc, 0, 10, 33);
    ~tNear.("...and its next turn goes on from there, with no jump", vals[\lvl], (33 / 127) * 10, 1e-9);
    // A count's and a choice's bands.
    now = now + 1;
    [65, 66, 67].do { |x| route.(\cc, 0, 11, x) };
    now = now + 1;
    ~tEq.("a count's band holds several values: an encoder turned within it is sent nothing back",
        [vals[\cnt], tick.(), sends.()], [2, 0, []]);
    [50, 53, 56].do { |x| route.(\cc, 0, 12, x) };
    now = now + 1;
    ~tEq.("...nor within a choice's", [vals[\pick], tick.(), sends.()], [1, 0, []]);
    route.(\cc, 0, 11, 80);
    vals.put(\cnt, 0);
    now = now + 1;
    tick.();
    ~tEq.("...but moved by the mouse, a count is sent its place", sends.(), [[2002, \control, 0, 11, 0]]);
    // Pick-up: an encoder sent its control's place catches it at once.
    now = now + 1;
    route.(\cc, 0, 16, 65);
    ~tNear.("pick-up: an encoder sent its control's place takes it with its first step", vals[\lvl4], (65 / 127) * 10, 1e-9);
    vals.put(\lvl4, 8);
    now = now + 1;
    tick.();
    ~tEq.("...moved by the mouse, it is sent the new place", sends.(), [[2002, \control, 0, 16, 102]]);
    now = now + 1;
    route.(\cc, 0, 16, 101);
    ~tNear.("...and takes it again with its first step, down this time", vals[\lvl4], (101 / 127) * 10, 1e-9);
    // Turned up to 105, then the mouse nudges it two steps back down: sent
    // 103, the encoder's next step up takes it (the hysteresis would have
    // left out a step back from 105).
    now = now + 1;
    route.(\cc, 0, 16, 105);
    vals.put(\lvl4, (103.07 / 127) * 10);
    now = now + 1;
    tick.();
    sends.();
    route.(\cc, 0, 16, 104);
    ~tNear.("...nudged by the mouse against its last turn, it takes it at its first step", vals[\lvl4], (104 / 127) * 10, 1e-9);
    // Sent 64 for 5, then the mouse goes on to 8 within the hold: the encoder,
    // turned from 64 before it is told, has to catch it.
    vals.put(\lvl4, 5);
    now = now + 1;
    tick.();
    ~tEq.("...the mouse moves it: it is sent its place", sends.(), [[2002, \control, 0, 16, 64]]);
    vals.put(\lvl4, 8);
    now = now + 0.1;
    tick.();
    route.(\cc, 0, 16, 65);
    ~tEq.("...moved again before the encoder is told, a turn from the place sent is held off by pick-up", [sends.(), vals[\lvl4]], [[], 8]);
    now = now + 1;
    tick.();
    route.(\cc, 0, 16, 103);
    ~tEq.("...and once it is told, it takes it again", [sends.(), vals[\lvl4]], [[[2002, \control, 0, 16, 102]], (103 / 127) * 10]);
    // Sent 64 for 5 (a hair above 0.5), then turned fast: three steps up.
    vals.put(\lvl4, 5);
    now = now + 1;
    tick.();
    sends.();
    route.(\cc, 0, 16, 67);
    ~tNear.("...and turned fast, three steps from the place sent, it takes it too", vals[\lvl4], (67 / 127) * 10, 1e-9);
    // Scale: 20, then 22 has the control a step's share up; sent everything
    // again (Send back switched on, a Rescan), the next step goes on from there.
    now = now + 1;
    route.(\cc, 0, 18, 20);
    route.(\cc, 0, 18, 22);
    v = vals[\lvl6];
    ~midiBackAgain.();
    now = now + 1;
    tick.();
    w = sends.().detect { |x| (x[1] == \control) and: { x[3] == 18 } };
    route.(\cc, 0, 18, w[4] + 1);
    ~tAssert.("scale: an encoder sent its control's place goes on from there by a step's share, not from where it was",
        (vals[\lvl6] - v).inclusivelyBetween(0, 0.1), "sent " ++ w ++ ", the control went from " ++ v ++ " to " ++ vals[\lvl6]);
    // Another controller.
    now = now + 1;
    route.(\cc, 0, 22, 70, 1001);
    now = now + 1;
    tick.();
    ~tEq.("another controller moves a control: the encoder on it is sent where it put it", sends.(),
        [[2002, \control, 0, 10, 70]]);

    // ---- lights
    now = now + 1;
    route.(\noteOn, 0, 60, 127);
    ~tEq.("a button pressed flips its toggle, and its light is sent at once", [vals[\tog], sends.()],
        [true, [[2002, \noteOn, 0, 60, 127]]]);
    now = now + 0.1;
    route.(\noteOff, 0, 60, 0);
    ~tEq.("...and again when it is let go: the controller may have darkened it itself", sends.(),
        [[2002, \noteOn, 0, 60, 127]]);
    ~tEq.("...and then nothing more", [tick.(), sends.()], [0, []]);
    vals.put(\tog, false);
    tick.();
    ~tEq.("the mouse turns the toggle off: its light goes off at the next tick, as a note off", sends.(),
        [[2002, \noteOff, 0, 60, 0]]);
    targets[\tog].put(\flip, { });
    now = now + 0.1;
    route.(\noteOn, 0, 60, 127);
    ~tEq.("a press the model refuses leaves the toggle off, and its light is put right", [vals[\tog], sends.()],
        [false, [[2002, \noteOff, 0, 60, 0]]]);
    targets[\tog].put(\flip, { vals.put(\tog, (vals[\tog] == true).not) });
    now = now + 0.1;
    route.(\noteOff, 0, 60, 0);
    sends.();
    // Tapped on and off, fast, over USB where nothing comes back: the second
    // press, 30 ms after the light the release had sent, is the hand's.
    now = now + 1;
    route.(\noteOn, 0, 60, 127);
    now = now + 0.06;
    route.(\noteOff, 0, 60, 0);
    now = now + 0.03;
    route.(\noteOn, 0, 60, 127);
    ~tEq.("tapped on and off fast, the second press is no echo of the light the release had sent: it turns the toggle off",
        [vals[\tog], sends.()], [false, [[2002, \noteOn, 0, 60, 127], [2002, \noteOn, 0, 60, 127], [2002, \noteOff, 0, 60, 0]]]);
    now = now + 0.01;
    ~tEq.("...and its release, 10 ms after the light off went, goes on to the bindings and Live, with nothing sent again for it",
        [route.(\noteOff, 0, 60, 0), tick.(), sends.()], [[], 0, []]);
    now = now + 1;
    route.(\noteOn, 0, 60, 127);
    now = now + 0.01;
    route.(\noteOff, 0, 60, 0);
    ~tEq.("a quick tap's release, 10 ms after its light on went, has the light sent again: the controller may have darkened it",
        [vals[\tog], sends.()], [true, [[2002, \noteOn, 0, 60, 127], [2002, \noteOn, 0, 60, 127]]]);
    vals.put(\tog, false);
    now = now + 1;
    tick.();
    sends.();
    now = now + 0.1;
    route.(\cc, 0, 17, 64);
    ~tEq.("a one-message CC switch pressed: its light is sent, 127", [vals[\tog4], sends.()],
        [true, [[2002, \control, 0, 17, 127]]]);
    ~tEq.("...and its echo, even one a thru changed, is dropped: the toggle stays on",
        [route.(\cc, 0, 17, 64), vals[\tog4]], [\echo, true]);
    now = now + 0.1;
    route.(\cc, 0, 14, 127);
    now = now + 0.1;
    route.(\cc, 0, 14, 0);
    ~tEq.("a press-and-release CC switch: its light is sent on the press, and again on the release",
        [vals[\tog3], sends.()], [true, [[2002, \control, 0, 14, 127], [2002, \control, 0, 14, 127]]]);
    now = now + 0.1;
    route.(\noteOn, 0, 62, 127);
    // Let go at once, within the light's 20 ms.
    route.(\noteOff, 0, 62, 0);
    ~tEq.("a hold toggle let go just after its light was sent goes off: a release is no echo, and its light goes out at once",
        [vals[\tog5], sends.()], [false, [[2002, \noteOn, 0, 62, 127], [2002, \noteOff, 0, 62, 0]]]);
    ~tEq.("...with nothing more for the tick", [tick.(), sends.()], [0, []]);
    // Over a DIN thru: let go before the light's echo is back.
    now = now + 0.1;
    route.(\noteOn, 0, 62, 127);
    now = now + 0.005;
    route.(\noteOff, 0, 62, 0);
    now = now + 0.003;
    ~tEq.("...and let go before its light's echo is back, that echo is still dropped: it stays off",
        [route.(\noteOn, 0, 62, 127), vals[\tog5]], [\echo, false]);
    tick.();
    sends.();
    now = now + 1;
    route.(\cc, 0, 13, 100);
    ~tEq.("a CC knob on a toggle: turned past the middle, the toggle goes on, and it is sent nothing back",
        [vals[\tog2], tick.(), sends.()], [true, 0, []]);
    vals.put(\tog2, false);
    now = now + 0.31;
    tick.();
    ~tEq.("...turned off by the mouse, it is sent 0 once it has been left alone", sends.(), [[2002, \control, 0, 13, 0]]);
    now = now + 1;
    [1, 30, 64].do { |x| route.(\cc, 0, 13, x) };
    ~tEq.("...and turned up from there past the middle, it goes on again", vals[\tog2], true);

    // ---- echoes
    vals.put(\lvl, 7.5);
    now = now + 1;
    tick.();
    ~tEq.("the mouse moves a level: its encoder is sent its place", sends.(), [[2002, \control, 0, 10, 95]]);
    ~tEq.("...and that coming straight back, as a MIDI thru sends it, is dropped: the level stays as the mouse set it",
        [route.(\cc, 0, 10, 95), vals[\lvl]], [\echo, 7.5]);
    ~tEq.("...once: the same value again is the encoder's", route.(\cc, 0, 10, 95), [\lvl]);
    vals.put(\lvl, 5);
    now = now + 1;
    tick.();
    sends.();
    ~tEq.("...and a turn of the encoder just after it was sent something is no echo: it acts",
        [route.(\cc, 0, 10, 62), vals[\lvl]], [[\lvl], (62 / 127) * 10]);
    vals.put(\lvl, 2.5);
    now = now + 1;
    tick.();
    sends.();
    now = now + 0.06;
    ~tEq.("...and so is one after the echo's 50 ms", route.(\cc, 0, 10, 32), [\lvl]);
    vals.put(\tog, true);
    now = now + 1;
    tick.();
    sends.();
    ~tEq.("a light's echo on a note is dropped whatever its velocity: it would flip the toggle back",
        [route.(\noteOn, 0, 60, 100), vals[\tog]], [\echo, true]);
    vals.put(\tog, false);
    now = now + 1;
    tick.();
    sends.();
    ~tEq.("a light off coming back, a note off (as SuperCollider hands over a note on of velocity 0 too), is no echo: "
        "a release goes on, and has nothing sent again so soon",
        [route.(\noteOff, 0, 60, 0), tick.(), sends.(), vals[\tog]], [[], 0, [], false]);
    ~tEq.("...and what was not sent back is no echo", route.(\noteOn, 0, 60, 127), [\tog]);
    vals.put(\tog, false);
    now = now + 1;
    tick.();
    sends.();

    // ---- when nothing is sent
    ~midiLearning = (learner: nil);
    vals.put(\lvl, 5);
    now = now + 1;
    ~tEq.("nothing is sent while a control is learning", tick.(), 0);
    ~midiLearning = nil;
    tick.();
    ~tEq.("...and what changed meanwhile goes after", sends.(), [[2002, \control, 0, 10, 64]]);
    // Another switch pressed while a learning counts a switch's presses goes
    // through, but its light waits for the learning's end.
    vals.put(\tog4, false);
    now = now + 1;
    ~midiLearnArm.(\tog2);
    route.(\cc, 0, 14, 127);
    now = now + 0.1;
    ~midiLearnLive.(now);
    route.(\cc, 0, 17, 127);
    ~tEq.("a one-message switch pressed while a learning counts another's presses switches, and is sent nothing yet",
        [~midiLearning !? { |l| l[\learner].counting }, vals[\tog4], sends.()], [true, true, []]);
    ~midiLearnDisarm.(nil);
    now = now + 1;
    tick.();
    ~tAssert.("...and once the learning is over, its light: what the switch shows of it isn't known",
        sends.().any { |x| x == [2002, \control, 0, 17, 127] });
    ~midiSweep = (binding: map.bindings[0], until: now + 20);
    vals.put(\lvl, 2.5);
    vals.put(\cnt, 4);
    now = now + 1;
    tick.();
    ~tEq.("while a knob's input range is swept, it alone is sent nothing", sends.(), [[2002, \control, 0, 11, 127]]);
    ~midiSweep = nil;
    tick.();
    ~tEq.("...and after, it is", sends.(), [[2002, \control, 0, 10, 32]]);
    targets[\lvl].put(\available, { false });
    vals.put(\lvl, 7.5);
    now = now + 1;
    ~tEq.("a control not there now is sent nothing", tick.(), 0);
    targets[\lvl].removeAt(\available);
    tick.();
    ~tEq.("...and once it is, its place", sends.(), [[2002, \control, 0, 10, 95]]);
    targets[\lvl].put(\available, { false });
    now = now + 1;
    route.(\cc, 0, 10, 20);
    targets[\lvl].removeAt(\available);
    now = now + 1;
    tick.();
    ~tEq.("a message while its control wasn't there: once it is, the encoder is sent its place again", sends.(),
        [[2002, \control, 0, 10, 95]]);
    // A control that can't be read, and one whose law throws: the others,
    // before and after them in the map, still are sent.
    targets[\lvl3].put(\get, { Error("unreadable").throw });
    vals.put(\cnt, 1);
    vals.put(\lvl6, 3);
    now = now + 1;
    tick.();
    ~tEq.("a control whose value can't be read is sent nothing, and the others still are", order.(sends.()),
        order.([[2002, \control, 0, 11, 32], [2002, \control, 0, 18, 38]]));
    targets[\lvl3].put(\get, { vals[\lvl3] });
    targets[\cnt].put(\toPos, { Error("a law on fire").throw });
    vals.put(\cnt, 2);
    vals.put(\lvl, 5);
    vals.put(\lvl6, 4);
    now = now + 1;
    tick.();
    ~tEq.("one that throws is skipped, and said: the others, before and after it, still are",
        [order.(sends.()), said.size, said.last.contains("cnt")],
        [order.([[2002, \control, 0, 10, 64], [2002, \control, 0, 18, 51]]), 1, true]);
    now = now + 1;
    tick.();
    ~tEq.("...said once, though it is tried again each time", said.size, 1);
    targets[\cnt].put(\toPos, { |y| y / 4 });
    now = now + 1;
    tick.();
    sends.();
    ~midiDeaf.add(1002);
    ~midiBackFrom.(settings);
    vals.put(\lvl, 2.5);
    now = now + 1;
    ~tEq.("an input not listened to is sent nothing", tick.(), 0);
    ~midiDeaf = IdentitySet.new;
    ~midiBackFrom.(settings);
    tick.();
    ~tEq.("...and listened to again, what changed meanwhile", sends.(), [[2002, \control, 0, 10, 32]]);
    // Another controller switched on: it is sent everything, the one already
    // sent back to nothing again.
    ~midiBackSwitch.("Pad", true);
    now = now + 1;
    tick.();
    ~tEq.("Send back switched on for another controller: it is sent everything, the first nothing again", sends.(),
        [[2005, \control, 0, 30, 64]]);
    ~tEq.("...and it is kept so in settings.json", ~midiSettingsRead.()[\sendBack]["Pad"], true);
    ~midiBackSwitch.("Pad", false);
    ~tEq.("...and switched off, it is kept so in settings.json", ~midiSettingsRead.()[\sendBack]["Pad"], false);
    tick.();
    sends.();

    // ---- a binding of no input and no channel: where its message came from
    now = now + 1;
    route.(\cc, 3, 20, 50);
    ~tNear.("a binding of no input and no channel is driven from any", vals[\lvl2], (50 / 127) * 10, 1e-9);
    tick.();
    ~tEq.("...sent nothing for its own move", sends.(), []);
    vals.put(\lvl2, 2.5);
    now = now + 1;
    tick.();
    ~tEq.("...but once something else moves its control, it is sent to where its message came from, input and channel",
        sends.(), [[2002, \control, 3, 20, 32]]);
    route.(\cc, 0, 20, 70, 1001);
    now = now + 1;
    tick.();
    ~tEq.("...and moved from an input that isn't sent back, only the one that is is sent where it is",
        sends.(), [[2002, \control, 3, 20, 70]]);
    ~midiBindingSwap.(~midiMap.bindings[11]);
    now = now + 1;
    tick.();
    ~tEq.("...turned round, it keeps where its message came from, and is sent its place in the new range",
        sends.(), [[2002, \control, 3, 20, 57]]);
    ~midiMapUndo.();
    now = now + 1;
    tick.();
    sends.();

    // ---- edits, a boot, a message unseen
    m = ~midiMap;
    ~midiMapEdit.(m.replacing(m.bindings[1], m.bindings[1].copy.put(\hysteresis, 0)));
    now = now + 1;
    ~tEq.("an edit of the map sends nothing again: every controller shows what it did", [tick.(), sends.()], [0, []]);
    vals.put(\lvl, 5);
    tick.();
    sends.();
    ~midiBindingChange.(~midiMap.bindings[0], (min: 0, max: 5));
    now = now + 1;
    tick.();
    ~tEq.("...but a mapping whose range changed is sent its control's place in the new range", sends.(),
        [[2002, \control, 0, 10, 127]]);
    ~midiMapUndo.();
    now = now + 1;
    tick.();
    ~tEq.("...and back by Undo, in the old range", sends.(), [[2002, \control, 0, 10, 64]]);
    // As the Cmd-period hook and a boot do it.
    ~midiMap.forgetStates;
    ~midiBackStale = true;
    now = now + 1;
    tick.();
    ~tEq.("after a boot or a Cmd-period (the router's states afresh) every controller is sent everything again",
        sends.().size, 13);
    ~midiForget.(\cc, 0, 10, 1002);
    now = now + 1;
    tick.();
    ~tEq.("a message the router didn't see (learning took it): its controller is sent its place again", sends.(),
        [[2002, \control, 0, 10, 64]]);
    max = ~midiBackMax;
    ~midiBackMax = 3;
    ~midiMap.forgetStates;
    ~midiBackStale = true;
    now = now + 1;
    ~tEq.("a tick sends at most ~midiBackMax messages, the rest the next ones", [tick.(), tick.(), tick.(), tick.(), tick.()],
        [3, 3, 3, 3, 1]);
    sends.();
    ~midiBackMax = max;

    // ---- an output that fails, and Rescan
    ~midiBackOuts.put(2002, (control: { |self| Error("unplugged").throw }));
    vals.put(\lvl, 7.5);
    now = now + 1;
    ~tEq.("an output that fails is said once, and sent nothing more",
        [tick.(), ~midiBackOuts[2002], ~midiLearnNote, said.last.contains("UC4")],
        [0, \dead, "Sending back to UC4 failed: Rescan to try again", true]);
    calls = 0;
    targets[\cnt].put(\toPos, { |y| calls = calls + 1; y / 4 });
    vals.put(\cnt, 3);
    ~tEq.("...and costs nothing more: its controls' places aren't worked out until a Rescan", [tick.(), calls], [0, 0]);
    targets[\cnt].put(\toPos, { |y| y / 4 });
    v = ~midiSettingsRead.();
    v[\sendBack].put("UC4", true);
    ~midiSettingsWrite.(v);
    ~midiSettings = nil;
    ~midiBackRescan.();
    tick.();
    ~tEq.("...Rescan lists the outputs again, opens them afresh, and sends everything", [sends.().size, ~midiDestinations.keys.asArray.sort],
        [13, [2001, 2002, 2005]]);
    // A pedal at 100 that can't take what it is sent, sent 32: armed for a
    // learning, its next flicker is a step from where it is, not from 32.
    ~midiLastSeen.put(LooperMidiLearn.key(\cc, 0, 10, 1002), [100, now - 5]);
    vals.put(\lvl, 2.5);
    now = now + 1;
    tick.();
    ~tEq.("what is sent is kept apart from what the input itself last sent: the pedal's 100 stays",
        [sends.(), ~midiLastSeen[LooperMidiLearn.key(\cc, 0, 10, 1002)] !? { |x| x[0] }], [[[2002, \control, 0, 10, 32]], 100]);
    ~midiLearnArm.(\lvl2);
    route.(\cc, 0, 10, 101);
    now = now + 0.1;
    ~midiLearnLive.(now);
    ~tEq.("...so the flicker of a pedal that didn't take it is not learned: no question, no binding, still learning",
        [~midiLearning.notNil, ~midiLearning !? { |l| l[\question] }, ~midiMap.bindingsFor(\lvl2).size], [true, nil, 1]);
    ~midiLearnDisarm.(nil);
    // A pedal resting at 70, sent 67, which it can't take: its flicker on
    // either side of 68 is 3 steps from neither.
    ~midiLastSeen.put(LooperMidiLearn.key(\cc, 0, 10, 1002), [70, now - 5]);
    vals.put(\lvl, (67 / 127) * 10);
    now = now + 1;
    tick.();
    ~tAssert.("a pedal at 70 is sent 67", sends.().any { |x| x == [2002, \control, 0, 10, 67] });
    now = now + 1;
    ~midiLearnArm.(\lvl2);
    route.(\cc, 0, 10, 68);
    now = now + 0.1;
    ~midiLearnLive.(now);
    route.(\cc, 0, 10, 70);
    now = now + 0.1;
    ~midiLearnLive.(now);
    ~tEq.("...armed, its flicker to 68 and back to 70 is not learned: a CC counts 3 steps from both where it was and the place sent",
        [~midiLearning.notNil, ~midiLearning !? { |l| l[\question] }, ~midiMap.bindingsFor(\lvl2).size], [true, nil, 1]);
    route.(\cc, 0, 10, 64);
    now = now + 0.1;
    ~midiLearnLive.(now);
    ~tEq.("...but a move to 64, 3 steps from both, is: CC 10 is the level's, so it asks",
        [~midiLearning.notNil, (~midiLearning !? { |l| l[\question] }).notNil], [true, true]);
    ~midiLearnDisarm.(nil);
    // An encoder at 30 that took 102: armed, a brush of one click is a step
    // from where it is, not 73 from its own last message.
    ~midiLastSeen.put(LooperMidiLearn.key(\cc, 0, 10, 1002), [30, now - 5]);
    vals.put(\lvl, 8);
    now = now + 1;
    tick.();
    ~tEq.("an encoder that took what it was sent", sends.(), [[2002, \control, 0, 10, 102]]);
    now = now + 1;
    ~midiLearnArm.(\lvl2);
    route.(\cc, 0, 10, 103);
    now = now + 0.1;
    ~midiLearnLive.(now);
    ~tEq.("...is not learned from a brush of one click: it is a step from the place sent",
        [~midiLearning.notNil, ~midiLearning !? { |l| l[\question] }, ~midiMap.bindingsFor(\lvl2).size], [true, nil, 1]);
    route.(\cc, 0, 10, 106);
    now = now + 0.1;
    ~midiLearnLive.(now);
    ~tEq.("...but is from a turn of three clicks from there: CC 10 is the level's, so it asks",
        [~midiLearning.notNil, (~midiLearning !? { |l| l[\question] }).notNil], [true, true]);
    ~midiLearnDisarm.(nil);
    now = now + 1;
    route.(\cc, 0, 10, 110);
    now = now + 1;
    ~midiLearnArm.(\lvl2);
    route.(\cc, 0, 10, 103);
    now = now + 0.1;
    ~midiLearnLive.(now);
    ~tEq.("...and once it has turned since (to 110), it counts from its own again: back to 103 at once is learned",
        [~midiLearning.notNil, (~midiLearning !? { |l| l[\question] }).notNil], [true, true]);
    ~midiLearnDisarm.(nil);
    // Never heard since the boot, sent 32: its first message only says where
    // it is, as for any CC never seen, and the place sent counts for nothing.
    ~midiLastSeen.removeAt(LooperMidiLearn.key(\cc, 0, 10, 1002));
    vals.put(\lvl, 2.5);
    now = now + 1;
    tick.();
    ~tAssert.("a control never heard since the boot is sent its place", sends.().any { |x| x == [2002, \control, 0, 10, 32] });
    now = now + 1;
    ~midiLearnArm.(\lvl2);
    route.(\cc, 0, 10, 30);
    now = now + 0.1;
    ~midiLearnLive.(now);
    ~tEq.("...and armed, its first message is not learned: it only says where it is",
        [~midiLearning.notNil, ~midiLearning !? { |l| l[\question] }, ~midiMap.bindingsFor(\lvl2).size], [true, nil, 1]);
    route.(\cc, 0, 10, 33);
    now = now + 0.1;
    ~midiLearnLive.(now);
    ~tEq.("...but 3 steps on it is, though a step from the place sent: where it was is where its first message said",
        [~midiLearning.notNil, (~midiLearning !? { |l| l[\question] }).notNil], [true, true]);
    ~midiLearnDisarm.(nil);
    // A CC switch let go, its light sent 127 at once: a light is no place.
    vals.put(\tog3, false);
    now = now + 1;
    route.(\cc, 0, 14, 127);
    route.(\cc, 0, 14, 0);
    ~tEq.("a CC switch pressed and let go has its light sent at once each time", sends.(),
        [[2002, \control, 0, 14, 127], [2002, \control, 0, 14, 127]]);
    now = now + 1;
    ~midiLearnArm.(\tog);
    route.(\cc, 0, 14, 127);
    now = now + 0.1;
    ~midiLearnLive.(now);
    ~tEq.("...so armed for a learning, its next press counts from its release, not from its light: it is learned",
        [~midiLearning !? { |l| l[\learner].counting }, ~midiLearning !? { |l| l[\learner].chosenKey }],
        [true, LooperMidiLearn.key(\cc, 0, 14, 1002)]);
    ~midiLearnDisarm.(nil);

    // ---- the clock
    tk = ~midiBackTick;
    ticks = 0;
    ~midiBackTick = { ticks = ticks + 1; 0 };
    ~midiBackGen = 7;
    ~midiBackTickAt = nil;
    ~tEq.("the clock ticks while its generation is the one in force, one tick at a time when they bunch up, and stops after",
        [~midiBackClockStep.(7), ~midiBackClockStep.(7), ~midiBackClockStep.(6), ticks], [~midiBackRate, ~midiBackRate, nil, 1]);
    ~midiBackTick = tk;
    v = ~midiBackSrcs;
    scheduled = List.new;
    ~midiBackSched = { |delay, fn| scheduled.add(delay) };
    ~midiBackSrcs = IdentitySet.new;
    ~tEq.("...with no input sent back to there is none", [real.(), scheduled.size], [false, 0]);
    ~midiBackSrcs = v;
    ~tEq.("...and with one, its first tick a second on, after a boot's window is made", [real.(), scheduled.asArray],
        [true, [~midiBackFirst]]);

    // ---- cost, and bursts: 100 knobs on one controller
    many = (0..99).collect { |i| (msg: \cc, num: i, chan: 1, device: "UC4", target: \lvl) };
    ~midiMap = h.new(many, "many");
    now = now + 1;
    ~tEq.("100 knobs on one controller are sent their places 40 a tick, what a DIN wire carries in one", [tick.(), tick.(), tick.()],
        [40, 40, 20]);
    w = sends.();
    now = now + 0.08;
    ~tEq.("...each stamped with when it leaves the wire: the 40th's echo, 80 ms after the tick, is still taken for one",
        route.(\cc, 1, 39, w[39][4]), \echo);
    t0 = Main.elapsedTime;
    50.do { tick.() };
    t0 = (Main.elapsedTime - t0) / 50;
    ~tAssert.("...a tick over them, in sync, takes under a millisecond", t0 < 0.001, (t0 * 1000).round(0.001).asString ++ " ms");
    now = now + 1;
    keep = vals[\lvl];
    vals.put(\lvl, 7.5);
    tick.();
    sends.();
    ~tNear.("...and what is sent right after a burst leaves after it",
        ~midiBackSend.(2002, (msg: \note, num: 99), 0, 127, 1002, \light, now), now + 0.04, 1e-9);
    sends.();
    ~midiMap = map;
    vals.put(\lvl, keep);
    ~midiBackFree = IdentityDictionary.new;

    // ---- a device of two ports, each with an output: a mapping that names
    // the device but no port goes where its message came from, not to the
    // other port, which may go to another instrument.
    v = [~midiSources, ~midiDestinations, ~midiMap];
    ~midiSources = IdentityDictionary[1006 -> ["Box", "Port A"], 1007 -> ["Box", "Port B"]];
    ~midiDestinations = IdentityDictionary[2006 -> ["Box", "Port A"], 2007 -> ["Box", "Port B"]];
    ~midiMap = h.new([(msg: \cc, num: 40, chan: 0, device: "Box", target: \lvl)], "box");
    ~midiBackFrom.((sendBack: Dictionary["Box" -> true]));
    now = now + 1;
    ~tEq.("a mapping that names a device of two ports, and no port, is sent nothing before its message comes", [tick.(), sends.()], [0, []]);
    route.(\cc, 0, 40, 30, 1006);
    vals.put(\lvl, 7.5);
    now = now + 1;
    tick.();
    ~tEq.("...then to the port it came from alone", sends.(), [[2006, \control, 0, 40, 95]]);
    ~midiSources = v[0];
    ~midiDestinations = v[1];
    ~midiMap = v[2];
    vals.put(\lvl, keep);
    ~midiBackFrom.(settings);

    // ---- a level, a CC knob's toggle and a CC knob's trigger layered on one
    // encoder: a send for the level moves the encoder under the other two,
    // which must neither switch nor fire at its next click.
    v = [~midiMap, ~midiTargets];
    n = 0;
    ~midiTargets = targets.copy.putAll(IdentityDictionary[\fire -> (id: \fire, kind: \trigger, fire: { n = n + 1 })]);
    ~midiMap = h.new([(msg: \cc, num: 24, chan: 0, device: "UC4", target: \lvl5),
        (msg: \cc, num: 24, chan: 0, device: "UC4", target: \tog6, layer: true),
        (msg: \cc, num: 24, chan: 0, device: "UC4", target: \fire, layer: true)], "macro");
    ~midiTargets.put(\tog6, mk.(\tog6, \toggle));
    vals.put(\tog6, false);
    vals.put(\lvl5, 5);
    now = now + 1;
    tick.();
    sends.();
    now = now + 1;
    route.(\cc, 0, 24, 30);
    vals.put(\lvl5, 8);
    now = now + 1;
    tick.();
    ~tEq.("a level, a CC knob's toggle and a CC knob's trigger on one encoder: the mouse moves the level, the encoder is sent its place",
        sends.(), [[2002, \control, 0, 24, 102]]);
    route.(\cc, 0, 24, 103);
    ~tEq.("...and its next click moves the level, and neither switches the toggle nor fires the trigger",
        [vals[\lvl5], vals[\tog6], n], [(103 / 127) * 10, false, 0]);
    // The same macro afresh (a boot, the macro just learned): the toggle and
    // the trigger haven't been heard yet.
    ~midiMap = h.new([(msg: \cc, num: 24, chan: 0, device: "UC4", target: \lvl5),
        (msg: \cc, num: 24, chan: 0, device: "UC4", target: \tog6, layer: true),
        (msg: \cc, num: 24, chan: 0, device: "UC4", target: \fire, layer: true)], "macro afresh");
    vals.put(\lvl5, 8);
    now = now + 1;
    tick.();
    ~tEq.("...and with the toggle and the trigger not heard yet (a boot, the macro just learned), the encoder is sent the level's place",
        sends.(), [[2002, \control, 0, 24, 102]]);
    route.(\cc, 0, 24, 103);
    ~tEq.("...and its next click neither switches the toggle nor fires the trigger either",
        [vals[\lvl5], vals[\tog6], n], [(103 / 127) * 10, false, 0]);
    ~midiMap = v[0];
    ~midiTargets = v[1];
    ~midiBackFrom.(settings);

    // ---- a CC switch's light and a level layered on one button: a light
    // sent moves the controller under the level, once the level too has acted
    // on the press; whichever shows there next is sent its own.
    v = [~midiMap, ~midiTargets];
    ~midiTargets = targets.copy;
    ~midiTargets.put(\tog8, mk.(\tog8, \toggle));
    ~midiTargets.put(\lvl7, mk.(\lvl7, \continuous));
    vals.put(\tog8, true);
    vals.put(\lvl7, 5);
    ~midiMap = h.new([(msg: \cc, num: 25, chan: 0, device: "UC4", target: \tog8, switch: \pressRelease),
        (msg: \cc, num: 25, chan: 0, device: "UC4", target: \lvl7, layer: true, takeover: \none)], "lights");
    now = now + 1;
    tick.();
    sends.();
    now = now + 1;
    route.(\cc, 0, 25, 127);
    ~tEq.("a CC switch's light and a level layered on one button: a press switches the toggle, its light sent at once, and the level acts on it too",
        [sends.(), vals[\tog8], vals[\lvl7]], [[[2002, \control, 0, 25, 0]], false, 10]);
    ~midiTargets[\tog8].put(\available, { false });
    now = now + 1;
    ~tEq.("...while the toggle isn't there, the level shows on the button: it is sent its place, as the light took the button",
        [tick.(), sends.()], [1, [[2002, \control, 0, 25, 127]]]);
    ~midiTargets[\tog8].removeAt(\available);
    now = now + 1;
    ~tEq.("...and back, the toggle's light again", [tick.(), sends.()], [1, [[2002, \control, 0, 25, 0]]]);
    ~midiTargets[\tog8].put(\available, { false });
    now = now + 1;
    ~tEq.("...and away again, the level's place again: the light took the button from it", [tick.(), sends.()],
        [1, [[2002, \control, 0, 25, 127]]]);
    ~midiMap = v[0];
    ~midiTargets = v[1];
    ~midiBackFrom.(settings);

    // ---- a light (the count's on Perform): sent only. The tick sends it as a
    // toggle's; a press on its button acts on nothing and has the light put
    // right at once (the UC4 in LED mode Std lights or darkens it itself); a
    // light off sent, its echo is dropped.
    v = [~midiMap, ~midiTargets];
    ~midiTargets = targets.copy;
    ~midiTargets.put(\lamp, (id: \lamp, kind: \light, get: { vals[\lamp] == true }));
    vals.put(\lamp, true);
    ~midiMap = h.new([(msg: \note, num: 70, chan: 0, device: "UC4", target: \lamp)], "lamp");
    now = now + 1;
    ~tEq.("a light learned on a note: the tick sends it as a toggle's", [tick.(), sends.()],
        [1, [[2002, \noteOn, 0, 70, 127]]]);
    now = now + 1;
    n = route.(\noteOn, 0, 70, 127);
    ~tEq.("...a press on its button acts on nothing, and has the light put right at once",
        [n, vals[\lamp], sends.()], [[], true, [[2002, \noteOn, 0, 70, 127]]]);
    now = now + 0.005;
    ~tEq.("...whose echo, a press 5 ms on, is dropped", route.(\noteOn, 0, 70, 127), \echo);
    vals.put(\lamp, false);
    now = now + 1;
    ~tEq.("...and dark, a note off", [tick.(), sends.()], [1, [[2002, \noteOff, 0, 70, 0]]]);
    ~midiMap = v[0];
    ~midiTargets = v[1];
    ~midiBackFrom.(settings);

    // ---- the boot, and the responders: an echo is not sent on to Live
    // Building them registers MIDIdefs, which would replace a running
    // megalooper's: this part runs only where no MIDI responder is registered.
    v = AbstractResponderFunc.allEnabled.keys.any { |k| k.asString.beginsWith("MIDI") };
    case
    { v and: { Platform.ideName == "none" } } {
        ~tFail.("no MIDI responder is registered before the responders' echo test, in a headless run",
            "an earlier test left one: " ++ AbstractResponderFunc.allEnabled.keys.asArray);
    }
    { v } { ~tSkip.("an echo through the responders", "MIDI responders run in this interpreter (a megalooper?)") }
    {
        before = MIDIdef.all.keys;
        lines = List.new;
        proxied = List.new;
        protect {
            // The port to Live, which is never sent back to.
            fakeDests = fakeDests ++ [(uid: 2009, device: "Out to Live", name: "Out to Live")];
            ~midiOut = (uid: 2009);
            [\noteOn, \noteOff, \control, \program, \bend, \touch, \polyTouch].do { |sel|
                ~midiOut.put(sel, { |self ... args| proxied.add([sel] ++ args); self });
            };
            ~midiLog = false;
            ~midiMonitorPush = { |line| lines.add(line) };
            ~midiBackOuts = IdentityDictionary[2002 -> \dead];
            ~midiBackSrcs = IdentitySet.new;
            ~midiBackTo = IdentityDictionary.new;
            ~setupMidiBindings.(h.new(map.bindings, "back"));
            ~tEq.("a boot: the inputs sent back to as settings.json has them, to their outputs, opened afresh; never an IAC bus nor the port to Live",
                [~midiBackSrcs.asArray, ~midiBackTo[1002], ~midiBackOuts.size, ~midiDestinations.keys.asArray.sort],
                [[1002], 2002, 0, [2001, 2002, 2005]]);
            ~midiTargets = targets;
            fn = { |name| MIDIdef.all[name] !? { |x| x.func } };
            now = now + 1;
            tick.();
            vals.put(\lvl, 7.5);
            now = now + 1;
            tick.();
            ~tEq.("through the responders: the encoder is sent its control's place", sent.last, [2002, \control, 0, 10, 95]);
            sends.();
            lines.clear;
            proxied.clear;
            fn.(\midiInCc).value(95, 10, 0, 1002);
            ~tEq.("...and its echo is not sent on to Live, and is logged as an echo",
                [proxied.size, lines.asArray, vals[\lvl]], [0, ["cc       num=10 val=95 chan=0  (echo of what was sent back)"], 7.5]);
            fn.(\midiInCc).value(96, 10, 0, 1002);
            ~tEq.("...while the encoder's own next message is", proxied.asArray, [[\control, 0, 10, 96]]);
            // Cmd-period: MIDI is dead until the rebuild, which sends
            // everything to where the bindings say.
            route.(\cc, 3, 20, 50);
            // A tick first, so the place it came from is in the list.
            tick.();
            ~midiCmdPeriodHook.value;
            now = now + 1;
            ~tEq.("Cmd-period forgets what was sent and where from: next, everything goes to where the bindings say",
                [~midiBackSent.size, tick.()], [0, 13]);
        } {
            MIDIdef.all.keys.reject { |k| before.includes(k) }.do { |k| MIDIdef.all[k] !? { |x| x.free } };
            ~midiCmdPeriodHook !? { |f| CmdPeriod.remove(f) };
        };
        ~tAssert.("and the responders it made are gone again", MIDIdef.all.keys.reject { |k| before.includes(k) }.isEmpty);
    };
} {
    ~tRemoveTree.(~midiUserRootOverride);
    keys.do { |k, i| currentEnvironment.put(k, saved[i]) };
};
}.value;
