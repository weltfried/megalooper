// Megalooper SA's drum scheduler (MegaSADrums) on the harness's recording stub
// server, with an injected wall clock, sender and dice seed: the time base
// (stamps, transport starts, readings), the pump and its per-hit cuts, the
// break, PC 17, the transport through the Looper's own port, the drift probe,
// the onset sink, the kit slots, and the session log (what the drums tell the
// Looper's session recorder, a fake here). No scsynth: the voices themselves
// are rendered and checked by scripts/sa/nrt-drum-voices.scd.
//
// Every check on what was sent first asserts that something was: an Event
// answers nil to anything it lacks, so a check over an empty log would pass on
// nothing.
//
// Times are explicit throughout. The main thread's logical time stands still
// for the whole run, so nothing here leans on it: the wall clock is a number
// the test sets, and every call that takes a `now` is given one. A caller on a
// thread with its own time is a Routine stepped with .next that sets
// thisThread.seconds.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megadrums-sched");

// --------------------------------------------------------------- fixture --
// A kit of 16 pads, 36..51, one file each (38's stereo), so a voice's buffer
// number IS its pad's note; the "operator" law at amount 1, so a voice's amp is
// its velocity / 127. Hats 42, 44 and 46 choke each other (group 1); 41
// retriggers. A second kit on two other files, for the slots' serials.
// In gap/, a third kit, gkit, for what the first does not have: every layer in
// group "carbon" with Beat Repeat on every pad, 36 retriggering as well, and
// pad 37's layer with a drive, a length and a sample start (files q<n>.wav,
// 0.5 s, so a voice's buffer number is its note there too). In share/, two
// kits whose files overlap: ka (36, 42) and kb (36, 42, 38), files s/x<n>.wav.
// The folder is this run's own (~tTempPath): runs at the same time do not
// share it.
~dsDir = ~tTempPath.("megadrums-sched");
~dsMakeKits = {
    var write = { |path, chans, frames = 2400|
        var sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(chans).sampleRate_(48000);
        sf.openWrite(path);
        sf.writeData(Signal.fill(frames * chans, { 0.1 }));
        sf.close;
    };
    var pad = { |n, file|
        "\"" ++ n ++ "\": { \"name\": \"Pad " ++ n ++ "\", \"choke\": "
            ++ (if([42, 44, 46].includes(n)) { 1 } { 0 }) ++ ", \"retrigger\": " ++ (n == 41)
            ++ ", \"layers\": [ { \"file\": \"" ++ file ++ "\", \"vel\": { \"law\": \"operator\", \"amount\": 1 } } ] }"
    };
    var gapPad = { |n, file, extra = ""|
        "\"" ++ n ++ "\": { \"name\": \"Pad " ++ n ++ "\", \"choke\": "
            ++ (if([42, 44, 46].includes(n)) { 1 } { 0 }) ++ ", \"retrigger\": " ++ ((n == 41) or: { n == 36 })
            ++ ", \"beatRepeat\": true, \"layers\": [ { \"group\": \"carbon\", \"file\": \"" ++ file ++ "\"" ++ extra
            ++ ", \"vel\": { \"law\": \"operator\", \"amount\": 1 } } ] }"
    };
    File.mkdir(~dsDir);
    File.mkdir(~dsDir +/+ "t");
    ((36..51) ++ [60, 61]).do { |n| write.(~dsDir +/+ "t" +/+ ("p" ++ n ++ ".wav"), if(n == 38) { 2 } { 1 }) };
    File.use(~dsDir +/+ "tkit.json", "w", { |f|
        f.write("{ \"version\": 1, \"key\": \"tkit\", \"name\": \"Test kit\", \"pads\": { "
            ++ (36..51).collect { |n| pad.(n, "t/p" ++ n ++ ".wav") }.join(", ") ++ " } }")
    });
    File.use(~dsDir +/+ "tkit2.json", "w", { |f|
        f.write("{ \"version\": 1, \"key\": \"tkit2\", \"name\": \"Second\", \"pads\": { "
            ++ [pad.(36, "t/p60.wav"), pad.(42, "t/p61.wav")].join(", ") ++ " } }")
    });
    File.mkdir(~dsDir +/+ "gap");
    File.mkdir(~dsDir +/+ "gap" +/+ "g");
    (36..51).do { |n| write.(~dsDir +/+ "gap" +/+ "g" +/+ ("q" ++ n ++ ".wav"), 1, 24000) };
    File.use(~dsDir +/+ "gap" +/+ "gkit.json", "w", { |f|
        f.write("{ \"version\": 1, \"key\": \"gkit\", \"name\": \"Gap kit\", \"groups\": { \"carbon\": \"Carbon\" }, \"pads\": { "
            ++ (36..51).collect { |n|
                gapPad.(n, "g/q" ++ n ++ ".wav", if(n == 37) { ", \"drive\": 6.84, \"lenSecs\": 0.03, \"startFrames\": 100" } { "" })
            }.join(", ") ++ " } }")
    });
    File.mkdir(~dsDir +/+ "share");
    File.mkdir(~dsDir +/+ "share" +/+ "s");
    [36, 38, 42].do { |n| write.(~dsDir +/+ "share" +/+ "s" +/+ ("x" ++ n ++ ".wav"), 1) };
    File.use(~dsDir +/+ "share" +/+ "ka.json", "w", { |f|
        f.write("{ \"version\": 1, \"key\": \"ka\", \"pads\": { "
            ++ [36, 42].collect { |n| pad.(n, "s/x" ++ n ++ ".wav") }.join(", ") ++ " } }")
    });
    File.use(~dsDir +/+ "share" +/+ "kb.json", "w", { |f|
        f.write("{ \"version\": 1, \"key\": \"kb\", \"pads\": { "
            ++ [36, 38, 42].collect { |n| pad.(n, "s/x" ++ n ++ ".wav") }.join(", ") ++ " } }")
    });
};
~dsDropKits = {
    var rm = { |dir|
        (dir +/+ "*").pathMatch.do { |p| if(p.last == $/) { rm.(p.drop(-1)) } { File.delete(p) } };
        File.delete(dir);
    };
    rm.(~dsDir);
};
// Buffer.read, answering at once: the buffer number is the one in the name.
~dsReader = { |srv, path, done|
    var n = PathName(path).fileNameWithoutExtension.drop(1).asInteger;
    done.((bufnum: n, path: path, numChannels: if(n == 38) { 2 } { 1 }, sampleRate: 48000, numFrames: 2400));
};
// A drums object on the stub, attached to a stub Looper playing a 2 s loop
// from lam (a bar of 4/4 at 120 BPM: a 16th is 0.125 s), both slots on the
// test kit (or `kit` from `dir`), every bundle logged as [time (nil: at once),
// msgs, wall].
~dsMake = { |lam = 90.0, loopDur = 2.0, kit = \tkit, dir|
    var fx = (log: List.new, wall: lam);
    var stub = ~tStubServer.();
    var l = ~tLooper.();
    var d;
    ~tPut.(l, \state, \playing);
    ~tPut.(l, \loopFrames, (loopDur * 48000).round.asInteger);
    ~tPut.(l, \loopStartTime, lam);
    ~tPut.(l, \lastResult, (numerator: 4, denominator: 4, k: 1, bpm: 120, loopDur: loopDur));
    ~tPut.(l, \phaseBus, Bus(\control, 7, 1, stub));
    d = MegaSADrums((server: stub));
    d.prUseBusses;
    d.wallClock = { fx[\wall] };
    d.sender = { |t, msgs| fx[\log].add([t, msgs, fx[\wall]]) };
    d.randSeed = 1234;
    d.kitDir = dir ? ~dsDir;
    d.kitReader = ~dsReader;
    d.setKit(\steps, kit);
    d.setKit(\onset, kit);
    d.attach(l);
    fx[\stub] = stub;
    fx[\looper] = l;
    fx[\drums] = d;
    fx
};
// The same on the gap kit.
~dsMakeGap = { |lam = 90.0, loopDur = 2.0| ~dsMake.(lam, loopDur, \gkit, ~dsDir +/+ "gap") };
// A pattern made plain: every lane silent but those given (lane -> the steps
// that fire, at chance 6), no alternates, velocity 127, no rolls.
~dsEvery = (0..15);
~dsPlain = { |d, which, lanes|
    4.do { |lane|
        var on = lanes[lane] ? [];
        d.setSteps(which, \chance, lane, Array.fill(16, { |i| if(on.includes(i)) { 6 } { 0 } }));
        d.setSteps(which, \alt, lane, Array.fill(16, 0));
        d.setSteps(which, \velo, lane, Array.fill(16, 6));
        d.setSteps(which, \roll, lane, Array.fill(16, 0));
    };
};
// The Looper's Start for boundary b: lead before it, as startMidiClock aims it.
~dsStart = { |fx, b|
    fx[\wall] = b - 0.1;
    fx[\drums].transportStart(b - 0.1);
};
// Pump every `step` of wall time up to `to`. With fx[\recs] (an IdentitySet)
// every decided record is kept there too, before the drums forget it.
~dsRun = { |fx, to, step = 0.01|
    var w = fx[\wall];
    while { w < (to - 1e-9) } {
        w = (w + step).min(to);
        fx[\wall] = w;
        fx[\drums].pump(w);
        fx[\recs] !? { |set| fx[\drums].decided.do { |r| set.add(r) } };
    };
};
// Every hit a log sent, in order, as (time:, note:, vel:, hitId:, ring:, group:,
// out:, chokeBus:, chokeOn:, voices:, cancelled:, wall:, addActions:): the
// voices of one hit id in one bundle are one hit, and a /c_set of its cancel
// bus to 1 sent after it cancels it. addActions: every voice's add action.
~dsHits = { |log|
    var hits = List.new, owner = IdentityDictionary.new;
    log.do { |b|
        var byId = IdentityDictionary.new;
        b[1].do { |m|
            var a, h;
            if(m[0] == \c_set) {
                m.copyToEnd(1).pairsDo { |bus, v| if(v == 1) { owner[bus] !? { |o| o[\cancelled] = true } } };
            };
            if((m[0] == \s_new) and: { m[1].asString.beginsWith("megaSADrumVoice") }) {
                a = ().putPairs(m.copyToEnd(5));
                h = byId[a[\hitId]];
                if(h.isNil) {
                    h = (time: b[0], note: a[\buf], vel: (a[\amp] * 127).round.asInteger, hitId: a[\hitId],
                        ring: a[\cancelBus], group: m[4], out: a[\out], chokeBus: a[\chokeBus],
                        chokeOn: a[\chokeOn], voices: 0, cancelled: false, wall: b[2], def: m[1],
                        addActions: List.new);
                    byId.put(a[\hitId], h);
                    hits.add(h);
                    owner.put(a[\cancelBus], h);
                };
                h[\voices] = h[\voices] + 1;
                h[\addActions].add(m[3]);
            };
        };
    };
    hits
};
// Every voice a log sent, in order: its s_new controls as an Event, plus
// (time:, group:, addAction:, cancelled:, wall:, note:). A /c_set of a cancel
// bus to 1 cancels the voices of the hit that last took that bus.
~dsVoices = { |log|
    var out = List.new, owner = IdentityDictionary.new;
    log.do { |b|
        b[1].do { |m|
            var a, v;
            if(m[0] == \c_set) {
                m.copyToEnd(1).pairsDo { |bus, val| if(val == 1) { (owner[bus] ? []).do { |x| x[\cancelled] = true } } };
            };
            if((m[0] == \s_new) and: { m[1].asString.beginsWith("megaSADrumVoice") }) {
                a = ().putPairs(m.copyToEnd(5));
                v = a.copy.putAll((time: b[0], group: m[4], addAction: m[3], cancelled: false, wall: b[2], note: a[\buf]));
                out.add(v);
                if(owner[a[\cancelBus]].isNil or: { owner[a[\cancelBus]][0][\hitId] != a[\hitId] }) {
                    owner.put(a[\cancelBus], List.new);
                };
                owner[a[\cancelBus]].add(v);
            };
        };
    };
    out.asArray
};
~dsVoicesSounding = { |log| ~dsVoices.(log).reject { |v| v[\cancelled] } };
~dsVoiceKey = { |v| v[\note].asString ++ "@" ++ v[\time].round(1e-6) };
~dsVoiceKeys = { |vs| vs.collect(~dsVoiceKey).asArray.sort };
~dsSounding = { |log| ~dsHits.(log).reject { |h| h[\cancelled] } };
~dsOf = { |hits, note| hits.select { |h| h[\note] == note } };
// Grid times: a hit's stamp less the 20 ms (no dHat or offset in these).
~dsGrid = { |hits| hits.collect { |h| h[\time] - 0.02 } };
~dsKey = { |h| h[\note].asString ++ "@" ++ (h[\time].round(1e-6)).asString };
~dsKeys = { |hits| hits.collect(~dsKey).asArray.sort };
~dsCancels = { |log| log.select { |b| b[1].any { |m| (m[0] == \c_set) and: { m[2] == 1 } } } };

~dsMakeKits.();

// ------------------------------------------------------------- arithmetic --
{
var c = MegaSADrums;
var l = ~tLooper.();
var lim;
var h = [[inf.neg, \main]], h2, h3, h4;
var late = { |t| (((t - 90.0) - 0.003) % 2.0) - (31.5 / 48000) };
~tEq.("the loop is heard 20 ms after its grid", c.loopAudioDelay, 0.02);
~tCheck.("the Looper's SynthDefs build", { l.loadSynthDefs });
lim = SynthDescLib.global[\looperMaster] !? { |s| s.def.children.detect { |u| u.class == Limiter } };
~tAssert.("the Looper's master has its Limiter", lim.notNil);
lim !? { ~tNear.("...whose look-ahead, 2 x its dur, is the drums' loopAudioDelay",
    2 * lim.inputs[2], c.loopAudioDelay, 1e-12) };
~tNear.("a Start lead before a boundary lands on it", c.startBoundary(91.9, 0.1, 90.0, 2.0), 92.0);
~tNear.("...one a clock tick late too", c.startBoundary(91.912, 0.1, 90.0, 2.0), 92.0);
~tNear.("...and one with the Live sync trim in the latency", c.startBoundary(91.93, 0.13, 90.0, 2.0), 92.0);
~tNear.("never a boundary in the past", c.startBoundary(92.6, 0.1, 90.0, 2.0), 94.0);
~tNear.("a landing's Start, on its boundary, keeps it", c.startBoundary(94.0, 0.1, 90.0, 2.0), 94.0);
~tNear.("no loop: now + latency", c.startBoundary(5.0, 0.1, nil, 0), 5.1);
~tEq.("16ths in a loop: k bars of the meter, whole",
    [(numerator: 4, denominator: 4, k: 1), (numerator: 7, denominator: 8, k: 2), (numerator: 3, denominator: 4, k: 1),
        (numerator: 5, denominator: 4, k: 1), (numerator: 6, denominator: 8, k: 1), nil].collect { |r| c.sixteenthsFor(r) },
    [16, 28, 12, 20, 12, 16]);
h2 = c.historyFrom(h, 10, \break);
~tEq.("a condition history: the value from an edge on, the edge included",
    [c.historyAt(h2, 9.99), c.historyAt(h2, 10), c.historyAt(h2, 50)], [\main, \break, \break]);
h3 = c.historyFrom(h2, 12, \main);
~tEq.("...an edge after it", [h3.size, c.historyAt(h3, 11), c.historyAt(h3, 12)], [3, \break, \main]);
h4 = c.historyFrom(h3, 11, \break);
~tEq.("...setting a value from an earlier time removes the later edges", [h4.size, c.historyAt(h4, 13)], [2, \break]);
~tEq.("...setting what is already in force adds no edge", c.historyFrom(h2, 11, \break).size, 2);
~tEq.("...and pruning keeps what was in force", c.historyPruned(h3, 10.5), [[inf.neg, \break], [12, \main]]);
~tNear.("a probe of a loop 3 ms late reads -3 ms (the drums move later)",
    c.probeError(late.(100.0), 48000, 100.0, 90.0, 0, 2.0, 0.125), -0.003, 1e-9);
~tNear.("...an estimate already at 3 ms reads 0", c.probeError(late.(100.0), 48000, 100.0, 90.0, 0.003, 2.0, 0.125), 0, 1e-9);
~tNear.("...and so across the loop's wrap", c.probeError(late.(92.001), 48000, 92.001, 90.0, 0, 2.0, 0.125), -0.003, 1e-9);
~tEqArray.("a drift step: a quarter of the error", c.driftStep(0, -0.003, 0), [0.00075, 0], 1e-12);
~tEqArray.("...at most 2 ms", c.driftStep(0, 0.02, 0), [-0.002, 1], 1e-12);
~tEqArray.("...the whole error when two in a row are over 10 ms", c.driftStep(-0.002, 0.018, 1), [-0.02, 0], 1e-12);
~tEq.("choke: a group's bus, a retriggering pad's own, otherwise the scratch bus with chokeOn 0",
    [c.chokeFor((note: 42, choke: 1), 100), c.chokeFor((note: 42, choke: 16), 100),
        c.chokeFor((note: 41, retrigger: true), 100), c.chokeFor((note: 60, retrigger: true), 100),
        c.chokeFor((note: 36), 100)],
    [[116, 1], [131, 1], [105, 1], [132, 0], [132, 0]]);
~tAssert.("...never a negative bus", (0..20).every { |g| c.chokeFor((note: 36, choke: g), 0)[0] >= 0 });
~tEq.("the onset part's first hit after a time",
    [c.onsetCursor([[0, 1], [0.5, 0.5], [1.2, 0.3]], 2.0, 10.0, 13.0),
        c.onsetCursor([[0, 1], [0.5, 0.5], [1.2, 0.3]], 2.0, 10.0, 13.3)], [[1, 2], [2, 0]]);
~tEq.("two bases whole periods apart play one grid", [c.congruent(14.0, 10.0, 2.0), c.congruent(14.1, 10.0, 2.0)],
    [true, false]);
}.value;

