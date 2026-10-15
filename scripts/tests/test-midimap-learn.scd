// Learning a mapping (docs/dev/midi-map.md 6.2-6.3): LooperMidiLearn, the pure
// rules for which message a control learns, on made-up messages and on the
// TSMega's own streams from the MIDI log (fixtures/pedal-streams.json and
// switch-streams.json, cut by tools/midi-log-streams.py). The log keeps no
// times, so the streams are played at made-up but plausible spacings: the
// pedal's flicker a few times a second, a footswitch's presses half a second
// apart.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-midimap-learn");

{
var dir = thisProcess.nowExecutingPath.dirname;
var ml = LooperMidiLearn;
var drive, read, stream, pedal, switches, out, l, seen, bound, armings, at;

// Messages through a learning as the router gives them: each [time, msg,
// chan, num, val, src], with what the router last saw of each CC or bend
// before it (`seen`: key -> [value, time], the state before the arm). Then
// time runs on 2 s, so a burst or a count can close. Answers the outcome.
drive = { |learner, msgs, seen|
    var last = 0;
    seen = seen ? Dictionary.new;
    msgs.do { |m|
        var key = m[1].asString ++ "/" ++ m[2] ++ "/" ++ m[3] ++ "/" ++ m[5];
        var was = seen[key];
        learner.feed(m[1], m[2], m[3], m[4], m[5], was !? { |w| w[0] }, was !? { |w| w[1] }, m[0]);
        if((m[1] == \cc) or: { m[1] == \bend }) { seen.put(key, [m[4], m[0]]) };
        last = m[0];
    };
    learner.tick(last + 2)
};
// A CC's values as messages from input 1, channel 0, `gap` seconds apart.
stream = { |num, values, gap = 0.3, from = 10| values.collect { |v, i| [from + (i * gap), \cc, 0, num, v, 1] } };
read = { |name|
    var d = try { File.readAllString(dir +/+ "fixtures" +/+ name).parseJSON["streams"] } { nil };
    var out = IdentityDictionary.new;
    (d ? []).do { |s| out.put(s["name"].asSymbol, s["values"].collect(_.asInteger)) };
    out
};
pedal = read.("pedal-streams.json");
switches = read.("switch-streams.json");
~tAssert.("the TSMega's streams from the MIDI log are read",
    (pedal.size == 4) and: { switches.size == 6 });

// ------------------------------------------------------------ one message --
out = drive.(ml.new(\x, \trigger, 0), [[1, \noteOn, 0, 60, 100, 1]]);
~tEq.("a note on is learned", out !? { |o| [o[\msg], o[\chan], o[\num], o[\src]] }, [\note, 0, 60, 1]);
out = drive.(ml.new(\x, \trigger, 0), [[1, \noteOff, 0, 60, 0, 1], [2, \touch, 0, nil, 30, 1], [3, \polytouch, 0, 60, 30, 1]]);
~tEq.("a note off, aftertouch and poly touch are not", out, nil);
out = drive.(ml.new(\x, \toggle, 0), [[1, \program, 3, 8, nil, 1]]);
~tEq.("a program change is learned, with its channel", out !? { |o| [o[\msg], o[\chan], o[\num]] }, [\program, 3, 8]);
~tEq.("...and no switch type: a program change has no release", out !? { |o| o[\switch] }, nil);

// -------------------------------------------------------------- the 3 steps --
out = drive.(ml.new(\x, \continuous, 0), stream.(20, [10, 11, 12]));
~tEq.("a CC never seen: its first value only says where it is, and 2 steps from there is not enough", out, nil);
out = drive.(ml.new(\x, \continuous, 0), stream.(20, [10, 11, 13]));
~tEq.("...3 steps is", out !? { |o| [o[\msg], o[\num]] }, [\cc, 20]);
seen = Dictionary["cc/0/20/1" -> [68, 0]];
out = drive.(ml.new(\x, \continuous, 1), stream.(20, [69, 70, 69, 70]), seen.copy);
~tEq.("a CC seen at 68 before the arm: hopping to 69 and 70 is not enough", out, nil);
out = drive.(ml.new(\x, \continuous, 1), stream.(20, [69, 71]), seen.copy);
~tEq.("...71 is", out !? { |o| o[\num] }, 20);
~tEq.("a learned knob has no switch type to ask about", out !? { |o| [o[\switch], o[\ask]] }, [nil, false]);
// A switch that sends the same value on every press: again after a second's
// silence counts, quicker does not.
seen = Dictionary["cc/0/30/1" -> [127, 0]];
out = drive.(ml.new(\x, \continuous, 0.5), [[0.9, \cc, 0, 30, 127, 1]], seen.copy);
~tEq.("the same value again within a second is not learned", out, nil);
out = drive.(ml.new(\x, \continuous, 0.5), [[1.2, \cc, 0, 30, 127, 1]], seen.copy);
~tEq.("...after a second's silence it is", out !? { |o| o[\num] }, 30);
out = drive.(ml.new(\x, \continuous, 0), [[1, \bend, 0, nil, 8192, 1], [1.2, \bend, 0, nil, 8500, 1]]);
~tEq.("pitch bend is not learned for a small move (308 of 16384)", out, nil);
out = drive.(ml.new(\x, \continuous, 0), [[1, \bend, 0, nil, 8192, 1], [1.2, \bend, 0, nil, 8600, 1]]);
~tEq.("...but is for 3/128 of its range", out !? { |o| [o[\msg], o[\num]] }, [\bend, nil]);

// --------------------------------------------------------------- the pedal --
// An arm before each message of the resting pedal in turn, then the next 20
// messages: it must never be learned.
bound = 0;
armings = 0;
[['sa-resting', 7], ['sa-resting-wide', 7], ['cc4-resting', 4]].do { |pair|
    var v = pedal[pair[0].asSymbol] ? [];
    (1, 4 .. (v.size - 21).max(1)).do { |i|
        var learner = ml.new(\x, \continuous, 0);
        var s = Dictionary[("cc/0/" ++ pair[1] ++ "/1") -> [v[i - 1], -1]];
        armings = armings + 1;
        if(drive.(learner, stream.(pair[1], v.copyRange(i, i + 19)), s).notNil) { bound = bound + 1 };
    };
};
~tAssert.("the resting pedal is never learned, wherever the arm comes (" ++ armings ++ " arms over its three streams)",
    (armings > 400) and: { bound == 0 }, bound.asString ++ " learned");
bound = 0;
armings = 0;
at = pedal['sa-played'] ? [];
(1, 25 .. (at.size - 21).max(1)).do { |i|
    var learner = ml.new(\x, \continuous, 0);
    armings = armings + 1;
    if(drive.(learner, stream.(7, at.copyRange(i, i + 19), 0.1), Dictionary["cc/0/7/1" -> [at[i - 1], -1]]).notNil) {
        bound = bound + 1;
    };
};
~tAssert.("the pedal played is learned where it moves (" ++ bound ++ " of " ++ armings ++ " arms)",
    (bound > 0) and: { bound < armings });

// -------------------------------------------------------------- the bursts --
out = drive.(ml.new(\x, \trigger, 0), [[1, \cc, 0, 0, 2, 1], [1.002, \cc, 0, 32, 0, 1], [1.004, \program, 0, 5, nil, 1]],
    Dictionary["cc/0/0/1" -> [0, -1], "cc/0/32/1" -> [5, -1]]);
~tEq.("a bank select before a program change is the program change's header", out !? { |o| [o[\msg], o[\num]] },
    [\program, 5]);
out = ml.new(\x, \trigger, 0);
drive.(out, [[1, \cc, 0, 99, 1, 1], [1.002, \cc, 0, 98, 20, 1], [1.004, \cc, 0, 6, 64, 1]],
    Dictionary["cc/0/99/1" -> [0, -1], "cc/0/98/1" -> [0, -1], "cc/0/6/1" -> [0, -1]]);
~tAssert.("an NRPN is refused, and says so", out.outcome.isNil and: { out.refusals.any { |r| r.contains("NRPN") } });
out = ml.new(\x, \continuous, 0);
drive.(out, [[1, \cc, 0, 20, 100, 1], [1.003, \cc, 0, 21, 90, 1], [1.006, \cc, 0, 22, 80, 1]],
    Dictionary["cc/0/20/1" -> [0, -1], "cc/0/21/1" -> [0, -1], "cc/0/22/1" -> [0, -1]]);
~tAssert.("a controller's snapshot of several knobs is refused: move just one",
    out.outcome.isNil and: { out.refusals.any { |r| r.contains("move just one") } });
drive.(out, stream.(21, [80, 70]), Dictionary["cc/0/21/1" -> [90, -1]]);
~tEq.("...and the learning goes on: one knob then is learned", out.outcome !? { |o| o[\num] }, 21);
out = drive.(ml.new(\x, \trigger, 0), [[1, \cc, 0, 7, 69, 1], [1.002, \program, 0, 9, nil, 1]],
    Dictionary["cc/0/7/1" -> [68, -1]]);
~tEq.("the pedal's flicker in the same burst as a stomp doesn't count", out !? { |o| [o[\msg], o[\num]] },
    [\program, 9]);
['cc0-0922', 'cc0-0928', 'cc0-1006'].do { |name|
    var v = switches[name] ? [];
    out = drive.(ml.new(\x, \continuous, 0), stream.(0, v, 0.02), Dictionary["cc/0/0/1" -> [v[0], -1]]);
    ~tEq.("the TSMega's CC 0 sweep " ++ name ++ " is learned like a knob, with no program change after it",
        out !? { |o| [o[\msg], o[\num]] }, [\cc, 0]);
};

// ---------------------------------------------------------- two presses --
// A CC learned for a switch is counted once it has been quiet for 1.5 s.
out = drive.(ml.new(\x, \trigger, 0), stream.(80, (switches['cc80-0922'] ? []).copyRange(0, 1), 0.5));
~tEq.("the TSMega's CC 80, pressed twice (0, 64: never seen before), is one message a press",
    out !? { |o| [o[\num], o[\switch], o[\ask]] }, [80, \oneMessage, false]);
out = drive.(ml.new(\x, \toggle, 0), stream.(80, [64, 64], 0.5), Dictionary["cc/0/80/1" -> [0, -1]]);
~tEq.("...and with its one repeat of 64, still one message a press", out !? { |o| o[\switch] }, \oneMessage);
out = drive.(ml.new(\x, \trigger, 0), stream.(81, (switches['cc81-0918'] ? []).copyRange(0, 1), 0.5),
    Dictionary["cc/0/81/1" -> [0, -1]]);
~tEq.("the TSMega's CC 81, the same", out !? { |o| o[\switch] }, \oneMessage);
out = drive.(ml.new(\x, \trigger, 0), [[1, \cc, 0, 50, 127, 1], [1.2, \cc, 0, 50, 0, 1], [1.8, \cc, 0, 50, 127, 1],
    [2.0, \cc, 0, 50, 0, 1]], Dictionary["cc/0/50/1" -> [0, -1]]);
~tEq.("a switch that sends 127 and 0 for each press is press and release", out !? { |o| [o[\switch], o[\ask]] },
    [\pressRelease, false]);
out = drive.(ml.new(\x, \trigger, 0), stream.(51, (0, 8 .. 127), 0.05), Dictionary["cc/0/51/1" -> [0, -1]]);
~tEq.("a knob turned for a switch is a knob", out !? { |o| o[\switch] }, \knob);
out = drive.(ml.new(\x, \trigger, 0), stream.(52, [127, 0, 127], 0.4), Dictionary["cc/0/52/1" -> [0, -1]]);
~tEq.("three messages can't be told: one message a press, and ask", out !? { |o| [o[\switch], o[\ask]] },
    [\oneMessage, true]);
l = ml.new(\x, \trigger, 0);
l.feed(\cc, 0, 53, 127, 1, 0, -1, 1);
l.tick(1.05);
l.feed(\cc, 0, 53, 0, 1, 127, 1, 1.4);
~tAssert.("while it counts it isn't done until the switch is quiet for 1.5 s",
    l.counting and: { l.tick(2.8).isNil } and: { l.tick(2.95).notNil } and: { l.outcome[\switch] == \oneMessage });

// ------------------------------------------------------------- its time --
l = ml.new(\x, \trigger, 100);
~tAssert.("a learning lasts 15 s", l.expired(114.9).not and: { l.expired(115.1) });
l.feed(\cc, 0, 54, 127, 1, 0, -1, 114);
l.tick(114.05);
~tAssert.("...but not while it counts the presses it has", l.counting and: { l.expired(115.2).not });
// A control that never goes quiet can't keep the counting going: 4 s after its
// first press it is counted with what it has. The pedal nudged 3 steps for a
// toggle, then flickering a step every 1.2 s, is a knob: on a switch it
// switches at 64 and back at 56, so the flicker can't flip it.
l = ml.new(\x, \toggle, 0);
seen = Dictionary["cc/0/7/1" -> [68, -1]];
out = nil;
at = nil;
(stream.(7, [71] ++ (70 ! 9).collect { |x, i| if(i.even) { 70 } { 71 } }, 1.2, 1) ++ [[13, \cc, 0, 7, 70, 1]]).do { |m|
    var key = "cc/0/7/1", was = seen[key];
    if(out.isNil) {
        out = l.feed(m[1], m[2], m[3], m[4], m[5], was !? { |w| w[0] }, was !? { |w| w[1] }, m[0]);
        if(out.notNil) { at = m[0] };
    };
    seen.put(key, [m[4], m[0]]);
};
~tAssert.("counting is cut 4 s after the first press when the control never goes quiet",
    at.notNil and: { at <= 5.9 }, "decided at " ++ at);
~tEq.("...and a pedal that flickers is a knob, not a switch a flicker would flip", out !? { |o| [o[\switch], o[\ask]] },
    [\knob, false]);
}.value;