// -------------------------------------------------------------- SynthDefs --
{
var want = [\out, \buf, \amp, \rate, \pan, \startFrames, \dur, \drive, \cancelBus, \chokeBus, \chokeOn,
    \hitId, \release, \bpOn, \bpFreq, \bpRq, \gateLen];
var names = { |name| SynthDescLib.global[name] !? { |d| d.controlNames.collect(_.asSymbol) } };
~tCheck.("the drums' SynthDefs build with no server", { MegaSADrums.loadSynthDefs });
[\megaSADrumVoice1, \megaSADrumVoice2].do { |name|
    ~tEq.(name ++ ": the voice's controls", names.(name), want);
};
~tEq.("the probe's", names.(\megaSADrumsProbe), [\phaseBus, \id]);
~tEq.("the drums' effects: the reverb (MegaSADrumsFx), its four spectra after in, out and mix", names.(\megaSADrumsFx), [\in, \out, \mix, \irOn, \ll, \lr, \rl, \rr]);
~tEq.("the onset kit's chain (MegaSADrumsFx)", names.(\megaSAOnsetFx), [\in, \out]);
~tNear.("a choked voice releases over 5 ms", SynthDescLib.global[\megaSADrumVoice1] !? { |d|
    d.controls.detect { |c| c.name.asSymbol == \release } !? { |c| c.defaultValue } }, 0.005, 1e-7);
}.value;

// ---------------------------------------------------------------- the model --
{
var d = MegaSADrums((server: ~tStubServer.()));
var got = List.new;
var ctl = SimpleController(d);
[\step, \steps, \length, \lane, \param, \pattern, \on, \mix, \padTrim, \groupTrim, \repeats, \kit, \kitState]
    .do { |k| ctl.put(k, { |obj, what ... args| got.add([what] ++ args) }) };
~tEq.("a new model has the Live set's patterns", [d.step(\main, \chance, 0, 0), d.step(\break, \chance, 0, 4)], [4, 6]);
~tEq.("...is on, not playing, in no break", [d.on, d.playing, d.breakActive], [true, false, false]);
~tEq.("...with Beat Repeat off (Live's recordings: about one stutter in twelve minutes)", d.repeats, false);
~tEq.("...edited in neither", [d.edited(\main), d.edited(\break)], [false, false]);
~tEq.("...and is alive, with its port", [d.alive, d.transport.class], [true, MegaSATransport]);
d.setStep(\main, \chance, 0, 0, 2);
~tEq.("setStep stores and notifies", [d.step(\main, \chance, 0, 0), got.last], [2, [\step, \main, \chance, 0, 0, 2]]);
got = List.new;
d.setStep(\main, \chance, 0, 0, 2);
~tEq.("...but not when nothing changed (a drag paints one value many times)", got.size, 0);
d.setStep(\main, \chance, 0, 0, 9);
~tEq.("a step is held to 0..6", [d.step(\main, \chance, 0, 0), got.last], [6, [\step, \main, \chance, 0, 0, 6]]);
~tEq.("the Live set's value, for a double-click", d.liveStep(\main, \chance, 0, 0), 4);
~tEq.("edited, once edited", d.edited(\main), true);
got = List.new;
~tCheck.("unknown patterns, pages, lanes, steps, settings and slots warn, and do not throw", {
    d.setStep(\fill, \chance, 0, 0, 1);
    d.setStep(\main, \flam, 0, 0, 1);
    d.setStep(\main, \chance, 4, 0, 1);
    d.setStep(\main, \chance, 0, 16, 1);
    d.setStep(\main, \chance, 0, 0, \x);
    d.setParam(\main, \swing, 1);
    d.setParam(\main, \clockSpeed, \fast);
    d.setLaneParam(\main, 0, \length, 4);
    d.setLaneParam(\main, 0, \pitch, 4);
    d.setLaneParam(\main, 7, \note, 40);
    d.setLength(\main, \nope, 0, 4);
    d.setSteps(\main, \chance, 0, [1, 2]);
    d.setKit(\drums, \tkit);
    d.setPadTrim(\steps, 36, 3);
    d.setReverbMix("loud");
    d.setOffsetMs(nil);
});
~tEq.("...and change and notify nothing", [got.size, d.step(\main, \chance, 0, 0)], [0, 6]);
~tEq.("getters answer nil for what is not there",
    [d.step(\fill, \chance, 0, 0), d.param(\main, \swing), d.laneParam(\main, 9, \note), d.length(\main, \x, 0)],
    [nil, nil, nil, nil]);
d.setParam(\main, \clockSpeed, 9);
~tEq.("setParam holds a setting to its range and notifies",
    [d.param(\main, \clockSpeed), got.last], [5, [\param, \main, \clockSpeed, 5]]);
d.setParam(\main, \shuffle3, -80);
~tEq.("...a shuffle dial by its name", d.param(\main, \shuffle3), -50.0);
d.setLaneParam(\break, 2, \delay, 70);
~tEq.("setLaneParam: a delay held to 50 ms", [d.laneParam(\break, 2, \delay), got.last],
    [50.0, [\lane, \break, 2, \delay, 50.0]]);
d.setLaneParam(\main, 1, \lock, true);
d.setLaneParam(\main, 1, \globalLength, 5);
d.setLength(\main, \velo, 1, 12);
~tEq.("a locked lane plays its global length on every page, and keeps each page's own",
    [d.effectiveLength(\main, \velo, 1), d.length(\main, \velo, 1)], [5, 12]);
~tEq.("setLength notifies", got.last, [\length, \main, \velo, 1, 12]);
d.setSteps(\main, \roll, 2, Array.fill(16, 1));
~tEq.("setSteps stores a whole page and notifies once", [d.step(\main, \roll, 2, 15), got.last], [1, [\steps, \main]]);
// The device's two dice, for one lane of one page. A scripted draw stands in
// for the language's: it answers 0, 1, 2, ... in turn, each held under n.
{
    var k = -1, draw = { |n| k = k + 1; k % n }, before = d.step(\main, \chance, 0, 0);
    d.setSteps(\main, \velo, 3, [0, 0, 0, 3, 3, 3, 6, 6, 6, 1, 2, 4, 5, 0, 6, 3]);
    got = List.new;
    d.randomizeLane(\main, \velo, 3, \less, draw);
    ~tEq.("randomize less: every step moves by -1, 0 or +1 as the dice fall, held to 0..6",
        (0..15).collect { |i| d.step(\main, \velo, 3, i) }, [0, 0, 1, 2, 3, 4, 5, 6, 6, 0, 2, 5, 4, 0, 6, 2]);
    ~tEq.("...said once, as a whole lane", got.asArray, [[\steps, \main]]);
    k = -1;
    d.setLength(\main, \velo, 3, 4);
    d.randomizeLane(\main, \velo, 3, \all, draw);
    ~tEq.("randomize: every step anew from 0 to 6, all 16 whatever the lane's length",
        (0..15).collect { |i| d.step(\main, \velo, 3, i) }, [0, 1, 2, 3, 4, 5, 6, 0, 1, 2, 3, 4, 5, 6, 0, 1]);
    ~tEq.("...of that lane on that page only", [d.step(\main, \chance, 0, 0), d.step(\main, \velo, 2, 0) == d.liveStep(\main, \velo, 2, 0),
        d.step(\break, \velo, 3, 1) == d.liveStep(\break, \velo, 3, 1)], [before, true, true]);
    ~tAssert.("with the language's own dice every step is still 0..6, and a lane of sixes moved by less never leaves 5..6",
        { d.randomizeLane(\main, \roll, 1, \all); (0..15).every { |i| (0..6).includes(d.step(\main, \roll, 1, i)) } }.value
            and: { d.setSteps(\main, \roll, 1, 6 ! 16); d.randomizeLane(\main, \roll, 1, \less);
                (0..15).every { |i| #[5, 6].includes(d.step(\main, \roll, 1, i)) } });
    got = List.new;
    d.randomizeLane(\main, \velo, 3, \wild, draw);
    d.randomizeLane(\main, \nopage, 3, \all, draw);
    d.randomizeLane(\main, \velo, 9, \all, draw);
    ~tEq.("an amount, a page or a lane there is not changes nothing and says nothing", got.asArray, []);
    k = -1;
    ~tEq.("the rule holds a moved step to 0..6 by itself: a 0 moved down stays 0, a 6 moved up stays 6",
        MegaSASteps.randomized([0, 6] ++ (3 ! 14), \less, { |n| k = k + 1; [0, 2][k % 2] }), [0, 6] ++ ([2, 4] ! 7).flat);
    ~tEq.("the rule itself: nil for an amount that is neither, 16 values else",
        [MegaSASteps.randomized(0 ! 16, \wild), MegaSASteps.randomized(nil, \less, { 2 }), MegaSASteps.randomized(6 ! 16, \all, { 9 })],
        [nil, 1 ! 16, 6 ! 16]);
}.value;
got = List.new;
d.resetPattern(\main);
~tEq.("resetPattern: the Live set's pattern back",
    [d.edited(\main), d.param(\main, \clockSpeed), d.step(\main, \chance, 0, 0), d.laneParam(\main, 1, \lock)],
    [false, 3, 4, false]);
~tEq.("...and says so", got.collect(_[0]).asArray, [\pattern, \steps]);
~tEq.("the settings tables are MegaSASteps'", [MegaSADrums.paramSpecs.size, MegaSADrums.laneParamSpecs.size],
    [MegaSASteps.paramSpecs.size, MegaSASteps.laneParamSpecs.size]);
got = List.new;
d.setOn(false, 10.0);
d.setOn(false, 10.0);
~tEq.("on: notifies every time, unchanged too (a refused toggle repaints)",
    got.select { |g| g[0] == \on }.asArray, [[\on, false], [\on, false]]);
d.toggleOn(10.0);
~tEq.("toggleOn", d.on, true);
d.setReverbMix(3);
d.setOffsetMs(-40);
~tEq.("the mix: the reverb 0..1, the offset -15..+50 ms", [d.reverbMix, d.offsetMs], [1, -15]);
~tEq.("...notified as \\mix", got.select { |g| g[0] == \mix }.collect { |g| g.copyToEnd(1) }.asArray,
    [[\reverbMix, 1], [\offsetMs, -15]]);
d.setRepeats(true);
~tEq.("Beat Repeat's switch", [d.repeats, got.last], [true, [\repeats, true]]);
ctl.remove;
}.value;

// ----------------------------------------------------------------- the kits --
{
var fx = ~dsMake.();
var d = fx[\drums];
~tEq.("the kits in the folder, by key", d.kitKeys, [\tkit, \tkit2]);
~tEq.("...with their names and pads", [d.kitInfo(\tkit)[\name], d.kitInfo(\tkit2)[\pads], d.kitInfo(\nope)],
    ["Test kit", [36, 42], nil]);
~tEq.("...read without a word", d.kitInfo(\tkit)[\warnings], []);
~tEq.("the fixture's kits are in", [d.kit(\steps), d.kitState(\steps), d.kit(\onset), d.kitState(\onset)],
    [\tkit, \ready, \tkit, \ready]);
~tEq.("pads and their names", [d.pads(\steps).size, d.padName(\steps, 42), d.padName(\onset, 99)], [16, "Pad 42", nil]);
d.setPadTrim(\steps, 42, 30);
d.setGroupTrim(\steps, \main, -40);
~tEq.("trims per pad and per group, -24..+12, kept by the kit's key",
    [d.padTrim(\steps, 42), d.groupTrim(\steps, \main), d.padTrim(\steps, 36), d.padTrim(\onset, 42)],
    [12, -24, 0, 12]);
d.setPadTrim(\steps, 42, 0);
d.setGroupTrim(\steps, \main, 0);
d.setKit(\onset, \nope);
~tEq.("a kit that is not there: the slot is silent and says so", [d.kit(\onset), d.kitState(\onset), d.kitFor(\onset)],
    [\nope, \missing, nil]);
}.value;

// ---------------------------------------------------------------- stamps --
{
var fx = ~dsMake.();
var d = fx[\drums];
var delta = (0.02 + 0.0017) + 0.007;
var hits, recs, notes, rolls, laneDelay = [0, 0.02, 0, 0.0075];
~dsPlain.(d, \main, (0: ~dsEvery, 1: [0, 4, 8, 12], 2: [4], 3: [0, 8]));
d.setLaneParam(\main, 1, \delay, 20);
d.setLaneParam(\main, 3, \delay, 7.5);
// A roll on step 2, two hits at 1/16t (80 ticks, a 16th being 120): the second
// is cut by step 3's note.
d.setSteps(\main, \roll, 0, Array.fill(16, { |i| if(i == 2) { 2 } { 0 } }));
d.instVarPut(\dHat, 0.0017);
d.setOffsetMs(7);
fx[\recs] = IdentitySet.new;
~dsStart.(fx, 92.0);
~dsRun.(fx, 94.0);
hits = ~dsHits.(fx[\log]);
recs = fx[\recs].asArray.select { |r| (r[\slot] == \steps) and: { r[\emitted] == true } };
notes = recs.select { |r| r[\kind] == \step };
rolls = recs.select { |r| r[\kind] == \roll };
~tAssert.("bundles were sent", (fx[\log].size > 0) and: { hits.size > 0 } and: { rolls.size > 0 });
~tEq.("...one per decided hit, none cancelled", [hits.size, hits.count(_[\cancelled])], [recs.size, 0]);
~tAssert.("every stamp is grid + 0.020 + dHat + offsetMs / 1000, to 1e-9",
    recs.every { |r| ((r[\stamp] - r[\grid]) - delta).abs < 1e-9 });
~tAssert.("...a note's grid its step's (92.0 + n 16ths) plus its lane's delay",
    notes.every { |r| ((r[\grid] - (92.0 + (r[\n] * 0.125))) - laneDelay[r[\lane]]).abs < 1e-9 });
~tAssert.("...and what was sent went out at those stamps",
    hits.every { |h| recs.any { |r| (r[\hitId] == h[\hitId]) and: { (r[\stamp] - h[\time]).abs < 1e-12 } } });
~tEqArray.("the hats every 16th from the boundary", ~dsOf.(hits, 42).select { |h| h[\vel] == 127 }
    .collect(_[\time]).keep(4), [92.0, 92.125, 92.25, 92.375] + delta, 1e-9);
~tEqArray.("the sidestick, 20 ms late (its lane's delay)", ~dsOf.(hits, 37).collect(_[\time]).keep(2),
    [92.02, 92.52] + delta, 1e-9);
~tEqArray.("the kick 7.5 ms late", ~dsOf.(hits, 36).collect(_[\time]).keep(2), [92.0075, 93.0075] + delta, 1e-9);
~tEqArray.("a roll hit 80 roll ticks after its note, the one after it cut by the next note",
    ~dsOf.(hits, 42).select { |h| h[\vel] != 127 }.collect(_[\time]), [92.25 + (80 * (0.125 / 120))] + delta, 1e-9);
~tEq.("...at 0.7 of its note's velocity", ~dsOf.(hits, 42).select { |h| h[\vel] != 127 }.collect(_[\vel]).keep(1), [88]);
~tEq.("every voice to the steps' group (tail) and bus, with its slot's cancel ring",
    [hits.collect(_[\group]).asSet.asArray, hits.collect(_[\out]).asSet.asArray,
        hits.every { |h| (h[\ring] >= 1000) and: { h[\ring] < 2024 } }], [[1001], [20], true]);
~tEq.("...each added to the TAIL of its group (addAction 1), so of two voices of one choke group starting in one block the later sent runs last and wins",
    hits.collect { |h| h[\addActions].asArray }.flatten.asSet.asArray, [1]);
~tEq.("...a hat on its choke group's bus, a kick on the scratch bus, chokeOn 0",
    [[~dsOf.(hits, 42).first[\chokeBus], ~dsOf.(hits, 42).first[\chokeOn]],
        [~dsOf.(hits, 36).first[\chokeBus], ~dsOf.(hits, 36).first[\chokeOn]]], [[3064, 1], [3080, 0]]);
~tEq.("the stereo pad plays the stereo voice, the others the mono one",
    [~dsOf.(hits, 38).collect(_[\def]).asSet.asArray, ~dsOf.(hits, 42).collect(_[\def]).asSet.asArray],
    [[\megaSADrumVoice2], [\megaSADrumVoice1]]);
~tEq.("the hit ids: one per hit, from 1, all different",
    [hits.first[\hitId], hits.collect(_[\hitId]).asSet.size == hits.size], [1, true]);
~tEq.("the playhead at a grid time: the step there and its lane step", d.playheadAt(92.13),
    (which: \main, n: 1, ls: 1));
~tEq.("...none before the transport plays", d.playheadAt(91.5), nil);
}.value;

// ----------------------------------------------------- rolls and the mute --
{
var fx = ~dsMake.();
var d = fx[\drums];
var hats;
~dsPlain.(d, \main, (0: [0, 4, 8]));
d.setSteps(\main, \roll, 0, Array.fill(16, { |i| case { i == 0 } { 2 } { i == 8 } { 1 } { 0 } }));
d.setParam(\main, \rollRate, 0);   // 1/8.: 360 ticks, three 16ths apart
~dsStart.(fx, 92.0);
~dsRun.(fx, 94.0);
hats = ~dsOf.(~dsSounding.(fx[\log]), 42);
~tAssert.("bundles were sent", hats.size > 0);
~tEqArray.("a roll runs on through steps that do not fire; a NEW note cuts the rest of it",
    ~dsGrid.(hats).keep(5), [92.0, 92.375, 92.5, 93.0, 93.375], 1e-9);
~tEq.("...each roll hit at 0.7 of the velocity before", hats.collect(_[\vel]).keep(5), [127, 88, 127, 127, 88]);
// Muted while step 0's note is decided, unmuted before its roll's first hit:
// a muted lane still starts and cuts rolls; only what it would send is held.
fx = ~dsMake.();
d = fx[\drums];
~dsPlain.(d, \main, (0: [0, 4, 8]));
d.setSteps(\main, \roll, 0, Array.fill(16, { |i| case { i == 0 } { 2 } { i == 8 } { 1 } { 0 } }));
d.setParam(\main, \rollRate, 0);
d.setLaneParam(\main, 0, \mute, true);
~dsStart.(fx, 92.0);
~dsRun.(fx, 92.2);
d.setLaneParam(\main, 0, \mute, false);
~dsRun.(fx, 94.0);
hats = ~dsOf.(~dsSounding.(fx[\log]), 42);
~tAssert.("bundles were sent", hats.size > 0);
~tEqArray.("a muted lane's note is not heard, the roll it started is",
    ~dsGrid.(hats).keep(4), [92.375, 92.5, 93.0, 93.375], 1e-9);
}.value;
// A roll hit on the next note's own time: at Roll Rate 1/16 a one-hit roll on
// step 0 falls on step 1, where the lane fires again. The new note cuts it
// (a roll hit at or after it), so step 1 sounds once, at the note's 127.
{
var fx = ~dsMake.();
var d = fx[\drums], hats;
~dsPlain.(d, \main, (0: [0, 1]));
d.setSteps(\main, \roll, 0, Array.fill(16, { |i| if(i == 0) { 1 } { 0 } }));
d.setParam(\main, \rollRate, 4);       // 1/16: 120 roll ticks, a 16th
~dsStart.(fx, 92.0);
~dsRun.(fx, 92.4);
hats = ~dsVoicesSounding.(fx[\log]).select { |v| (v[\note] == 42) and: { ((v[\time] - 0.02) - 92.125).abs < 1e-9 } };
~tAssert.("bundles were sent", ~dsVoices.(fx[\log]).size > 0);
~tEq.("Roll Rate 1/16: one voice on step 1, the new note at full velocity (the roll hit it cuts never sounds)",
    hats.collect { |v| (v[\amp] * 127).round.asInteger }, [127]);
}.value;

// --------------------------------------------------------------- the break --
{
var fx = ~dsMake.();
var d = fx[\drums];
var active = List.new;
var ctl = SimpleController(d).put(\breakActive, { |o, w, v| active.add(v) });
var snd, kicks, hats, after;
~dsPlain.(d, \main, (3: ~dsEvery));
~dsPlain.(d, \break, (0: ~dsEvery));
~dsStart.(fx, 92.0);
~dsRun.(fx, 92.53);
d.breakOpened(92.53);
~tEq.("a stomp: the break is in force at once", [d.breakActive, active.asArray], [true, [true]]);
~dsRun.(fx, 92.6);
d.breakEndsAt(94.0021, 92.6);
~dsRun.(fx, 94.0021);
after = fx[\log].size;
d.breakClosed(94.0021);
~dsRun.(fx, 94.3);
snd = ~dsSounding.(fx[\log]);
kicks = ~dsGrid.(~dsOf.(snd, 36));
hats = ~dsGrid.(~dsOf.(snd, 42));
~tAssert.("bundles were sent", snd.size > 0);
~tEqArray.("the main pattern up to the stomp less 20 ms (what the hole silences)",
    kicks.select { |t| t < 93 }, [92.0, 92.125, 92.25, 92.375, 92.5], 1e-9);
~tAssert.("...a kick decided before the stomp inside the hole was cancelled",
    ~dsHits.(fx[\log]).any { |h| (h[\note] == 36) and: { h[\cancelled] } and: { ((h[\time] - 0.02) - 92.625).abs < 1e-9 } });
~tEqArray.("the break pattern from there to the loop boundary \\breakEndsAt rounds to (94.0021 -> 94.0)",
    [hats.first, hats.last, hats.size], [92.625, 93.875, 11], 1e-9);
~tNear.("the main pattern back on that boundary", kicks.select { |t| t > 93 }.first, 94.0);
~tEq.("...and the planned \\break false at the end changes nothing", ~dsCancels.(fx[\log].copyToEnd(after)).size, 0);
~tEq.("breakActive: on with the stomp, off once the boundary is heard", active.asArray, [true, false]);
~tEq.("the playhead in the break is the break pattern's", d.playheadAt(93.01), (which: \break, n: 8, ls: 8));
ctl.remove;
}.value;
{
var fx = ~dsMake.();
var d = fx[\drums];
var snd, kicks, hats;
~dsPlain.(d, \main, (3: ~dsEvery));
~dsPlain.(d, \break, (0: ~dsEvery));
~dsStart.(fx, 92.0);
~dsRun.(fx, 92.5);
d.breakOpened(92.5);
~dsRun.(fx, 92.6);
d.breakEndsAt(94.003, 92.6);
~dsRun.(fx, 93.5);
d.breakOpened(93.5);              // a second stomp
~dsRun.(fx, 94.5);
d.breakEndsAt(96.004, 94.5);
~dsRun.(fx, 96.3);
d.breakClosed(96.004);
~dsRun.(fx, 96.5);
d.breakOpened(96.5);
~dsRun.(fx, 96.6);
d.breakEndsAt(98.003, 96.6);
~dsRun.(fx, 97.03);
d.breakClosed(97.03);              // cancelled early (a stop or a clear)
~dsRun.(fx, 97.5);
snd = ~dsSounding.(fx[\log]);
kicks = ~dsGrid.(~dsOf.(snd, 36));
hats = ~dsGrid.(~dsOf.(snd, 42));
~tAssert.("bundles were sent", snd.size > 0);
~tNear.("a second stomp keeps the hole where the first opened it", hats.first, 92.5);
~tAssert.("...and takes the planned end away: the break plays on through 94.0",
    hats.any { |t| (t - 94.0).abs < 1e-9 } and: { kicks.every { |t| (t < 92.48) or: { t >= 95.99 } } });
~tNear.("...until the next \\breakEndsAt", kicks.select { |t| t > 93 }.first, 96.0);
~tEqArray.("a break ended early: the main pattern back from the moment heard",
    [hats.select { |t| t > 96.4 }.first, hats.last, kicks.select { |t| t > 96.4 }.first], [96.5, 97.0, 97.125], 1e-9);
~tAssert.("...a hat decided after that edge was cancelled", ~dsHits.(fx[\log]).any { |h|
    (h[\note] == 42) and: { h[\cancelled] } and: { ((h[\time] - 0.02) - 97.125).abs < 1e-9 } });
}.value;
// A stomp just after a planned end, in the 20 ms before its boundary is
// heard: the Looper has resumed and ended its break (\break false came), and
// opens a new one from the stomp. The drums carry the break pattern on
// through the new hole. 8 ms after the end every main hit of the new hole is
// still to come; 16 ms after it, the downbeat's main kick is already inside
// the margin and sounds, and the break pattern takes over after it.
{
var go = { |stomp|
    var fx = ~dsMake.();
    var d = fx[\drums];
    var active = List.new;
    var ctl = SimpleController(d).put(\breakActive, { |o, w, v| active.add([fx[\wall], v]) });
    var snd;
    ~dsPlain.(d, \main, (3: ~dsEvery));
    ~dsPlain.(d, \break, (0: ~dsEvery));
    ~dsStart.(fx, 92.0);
    ~dsRun.(fx, 92.53);
    d.breakOpened(92.53);
    ~dsRun.(fx, 92.6);
    d.breakEndsAt(94.0021, 92.6);
    ~dsRun.(fx, 94.0021);
    d.breakClosed(94.0021);
    ~dsRun.(fx, stomp);
    d.breakOpened(stomp);
    ~dsRun.(fx, stomp + 0.004);
    d.breakEndsAt(96.0021, stomp + 0.004);
    ~dsRun.(fx, 96.0021);
    d.breakClosed(96.0021);
    ~dsRun.(fx, 96.3);
    ctl.remove;
    snd = ~dsSounding.(fx[\log]);
    (kicks: ~dsGrid.(~dsOf.(snd, 36)), hats: ~dsGrid.(~dsOf.(snd, 42)), active: active.asArray, sent: snd.size)
};
var a = go.(94.010), b = go.(94.016);
~tAssert.("bundles were sent", (a[\sent] > 0) and: { b[\sent] > 0 });
~tAssert.("a stomp 8 ms after a planned end: no main hit until the new break's end",
    a[\kicks].every { |t| (t < 92.51) or: { t >= 95.99 } }, a[\kicks].select { |t| (t >= 92.51) and: { t < 95.99 } });
~tEqArray.("...the break pattern on through both holes", [a[\hats].first, a[\hats].last, a[\hats].size],
    [92.625, 95.875, 27], 1e-9);
~tAssert.("...and breakActive on until the second end is heard",
    (a[\active].collect(_[1]) == [true, false]) and: { a[\active].last[0] >= 96.02 }, a[\active]);
~tEqArray.("16 ms after it: the downbeat's main kick (already too close to cancel), then the break pattern",
    [b[\kicks].select { |t| (t >= 92.51) and: { t < 95.99 } }, b[\hats].select { |t| (t > 93.99) and: { t < 94.2 } }].flat,
    [94.0, 94.125], 1e-9);
~tAssert.("...through to the new end", b[\hats].last.notNil and: { (b[\hats].last - 95.875).abs < 1e-9 }
    and: { b[\kicks].select { |t| (t > 94.01) and: { t < 95.99 } }.isEmpty }, [b[\hats].last, b[\kicks]]);
}.value;

// A multiply struck on a pass its factor does not divide (x2 on the third
// pass, at 97.3): the engine is not respawned and its Phasor keeps its level,
// so it wraps at lam + 3 old loops + k new ones (100, 104, ...), half a new
// loop off loopStartTime's boundaries (98, 102, 106). The Looper's resume
// comes from the engine's phase, so it is a real boundary, a little late or a
// little early; the drums must end the break there, not on the nominal
// boundary nearest it (106 or 102, a whole old loop out either way).
{
var run = { |mulAt, stomp, realEnd, eps|
    var fx = ~dsMake.(90.0, 2.0);
    var d = fx[\drums], l = fx[\looper], snd;
    ~dsPlain.(d, \main, (3: ~dsEvery));
    ~dsPlain.(d, \break, (0: ~dsEvery));
    ~dsStart.(fx, 92.0);
    ~dsRun.(fx, mulAt);
    // Looper.multiply x2 as the language sees it: the loop twice as long, two
    // bars a loop, loopStartTime where it was.
    ~tPut.(l, \loopFrames, (4.0 * 48000).round.asInteger);
    ~tPut.(l, \lastResult, (numerator: 4, denominator: 4, k: 2, bpm: 120, loopDur: 4.0));
    ~dsRun.(fx, stomp);
    d.breakOpened(stomp);
    ~dsRun.(fx, stomp + 0.01);
    d.breakEndsAt(realEnd + eps, stomp + 0.01);
    fx[\breakEnd] = d.instVarAt(\breakEnd);
    ~dsRun.(fx, realEnd + eps);
    d.breakClosed(realEnd + eps);
    ~dsRun.(fx, realEnd + 1.0);
    snd = ~dsSounding.(fx[\log]);
    fx[\kicks] = ~dsGrid.(~dsOf.(snd, 36));
    fx[\hats] = ~dsGrid.(~dsOf.(snd, 42));
    fx
};
var late = run.(97.3, 101.0, 104.0, 0.0021), early = run.(97.3, 101.0, 104.0, -0.0005);
var lateStomp = run.(97.3, 103.5, 104.0, -0.0005), even = run.(95.3, 99.0, 102.0, 0.0021);
~tAssert.("bundles were sent", [late, early, lateStomp, even].every { |f| f[\kicks].notEmpty and: { f[\hats].notEmpty } });
~tEqArray.("after a multiply on an odd pass the break ends where the engine's loop comes back (104), the resume 2.1 ms late or 0.5 ms early",
    [late[\breakEnd], early[\breakEnd]], [104.0, 104.0], 1e-9);
~tEqArray.("...the break pattern up to it, the main pattern from it",
    [late[\hats].last, late[\kicks].detect { |t| t > 100.9 }, early[\hats].last, early[\kicks].detect { |t| t > 100.9 }],
    [103.875, 104.0, 103.875, 104.0], 1e-9);
~tEqArray.("...and a stomp in the pass's second half still plays the break pattern",
    lateStomp[\hats].select { |t| t > 103.4 }, [103.5, 103.625, 103.75, 103.875], 1e-9);
~tNear.("an even pass (x2 on the second): the break ends on loopStartTime's own boundary", even[\breakEnd], 102.0, 1e-9);
}.value;

// ----------------------------------------- cut semantics, delays straddling --
// Three runs of one set: A without a break, I with the break known before
// anything was decided, R with the stomp at 92.56 while the drums run. The
// main kick plays every 16th with no delay and the main hat 50 ms late; the
// break's sidestick every 16th, its snare 50 ms late. At the stomp, hits
// decided with stamps still past wall + margin must come out as in I, the rest
// as in A: nothing lost before the edge, nothing doubled, exactly re-derived.
{
var mk = { |stompAhead|
    var fx = ~dsMake.();
    var d = fx[\drums];
    ~dsPlain.(d, \main, (0: ~dsEvery, 3: ~dsEvery));
    ~dsPlain.(d, \break, (1: ~dsEvery, 2: ~dsEvery));
    d.setLaneParam(\main, 0, \delay, 50);
    d.setLaneParam(\break, 2, \delay, 50);
    ~dsStart.(fx, 92.0);
    if(stompAhead) { d.breakOpened(92.56) };
    fx
};
var fa = mk.(false), fi = mk.(true), fr = mk.(false);
var cutLine = 92.56 + fr[\drums].margin;
var a, i, r, want;
~dsRun.(fa, 93.5);
~dsRun.(fi, 93.5);
~dsRun.(fr, 92.56);
fr[\drums].breakOpened(92.56);
~dsRun.(fr, 93.5);
a = ~dsSounding.(fa[\log]);
i = ~dsSounding.(fi[\log]);
r = ~dsSounding.(fr[\log]);
~tAssert.("bundles were sent", (a.size > 0) and: { i.size > 0 } and: { r.size > 0 });
want = (a.select { |h| h[\time] <= cutLine } ++ i.select { |h| h[\time] > cutLine });
~tEq.("a stomp while running: what sounds is the run without the break up to wall + margin, the break from there",
    ~dsKeys.(r), ~dsKeys.(want));
~tEq.("...nothing twice", ~dsKeys.(r).asSet.size, r.size);
~tAssert.("...nothing lost before the edge", a.select { |h| (h[\time] - 0.02) < 92.54 }
    .every { |h| ~dsKeys.(r).includesEqual(~dsKey.(h)) });
~tAssert.("...the step before the edge straddles it: its kick kept, its 50 ms hat cancelled, the break's snare sent",
    ~dsKeys.(r).includesEqual(~dsKey.((note: 36, time: 92.52))) and: { ~dsKeys.(r).includesEqual(~dsKey.((note: 42, time: 92.57))).not }
        and: { ~dsKeys.(r).includesEqual(~dsKey.((note: 38, time: 92.57))) }
        and: { ~dsKeys.(r).includesEqual(~dsKey.((note: 37, time: 92.52))).not });
~tAssert.("...that hat was sent before the stomp and cancelled by it", ~dsHits.(fr[\log]).any { |h|
    (h[\note] == 42) and: { h[\cancelled] } and: { (h[\time] - 92.57).abs < 1e-9 } and: { h[\wall] < 92.56 } });
}.value;

// -------------------------------------- both patterns in phase across a break --
// The Live set's own patterns and dice. Both patterns decide every step all
// along, so after a break the main pattern is exactly where it would have
// been, and in the hole the break pattern is exactly what it would have been
// had it played from the start (its rolls from before the stomp included).
{
var fa = ~dsMake.(), fb = ~dsMake.(), fc = ~dsMake.();
var a, b, c, inHole, line = 92.53 + fb[\drums].margin;
~dsStart.(fa, 92.0);
~dsStart.(fb, 92.0);
fc[\drums].setBreakPattern(true, 91.0);
~dsStart.(fc, 92.0);
~dsRun.(fa, 96.0);
~dsRun.(fc, 96.0);
~dsRun.(fb, 92.53);
fb[\drums].breakOpened(92.53);
~dsRun.(fb, 92.6);
fb[\drums].breakEndsAt(94.0021, 92.6);
~dsRun.(fb, 94.0021);
fb[\drums].breakClosed(94.0021);
~dsRun.(fb, 96.0);
a = ~dsSounding.(fa[\log]);
b = ~dsSounding.(fb[\log]);
c = ~dsSounding.(fc[\log]);
~tAssert.("bundles were sent", (a.size > 0) and: { b.size > 0 } and: { c.size > 0 });
inHole = { |h| (h[\time] > line) and: { (h[\time] - 0.02) < 94.0 } };
~tEq.("in the hole: the break pattern as if it had played all along",
    ~dsKeys.(b.select(inHole)), ~dsKeys.(c.select(inHole)));
~tEq.("before and after it: the main pattern exactly as without the break",
    ~dsKeys.(b.reject(inHole)), ~dsKeys.(a.reject(inHole)));
~tAssert.("...which has hits after the break (a real comparison)", a.reject(inHole).any { |h| h[\time] > 94.0 });
}.value;

// ------------------------------------------------------------------- PC 17 --
{
var fx = ~dsMake.();
var d = fx[\drums], l = fx[\looper];
var ons = List.new;
var ctl = SimpleController(d).put(\on, { |o, w, v| ons.add(v) });
var snd, kicks, onset;
~dsPlain.(d, \main, (3: ~dsEvery));
~tPut.(l, \onsetNoteRolls, [0.0]);
~dsStart.(fx, 92.0);
d.startOnsets(l, [[0.0, 1.0]], 0.5, 91.9);
~dsRun.(fx, 92.5);
d.setOn(false, 92.5);
~dsRun.(fx, 93.0);
d.setOn(true, 93.0);
d.setOn(true, 93.0);
~dsRun.(fx, 93.5);
snd = ~dsSounding.(fx[\log]);
kicks = ~dsGrid.(~dsOf.(snd.select { |h| h[\group] == 1001 }, 36));
onset = ~dsGrid.(snd.select { |h| h[\group] == 1003 });
~tAssert.("bundles were sent", snd.size > 0);
~tEqArray.("PC 17 off: the steps stop from the moment heard (t - 0.020)",
    kicks.select { |t| t < 93 }, [92.0, 92.125, 92.25, 92.375], 1e-9);
~tAssert.("...a kick already sent after the edge cancelled", ~dsHits.(fx[\log]).any { |h|
    (h[\group] == 1001) and: { h[\cancelled] } and: { ((h[\time] - 0.02) - 92.5).abs < 1e-9 } });
~tNear.("on again: back from its own edge", kicks.select { |t| t > 92.9 }.first, 93.0);
~tEq.("\\on notified for every press, a repeated one too", ons.asArray, [false, true, true]);
~tEqArray.("the onset kit ignores PC 17 (it is the steps' switch only, as in Live)",
    onset.select { |t| (t > 92.3) and: { t < 93.2 } }, [92.5, 93.0], 1e-9);
ctl.remove;
}.value;

// -------------------------------------------------------------------- stop --
{
var fx = ~dsMake.();
var d = fx[\drums];
var playing = List.new;
var ctl = SimpleController(d).put(\playing, { |o, w, v| playing.add(v) });
var snd, kicks, n, hits, first, second;
~dsPlain.(d, \main, (0: [0, 4, 8, 12], 3: ~dsEvery));
d.setSteps(\main, \roll, 0, Array.fill(16, 3));
~dsStart.(fx, 92.0);
~tEq.("a Start: playing", [d.playing, playing.asArray], [true, [true]]);
~dsRun.(fx, 92.53);
d.transportStop(92.53);
~tEq.("a Stop: not playing", [d.playing, playing.asArray], [false, [true, false]]);
n = fx[\log].size;
~dsRun.(fx, 93.5);
~tEq.("...and the pump decides nothing more", fx[\log].size, n);
snd = ~dsSounding.(fx[\log]);
~tAssert.("bundles were sent", snd.size > 0);
~tAssert.("...nothing sounds from the moment heard on, rolls included",
    snd.every { |h| (h[\time] - 0.02) < 92.51 });
~tAssert.("...what was sent past it was cancelled", ~dsHits.(fx[\log]).select { |h| (h[\time] - 0.02) >= 92.51 }
    .every(_[\cancelled]) and: { ~dsHits.(fx[\log]).any { |h| (h[\time] - 0.02) >= 92.51 } });
// Started again: a new origin, the step counters from 0, new dice.
~dsStart.(fx, 96.0);
~dsRun.(fx, 96.3);
hits = ~dsGrid.(~dsOf.(~dsSounding.(fx[\log]), 36));
~tNear.("a Start after a Stop plays from its boundary", hits.select { |t| t > 95 }.first, 96.0);
~tEq.("...the steps counted from 0 again", d.playheadAt(96.13), (which: \main, n: 1, ls: 1));
first = d.instVarAt(\epochs).collect { |e| e[\seed] };
~tEq.("...with dice drawn again (the seed per transport start)", first.asArray.asSet.size, first.size);
ctl.remove;
}.value;
// PC 17 and a Stop between a step and its heard time: both take effect from
// the moment heard, so their edge is 20 ms before the press. A kick on 92.5
// is heard at 92.52; PC 17 off (or a Stop) at 92.51 comes before that and cuts
// it; on again at 93.01 comes before the kick on 93.0 is heard, which plays.
{
var go = { |what|
    var fx = ~dsMake.(), d = fx[\drums];
    ~dsPlain.(d, \main, (3: ~dsEvery));
    ~dsStart.(fx, 92.0);
    ~dsRun.(fx, 92.51);
    if(what == \stop) { d.transportStop(92.51) } { d.setOn(false, 92.51) };
    ~dsRun.(fx, 93.01);
    if(what == \on) { d.setOn(true, 93.01) };
    ~dsRun.(fx, 93.4);
    ~dsGrid.(~dsOf.(~dsSounding.(fx[\log]), 36)).collect(_.round(1e-6))
};
var off = go.(\on), stop = go.(\stop);
~tAssert.("bundles were sent", (off.size > 0) and: { stop.size > 0 });
~tEq.("PC 17 off at 92.51: the kick on 92.5, heard at 92.52, is cut", off.select { |t| t < 93 }.last, 92.375);
~tEq.("...on at 93.01: the kick on 93.0, heard at 93.02, plays", off.select { |t| t > 92.9 }.first, 93.0);
~tEq.("a Stop at 92.51 cuts the kick on 92.5 too", stop.last, 92.375);
}.value;

// ------------------------------------------------------- stale logical time --
// The Start, the pump and a stomp from a thread whose logical time lags wall
// by 0.2 s (an analysis just ran on it), through the DEFAULT sender: deltas
// from that stale time, the stub recording what scsynth would play each
// bundle at. Nothing may be stamped before wall + margin, nothing sent twice.
{
var fx = ~dsMake.();
var d = MegaSADrums((server: fx[\stub]));
var stub = fx[\stub], r, sent, snd;
var l = fx[\looper];
fx[\drums].free;
d.prUseBusses;
d.wallClock = { fx[\wall] };
d.randSeed = 1234;
d.kitDir = ~dsDir;
d.kitReader = ~dsReader;
d.setKit(\steps, \tkit);
d.attach(l);
stub[\sendBundle] = { |self, time ... args| self[\bundles].add([thisThread.seconds + (time ? 0), args, fx[\wall]]); self };
~dsPlain.(d, \main, (0: ~dsEvery, 3: ~dsEvery));
d.setSteps(\main, \roll, 0, Array.fill(16, 2));
r = Routine {
    fx[\wall] = 91.95;
    thisThread.seconds = 91.75;
    d.transportStart(thisThread.seconds);
    0.yield;
    (0..120).do { |k|
        fx[\wall] = 91.95 + (k * 0.01);
        thisThread.seconds = fx[\wall] - 0.2;
        d.pump(fx[\wall]);
        if(k == 60) { d.breakOpened(thisThread.seconds) };
        0.yield;
    };
};
while { r.next.notNil } { };
sent = stub[\bundles].select { |b| b[1].any { |m| m[0] == \s_new } };
snd = ~dsSounding.(stub[\bundles]);
~tAssert.("bundles were sent", (sent.size > 0) and: { snd.size > 0 });
~tAssert.("from a caller 0.2 s behind: nothing stamped before wall + margin",
    sent.every { |b| b[0] > (b[2] + d.margin) }, sent.reject { |b| b[0] > (b[2] + d.margin) }.collect { |b| [b[0], b[2]] });
~tEq.("...and nothing sounding twice", ~dsKeys.(snd).asSet.size, snd.size);
~tAssert.("...the absolute stamps exact: the hats on the 16ths from 92.0",
    ~dsOf.(snd, 42).select { |h| h[\vel] == 127 }.every { |h| ((((h[\time] - 0.02) - 92.0) / 0.125) - (((h[\time] - 0.02) - 92.0) / 0.125).round).abs < 1e-6 });
~tAssert.("...the stomp reported late cut only what could still be cancelled", ~dsHits.(stub[\bundles])
    .select(_[\cancelled]).every { |h| h[\time] > (91.95 + 0.6 + d.margin) });
~tAssert.("...and did cut what it could (a stomp that cut nothing would pass the check above on nothing)",
    ~dsHits.(stub[\bundles]).count(_[\cancelled]) > 0);
}.value;

// ------------------------------------------------------------------ drops --
{
var fx = ~dsMake.();
var d = fx[\drums];
var snd;
~dsPlain.(d, \main, (3: ~dsEvery));
~dsStart.(fx, 92.0);
fx[\wall] = 92.0;
d.pump(92.0);
fx[\wall] = 92.6;
d.pump(92.6);                       // a 600 ms stall
snd = ~dsSounding.(fx[\log]);
~tAssert.("bundles were sent", snd.size > 0);
~tEq.("a stall: every hit that would sound late is dropped, and counted", d.dropped, 4);
~tEqArray.("...not sent late in a burst", ~dsGrid.(snd), [92.0, 92.625], 1e-9);
fx[\wall] = 93.6;
d.pump(93.6);
~tEq.("...counted on across bursts", d.dropped, 11);
}.value;

// ---------------------------------------------------- Clock Speed at bar 20 --
{
var go = { |speed, retrig = true|
    var fx = ~dsMake.();
    var d = fx[\drums];
    ~dsPlain.(d, \main, (3: ~dsEvery));
    d.setParam(\main, \autoRetrigger, retrig);
    ~dsStart.(fx, 92.0);
    ~dsRun.(fx, 132.0, 0.05);
    d.setParam(\main, \clockSpeed, speed);
    ~dsRun.(fx, 134.1, 0.05);
    fx
};
var fx0 = go.(0), fx5 = go.(5), fxr = go.(0, false), k0, k5;
k0 = ~dsGrid.(~dsOf.(~dsSounding.(fx0[\log]), 36));
k5 = ~dsGrid.(~dsOf.(~dsSounding.(fx5[\log]), 36));
~tAssert.("bundles were sent", (k0.size > 0) and: { k5.size > 0 });
~tEqArray.("Clock Speed 100 -> 50 % at bar 20: on within one new step, in 8ths",
    k0.select { |t| t > 131.9 }.keep(4), [132.0, 132.25, 132.5, 132.75], 1e-9);
~tEqArray.("Clock Speed 100 -> 200 %: on within one new step, in 32nds",
    k5.select { |t| t > 131.9 }.keep(4), [132.0, 132.0625, 132.125, 132.1875], 1e-9);
~tEq.("...no step silenced for 20 bars, none replayed in a burst", [fx0[\drums].dropped, fx5[\drums].dropped], [0, 0]);
~tEq.("the first Clock Speed edit arms a resync, as Live's does (Auto Retrigger off: only it can)",
    fxr[\drums].playheadAt(134.0 + 1e-6), (which: \main, n: 168, ls: 0));
}.value;
// A pattern put in whole before the transport has ever played (the kept
// drums at boot, a preset) is the device's stored state, which Live restores
// before it arms that resync: its Shuffle Length differing leaves the first
// edit's resync still to come. A Clock Speed edit by hand uses it up, as the
// device's own knob does.
{
var fx = ~dsMake.();
var d = fx[\drums], p, hand;
~dsPlain.(d, \main, (3: ~dsEvery));
d.setParam(\main, \autoRetrigger, false);
p = d.patterns[\main].deepCopy;
p[\shuffleLength] = 4;
d.setPattern(\main, p);
~tEq.("a pattern put in before the transport has played leaves the first edit's resync to come",
    [d.param(\main, \shuffleLength), d.instVarAt(\timeShiftArm)[\main]], [4, true]);
~dsStart.(fx, 92.0);
~dsRun.(fx, 132.0, 0.05);
d.setParam(\main, \clockSpeed, 0);
~dsRun.(fx, 134.1, 0.05);
~tEq.("...which the first Clock Speed edit in play then arms", d.playheadAt(134.0 + 1e-6), (which: \main, n: 168, ls: 0));
hand = MegaSADrums((server: ~tStubServer.()));
hand.setParam(\break, \clockSpeed, 2);
~tEq.("...while an edit by hand before the transport plays uses it up", hand.instVarAt(\timeShiftArm)[\break], false);
}.value;

// ----------------------------------- the shuffle and the retrigger rate --
// The set's dials at Global Shuffle 100 % through the pump: the steps fire
// where the device's 1/64-note metro puts them. At 150 % with the first two
// dials pulled together two steps land on one 1/64 tick: the earlier is
// skipped, the step plays once. Auto Trigger Rate 2 Bars: a 12-step lane
// resyncs every 32 steps, not every 16.
{
var fx = ~dsMakeGap.(), d = fx[\drums], kicks, fx2, d2, k2, want2, fx3, d3, steps;
~dsPlain.(d, \main, (3: ~dsEvery));
d.setParam(\main, \autoRetrigger, false);
d.setParam(\main, \globalShuffle, 100);
~dsStart.(fx, 92.0);
~dsRun.(fx, 93.0);
kicks = ~dsVoicesSounding.(fx[\log]).select { |v| v[\note] == 36 }
    .collect { |v| (((v[\time] - 0.02) - 92.0) / 0.125).round(1e-6) };
~tAssert.("bundles were sent", kicks.size >= 7);
~tEq.("the set's dials at Global Shuffle 100 %: the steps where the device's metro puts them",
    kicks.keep(7), [0.25, 0.75, 2.0, 3.0, 3.75, 5.0, 6.25]);
fx2 = ~dsMakeGap.();
d2 = fx2[\drums];
~dsPlain.(d2, \main, (3: ~dsEvery));
d2.setParam(\main, \autoRetrigger, false);
d2.setParam(\main, \shuffleLength, 4);
d2.setParam(\main, \shuffle1, 45);
d2.setParam(\main, \shuffle2, -45);
d2.setParam(\main, \globalShuffle, 100);
d2.setParam(\main, \clockSpeed, 4);
~dsStart.(fx2, 92.0);
~dsRun.(fx2, 93.0);
k2 = ~dsVoicesSounding.(fx2[\log]).select { |v| v[\note] == 36 }
    .collect { |v| ((((v[\time] - 0.02) - 92.0) / 0.125) * 120).round(1e-6) };
want2 = (0..9).collect { |n| MegaSASteps.fireTick(n, 90, MegaSASteps.shuffleOffsets([45, -45, 0, 0, 0, 0, 0, 0], 4, 100), 4) }
    .asSet.asArray.sort;
~tAssert.("bundles were sent", k2.size > 4);
~tEq.("at 150 % two steps on one 1/64 tick play once (the earlier skipped)", k2.keep(want2.size), want2);
fx3 = ~dsMakeGap.();
d3 = fx3[\drums];
~dsPlain.(d3, \main, (3: [0]));
d3.setLength(\main, \chance, 3, 12);
d3.setParam(\main, \autoTriggerRate, 1);
~dsStart.(fx3, 92.0);
~dsRun.(fx3, 97.7);
steps = ~dsVoicesSounding.(fx3[\log]).select { |v| v[\note] == 36 }
    .collect { |v| (((v[\time] - 0.02) - 92.0) / 0.125).round.asInteger };
~tEq.("Auto Trigger Rate 2 Bars: a 12-step lane resyncs every 32 steps", steps.keep(5), [0, 12, 24, 32, 44]);
}.value;

// ---------------------------------------------------------------- readings --
{
var fx = ~dsMake.();
var d = fx[\drums], l = fx[\looper];
var r34 = (numerator: 3, denominator: 4, k: 1, bpm: 90, loopDur: 2.0);
var p = (index: 1, result: r34, at: 96.0, loops: 1, restart: false);
var kicks, landed;
~dsPlain.(d, \main, (3: ~dsEvery));
~dsStart.(fx, 92.0);
~dsRun.(fx, 93.0);
d.readingArmed(p, 93.0);
~dsRun.(fx, 96.0);
landed = fx[\log].size;
~tPut.(l, \readingIndex, 1);
d.setAnalysis(r34, 96.0);
d.readingCleared(96.0);
~dsRun.(fx, 96.2);
~tEq.("a reading landing: the step count goes on across it (two loops of 16)", d.playheadAt(96.0 + 1e-6),
    (which: \main, n: 32, ls: 0));
~dsRun.(fx, 97.0);
kicks = ~dsGrid.(~dsOf.(~dsSounding.(fx[\log]), 36));
~tAssert.("bundles were sent", kicks.size > 0);
~tEqArray.("a reading without a restart: the old 16ths up to its landing",
    kicks.select { |t| (t > 95.6) and: { t < 96 } }, [95.625, 95.75, 95.875], 1e-9);
~tEqArray.("...the new from it (a bar of 3/4 in the same loop: 12 16ths)",
    kicks.select { |t| t >= 96 }.keep(4), [96.0, 96 + (2 / 12), 96 + (4 / 12), 96.5], 1e-9);
~tEq.("...put in ahead: nothing sent was ever cancelled", ~dsHits.(fx[\log]).count(_[\cancelled]), 0);
~tEq.("...and its confirmation at the landing changed nothing", ~dsCancels.(fx[\log].copyToEnd(landed)).size, 0);
}.value;
{
var fx = ~dsMake.();
var d = fx[\drums], l = fx[\looper];
var r34 = (numerator: 3, denominator: 4, k: 1, bpm: 90, loopDur: 2.0);
var p = (index: 1, result: r34, at: 96.0, loops: 1, restart: true);
var kicks, epochs;
~dsPlain.(d, \main, (3: ~dsEvery));
~dsStart.(fx, 92.0);
~dsRun.(fx, 93.0);
d.readingArmed(p, 93.0);
epochs = d.instVarAt(\epochCount);
~tEq.("a reading with a restart goes in ahead as a new origin", epochs, 2);
~dsRun.(fx, 96.0);
d.transportStart(96.0);
~tEq.("...the Looper's Start at its landing is a confirmation, no third origin", d.instVarAt(\epochCount), 2);
~tPut.(l, \readingIndex, 1);
d.setAnalysis(r34, 96.0);
d.readingCleared(96.0);
~dsRun.(fx, 96.2);
~tEq.("...the steps count from 0 there", d.playheadAt(96.0 + 1e-6), (which: \main, n: 0, ls: 0));
~dsRun.(fx, 97.0);
kicks = ~dsGrid.(~dsOf.(~dsSounding.(fx[\log]), 36));
~tAssert.("bundles were sent", kicks.size > 0);
~tEqArray.("...the old grid up to it, the new from it",
    kicks.select { |t| t > 95.7 }.keep(4), [95.75, 95.875, 96.0, 96 + (2 / 12)], 1e-9);
~tEq.("...nothing sent was ever cancelled", ~dsHits.(fx[\log]).count(_[\cancelled]), 0);
}.value;
// Cancelled: the reading is armed for 94.0, the drums decide past it under its
// grid (at 200 % a step is 50 ms in 5/4, 62.5 ms in 4/4), then the Looper
// takes it back before it lands. What sounds is the run with no reading.
{
var mk = {
    var fx = ~dsMake.();
    var d = fx[\drums];
    ~dsPlain.(d, \main, (3: ~dsEvery));
    d.setParam(\main, \clockSpeed, 5);
    ~dsStart.(fx, 92.0);
    fx
};
var fa = mk.(), fr = mk.();
var p = (index: 1, result: (numerator: 5, denominator: 4, k: 1, bpm: 150, loopDur: 2.0), at: 94.0, loops: 1,
    restart: false);
var cancels;
~dsRun.(fa, 95.0);
~dsRun.(fr, 93.5);
fr[\drums].readingArmed(p, 93.5);
~dsRun.(fr, 93.97);
~tAssert.("(the drums decided past the landing under the reading's grid)", ~dsHits.(fr[\log])
    .any { |h| ((h[\time] - 0.02) - 94.05).abs < 1e-9 });
cancels = ~dsCancels.(fr[\log]).size;
fr[\drums].readingCleared(93.97);
~dsRun.(fr, 95.0);
~tAssert.("bundles were sent", (~dsSounding.(fa[\log]).size > 0) and: { ~dsSounding.(fr[\log]).size > 0 });
~tEq.("a cancelled reading comes out: what sounds is the run without it",
    ~dsKeys.(~dsSounding.(fr[\log])), ~dsKeys.(~dsSounding.(fa[\log])));
~tAssert.("...its hits past the landing cancelled", ~dsCancels.(fr[\log]).size > cancels);
~tEq.("...and nothing dropped", fr[\drums].dropped, 0);
}.value;
// A reading that restarts, taken back: a loop ahead, 40 ms before it lands
// (its own hits already sent, a roll crossing the landing), or replaced by a
// second press with a reading that does not restart. Each must sound as the
// run that never had it, nothing re-decided late. A 15-step hat lane with a
// roll at 1/8. on its step 0 crosses 94.0 (Auto Retrigger off).
{
var mk = {
    var fx = ~dsMakeGap.(), d = fx[\drums];
    ~dsPlain.(d, \main, (3: ~dsEvery, 0: [0]));
    d.setLaneParam(\main, 0, \note, 42);
    d.setLength(\main, \chance, 0, 15);
    d.setLength(\main, \roll, 0, 15);
    d.setSteps(\main, \roll, 0, Array.fill(16, { |i| if(i == 0) { 2 } { 0 } }));
    d.setParam(\main, \rollRate, 0);
    d.setParam(\main, \autoRetrigger, false);
    ~dsStart.(fx, 92.0);
    fx
};
var p = (index: 1, result: (numerator: 7, denominator: 8, k: 1, bpm: 120, loopDur: 2.0), at: 94.0, loops: 1, restart: true);
var p2 = (index: 2, result: (numerator: 4, denominator: 4, k: 1, bpm: 120, loopDur: 2.0), at: 94.0, loops: 1, restart: false);
var fa = mk.(), fc = mk.(), fe = mk.(), fr = mk.(), a, c, e, r;
~dsRun.(fa, 96.0);
~dsRun.(fc, 93.0); fc[\drums].readingArmed(p, 93.0); ~dsRun.(fc, 93.5); fc[\drums].readingCleared(93.5); ~dsRun.(fc, 96.0);
~dsRun.(fe, 93.0); fe[\drums].readingArmed(p, 93.0); ~dsRun.(fe, 93.96); fe[\drums].readingCleared(93.96); ~dsRun.(fe, 96.0);
~dsRun.(fr, 93.0); fr[\drums].readingArmed(p, 93.0); ~dsRun.(fr, 93.2); fr[\drums].readingArmed(p2, 93.2);
~dsRun.(fr, 94.0); ~tPut.(fr[\looper], \readingIndex, 2); fr[\drums].readingCleared(94.0); ~dsRun.(fr, 96.0);
a = ~dsVoicesSounding.(fa[\log]);
c = ~dsVoicesSounding.(fc[\log]);
e = ~dsVoicesSounding.(fe[\log]);
r = ~dsVoicesSounding.(fr[\log]);
~tAssert.("bundles were sent, a roll crossing 94.0 among them",
    (a.size > 0) and: { a.any { |v| (v[\note] == 42) and: { v[\time] > 94.1 } and: { v[\time] < 94.3 } } });
~tEq.("a restart reading taken back a loop ahead: as if never armed", ~dsVoiceKeys.(c), ~dsVoiceKeys.(a));
~tEq.("...taken back 40 ms before it lands, its own hits sent: as if never armed, the roll across it back",
    ~dsVoiceKeys.(e), ~dsVoiceKeys.(a));
~tEq.("...replaced by a second press, a reading that does not restart: no restart", ~dsVoiceKeys.(r), ~dsVoiceKeys.(a));
~tEq.("...and none of it decided again too late (nothing dropped)", [fc, fe, fr].collect { |f| f[\drums].dropped }, [0, 0, 0]);
}.value;

// ------------------------------------------ the Looper's port, end to end --
{
var now = thisThread.seconds;          // the main thread's time, standing still
var fx = ~dsMake.(now - 1.0);          // a loop that started a second ago
var d = fx[\drums], l = fx[\looper], port = l.midiOut;
var at = { |w, fn| Routine { thisThread.seconds = w; fx[\wall] = w; fn.value }.next };
var snd, kicks, hats, onset, n;
~tEq.("attach: the Looper's MIDI port is the drums' transport", port === d.transport, true);
~tEq.("...its onset sink the drums, and a Start relocates nothing", [l.onsetNoteSink === d, l.startsRelocate], [true, false]);
~tNear.("the port's latency: the drums' lead", port.latency, d.lead, 1e-12);
~dsPlain.(d, \main, (3: ~dsEvery));
~dsPlain.(d, \break, (0: ~dsEvery));
port.start;
fx[\wall] = now + 0.9;
~dsRun.(fx, now + 1.5);
at.(now + 1.5, { l.changed(\break, true) });
~dsRun.(fx, now + 1.6);
at.(now + 1.6, { l.changed(\breakEndsAt, now + 3.0021) });
~dsRun.(fx, now + 3.0021);
at.(now + 3.0021, { l.changed(\break, false) });
~dsRun.(fx, now + 3.5);
~tPut.(l, \engineSynth, ~tStubSynth.(l, \looperEngineMono));
~tPut.(l, \onsetNotePattern, [[0.1, 1.0], [1.1, 0.5]]);
~tPut.(l, \onsetNotePatternDur, 2.0);
~tPut.(l, \onsetNoteRolls, [0.0, 0.0]);
~tPut.(l, \onsetNotes, true);
at.(now + 3.5, { l.startOnsetNotes });
~dsRun.(fx, now + 4.8);
at.(now + 4.8, { l.stopPlayback });
~dsRun.(fx, now + 6.0);
snd = ~dsSounding.(fx[\log]);
kicks = ~dsGrid.(~dsOf.(snd.select { |h| h[\group] == 1001 }, 36));
hats = ~dsGrid.(~dsOf.(snd.select { |h| h[\group] == 1001 }, 42));
onset = ~dsGrid.(snd.select { |h| h[\group] == 1003 });
~tAssert.("bundles were sent", (kicks.size > 0) and: { hats.size > 0 } and: { onset.size > 0 });
~tNear.("the Looper's Start began the drums on the boundary it aimed at", kicks.first, now + 1.0, 1e-9);
~tEqArray.("its \\break, \\breakEndsAt and \\break false switched the patterns",
    [hats.first, hats.last, kicks.select { |t| t > (now + 2) }.first], [now + 1.5, now + 2.875, now + 3.0], 1e-9);
~tEqArray.("its onset part played through the sink, on the onset kit's group", onset, [now + 4.1], 1e-9);
~tEq.("its stop stopped the drums", d.playing, false);
~tAssert.("...nothing after its edge", kicks.every { |t| t < (now + 4.78) });
d.free;
// On a reboot the old Looper plays on until ~setupLooper frees it, after the
// new MegaSA is up: its MIDI clock calls its port every tick meanwhile.
~tEq.("free lets go of the Looper, which keeps the drums' port and sink, dead now, and its Starts relocate again",
    [l.midiOut === port, l.onsetNoteSink === d, port.alive, l.startsRelocate], [true, true, false, true]);
~tCheck.("...so the old Looper's MIDI clock, still running, ticks on into nothing (no nil.midiClock)", {
    var clock;
    l.startMidiClock(201, 2.0);
    clock = ~tGet.(l, \midiClockRoutine);
    // Each .next is one tick of it: the port's latency, start, midiClock.
    4.do { clock.next };
    clock.stop;
});
n = fx[\log].size;
~tCheck.("a freed drums object and its old port do nothing", {
    port.start;
    port.stop;
    port.noteOn(1, 36, 100);
    d.pump(now + 7);
    d.transportStart(now + 7);
    d.startOnsets(l, [[0.1, 1.0]], 2.0);
    d.stopOnsets(l);
    d.setOn(false);
    d.breakOpened(now + 7);
});
~tEq.("...nothing at all", [fx[\log].size, d.alive, port.latency], [n, false, 0]);
}.value;

// ------------------------------------------------------------- the drift --
// A stub probe: the loop runs 3 ms behind the language's model, and every
// probe the drums send is answered with the phase it would read (the block's
// first sample: 31.5 samples before the probe's time, on average).
{
var mk = { |probing|
    var fx = ~dsMake.();
    var d = fx[\drums];
    fx[\probes] = List.new;
    ~dsPlain.(d, \main, (3: ~dsEvery));
    d.autoProbe = probing;
    d.sender = { |t, msgs|
        fx[\log].add([t, msgs, fx[\wall]]);
        msgs.do { |m| if((m[0] == \s_new) and: { m[1] == \megaSADrumsProbe }) { fx[\probes].add([m[m.indexOf(\id) + 1], t]) } };
    };
    ~dsStart.(fx, 92.0);
    fx
};
var run = { |fx, to|
    var w = fx[\wall];
    while { w < (to - 1e-9) } {
        w = (w + 0.05).min(to);
        fx[\wall] = w;
        fx[\drums].pump(w);
        fx[\probes].do { |p|
            fx[\drums].probeReply(p[0], (((p[1] - 90.0) - 0.003) % 2.0) - (31.5 / 48000), p[1] + 0.001);
        };
        fx[\probes] = List.new;
    };
};
var fp = mk.(true), fn = mk.(false);
var probes, probeTimes, lastKick, gridsP, gridsN, sentP, sentN, onsetHit;
run.(fp, 150.0);
run.(fn, 150.0);
probes = fp[\log].count { |b| b[1].any { |m| (m[0] == \s_new) and: { m[1] == \megaSADrumsProbe } } };
~tAssert.("bundles were sent", (fp[\log].size > 0) and: { probes > 0 });
~tEq.("a probe every 2 s, at once from the start", probes, 30);
probeTimes = fp[\log].select { |b| b[1].any { |m| (m[0] == \s_new) and: { m[1] == \megaSADrumsProbe } } }.collect(_[0]);
~tAssert.("...on a steady 2 s cadence: the k-th 2k s after the first (within this test's 50 ms pumps), never drifting",
    probeTimes.every { |t, k| ((t - (probeTimes[0] + (2 * k))) > -0.002) and: { (t - (probeTimes[0] + (2 * k))) < 0.052 } });
~tNear.("the estimate settles on the loop's 3 ms", fp[\drums].dHat, 0.003, 1e-5);
~tNear.("...the last probe's error about nothing", fp[\drums].lastProbeError, 0, 1e-5);
lastKick = fp[\drums].decided.select { |r| (r[\kind] == \step) and: { r[\emitted] == true } }.last;
~tNear.("...so the hits are stamped 3 ms later: nominal + 0.003", lastKick[\stamp] - lastKick[\grid], 0.023, 1e-5);
gridsP = fp[\drums].decided.select { |r| r[\kind] == \step }.collect { |r| r[\grid] };
gridsN = fn[\drums].decided.select { |r| r[\kind] == \step }.collect { |r| r[\grid] };
~tAssert.("...while no grid time moves at all: the same grid as without the probe",
    (gridsP.size == gridsN.size) and: { gridsP.size > 0 } and: { gridsP.every { |g, i| g == gridsN[i] } });
sentP = ~dsHits.(fp[\log]);
sentN = ~dsHits.(fn[\log]);
~tAssert.("...every hit of the run the same, each only later by the estimate it was decided under (0 to 3 ms)",
    (sentP.size == sentN.size) and: { sentP.size > 400 } and: { sentP.every { |h, i|
        (h[\note] == sentN[i][\note]) and: { (h[\time] - sentN[i][\time]) >= -1e-12 }
            and: { (h[\time] - sentN[i][\time]) <= (0.003 + 1e-6) } } });
~tEq.("...with no probe at all on a stub server", MegaSADrums((server: ~tStubServer.())).autoProbe, false);
fp[\looper].instVarPut(\onsetNoteRolls, [0.0]);
fp[\drums].startOnsets(fp[\looper], [[0.5, 1.0]], 2.0, 150.0);
run.(fp, 151.0);
onsetHit = fp[\drums].decided.detect { |r| (r[\slot] == \onset) and: { r[\emitted] == true } };
~tNear.("the onset kit is stamped with the same estimate", onsetHit !? { |r| r[\stamp] - r[\grid] }, 0.023, 1e-5);
}.value;
{
var fx = ~dsMake.();
var d = fx[\drums], l = fx[\looper];
var late = { |t, lam = 90.0| (((t - lam) - 0.003) % 2.0) - (31.5 / 48000) };
var id, held, rec;
~dsStart.(fx, 92.0);
~dsRun.(fx, 92.5);
fx[\wall] = 93.0;
id = d.probe(93.0);
~tAssert.("a probe is sent while the loop plays forwards", id.notNil);
rec = d.instVarAt(\probes)[id];
d.probeReply(id, late.(rec[\time]), rec[\time] + 0.01);
~tNear.("...and moves the estimate", d.dHat, 0.00075, 1e-9);
held = d.dHat;
fx[\wall] = 94.0;
id = d.probe(94.0);
rec = d.instVarAt(\probes)[id];
~tPut.(l, \reverseFlag, true);
l.changed(\reverse, true);
d.probeReply(id, late.(rec[\time]), rec[\time] + 0.01);
~tEq.("a reply to a probe sent before a reverse is discarded", d.dHat, held);
~tEq.("...no probe while reversed", d.probe(95.0), nil);
~tPut.(l, \reverseFlag, false);
l.changed(\reverse, false);
~tEq.("...nor after it, the phase being shifted for good (that is not drift)", d.probe(96.0), nil);
d.breakEndsAt(95.3021, 95.0);
~tNear.("...and a break then ends on the nearest 16th, not the loop boundary the model would put",
    d.instVarAt(\breakEnd), 95.25, 1e-9);
~tPut.(l, \loopStartTime, 98.0);
fx[\wall] = 98.1;
l.changed(\state, \playing);
~tEq.("a new engine (loopStartTime moved): the estimate from 0", d.dHat, 0);
id = d.probe(98.1);
~tAssert.("...and probes again", id.notNil);
rec = d.instVarAt(\probes)[id];
d.probeReply(id, late.(rec[\time], 98.0), rec[\time] + 0.04);
~tEq.("a reply arriving more than 30 ms after its time is discarded", d.dHat, 0);
id = d.probe(98.2);
rec = d.instVarAt(\probes)[id];
~tPut.(l, \loopStartTime, 100.0);
d.probeReply(id, late.(rec[\time], 98.0), rec[\time] + 0.01);
~tEq.("...and one whose engine changed under it", d.dHat, 0);
~tPut.(l, \state, \stopped);
~tEq.("no probe while the loop is stopped", d.probe(101.0), nil);
}.value;

// ------------------------------------------------------------ the onset sink --
{
var fx = ~dsMake.();
var d = fx[\drums], l = fx[\looper];
var pat = [[0.1, 1.0], [0.6, 0.5], [1.4, 0.1]];
var delta = (0.02 + 0.001) + 0.007;
// After the engine respawns below, the drift estimate starts again from 0.
var delta2 = 0.02 + 0.007;
var hits, n, all, pat2;
~tPut.(l, \onsetNoteRolls, [0.1, 0.2, 0.3]);
~tPut.(l, \onsetNoteOffsetMs, 5);
d.setOffsetMs(7);
d.instVarPut(\dHat, 0.001);
fx[\wall] = 91.0;
d.startOnsets(l, pat, 2.0, 91.0);
~dsRun.(fx, 95.0);
hits = ~dsSounding.(fx[\log]);
~tAssert.("bundles were sent", hits.size > 0);
~tEqArray.("the onset part at base + (m * period) + its time, base = loopStartTime + onsetNoteOffsetMs, stamped + 0.020 + dHat + offset, from the first hit not too late",
    hits.collect(_[\time]).keep(6), [91.405, 92.105, 92.605, 93.405, 94.105, 94.605] + delta, 1e-9);
~tEq.("...at the Looper's velocity for its strength (0.1 -> 69, 1 -> 127, 0.5 -> 110)",
    hits.collect(_[\vel]).keep(3), [69, 127, 110]);
~tEq.("...on the Looper's onset note, through the onset kit's group and bus, its own cancel ring",
    [hits.first[\note], hits.first[\group], hits.first[\out], (hits.first[\ring] >= 2024) and: { hits.first[\ring] < 3048 }],
    [36, 1003, 22, true]);
n = fx[\log].size;
d.startOnsets(l, pat, 2.0, 95.0);
~tPut.(l, \loopStartTime, 94.0);       // an engine respawned two loops on (a chain handoff)
d.startOnsets(l, pat, 2.0, 95.0);
~dsRun.(fx, 96.03);
all = ~dsHits.(fx[\log]);
~tEq.("a restart onto the same grid changes nothing: no cut, nothing sent twice",
    [~dsCancels.(fx[\log].copyToEnd(n)).size, ~dsKeys.(all).asSet.size], [0, all.size]);
pat2 = [[0.3, 1.0]];
d.startOnsets(l, pat2, 2.0, 96.03);
~dsRun.(fx, 99.0);
hits = ~dsSounding.(fx[\log]);
~tAssert.("another take's pattern cuts the old one's hits still to come",
    ~dsHits.(fx[\log]).any { |h| h[\cancelled] and: { (h[\time] - (96.105 + delta2)).abs < 1e-9 } }
        and: { hits.every { |h| (h[\time] - (96.105 + delta2)).abs > 1e-9 } });
~tEqArray.("...and plays its own", hits.select { |h| h[\time] > 96.1 }.collect(_[\time]),
    [96.305, 98.305] + delta2, 1e-9);
l.onsetNoteChance = 0.15;
~tPut.(l, \onsetNoteRolls, [0.1, 0.2, 0.3]);
l.onsetNote = 40;
pat2 = [[0.3, 1.0], [0.9, 1.0], [1.5, 1.0]];
d.startOnsets(l, pat2, 2.0, 99.0);
d.setOn(false, 99.0);
~dsRun.(fx, 101.0);
hits = ~dsSounding.(fx[\log]).select { |h| h[\time] > 99.1 };
~tEqArray.("only the hits the Looper's chance lets through (its rolls under the chance), PC 17 off or not",
    hits.collect(_[\time]), [100.305] + delta2, 1e-9);
~tEq.("...on the onset note read per hit", hits.collect(_[\note]), [40]);
n = fx[\log].size;
d.stopOnsets(l, 101.0);
~dsRun.(fx, 103.0);
~tEq.("stopOnsets: nothing more", ~dsHits.(fx[\log].copyToEnd(n)).size, 0);
d.onsetNoteOn(38, 100, 103.2);
~tEq.("a test note through the port's noteOn sounds on the onset kit at its time",
    ~dsHits.(fx[\log]).last !? { |h| [h[\note], h[\vel], h[\time], h[\group]] }, [38, 100, 103.2, 1003]);
}.value;

// ---------------------------------------------- what reaches the voices --
// On the gap kit: the trims in a sent voice's amp (a steps hit, an onset hit
// and a Beat Repeat repeat), a layer's drive, length and sample start in its
// s_new, the onset kit on its own choke block, and every voice added to the
// tail of its group. Trims are kept per kit key, and both slots play gkit
// here, so they share one table: the onset voice takes the group trim too.
{
var fx = ~dsMakeGap.(), d = fx[\drums], l = fx[\looper], v, steps, onset, rep;
~dsPlain.(d, \main, (3: [0], 0: [6]));
d.setLaneParam(\main, 0, \note, 42);
d.setPadTrim(\steps, 36, -6);
d.setGroupTrim(\steps, \carbon, 3);
l.onsetNote = 38;
d.setPadTrim(\onset, 38, -12);
d.repeatChance = 1;
d.setRepeats(true, 91.0);
~tPut.(l, \onsetNoteRolls, [0.0]);
~dsStart.(fx, 92.0);
d.startOnsets(l, [[0.25, 1.0]], 2.0, 91.9);
~dsRun.(fx, 93.6);
v = ~dsVoicesSounding.(fx[\log]);
steps = v.detect { |x| (x[\note] == 36) and: { x[\group] == 1001 } };
onset = v.detect { |x| x[\group] == 1003 };
rep = v.detect { |x| x[\group] == 1002 };
~tAssert.("bundles were sent", steps.notNil and: { onset.notNil } and: { rep.notNil });
~tNear.("a steps kick at velocity 127: its pad trim and its layer group's trim in its amp",
    steps !? { |x| x[\amp] }, (-6 + 3).dbamp, 1e-9);
~tNear.("...the onset kit's pad trim in the onset voice's", onset !? { |x| x[\amp] }, (3 - 12).dbamp, 1e-9);
~tNear.("...and a repeat's: repeat 1's level times the group trim (the hat's pad has none)",
    rep !? { |x| x[\amp] }, MegaSADrumsFx.beatRepeatLevel(1) * 3.dbamp, 1e-9);
~tEq.("every voice, steps, onset and repeat, added to the tail of its group (addAction 1)",
    [v.collect(_[\addAction]).asSet.asArray, v.collect(_[\group]).asSet.asArray.sort], [[1], [1001, 1002, 1003]]);
}.value;
{
var fx = ~dsMakeGap.(), d = fx[\drums], l = fx[\looper], v, sn, steps, onset;
~dsPlain.(d, \main, (1: [0], 3: [0]));
~tPut.(l, \onsetNoteRolls, [0.0]);
~dsStart.(fx, 92.0);
d.startOnsets(l, [[0.25, 1.0]], 2.0, 91.9);
~dsRun.(fx, 92.6);
v = ~dsVoicesSounding.(fx[\log]);
sn = v.detect { |x| x[\note] == 37 };
steps = v.detect { |x| (x[\note] == 36) and: { x[\group] == 1001 } };
onset = v.detect { |x| (x[\note] == 36) and: { x[\group] == 1003 } };
~tAssert.("bundles were sent", sn.notNil and: { steps.notNil } and: { onset.notNil });
sn !? {
    ~tEqArray.("a layer's drive (the One Hit Kit's Simpler drive), lenSecs and startFrames reach its voice",
        [sn[\drive], sn[\dur], sn[\startFrames]], [6.84, 0.03, 100], 1e-9);
};
~tEq.("a retriggering kick: the steps' on the steps' pad bus, the onset kit's on its own block (never one another's)",
    [steps !? { |x| [x[\chokeBus], x[\chokeOn]] }, onset !? { |x| [x[\chokeBus], x[\chokeOn]] }], [[3048, 1], [3081, 1]]);
}.value;

// --------------------------------------------------- kit slots and buffers --
{
var fx = ~dsMake.();
var d = fx[\drums];
var reads = List.new, states = List.new;
var ctl = SimpleController(d).put(\kitState, { |o, w, slot, st| states.add([slot, st]) });
var cachedNames = { d.bufferCache.keys.collect { |p| PathName(p.asString).fileName }.asArray };
d.kitReader = { |srv, path, done| reads.add([path, done]) };
d.setKit(\steps, \tkit2);
~tEq.("a kit loading: the slot shows it, says so, and the old kit plays on",
    [d.kit(\steps), d.kitState(\steps), d.kitFor(\steps).key], [\tkit2, \loading, \tkit]);
~tEq.("...its files read once each", reads.size, 2);
d.setKit(\steps, \tkit);
~tEq.("switched back: every buffer is cached, so that kit is in at once",
    [d.kit(\steps), d.kitState(\steps), d.kitFor(\steps).key], [\tkit, \ready, \tkit]);
reads.do { |r| ~dsReader.(nil, r[0], r[1]) };
~tEq.("the earlier request completing after: dropped, the later one's kit stays",
    [d.kit(\steps), d.kitState(\steps), d.kitFor(\steps).key], [\tkit, \ready, \tkit]);
~tEq.("...the states as they came", states.asArray, [[\steps, \loading], [\steps, \loading], [\steps, \ready]]);
~tAssert.("its buffers went into the cache", cachedNames.().includesEqual("p60.wav"));
fx[\wall] = 91.5;
d.pump(91.5);
~tAssert.("...and, no kit using them, are freed a second later", cachedNames.().includesEqual("p60.wav").not
    and: { cachedNames.().includesEqual("p36.wav") });
ctl.remove;
// A buffer outlives the last voice that can play it.
d.kitReader = ~dsReader;
d.setKit(\steps, \tkit2);
~dsPlain.(d, \main, (3: [0]));
~dsStart.(fx, 92.0);
~dsRun.(fx, 92.05);
~tAssert.("(a kick of the second kit sent at 92.02)", ~dsHits.(fx[\log]).any { |h| h[\note] == 60 });
d.setKit(\steps, \tkit);
~dsRun.(fx, 93.05);
~tAssert.("a buffer is kept for a second after its last voice can have ended", cachedNames.().includesEqual("p60.wav"));
~dsRun.(fx, 93.1);
~tAssert.("...and freed then (92.02 + its 50 ms + the release + 1 s)", cachedNames.().includesEqual("p60.wav").not);
}.value;

// ------------------------------------------ kit loads that overlap, kitDir --
// Loads whose reads overlap in flight (a pick before the last kit's buffers
// are in, the same kit twice, one kit in both slots from a preset): each file
// is read once, a later load waiting for the read already on its way, and no
// buffer is left on the server that nothing holds. Real Buffers on the stub,
// so a /b_free is a /b_free.
{
var run = { |picks|
    var stub = ~tStubServer.(), wall = 10.0, reads = List.new, made = IdentitySet.new;
    var d = MegaSADrums((server: stub)), freed, held;
    d.prUseBusses;
    d.wallClock = { wall };
    d.sender = { |t, msgs| };
    d.kitDir = ~dsDir +/+ "share";
    d.kitReader = { |srv, path, done| reads.add([path, done]) };
    picks.do { |p| d.setKit(p[0], p[1]) };
    // The server answers every read, in the order they went out.
    reads.do { |r| var b = Buffer.new(stub, 2400, 1); made.add(b.bufnum); r[1].value(b) };
    10.do { wall = wall + 0.5; d.pump(wall) };
    freed = stub[\msgs].select { |m| (m[0] == \b_free) or: { m[0] == "/b_free" } }.collect(_[1]).asSet;
    held = d.bufferCache.values.collect(_.bufnum).asSet;
    (reads: reads.size, leaked: made.reject { |n| freed.includes(n) or: { held.includes(n) } }.size,
        held: held.size, states: [d.kitState(\steps), d.kitState(\onset)], drums: d)
};
var ab = run.([[\steps, \ka], [\steps, \kb]]), twice = run.([[\onset, \kb], [\onset, \kb]]);
var both = run.([[\steps, \kb], [\onset, \kb]]);
~tEq.("a pick before the last one's buffers are in, two files shared: each file read once, no buffer left that nothing holds",
    [ab[\reads], ab[\leaked], ab[\held], ab[\states][0]], [3, 0, 3, \ready]);
~tEq.("...the same kit picked twice in a row", [twice[\reads], twice[\leaked], twice[\states][1]], [3, 0, \ready]);
~tEq.("...one kit in both slots at once (a preset)", [both[\reads], both[\leaked], both[\states]], [3, 0, [\ready, \ready]]);
~tAssert.("...the two slots playing the same buffers", both[\drums].kitFor(\steps).buffers.keys.every { |k|
    both[\drums].kitFor(\steps).buffers[k] === both[\drums].kitFor(\onset).buffers[k] });
[ab, twice, both].do { |r| r[\drums].free };
}.value;
// kitDir moved at runtime (another kits folder) while a kit read from the
// first stays in its slot: its buffers are its own folder's, and stay.
{
var fx = ~dsMake.();
var d = fx[\drums];
var onsetPaths = d.kitFor(\onset).files(d.kitFor(\onset).root).collect(_.asSymbol);
d.kitDir = ~dsDir +/+ "share";
d.setKit(\steps, \ka);
~dsRun.(fx, 95.0, 0.1);
~tEq.("kitDir moved, a kit from the new folder in one slot: the kit from the old one in the other keeps every buffer",
    [d.kitFor(\onset).key, d.kitState(\onset), onsetPaths.size, onsetPaths.count { |p| d.bufferCache[p].notNil }],
    [\tkit, \ready, 16, 16]);
}.value;

// ---------------------------------------------- a Start over a running transport --
// A 7/8 loop (14 16ths) with Auto Retrigger off, so the lanes run on from the
// origin and a new origin shows: the kick plays lane step 0 of 16.
{
var fx = ~dsMake.(90.0, 1.75);
var d = fx[\drums];
var kicks, hats;
~tPut.(fx[\looper], \lastResult, (numerator: 7, denominator: 8, k: 1, bpm: 120, loopDur: 1.75));
// The kick on lane step 0; a hat on step 11 with a 3-hit roll at 1/16t, so the
// old origin's step 27 (95.125) rolls on past the new boundary (95.2083,
// 95.2917, 95.375).
~dsPlain.(d, \main, (3: [0], 0: [11]));
d.setParam(\main, \autoRetrigger, false);
d.setSteps(\main, \roll, 0, Array.fill(16, { |i| if(i == 11) { 3 } { 0 } }));
~dsStart.(fx, 91.75);
~dsRun.(fx, 95.15);
~dsStart.(fx, 95.25);              // the Looper's Start again (an overdub found the meter, say)
~dsRun.(fx, 98.0);
kicks = ~dsGrid.(~dsOf.(~dsSounding.(fx[\log]), 36));
hats = ~dsGrid.(~dsOf.(~dsSounding.(fx[\log]), 42));
~tAssert.("bundles were sent", (kicks.size > 0) and: { hats.size > 0 });
~tEqArray.("a Start over a running transport: the old origin plays up to its boundary, a new one from it",
    kicks, [91.75, 93.75, 95.25, 97.25], 1e-9);
~tAssert.("...the old origin's kick after it (95.75) never sounds", kicks.every { |t| (t - 95.75).abs > 1e-9 });
~tEqArray.("...and its rolls stop at the boundary", hats.select { |t| (t > 95) and: { t < 95.5 } },
    [95.125, 95.125 + (80 * (0.125 / 120))], 1e-9);
~tEq.("...nothing twice", ~dsKeys.(~dsSounding.(fx[\log])).asSet.size, ~dsSounding.(fx[\log]).size);
~tEq.("...and its steps from 0", d.playheadAt(95.25 + 1e-6), (which: \main, n: 0, ls: 0));
}.value;

// ------------------------------------------------------- a reading re-armed --
{
var fx = ~dsMake.();
var d = fx[\drums], l = fx[\looper];
var p1 = (index: 1, result: (numerator: 3, denominator: 4, k: 1, bpm: 90, loopDur: 2.0), at: 94.0, loops: 1, restart: false);
var p2 = (index: 2, result: (numerator: 5, denominator: 4, k: 1, bpm: 150, loopDur: 2.0), at: 94.0, loops: 1, restart: false);
var kicks;
~dsPlain.(d, \main, (3: ~dsEvery));
~dsStart.(fx, 92.0);
~dsRun.(fx, 93.0);
d.readingArmed(p1, 93.0);
d.readingArmed(p2, 93.2);          // pressed again: the reading after it, armed in its place
~dsRun.(fx, 94.0);
~tPut.(l, \readingIndex, 2);
d.readingCleared(94.0);
~dsRun.(fx, 94.5);
kicks = ~dsGrid.(~dsOf.(~dsSounding.(fx[\log]), 36)).select { |t| t >= 94.0 };
~tAssert.("bundles were sent", kicks.size > 0);
~tEqArray.("a reading armed over another replaces it: the grid is the later one's (5/4, 20 16ths)",
    kicks.keep(3), [94.0, 94.1, 94.2], 1e-9);
}.value;

// --------------------------------------------- readings around a Start --
// (a) A reading armed in the last `lead` before a boundary a Start has just
// put an epoch on, landing on it: without a restart the Looper sends no Start
// there, so the epoch itself takes the reading's grid from its start; taken
// back, the epoch has its own again. With a restart the Looper's Start at the
// landing begins it again on the reading's grid. (b) A Start between a
// reading's arm and its landing (an overdub detection's): the new epoch
// carries the landing.
{
var r34 = (numerator: 3, denominator: 4, k: 1, bpm: 90, loopDur: 2.0);
var third = [92.0, 92 + (2 / 12), 92 + (4 / 12), 92.5];
var atStart = { |restart, cancel|
    var fx = ~dsMake.();
    var d = fx[\drums], l = fx[\looper];
    var p = (index: 1, result: r34, at: 92.0, loops: 1, restart: restart);
    ~dsPlain.(d, \main, (3: ~dsEvery));
    ~dsStart.(fx, 92.0);
    ~dsRun.(fx, 91.95);
    d.readingArmed(p, 91.95);
    fx[\kind] = d.instVarAt(\pendingLanding)[\kind];
    if(cancel) {
        ~dsRun.(fx, 91.97);
        d.readingCleared(91.97);
    } {
        ~dsRun.(fx, 91.98);
        // the Looper's landing, 20 ms before the boundary: a Start if it restarts
        if(restart) { d.transportStart(91.98) };
        ~dsRun.(fx, 92.0);
        ~tPut.(l, \readingIndex, 1);
        ~tPut.(l, \lastResult, r34);
        d.setAnalysis(r34, 92.0);
        d.readingCleared(92.0);
    };
    ~dsRun.(fx, 93.0);
    fx[\kicks] = ~dsGrid.(~dsOf.(~dsSounding.(fx[\log]), 36));
    fx
};
var a = atStart.(false, false), ar = atStart.(true, false), ac = atStart.(false, true);
var between = { |restart, cancel|
    var fx = ~dsMake.();
    var d = fx[\drums], l = fx[\looper];
    var p = (index: 1, result: r34, at: 96.0, loops: 1, restart: restart);
    ~dsPlain.(d, \main, (3: ~dsEvery));
    ~dsStart.(fx, 92.0);
    ~dsRun.(fx, 93.0);
    d.readingArmed(p, 93.0);
    ~dsRun.(fx, 93.9);
    d.transportStart(93.9);            // a Start for 94.0
    if(cancel) {
        ~dsRun.(fx, 95.0);
        d.readingCleared(95.0);
        ~dsRun.(fx, 96.0);
    } {
        ~dsRun.(fx, 95.98);
        if(restart) { d.transportStart(95.98) };
        ~dsRun.(fx, 96.0);
        ~tPut.(l, \readingIndex, 1);
        ~tPut.(l, \lastResult, r34);
        d.setAnalysis(r34, 96.0);
        d.readingCleared(96.0);
    };
    ~dsRun.(fx, 97.0);
    fx[\kicks] = ~dsGrid.(~dsOf.(~dsSounding.(fx[\log]), 36));
    fx[\from96] = d.playheadAt(96.0 + 1e-6);
    fx[\epochs] = d.instVarAt(\epochCount);
    fx
};
var b = between.(false, false), br = between.(true, false), bc = between.(false, true);
~tAssert.("bundles were sent", [a, ar, ac, b, br, bc].every { |f| f[\kicks].notEmpty });
~tEq.("a reading landing on the boundary a Start just took: it goes in (a segment)", a[\kind], \segment);
~tEqArray.("...the drums take its grid from that boundary (3/4: 12 16ths in the loop)",
    a[\kicks].select { |t| t >= 92.0 }.keep(4), third, 1e-9);
~tEqArray.("...taken back before it lands, the boundary keeps its own grid",
    ac[\kicks].select { |t| t >= 92.0 }.keep(4), [92.0, 92.125, 92.25, 92.375], 1e-9);
~tEq.("a restart onto that boundary is left to the Looper's Start there", ar[\kind], \none);
~tEqArray.("...which begins it on the reading's grid", ar[\kicks].select { |t| t >= 92.0 }.keep(4), third, 1e-9);
~tEqArray.("a Start between a reading's arm and its landing: the new epoch lands the reading",
    b[\kicks].select { |t| t >= 96.0 }.keep(4), third + 4, 1e-9);
~tEq.("...counting on from that Start's origin (16 steps on at 96.0)", b[\from96] !? { |x| x[\n] }, 16);
~tEq.("...a restart's landing as its own origin, the Looper's Start there a confirmation (no fifth epoch)",
    [br[\from96], br[\epochs]], [(which: \main, n: 0, ls: 0), 4]);
~tEqArray.("...on its grid", br[\kicks].select { |t| t >= 96.0 }.keep(4), third + 4, 1e-9);
~tEqArray.("...and taken back after the Start, the Start's grid plays on",
    bc[\kicks].select { |t| t >= 96.0 }.keep(4), [96.0, 96.125, 96.25, 96.375], 1e-9);
}.value;

// ---------------------------------------------------- the server side --
// build on the stub server: the busses it takes and clears, the tree it
// makes, the responder; free takes it all down.
{
var stub = ~tStubServer.();
var d = MegaSADrums((server: stub));
var group = Group.basicNew(stub, 900);
var msgs, clears, news;
Routine { d.build(group, 16, 18, 20, 22) }.next;
msgs = stub[\msgs];
clears = stub[\bundles].collect { |b| b[1] }.flatten(1).select { |m| m[0] == \c_setn };
~tEq.("build: built", d.built, true);
~tEq.("...two cancel rings of 1024 and two choke blocks of 33 busses, all cleared to 0",
    clears.collect { |m| [m[2], m.copyToEnd(3).every(_ == 0)] }.asArray.sort { |a, b| a[0] <= b[0] },
    [[33, true], [33, true], [1024, true], [1024, true]]);
news = msgs.select { |m| (m[0] == 21) or: { m[0] == "/g_new" } or: { m[0] == \g_new } };
~tEq.("...three voice groups at the tail of the drum group", news.size, 3);
~tAssert.("...the two effects at its tail, from the drum busses to the strips' busses",
    msgs.any { |m| (m.includes(\megaSADrumsFx)) and: { m.includes(16) } and: { m.includes(18) } }
        and: { msgs.any { |m| (m.includes(\megaSAOnsetFx)) and: { m.includes(20) } and: { m.includes(22) } } });
~tAssert.("...and the probe's responder", d.instVarAt(\probeResp).notNil);
// On a stub of its own, never through a nil target: Group.tail(nil) is
// Server.default's, a running megalooper's outside the harness. This one runs
// out of node IDs at its third voice group, part-way through the build.
~tCheck.("a build that fails is posted, not thrown", {
    var failing = ~tStubServer.(), n = 0, bad, before;
    failing[\nextNodeID] = { |self| n = n + 1; if(n > 2) { Error("the stub is out of node IDs").throw }; 4000 + n };
    bad = MegaSADrums((server: failing));
    before = failing[\controlBusAllocator].blocks.size;
    bad.build(Group.basicNew(failing, 3999), 0, 0, 0, 0);
    ~tEq.("...and gives back the busses it took", [bad.built, failing[\controlBusAllocator].blocks.size], [false, before]);
    ~tEq.("...and frees the two voice groups it had made", failing[\msgs].select { |m| m[0] == 11 }.collect(_[1]).sort, [4001, 4002]);
});
// A drum group that is not on the drums' own server, or none at all, is
// refused before anything is taken or sent.
~tCheck.("a drum group on another server, or none, is refused", {
    // (Nothing reaches the default server either: run-tests.scd fails a file
    // that makes a node there.)
    var own = ~tStubServer.(), other = ~tStubServer.(), bad, busses;
    [nil, Group.basicNew(other, 900), 900].do { |g|
        bad = MegaSADrums((server: own));
        busses = own[\controlBusAllocator].blocks.size;
        bad.build(g, 0, 0, 0, 0);
        ~tAssert.("...not built on " ++ g ++ ", nothing sent, no bus taken",
            bad.built.not and: { own[\msgs].isEmpty } and: { own[\bundles].isEmpty } and: { other[\msgs].isEmpty }
                and: { own[\controlBusAllocator].blocks.size == busses },
            [own[\msgs], other[\msgs]].asString);
    };
});
~tAssert.("the test harness's default server is its trap, not one a megalooper may be running",
    (Server.default === ~tTrapServer) and: { Server.default.addr.port == 9 });
d.free;
~tAssert.("free: nodes freed, the responder gone", msgs.count { |m| (m[0] == 11) or: { m[0] == "/n_free" } or: { m[0] == \n_free } } >= 5
    and: { d.instVarAt(\probeResp).isNil });
~tEq.("...and nothing left running", [d.alive, d.built, d.instVarAt(\pumpRoutine)], [false, false, nil]);
}.value;
// The probe's responder: its function reads SendReply's message as scsynth
// sends it, [path, node, replyID, In.kr(phaseBus), id], the values as floats.
// On the rig it is the drift correction's only way in; every other drift test
// calls probeReply directly.
{
var stub = ~tStubServer.();
var l = ~tLooper.(), d, wall = 93.0, id, rec, resp, phase;
~tPut.(l, \state, \playing);
~tPut.(l, \loopFrames, 96000);
~tPut.(l, \loopStartTime, 90.0);
~tPut.(l, \lastResult, (numerator: 4, denominator: 4, k: 1, bpm: 120, loopDur: 2.0));
~tPut.(l, \phaseBus, Bus(\control, 7, 1, stub));
d = MegaSADrums((server: stub));
d.wallClock = { wall };
Routine { d.build(Group.basicNew(stub, 900), 16, 18, 20, 22) }.next;
d.attach(l);
id = d.probe(wall);
rec = id !? { d.instVarAt(\probes)[id] };
resp = d.instVarAt(\probeResp);
~tAssert.("a probe, and its responder", rec.notNil and: { resp.notNil });
rec !? {
    phase = (((rec[\time] - 90.0) - 0.003) % 2.0) - (31.5 / 48000);
    wall = rec[\time] + 0.005;
    resp.func.value(['/megaSADrumsProbe', 1500, -1, phase, id.asFloat], wall, nil, 57110);
    ~tNear.("a reply through the responder moves the estimate (the loop 3 ms late)", d.dHat, 0.00075, 1e-6);
};
d.free;
}.value;

// ---------------------------------------------------------- re-entrancy --
{
var fx = ~dsMake.();
var d = fx[\drums];
var seen = List.new, once = true;
var ctl = SimpleController(d).put(\on, { |o, w, flag| seen.add([flag, d.instVarAt(\busy)]) });
~dsPlain.(d, \main, (3: ~dsEvery));
d.sender = { |t, msgs|
    fx[\log].add([t, msgs, fx[\wall]]);
    // A sender (a dependant, say) that turns the drums off from inside the pump.
    if(once and: { msgs.any { |m| m[0] == \s_new } }) { once = false; d.setOn(false, fx[\wall]) };
};
~dsStart.(fx, 92.0);
~dsRun.(fx, 92.3);
~tAssert.("bundles were sent", fx[\log].size > 0);
~tEq.("a change asked for inside the pump is applied after it, and its notification goes out after",
    seen.asArray, [[false, false]]);
~tEq.("...and it holds: nothing sounds after its edge", ~dsSounding.(fx[\log]).size, 0);
ctl.remove;
}.value;

// ------------------------------------------------------------ the session log --
// What the drums tell the Looper's session recorder (MegaSADrums' Session log
// section): every hit that sounded, once, in a batch a pump, logLag after it
// was heard; and what their transport did, at its heard times. The recorder is
// a fake in the Looper's sessionRec: it keeps each logHits batch with the wall
// it came at, each logEvent as [ev, fields, at, wall], and counts the calls;
// logTime is seconds from its startedAt, as the real one's. What sounded is
// read off the bundles sent (~dsSounding), so "the log holds what sounded" is
// held against what scsynth would have played.
~dsRec = { |fx, startedAt = 91.0, logging = true|
    var rec = (logging: logging, startedAt: startedAt, batches: List.new, events: List.new, calls: 0, evCalls: 0);
    rec[\logHits] = { |self, hits|
        self[\calls] = self[\calls] + 1;
        if(self[\logging] == true) { self[\batches].add([fx[\wall], hits]); true } { false }
    };
    rec[\logEvent] = { |self, ev, fields, at|
        self[\evCalls] = self[\evCalls] + 1;
        if(self[\logging] == true) { self[\events].add([ev, fields, at, fx[\wall]]); true } { false }
    };
    rec[\logTime] = { |self, seconds| seconds !? { |s| s - (self[\startedAt] ? s) } };
    ~tPut.(fx[\looper], \sessionRec, rec);
    rec
};
// Every hit logged, in the order told.
~dsLogged = { |rec| rec[\batches].asArray.collect(_[1]).flatten(1) };
~dsLogKey = { |h| h[\note].asString ++ "@" ++ (h[\at].round(1e-6)).asString };
~dsLogKeys = { |hits| hits.collect(~dsLogKey).asArray.sort };
~dsEv = { |rec, name| rec[\events].asArray.select { |e| e[0] == name } };
~dsGridOf = { |e| [\bpm, \numerator, \denominator, \n16, \loopDur].collect { |k| e[1][k] } };

{
~tEq.("the log tells what was heard 50 ms ago", MegaSADrums.logLag, 0.05);
~tEq.("a condition history's edge in force: its time, inf.neg for the first entry",
    [MegaSADrums.historyEdgeAt([[inf.neg, \main], [10, \break], [12, \main]], 11),
        MegaSADrums.historyEdgeAt([[inf.neg, \main], [10, \break]], 10),
        MegaSADrums.historyEdgeAt([[inf.neg, \main], [10, \break]], 9.5)], [10, 10, inf.neg]);
}.value;

// Steps, a roll and the onset part, recorded from before the Start: the log
// holds exactly what sounded, each hit once, told at the first pump after it
// was heard logLag ago, with its fields. The onset gate is the player's 60 ms,
// not the Looper's 20 ms default, so the gate logged can only be the setting.
{
var fx = ~dsMake.();
var d = fx[\drums], l = fx[\looper];
var rec, logged, heard, steps, rolls, onsets, line = 93.95;
~dsPlain.(d, \main, (0: ~dsEvery, 3: [0, 4, 8, 12]));
d.setSteps(\main, \roll, 0, Array.fill(16, { |i| if(i == 2) { 2 } { 0 } }));
d.setOffsetMs(7);
rec = ~dsRec.(fx, 91.0);
l.onsetNoteGateMs = 60;
~tPut.(l, \onsetNoteRolls, [0.0]);
~dsStart.(fx, 92.0);
d.startOnsets(l, [[0.25, 1.0]], 1.0, 91.9);
~dsRun.(fx, 94.0);
logged = ~dsLogged.(rec);
heard = ~dsSounding.(fx[\log]).select { |h| h[\time] < line };
~tAssert.("bundles were sent, and hits logged", (heard.size > 0) and: { logged.size > 0 });
~tEq.("the log holds exactly the hits that sounded (to logLag ago), each once",
    ~dsLogKeys.(logged), ~dsKeys.(heard));
~tEq.("...none twice", logged.collect(~dsLogKey).asSet.size, logged.size);
~tAssert.("...each told once heard logLag ago, at the first pump after",
    rec[\batches].every { |b| b[1].every { |h|
        (h[\at] < (b[0] - MegaSADrums.logLag)) and: { h[\at] >= (((b[0] - 0.01) - MegaSADrums.logLag) - 1e-9) } } });
~tAssert.("...in one batch a pump, never an empty one, each in time order",
    (rec[\batches].collect(_[0]).asSet.size == rec[\batches].size)
        and: { rec[\batches].every { |b| b[1].notEmpty and: { b[1].collect(_[\at]) == b[1].collect(_[\at]).copy.sort } } });
~tAssert.("...two hits heard together told together (a kick and a hat on one 16th)",
    rec[\batches].any { |b| b[1].size > 1 });
~tEq.("...as many calls as batches", rec[\calls], rec[\batches].size);
steps = logged.select { |h| h[\kind] == \step };
rolls = logged.select { |h| h[\kind] == \roll };
onsets = logged.select { |h| h[\kind] == \onset };
~tAssert.("steps, a roll and onset hits are all in the log",
    steps.notEmpty and: { rolls.notEmpty } and: { onsets.notEmpty } and: { (steps.size + rolls.size + onsets.size) == logged.size });
~tAssert.("a step: the steps' slot, its pattern, lane and note, its velocity and kit, no gate",
    steps.every { |h| (h[\slot] == \steps) and: { h[\which] == \main } and: { h[\kit] == \tkit } and: { h[\vel] == 127 }
        and: { h[\gate].isNil } and: { [[0, 42], [3, 36]].includesEqual([h[\lane], h[\note]]) } });
~tAssert.("a roll hit: kind \\roll, its note's lane and pattern, at its own velocity (0.7 of the note's)",
    rolls.every { |h| (h[\slot] == \steps) and: { h[\lane] == 0 } and: { h[\note] == 42 } and: { h[\which] == \main }
        and: { h[\vel] == 88 } });
~tAssert.("an onset hit: the onset kit's slot, the Looper's note and velocity, its onset gate in seconds (the Looper's 60 ms), no lane",
    onsets.every { |h| (h[\slot] == \onset) and: { h[\note] == 36 } and: { h[\vel] == 127 } and: { h[\kit] == \tkit }
        and: { h[\gate].notNil and: { (h[\gate] - 0.06).abs < 1e-12 } } and: { h[\lane].isNil } and: { h[\which].isNil } },
    onsets.collect(_[\gate]).asArray);
~tAssert.("each at its stamp, the time it is heard: the kicks on the 16ths from 92.0, + 20 ms + the offset",
    steps.select { |h| h[\note] == 36 }.every { |h|
        var k = ((h[\at] - 0.027) - 92.0) / 0.125;
        (k - k.round).abs < 1e-6 });
~tEqArray.("...the onset hits at loopStartTime + 0.25 + m s, + 20 ms + the offset",
    onsets.collect(_[\at]), [92.25, 93.25] + 0.027, 1e-9);
}.value;

// Hits a change took back never reach the log (a break, PC 17, a Stop, a
// reading taken back); a hit taken back and sent again (PC 17 off and on
// inside the lead) sounded once and is logged once. A 50 ms hat delay keeps
// hits in flight across each change.
{
var go = { |what|
    var fx = ~dsMake.(), d = fx[\drums], rec;
    ~dsPlain.(d, \main, (0: ~dsEvery, 3: ~dsEvery));
    ~dsPlain.(d, \break, (1: ~dsEvery));
    d.setLaneParam(\main, 0, \delay, 50);
    rec = ~dsRec.(fx, 91.0);
    ~dsStart.(fx, 92.0);
    ~dsRun.(fx, 92.53);
    switch(what,
        \break, { d.breakOpened(92.53) },
        \pc17, { d.setOn(false, 92.53) },
        \stop, { d.transportStop(92.53) },
        \pc17Back, { d.setOn(false, 92.53); ~dsRun.(fx, 92.55); d.setOn(true, 92.55) }
    );
    ~dsRun.(fx, 93.5);
    (snd: ~dsSounding.(fx[\log]).select { |h| h[\time] < 93.45 }, cut: ~dsHits.(fx[\log]).select(_[\cancelled]),
        logged: ~dsLogged.(rec))
};
var runs = [\break, \pc17, \stop, \pc17Back].collect { |w| [w, go.(w)] };
var back, r;
runs.do { |a|
    ~tAssert.(a[0] ++ ": bundles were sent, and some taken back", a[1][\cut].notEmpty and: { a[1][\snd].notEmpty });
    ~tEq.(a[0] ++ ": the log holds what sounded, no hit taken back", ~dsLogKeys.(a[1][\logged]), ~dsKeys.(a[1][\snd]));
};
r = runs[0][1];
~tAssert.("the break pattern's hits in the log as \\break's", r[\logged].select { |h| h[\note] == 37 }.notEmpty
    and: { r[\logged].select { |h| h[\note] == 37 }.every { |h| (h[\which] == \break) and: { h[\lane] == 1 } } });
r = runs[3][1];
back = ~dsKeys.(r[\cut]).select { |k| ~dsKeys.(r[\snd]).includesEqual(k) };
~tAssert.("PC 17 off and on inside the lead: hits taken back and sent again", back.notEmpty);
~tAssert.("...each logged once, as it sounded", back.every { |k| ~dsLogKeys.(r[\logged]).occurrencesOf(k) == 1 });
}.value;
{
var fx = ~dsMake.(), d = fx[\drums], rec, snd, cut;
var p = (index: 1, result: (numerator: 5, denominator: 4, k: 1, bpm: 150, loopDur: 2.0), at: 94.0, loops: 1,
    restart: false);
~dsPlain.(d, \main, (3: ~dsEvery));
d.setParam(\main, \clockSpeed, 5);
rec = ~dsRec.(fx, 91.0);
~dsStart.(fx, 92.0);
~dsRun.(fx, 93.5);
d.readingArmed(p, 93.5);
~dsRun.(fx, 93.97);
d.readingCleared(93.97);
~dsRun.(fx, 95.0);
snd = ~dsSounding.(fx[\log]).select { |h| h[\time] < 94.95 };
cut = ~dsHits.(fx[\log]).select(_[\cancelled]);
~tAssert.("a reading taken back: its hits past the landing were cancelled", cut.notEmpty and: { snd.notEmpty });
~tEq.("...and the log holds only what sounded", ~dsLogKeys.(~dsLogged.(rec)), ~dsKeys.(snd));
~tEq.("...the transport only its Start: no segment that never came", rec[\events].collect(_[0]).asArray, [\drumsStart]);
}.value;

// A rewind into hits already too close to cancel (a Start that comes late with
// a negative offset does it; here, the most direct way, a reading taken back
// after its landing): the drums decide again from there, and the hit already
// heard is out of their table (too late to cancel, it sounded; its double,
// decided again, is dropped). The log still has it, once: it holds what was
// sent and heard, not what the table remembers.
{
var fx = ~dsMake.(), d = fx[\drums], rec, snd;
var p = (index: 1, result: (numerator: 3, denominator: 4, k: 1, bpm: 90, loopDur: 2.0), at: 94.0, loops: 1,
    restart: false);
~dsPlain.(d, \main, (3: ~dsEvery));
rec = ~dsRec.(fx, 91.0);
~dsStart.(fx, 92.0);
~dsRun.(fx, 93.0);
d.readingArmed(p, 93.0);
~dsRun.(fx, 94.05);
d.readingCleared(94.05);
~tAssert.("(the kick on the landing heard, then gone from the table)", d.decided.every { |r|
    ((r[\grid] - 94.0).abs > 1e-9) or: { r[\emitted] != true } });
~dsRun.(fx, 95.0);
snd = ~dsSounding.(fx[\log]).select { |h| h[\time] < 94.95 };
~tAssert.("bundles were sent, the kick on the landing among them", snd.any { |h| (h[\time] - 94.02).abs < 1e-9 });
~tEq.("a reading taken back late: the log holds what sounded, the kick on the landing once",
    ~dsLogKeys.(~dsLogged.(rec)), ~dsKeys.(snd));
}.value;

// Beat Repeat switched on, on the gap kit (its pads all repeat, every capture
// fires): the repeats that sounded are logged as kind \repeat.
{
var fx = ~dsMakeGap.(), d = fx[\drums], rec, logged, snd, reps;
~dsPlain.(d, \main, (3: [0], 0: [6]));
d.setLaneParam(\main, 0, \note, 42);
d.repeatChance = 1;
d.setRepeats(true, 91.0);
rec = ~dsRec.(fx, 91.0);
~dsStart.(fx, 92.0);
~dsRun.(fx, 93.6);
logged = ~dsLogged.(rec);
snd = ~dsSounding.(fx[\log]).select { |h| h[\time] < 93.55 };
reps = logged.select { |h| h[\kind] == \repeat };
~tAssert.("Beat Repeat on: repeats sounded, and were logged", reps.notEmpty and: { snd.any { |h| h[\group] == 1002 } });
~tEq.("...the log holding every hit that sounded, the repeats with them", ~dsLogKeys.(logged), ~dsKeys.(snd));
~tEq.("...as many repeats as sounded on the repeat group", reps.size, snd.count { |h| h[\group] == 1002 });
~tEq.("...each in the steps' slot, with the lane and pattern of the hat it repeats, and the kit",
    reps.collect { |h| [h[\slot], h[\note], h[\lane], h[\which], h[\kit]] }.asSet.asArray, [[\steps, 42, 0, \main, \gkit]]);
}.value;

// The transport in the log: a Start, a break with its planned end, PC 17 off
// and on, a reading that lands without a restart, one that restarts, a Stop
// and a Start again. Each change told once, at its heard time (grid + 20 ms
// + the offset), logLag after it, the grids with it.
{
var fx = ~dsMake.(), d = fx[\drums], l = fx[\looper], rec, evs, starts, seg, dl = 0.027, want;
var r34 = (numerator: 3, denominator: 4, k: 1, bpm: 90, loopDur: 2.0);
var r78 = (numerator: 7, denominator: 8, k: 1, bpm: 105, loopDur: 2.0);
~dsPlain.(d, \main, (3: ~dsEvery));
~dsPlain.(d, \break, (0: ~dsEvery));
d.setOffsetMs(7);
rec = ~dsRec.(fx, 91.0);
~dsStart.(fx, 92.0);
~dsRun.(fx, 92.53);
d.breakOpened(92.53);
~dsRun.(fx, 92.6);
d.breakEndsAt(94.0021, 92.6);
~dsRun.(fx, 94.0021);
d.breakClosed(94.0021);
~dsRun.(fx, 94.5);
d.setOn(false, 94.5);
~dsRun.(fx, 95.0);
d.setOn(true, 95.0);
d.readingArmed((index: 1, result: r34, at: 96.0, loops: 1, restart: false), 95.0);
~dsRun.(fx, 96.0);
~tPut.(l, \readingIndex, 1);
d.setAnalysis(r34, 96.0);
d.readingCleared(96.0);
~dsRun.(fx, 96.5);
d.readingArmed((index: 2, result: r78, at: 98.0, loops: 1, restart: true), 96.5);
~dsRun.(fx, 98.0);
d.transportStart(98.0);
~tPut.(l, \readingIndex, 2);
d.setAnalysis(r78, 98.0);
d.readingCleared(98.0);
~dsRun.(fx, 99.0);
d.transportStop(99.0);
~dsRun.(fx, 99.6);
~dsStart.(fx, 100.0);
~dsRun.(fx, 100.4);
evs = rec[\events];
want = [[\drumsStart, 92.0], [\breakStart, 92.51], [\breakEnd, 94.0], [\drumsOn, 94.48], [\drumsOn, 94.98],
    [\drumsSegment, 96.0], [\drumsStart, 98.0], [\drumsStop, 98.98], [\drumsStart, 100.0]];
~tEq.("the transport in the log: each change once, in order", evs.collect(_[0]).asArray, want.collect(_[0]));
~tEqArray.("...each at its heard time: its grid time + 20 ms + the offset",
    evs.collect(_[2]).asArray, want.collect { |w| w[1] + dl }, 1e-9);
~tAssert.("...each told logLag after it, at the first pump after",
    evs.notEmpty and: { evs.every { |e| (e[3] >= ((e[2] + MegaSADrums.logLag) - 1e-6))
        and: { e[3] < (((e[2] + MegaSADrums.logLag) + 0.01) + 1e-6) } } });
starts = ~dsEv.(rec, \drumsStart);
~tEqArray.("drumsStart: the grid from the origin (bpm 15 / s16 exactly, the meter, n16, the loop)",
    starts.collect(~dsGridOf), [[120, 4, 4, 16, 2.0], [105, 7, 8, 14, 2.0], [120, 4, 4, 16, 2.0]], 1e-9);
~tEqArray.("...origin: the same moment on the log's axis", starts.collect { |e| e[1][\origin] },
    starts.collect { |e| e[2] - 91.0 }, 1e-9);
~tEqArray.("...the 7/8 restart's tempo the loop's over its 14 16ths, exactly",
    [(starts[1] !? { |e| e[1][\bpm] }) ? -1], [15 / (2.0 / 14)], 0);
seg = ~dsEv.(rec, \drumsSegment);
~tEqArray.("drumsSegment: the landing's grid (3/4: 12 16ths in the loop, 90 BPM), from the landing",
    seg.collect(~dsGridOf) ++ seg.collect { |e| e[1][\origin] }, [[90, 3, 4, 12, 2.0], 96.0 + dl - 91.0], 1e-9);
~tEq.("drumsOn: off, then on", ~dsEv.(rec, \drumsOn).collect { |e| e[1][\on] }.asArray, [false, true]);
~tAssert.("...and no change marked as the state in force", evs.every { |e| e[1][\inForce].isNil });
}.value;
// A second stomp takes the planned end away: one break in the log, to the end
// that came. A restart reading taken back never starts anything.
{
var fx = ~dsMake.(), d = fx[\drums], rec, evs;
~dsPlain.(d, \main, (3: ~dsEvery));
~dsPlain.(d, \break, (0: ~dsEvery));
rec = ~dsRec.(fx, 91.0);
~dsStart.(fx, 92.0);
~dsRun.(fx, 92.5);
d.breakOpened(92.5);
~dsRun.(fx, 92.6);
d.breakEndsAt(94.003, 92.6);
~dsRun.(fx, 93.5);
d.breakOpened(93.5);
~dsRun.(fx, 94.5);
d.breakEndsAt(96.004, 94.5);
~dsRun.(fx, 96.004);
d.breakClosed(96.004);
~dsRun.(fx, 96.5);
evs = rec[\events].reject { |e| e[0] == \drumsStart };
~tEq.("a second stomp that takes the planned end away: one break in the log", evs.collect(_[0]).asArray,
    [\breakStart, \breakEnd]);
~tEqArray.("...from the first stomp, heard, to the end that came (94.0 never told)", evs.collect(_[2]).asArray,
    [92.48, 96.0] + 0.02, 1e-9);
}.value;
{
var fx = ~dsMake.(), d = fx[\drums], rec;
var p = (index: 1, result: (numerator: 7, denominator: 8, k: 1, bpm: 105, loopDur: 2.0), at: 94.0, loops: 1, restart: true);
~dsPlain.(d, \main, (3: ~dsEvery));
rec = ~dsRec.(fx, 91.0);
~dsStart.(fx, 92.0);
~dsRun.(fx, 93.0);
d.readingArmed(p, 93.0);
~dsRun.(fx, 93.96);
d.readingCleared(93.96);
~dsRun.(fx, 95.0);
~tEq.("a restart reading taken back 40 ms before it lands: no drumsStart for it",
    rec[\events].collect(_[0]).asArray, [\drumsStart]);
}.value;

// A recording begun while the drums play, in a break, PC 17 off, after a
// reading landed: the Looper's \sessionRecording brings the state in force at
// once (the segment playing, from its own start, so the set's tempo is in the
// log from the stomp), and nothing heard before the stomp.
{
var fx = ~dsMake.(), d = fx[\drums], l = fx[\looper], rec, evs, first, logged, snd;
var r34 = (numerator: 3, denominator: 4, k: 1, bpm: 90, loopDur: 2.0);
~dsPlain.(d, \main, (3: ~dsEvery));
~dsPlain.(d, \break, (0: ~dsEvery));
rec = ~dsRec.(fx, nil, false);
~dsStart.(fx, 92.0);
~dsRun.(fx, 95.0);
d.readingArmed((index: 1, result: r34, at: 96.0, loops: 1, restart: false), 95.0);
~dsRun.(fx, 96.0);
~tPut.(l, \readingIndex, 1);
d.readingCleared(96.0);
~dsRun.(fx, 96.9);
d.breakOpened(96.9);
d.setOn(false, 97.0);
~dsRun.(fx, 97.3);
~tEq.("a recorder that does not log is told nothing", [rec[\calls], rec[\evCalls]], [0, 0]);
rec[\logging] = true;
rec[\startedAt] = 97.3;
l.changed(\sessionRecording, true);
evs = rec[\events].copy;
~tEq.("a recording begun mid-run is told the state in force at once: the segment playing, the break, PC 17 off",
    evs.collect(_[0]).asArray, [\drumsStart, \breakStart, \drumsOn]);
first = evs.first;
first !? {
    ~tEqArray.("...the segment's grid from its own start (96.0, heard), before the stomp on the log's axis",
        [first[2]] ++ ~dsGridOf.(first) ++ [first[1][\origin]], [96.02, 90, 3, 4, 12, 2.0, 96.02 - 97.3], 1e-9);
    ~tEq.("...marked as the state in force", first[1][\inForce], true);
};
~tEqArray.("...the break and PC 17 from their own edges", evs.copyToEnd(1).collect(_[2]).asArray,
    [96.88, 96.98] + 0.02, 1e-9);
~tEq.("...PC 17 off", evs.last !? { |e| e[1][\on] }, false);
d.setOn(true, 97.5);
~dsRun.(fx, 98.5);
~tEq.("...and from there on the changes only", rec[\events].collect(_[0]).asArray, [\drumsStart, \breakStart, \drumsOn, \drumsOn]);
logged = ~dsLogged.(rec);
snd = ~dsSounding.(fx[\log]).select { |h| h[\time] < 98.45 };
~tAssert.("hits were sent before and after, and logged", snd.any { |h| h[\time] < 97.3 } and: { logged.notEmpty });
~tEq.("...the log's those heard from the stomp on", ~dsLogKeys.(logged), ~dsKeys.(snd.select { |h| h[\time] >= 97.3 }));
}.value;
// A recorder that starts logging with no word from the Looper is heard at the
// next pump: the segment in force, and the hits from the stomp on, a hit
// heard just before it (and told after it) not among them.
{
var fx = ~dsMake.(), d = fx[\drums], rec, snd;
~dsPlain.(d, \main, (3: ~dsEvery));
rec = ~dsRec.(fx, nil, false);
~dsStart.(fx, 92.0);
~dsRun.(fx, 93.3);
rec[\logging] = true;
rec[\startedAt] = 93.3;
~dsRun.(fx, 94.0);
~tEq.("a recording found logging at a pump: the segment in force told", rec[\events].collect(_[0]).asArray, [\drumsStart]);
~tAssert.("...at that first pump, from the epoch's origin", rec[\events].first !? { |e|
    ((e[3] - 93.31).abs < 1e-6) and: { (e[2] - 92.02).abs < 1e-9 } and: { e[1][\inForce] == true } } ? false);
snd = ~dsSounding.(fx[\log]).select { |h| h[\time] < 93.95 };
~tAssert.("(a kick heard at 93.27, told at a pump after the stomp)", snd.any { |h| (h[\time] - 93.27).abs < 1e-9 });
~tEq.("...the hits those heard from the stomp on", ~dsLogKeys.(~dsLogged.(rec)), ~dsKeys.(snd.select { |h| h[\time] >= 93.3 }));
}.value;

// A set that stops keeps its log open until its WAVs end (the recorder's
// tail): the drums go on telling it what they play, as changes — no second
// state in force — for as long as it logs, and then nothing.
{
var fx = ~dsMake.(), d = fx[\drums], l = fx[\looper], rec, before, after, snd;
~dsPlain.(d, \main, (3: ~dsEvery));
~dsPlain.(d, \break, (0: ~dsEvery));
rec = ~dsRec.(fx, 91.0);
~dsStart.(fx, 92.0);
~dsRun.(fx, 93.0);
before = rec[\events].size;
l.changed(\sessionRecording, false);
~dsRun.(fx, 93.04);
d.breakOpened(93.04);
~dsRun.(fx, 93.3);
after = rec[\events].copyToEnd(before);
~tEq.("a set that stops but still logs (its tail) is told the changes, and no state in force again",
    after.collect { |e| [e[0], e[1][\inForce]] }.asArray, [[\breakStart, nil]]);
snd = ~dsSounding.(fx[\log]).select { |h| h[\time] < 93.25 };
~tEq.("...and every hit heard, the last moments too", ~dsLogKeys.(~dsLogged.(rec)), ~dsKeys.(snd));
rec[\logging] = false;
before = [rec[\calls], rec[\evCalls]];
~dsRun.(fx, 93.6);
~tEq.("...then, its log closed, nothing more", [rec[\calls], rec[\evCalls]], before);
}.value;

// No recorder logging, a recording stopped, no Looper: nothing told, and the
// drums play on. A recorder that throws costs them nothing either.
{
var fx = ~dsMake.(), d = fx[\drums], rec, n, lone, w = 10.0, sent = List.new;
~dsPlain.(d, \main, (3: ~dsEvery));
rec = ~dsRec.(fx, 91.0, false);
~dsStart.(fx, 92.0);
~dsRun.(fx, 93.0);
~tAssert.("bundles were sent", ~dsSounding.(fx[\log]).notEmpty);
~tEq.("a recorder that does not log is never called, for hits or the transport", [rec[\calls], rec[\evCalls]], [0, 0]);
rec[\logging] = true;
~dsRun.(fx, 93.5);
~tAssert.("(logging: hits told)", rec[\batches].notEmpty);
rec[\logging] = false;
n = [rec[\calls], rec[\evCalls]];
~dsRun.(fx, 94.0);
~tEq.("...and once it stops, nothing more", [rec[\calls], rec[\evCalls]], n);
rec[\events].clear;
rec[\logging] = true;
~dsRun.(fx, 94.1);
~tEq.("the next recording is told the state in force again, its own first line",
    rec[\events].collect { |e| [e[0], e[1][\inForce]] }.asArray, [[\drumsStart, true]]);
rec[\logging] = false;
~dsRun.(fx, 94.2);
n = [rec[\calls], rec[\evCalls]];
rec[\logging] = true;
d.detach;
~dsRun.(fx, 94.5);
~tEq.("drums let go of the Looper tell its recorder nothing", [rec[\calls], rec[\evCalls]], n);
~tAssert.("...and play on", ~dsSounding.(fx[\log]).any { |h| h[\time] > 94.1 });
lone = MegaSADrums((server: ~tStubServer.()));
lone.prUseBusses;
lone.wallClock = { w };
lone.sender = { |t, msgs| sent.add(t) };
lone.kitDir = ~dsDir;
lone.kitReader = ~dsReader;
lone.setKit(\onset, \tkit);
~tCheck.("drums never attached send and pump, telling no one", {
    lone.onsetNoteOn(36, 100, 10.1);
    lone.pump(10.0);
    w = 10.3;
    lone.pump(10.3);
});
~tEq.("...the hit sent all the same", sent.select(_.notNil).asArray, [10.1]);
lone.free;
}.value;
{
var fx = ~dsMake.(), d = fx[\drums], rec;
~dsPlain.(d, \main, (3: ~dsEvery));
rec = ~dsRec.(fx, 91.0);
rec[\logHits] = { |self, hits| Error("the disk is full").throw };
~dsStart.(fx, 92.0);
~tCheck.("a recorder that throws on every batch", { ~dsRun.(fx, 93.0) });
~tEqArray.("...costs the drums nothing: every 16th still sent", ~dsGrid.(~dsOf.(~dsSounding.(fx[\log]), 36)).keep(9),
    (0..8).collect { |k| 92.0 + (k * 0.125) }, 1e-9);
~tAssert.("...and the transport still told", rec[\events].notEmpty);
}.value;

// ---------------------------------------------- the effects' sleep (CPU) --
// The pump pauses the reverb and the onset chain (n_run 0) once nothing can
// sound through them for fxRest; a hit wakes its slot's synth at once, before
// its voices' bundle, the other sleeping on; a device on the drums' chain
// switched on (stepsHeld) keeps the reverb awake.
{
var fx = ~dsMake.(90.0), d = fx[\drums];
var rev = Synth.basicNew(\megaSADrumsFx, fx[\stub], 901), ons = Synth.basicNew(\megaSAOnsetFx, fx[\stub], 902);
var held = false, n, at, voices, stamp;
// The n_run messages the log holds from entry `from`, as [entry, msg].
var runs = { |from|
    var out = List.new;
    fx[\log].do { |e, i| if(i >= from) { e[1].do { |m| if(m[0] == 12) { out.add([i, m]) } } } };
    out.asArray
};
var voicesFrom = { |from| (fx[\log].copyToEnd(from).detectIndex { |e|
    e[1].any { |m| (m[0] == \s_new) and: { m[1].asString.beginsWith("megaSADrumVoice") } } }) !? { |i| i + from } };
d.instVarPut(\fxSynth, rev);
d.instVarPut(\onsetFxSynth, ons);
d.stepsHeld = { held };
~dsRun.(fx, 90.05);
~tEq.("nothing has sounded: the pump pauses both effects, once each",
    runs.(0).collect(_[1]), [[12, 901, 0], [12, 902, 0]]);
~dsRun.(fx, 91.0);
~tEq.("...and sends nothing more while all stays quiet", runs.(0).size, 2);
n = fx[\log].size;
d.onsetNoteOn(38, 100, 91.3);
~dsRun.(fx, 91.4);
at = runs.(n);
voices = voicesFrom.(n);
~tEq.("an onset hit wakes the onset chain, at once and before its voices' bundle, and the reverb sleeps on",
    [at.collect(_[1]), at.first !? { |x| fx[\log][x[0]][0] }, (at.first !? { |x| voices.notNil and: { x[0] < voices } }) ? false],
    [[[12, 902, 1]], nil, true]);
stamp = voices !? { |i| fx[\log][i][0] } ? 91.3;
n = fx[\log].size;
~dsRun.(fx, stamp + MegaSADrums.fxRest);
~tEq.("...and does not sleep while the hit, and fxRest after it, may still sound", runs.(n), []);
~dsRun.(fx, stamp + MegaSADrums.fxRest + 0.2);
~tEq.("...then it sleeps again", runs.(n).collect(_[1]), [[12, 902, 0]]);
held = true;
n = fx[\log].size;
~dsRun.(fx, fx[\wall] + 0.02);
~tEq.("a device on the drums' chain switched on wakes the reverb within a pump, with no hit",
    runs.(n).collect(_[1]), [[12, 901, 1]]);
~dsRun.(fx, fx[\wall] + 2);
~tEq.("...and keeps it awake", runs.(n).size, 1);
held = false;
~dsRun.(fx, fx[\wall] + 0.02);
~tEq.("...switched off again, the reverb sleeps", runs.(n).collect(_[1]), [[12, 901, 1], [12, 901, 0]]);
~dsPlain.(d, \main, (0: [0]));
n = fx[\log].size;
~dsStart.(fx, 98.0);
~dsRun.(fx, 98.3);
at = runs.(n);
voices = voicesFrom.(n);
~tEq.("a steps hit wakes the reverb, before its voices' bundle, and the onset chain sleeps on",
    [at.collect(_[1]), (at.first !? { |x| voices.notNil and: { x[0] < voices } }) ? false], [[[12, 901, 1]], true]);
}.value;

~dsDropKits.();
[\dsDir, \dsMakeKits, \dsDropKits, \dsReader, \dsMake, \dsMakeGap, \dsEvery, \dsPlain, \dsStart, \dsRun, \dsHits,
    \dsVoices, \dsVoicesSounding, \dsVoiceKey, \dsVoiceKeys, \dsSounding, \dsOf, \dsGrid, \dsKey, \dsKeys,
    \dsCancels, \dsRec, \dsLogged, \dsLogKey, \dsLogKeys, \dsEv, \dsGridOf].do { |k| currentEnvironment.put(k, nil) };
