// Megalooper SA's drum effects (MegaSADrumsFx), Kit-Carbon's Beat Repeat as
// MegaSADrums emulates it, and the drums' presets and Keep: the effects' pure
// arithmetic with numbers, the impulse responses' loading and the reverb's
// swap on the recording stub server, Beat Repeat on the stub with an injected
// wall clock, sender and dice seed (every time explicit, as in
// test-megadrums-sched.scd), and preset files in a temporary folder. What the
// effects do in scsynth is scripts/sa/nrt-drums-fx.scd's.
//
// Every check on what was sent first asserts that something was: an Event
// answers nil to anything it lacks, so a check over an empty log would pass on
// nothing.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megadrums-fx");

// --------------------------------------------------------------- fixture --
// Two kits of the 16 pads 36..51, every file mono at 48 kHz:
//   brkit     Beat Repeat on every pad, the band filter on 36..40; each pad a
//             \carbon layer c<n>.wav (0.5 s), and 36 and 42 a \layer layer
//             l<n>.wav (0.2 s) besides, for the carbon-only rule. Hats 42, 44
//             and 46 choke each other (group 1), every other pad retriggers
//             (chokes itself), as Kit-Carbon's do. The "operator" law at 1,
//             so a voice's amp at velocity 127 is 1.
//   plainkit  the same pads with no Beat Repeat, files p<n>.wav.
// The fake reader numbers a buffer by its file: c42 -> 42, l42 -> 142,
// p42 -> 242. And two impulse-response folders: _ir/ at 48 kHz, and one at
// 44.1 kHz for the resampling path. The folder is this run's own
// (~tTempPath): runs at the same time do not share it.
~bfDir = ~tTempPath.("megadrums-fx");
~bfDir441 = ~bfDir +/+ "at441";
~bfWrite = { |path, frames, rate = 48000, value = 0.1|
    var sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(1).sampleRate_(rate);
    sf.openWrite(path);
    sf.writeData(Signal.fill(frames, { value }));
    sf.close;
};
~bfPad = { |n, layers, repeat|
    var hat = [42, 44, 46].includes(n);
    "\"" ++ n ++ "\": { \"name\": \"Pad " ++ n ++ "\", \"choke\": " ++ (if(hat) { 1 } { 0 })
        ++ ", \"retrigger\": " ++ hat.not ++ ", \"beatRepeat\": " ++ repeat
        ++ ", \"repeatFilter\": " ++ (repeat and: { n <= 40 }) ++ ", \"layers\": [ "
        ++ layers.collect { |gf|
            "{ \"group\": \"" ++ gf[0] ++ "\", \"file\": \"" ++ gf[1]
                ++ "\", \"vel\": { \"law\": \"operator\", \"amount\": 1 } }"
        }.join(", ") ++ " ] }"
};
~bfMakeFiles = {
    var ir = { |dir, rate|
        File.mkdir(dir +/+ "_ir");
        MegaSADrumsFx.irKeys.do { |k| ~bfWrite.(dir +/+ "_ir" +/+ (k ++ ".wav"), 2000, rate, 0.01) };
        File.use(dir +/+ "_ir" +/+ "ir.json", "w", { |f|
            f.write("{ \"version\": 1, \"rate\": " ++ rate ++ ", \"files\": { "
                ++ MegaSADrumsFx.irKeys.collect { |k| "\"" ++ k ++ "\": \"_ir/" ++ k ++ ".wav\"" }.join(", ") ++ " } }")
        });
    };
    File.mkdir(~bfDir +/+ "f");
    (36..51).do { |n|
        ~bfWrite.(~bfDir +/+ "f" +/+ ("c" ++ n ++ ".wav"), 24000);
        ~bfWrite.(~bfDir +/+ "f" +/+ ("p" ++ n ++ ".wav"), 24000);
    };
    [36, 42].do { |n| ~bfWrite.(~bfDir +/+ "f" +/+ ("l" ++ n ++ ".wav"), 9600) };
    File.use(~bfDir +/+ "brkit.json", "w", { |f|
        f.write("{ \"version\": 1, \"key\": \"brkit\", \"name\": \"Repeat kit\", "
            ++ "\"groups\": { \"carbon\": \"Carbon\", \"layer\": \"Layer\" }, \"pads\": { "
            ++ (36..51).collect { |n|
                ~bfPad.(n, [["carbon", "f/c" ++ n ++ ".wav"]] ++ (if([36, 42].includes(n)) { [["layer", "f/l" ++ n ++ ".wav"]] } { [] }), true)
            }.join(", ") ++ " } }")
    });
    File.use(~bfDir +/+ "plainkit.json", "w", { |f|
        f.write("{ \"version\": 1, \"key\": \"plainkit\", \"name\": \"Plain\", \"groups\": { \"kit\": \"Kit\" }, \"pads\": { "
            ++ (36..51).collect { |n| ~bfPad.(n, [["kit", "f/p" ++ n ++ ".wav"]], false) }.join(", ") ++ " } }")
    });
    ir.(~bfDir, 48000);
    File.mkdir(~bfDir441);
    ir.(~bfDir441, 44100);
};
~bfDropFiles = {
    var rm = { |dir|
        (dir +/+ "*").pathMatch.do { |p| if(p.last == $/) { rm.(p.drop(-1)) } { File.delete(p) } };
        File.delete(dir);
    };
    rm.(~bfDir);
};
~bfReader = { |srv, path, done|
    var name = PathName(path).fileNameWithoutExtension;
    var base = (c: 0, l: 100, p: 200)[name[0].asSymbol] ? 300;
    done.((bufnum: base + name.drop(1).asInteger, path: path, numChannels: 1, sampleRate: 48000, numFrames: 24000));
};
// Real Buffers on the stub for the impulse responses (their numFrames is what
// PartConv.calcBufSize reads), and the paths asked for.
~bfIrReads = List.new;
~bfIrReader = { |srv, path, done|
    ~bfIrReads.add(path);
    done.(Buffer.alloc(srv, 2000, 1));
};
// A drums object on the stub, attached to a stub Looper playing a 2 s loop
// from lam (a bar of 4/4 at 120 BPM: a 16th is 0.125 s), both slots on `kit`,
// every bundle logged as [time (nil: at once), msgs, wall]. Beat Repeat's
// switch, off in a new drums object, is on here unless `repeatsOn` is false.
~bfMake = { |lam = 90.0, loopDur = 2.0, kit = \brkit, result, repeatsOn = true|
    var fx = (log: List.new, wall: lam);
    var stub = ~tStubServer.();
    var l = ~tLooper.();
    var d;
    ~tPut.(l, \state, \playing);
    ~tPut.(l, \loopFrames, (loopDur * 48000).round.asInteger);
    ~tPut.(l, \loopStartTime, lam);
    ~tPut.(l, \lastResult, result ?? { (numerator: 4, denominator: 4, k: 1, bpm: 120, loopDur: loopDur) });
    ~tPut.(l, \phaseBus, Bus(\control, 7, 1, stub));
    d = MegaSADrums((server: stub));
    d.prUseBusses;
    d.wallClock = { fx[\wall] };
    d.sender = { |t, msgs| fx[\log].add([t, msgs, fx[\wall]]) };
    d.randSeed = 1234;
    d.kitDir = ~bfDir;
    d.kitReader = ~bfReader;
    d.setKit(\steps, kit);
    d.setKit(\onset, kit);
    if(repeatsOn) { d.setRepeats(true, lam - 1) };
    d.attach(l);
    fx[\stub] = stub;
    fx[\looper] = l;
    fx[\drums] = d;
    fx
};
// A pattern made plain: every lane silent but those given, lane ->
// (note:, steps: [...], delay: ms), at chance 6, velocity 127, no alternates,
// no rolls.
~bfPattern = { |d, which, lanes|
    4.do { |lane|
        var spec = lanes[lane];
        var on = (spec !? { |s| s[\steps] }) ? [];
        d.setSteps(which, \chance, lane, Array.fill(16, { |i| if(on.includes(i)) { 6 } { 0 } }));
        d.setSteps(which, \alt, lane, Array.fill(16, 0));
        d.setSteps(which, \velo, lane, Array.fill(16, 6));
        d.setSteps(which, \roll, lane, Array.fill(16, 0));
        d.setLaneParam(which, lane, \delay, (spec !? { |s| s[\delay] }) ? 0);
        spec !? { |s| s[\note] !? { |n| d.setLaneParam(which, lane, \note, n) } };
    };
};
~bfStart = { |fx, b|
    fx[\wall] = b - 0.1;
    fx[\drums].transportStart(b - 0.1);
};
~bfRun = { |fx, to, step = 0.01|
    var w = fx[\wall];
    while { w < (to - 1e-9) } {
        w = (w + step).min(to);
        fx[\wall] = w;
        fx[\drums].pump(w);
    };
};
// Every voice a log sent, in order: its s_new controls as an Event, plus
// (time:, def:, group:, cancelled:, wall:). A /c_set of a cancel bus to 1
// cancels the voices of the hit that last took that bus.
~bfVoices = { |log|
    var out = List.new, onBus = IdentityDictionary.new;
    log.do { |b|
        b[1].do { |m|
            var a, v;
            if(m[0] == \c_set) {
                m.copyToEnd(1).pairsDo { |bus, val| if(val == 1) { (onBus[bus] ? []).do { |x| x[\cancelled] = true } } };
            };
            if((m[0] == \s_new) and: { m[1].asString.beginsWith("megaSADrumVoice") }) {
                a = ().putPairs(m.copyToEnd(5));
                v = a.copy.putAll((time: b[0], def: m[1], group: m[4], addAction: m[3], cancelled: false, wall: b[2]));
                out.add(v);
                if(onBus[a[\cancelBus]].isNil or: { onBus[a[\cancelBus]][0][\hitId] != a[\hitId] }) {
                    onBus.put(a[\cancelBus], List.new);
                };
                onBus[a[\cancelBus]].add(v);
            };
        };
    };
    out
};
~bfRepeats = { |log| ~bfVoices.(log).select { |v| v[\group] == 1002 } };
// A message's command, however it was spelled (\b_free, "/b_alloc", ...).
~bfIs = { |m, name| [name.asString, "/" ++ name].includesEqual(m[0].asString) };
~bfSounding = { |voices| voices.reject { |v| v[\cancelled] } };
~bfKey = { |v| [v[\buf], v[\time].round(1e-6), v[\startFrames].round(1e-3), v[\dur].round(1e-6)] };
~bfKeys = { |voices| voices.collect(~bfKey).asArray.sort { |a, b| a.asString < b.asString } };

~bfMakeFiles.();

// ------------------------------------------------------- the reverb's sums --
{
var c = MegaSADrumsFx;
~tEq.("the wet's own delay: 10 ms less PartConv's latency, 32 samples at 48 kHz / 64",
    [c.wetDelaySamples(48000, 64), c.wetDelaySamples(96000, 64), c.wetDelaySamples(48000, 128)], [32, 512, 96]);
~tEq.("...negative at 44.1 kHz (PartConv alone is later; the graph adds nothing then)",
    c.wetDelaySamples(44100, 64), -7);
~tEq.("...so PartConv's latency at fft 1024 (512 - 64) and it make the 480 samples of the predelay",
    ((c.fftSize / 2) - 64) + c.wetDelaySamples(48000, 64), (0.010 * 48000).round);
~tEq.("the four responses in order: in L to out L, L to R, R to L, R to R", c.irKeys, [\ll, \lr, \rl, \rr]);
~tEq.("the low cut on the wet", c.lowCut, 80);
}.value;

// ------------------------------------------------- the onset chain's sums --
{
var c = MegaSADrumsFx;
var comp = c.onsetComp, red, lift, ceiling = (-0.3).dbamp, knee = (-3.3).dbamp, xs, ys;
var full = [0.7, -0.31, 0.123456789, 1.5e-7], low = [0.3, 0.2, -0.05, 1e-8], high = [0.1, -0.4, 0.07, 3e-9];
~tNear.("the knee: nothing below it", c.kneeCurve(-3.5, 6), 0, 1e-12);
~tNear.("...a quadratic through it: (over + knee / 2) ** 2 / (2 * knee)", c.kneeCurve(-1.25, 6), (1.75 ** 2) / 12, 1e-12);
~tNear.("...at the threshold, knee / 8", c.kneeCurve(0, 6), 0.75, 1e-12);
~tNear.("...the level itself above it", c.kneeCurve(6.75, 6), 6.75, 1e-12);
~tNear.("...continuous at its top", c.kneeCurve(3, 6), 3, 1e-12);
red = (1 - (1 / 4.06));
~tNear.("the gain computer: at the threshold (-16.75 dB) the knee takes 0.565 dB",
    c.compGainDb(-16.75, -16.75, 4.06, 6), 0.75.neg * red, 1e-12);
~tNear.("...6.75 dB over it, 6.75 * (1 - 1 / 4.06)", c.compGainDb(-10, -16.75, 4.06, 6), 6.75.neg * red, 1e-12);
~tNear.("...1.25 dB under it, still a little (inside the 6 dB knee)", c.compGainDb(-18, -16.75, 4.06, 6),
    ((1.75 ** 2) / 12).neg * red, 1e-12);
~tNear.("...well under it, only the makeup and output", c.compGainDb(-30, -16.75, 4.06, 6, 12.6, 0.99), 13.59, 1e-12);
~tNear.("the makeup: 16.75 * (1 - 1 / 4.06) = +12.62 dB", c.makeupDb(comp[\thresholdDb], comp[\ratio]), 16.75 * red, 1e-12);
lift = ((1 - comp[\mix]) + (comp[\mix] * (c.makeupDb(comp[\thresholdDb], comp[\ratio]) + comp[\outputDb]).dbamp)).ampdb;
~tNear.("...so at 22 % the parallel path lifts what is under the knee by about 5 dB", lift, 5.26, 0.02);
~tAssert.("the EQ's bands at 0 dB give the signal back to the bit",
    full.every { |x, i| c.eqThreeMix(x, low[i], high[i], 1, 1, 1) == x });
~tAssert.("...and with gains they are low, middle (full - low - high) and high, each at its own",
    full.every { |x, i|
        var want = (low[i] * 1.84.dbamp) + ((x - low[i] - high[i]) * 0.7) + (high[i] * 2.54.dbamp);
        (c.eqThreeMix(x, low[i], high[i], 1.84.dbamp, 0.7, 2.54.dbamp) - want).abs < 1e-12
    });
~tEq.("the set's EQ Three, Squash and Limiter", [c.onsetEq[\lowDb], c.onsetEq[\highDb], c.onsetEq[\lowFreq],
    c.onsetEq[\highFreq], c.onsetSquash[\thresholdDb], c.onsetSquash[\ratio], c.onsetLimit[\ceilingDb]],
    [1.84, 2.54, 250, 2500, -3.54, 2.313, -0.3]);
xs = [0, 0.1, -0.3, 0.68, knee - 1e-9];
~tAssert.("the soft clip: exact up to its knee", xs.every { |x| c.softClip(x, ceiling, knee) == x });
ys = [knee + 1e-6, 0.75, 0.8, 0.9, 1, 1.2];
~tAssert.("...above it rising, under the ceiling (-0.3 dBFS)", ys.every { |x|
    var y = c.softClip(x, ceiling, knee);
    (y < ceiling) and: { y > knee } } and: { ys.drop(-1).every { |x, i|
        c.softClip(ys[i + 1], ceiling, knee) > c.softClip(x, ceiling, knee) } });
~tAssert.("...and never over it, however loud", [2, 100, 1e6, 1e30].every { |x| c.softClip(x, ceiling, knee) <= ceiling });
~tNear.("...with slope 1 at the knee (no corner)", (c.softClip(knee + 1e-7, ceiling, knee) - knee) / 1e-7, 1, 1e-4);
~tEq.("...the same for negative values", c.softClip(-2, ceiling, knee), c.softClip(2, ceiling, knee).neg);
~tAssert.("...so full scale through the last stage (+1.1 dB) stays under 0 dBFS",
    c.softClip(1.1.dbamp, ceiling, knee) < 1);
}.value;

// --------------------------------------------- resampling (another rate) --
{
var c = MegaSADrumsFx;
var dc = FloatArray.fill(480, 1), sine, out, want, ok;
out = c.resample(dc, 48000, 44100);
~tEq.("resampling: round(n * to / from) samples", out.size, (480 * 44100 / 48000).round.asInteger);
~tAssert.("...a constant stays constant (each output's weights sum to 1)",
    out.copyRange(20, out.size - 21).every { |x| (x - 1).abs < 1e-6 });
sine = FloatArray.fill(4800, { |i| sin((2pi * 1000) * (i / 48000)) });
out = c.resample(sine, 48000, 44100);
ok = (40 .. (out.size - 41)).every { |j| (out[j] - sin((2pi * 1000) * (j / 44100))).abs < 2e-3 };
~tAssert.("...a 1 kHz sine is a 1 kHz sine at the new rate", ok);
out = c.resample(sine, 44100, 48000);
~tEq.("...upwards too", out.size, (4800 * 48000 / 44100).round.asInteger);
~tNear.("an impulse response is scaled by from / to, so it filters as it did",
    c.resampleIR(dc, 48000, 44100)[100], 48000 / 44100, 1e-5);
}.value;

// --------------------------------------------------------------- Beat Repeat's laws --
{
var c = MegaSADrumsFx;
var times = c.beatRepeatTimes(0.125), lens;
~tEq.("5 repeats after the slice (gate 6/16 over grid 1/16, less the slice)", c.beatRepeatCount, 5);
~tEqArray.("their levels: exp(-10 * 0.29365 ** 2 * k / 4), about -1.9 dB a repeat",
    (1..5).collect { |k| c.beatRepeatLevel(k).ampdb }, [-1.8725, -3.7449, -5.6174, -7.4899, -9.3623], 1e-4);
~tEqArray.("their rates: -1 st, then a factor of 1 - 0.1 * 0.11905 each",
    (1..5).collect { |k| c.beatRepeatRate(k).ratiomidi }, [-1.2073, -1.4147, -1.6220, -1.8294, -2.0367], 1e-4);
~tNear.("...repeat 1's rate", c.beatRepeatRate(1), (2 ** (-1 / 12)) * 0.988095, 1e-9);
~tEq.("when they play for a 16th of 0.125 s: five", times.size, 5);
~tNear.("...the first right after the slice", times[0][0], 0.125, 1e-12);
~tAssert.("...each grid / rate long and contiguous", (0..3).every { |i|
    ((times[i + 1][0] - (times[i][0] + times[i][1])).abs < 1e-12)
        and: { (times[i][1] - (0.125 / c.beatRepeatRate(i + 1))).abs < 1e-12 } });
~tNear.("...the fifth cut at the gate, 6/16 after the capture", times[4][0] + times[4][1], 0.75, 1e-12);
~tAssert.("...which it would otherwise run past", (times[4][0] + (0.125 / c.beatRepeatRate(5))) > 0.75);
~tEq.("capture points: 6/16 into every 2 bars of 4 quarters (720 + 3840 c ticks)",
    [c.captureTick(0), c.captureTick(1), c.captureTick(7)], [720, 4560, 27600]);
~tEq.("...and the first at or after a tick", [c.captureIndexAt(0), c.captureIndexAt(720), c.captureIndexAt(721),
    c.captureIndexAt(4560), c.captureIndexAt(-500)], [0, 0, 1, 1, 0]);
~tNear.("the chance: the set's 30/127", c.beatRepeatChance, 30 / 127, 1e-8);
~tEqArray.("the band filter: 1515 Hz, 2.625 octaves read as edges at about 610 Hz and 3.76 kHz",
    c.bandEdges(c.beatRepeatFilterFreq, c.bandRq(c.beatRepeatFilterWidth)), [610.05, 3763.28], 0.01);
~tNear.("...the edges' ratio is the width", (c.bandEdges(1000, c.bandRq(2.625)).reverse.reduce('/')).log2, 2.625, 1e-9);
~tNear.("...their geometric mean the centre", c.bandEdges(1515.18, 2.0814).product.sqrt, 1515.18, 1e-6);
~tEq.("the layers repeated: the pads' own chains", MegaSADrums.repeatGroup, \carbon);
}.value;

// -------------------------------------------------------------- SynthDefs --
{
var names = { |name| SynthDescLib.global[name] !? { |d| d.controlNames.collect(_.asSymbol) } };
~tCheck.("MegaSADrums.loadSynthDefs builds the effects too, with no server", { MegaSADrums.loadSynthDefs });
~tEq.("the drums' reverb: in, out, mix, irOn and its four spectra", names.(\megaSADrumsFx),
    [\in, \out, \mix, \irOn, \ll, \lr, \rl, \rr]);
~tNear.("...mix at Live's 15.08 %", SynthDescLib.global[\megaSADrumsFx] !? { |d|
    d.controls.detect { |c| c.name.asSymbol == \mix } !? { |c| c.defaultValue } }, 0.1508, 1e-6);
~tEq.("...off by default (exactly dry until it has its spectra)", SynthDescLib.global[\megaSADrumsFx] !? { |d|
    d.controls.detect { |c| c.name.asSymbol == \irOn } !? { |c| c.defaultValue } }, 0);
~tEq.("the onset kit's chain: in and out, as the stand-in had", names.(\megaSAOnsetFx), [\in, \out]);
~tEq.("the voices keep their controls (the band filter's too)", names.(\megaSADrumVoice1),
    [\out, \buf, \amp, \rate, \pan, \startFrames, \dur, \drive, \cancelBus, \chokeBus, \chokeOn,
        \hitId, \release, \bpOn, \bpFreq, \bpRq, \gateLen]);
}.value;

// ------------------------------------------------- the impulse responses --
{
var stub = ~tStubServer.();
var warnings = List.new;
var info = MegaSADrumsFx.irInfo(~bfDir, warnings);
var got, gens, allocs, said;
~tAssert.("irInfo: ir.json's four files, absolute", info.notNil and: { info[\files].size == 4 }
    and: { info[\files].every { |p| (p[0] == $/) and: { File.exists(p) } } }, warnings);
~tEq.("...in irKeys order", info !? { |i| i[\files].collect { |p| PathName(p).fileNameWithoutExtension.asSymbol } },
    [\ll, \lr, \rl, \rr]);
warnings = List.new;
~tEq.("...nil for a folder with none, saying why", [MegaSADrumsFx.irInfo(~bfDir +/+ "f", warnings), warnings.size],
    [nil, 1]);
File.mkdir(~bfDir +/+ "v2" +/+ "_ir");
File.use(~bfDir +/+ "v2" +/+ "_ir" +/+ "ir.json", "w", { |f| f.write("{ \"version\": 2, \"files\": {} }") });
warnings = List.new;
~tAssert.("...and for a newer ir.json than this build reads", MegaSADrumsFx.irInfo(~bfDir +/+ "v2", warnings).isNil
    and: { warnings.any { |w| w.contains("newer") } }, warnings.asArray);
~bfIrReads = List.new;
Routine { MegaSADrumsFx.loadIR(stub, ~bfDir, { |specs| got = specs }, ~bfIrReader) }.next;
allocs = stub[\msgs].select { |m| ~bfIs.(m, \b_alloc) and: { m[2] != 2000 } };
gens = stub[\msgs].select { |m| ~bfIs.(m, \b_gen) };
~tAssert.("messages were sent", stub[\msgs].size > 0);
~tEq.("loadIR: the four files, each read as it is (48 kHz)", ~bfIrReads.collect { |p| PathName(p).fileName }.asArray,
    ["ll.wav", "lr.wav", "rl.wav", "rr.wav"]);
~tEq.("...four spectra sized by PartConv.calcBufSize at 1024 (2000 frames: 4 partitions of 512)",
    allocs.collect { |m| m[2] }.asArray, [4096, 4096, 4096, 4096]);
~tEq.("...each prepared from its own response at 1024", gens.collect { |m| [m[2].asString, m[4]] }.asArray,
    Array.fill(4, ["PreparePartConv", 1024]));
~tAssert.("...in the order of the responses read", got.notNil and: {
    gens.every { |m, i| m[1] == got[i].bufnum } });
~tEq.("...the action gets the four spectra", got !? { |g| [g.size, g.every { |b| b.isKindOf(Buffer) }] }, [4, true]);
~tAssert.("...and the responses read are freed once prepared", stub[\msgs].count { |m| ~bfIs.(m, \b_free) } >= 4);
// At another rate: resampled in the language, through temporary files.
stub = ~tStubServer.();
got = 0;
~bfIrReads = List.new;
Routine { MegaSADrumsFx.loadIR(stub, ~bfDir441, { |specs| got = specs }, ~bfIrReader) }.next;
~tAssert.("a 44.1 kHz response on a 48 kHz server: resampled, read from a temporary file, and in",
    (got.size == 4) and: { ~bfIrReads.every { |p| PathName(p).fileName.beginsWith("megasa-ir-") } });
~tAssert.("...whose temporary files are gone afterwards", ~bfIrReads.every { |p| File.exists(p).not });
// No responses: the action hears nil.
got = 0;
Routine { MegaSADrumsFx.loadIR(~tStubServer.(), ~bfDir +/+ "f", { |specs| got = specs }, ~bfIrReader) }.next;
~tEq.("no ir.json: the action hears nil (the drums play dry)", got, nil);
got = 0;
Routine { MegaSADrumsFx.loadIR(~tStubServer.(), ~bfDir, { |specs| got = specs }, { |srv, path, done| done.(nil) }) }.next;
~tEq.("...nor when the server reads none", got, nil);
}.value;

// ------------------------------------------- the reverb on the server side --
// build on the stub: the steps' effects start dry (irOn 0) on a zero spectrum
// allocated before them; reloadReverb replaces them in place with a synth on
// the four spectra; free takes the synths before their buffers.
{
var stub = ~tStubServer.();
var d = MegaSADrums((server: stub));
var group = Group.basicNew(stub, 900);
var states = List.new;
var ctl = SimpleController(d).put(\reverb, { |o, w, st| states.add(st) });
var msgs, fxNew, dummyAlloc, replace, args, first, specs, freesAt, frees, nfree, specNums, lastReplace;
d.kitDir = ~bfDir;
Routine { d.build(group, 16, 18, 20, 22) }.next;
msgs = stub[\msgs];
~tAssert.("messages were sent", msgs.size > 0);
dummyAlloc = msgs.detectIndex { |m| ~bfIs.(m, \b_alloc) and: { m[2] == 1024 } };
fxNew = msgs.detectIndex { |m| (m[0] == 9) and: { m[1] == \megaSADrumsFx } };
~tAssert.("build: the zero spectrum is allocated before the effects start", dummyAlloc.notNil and: { fxNew.notNil }
    and: { dummyAlloc < fxNew });
args = fxNew !? { |i| ().putPairs(msgs[i].copyToEnd(5)) };
~tEq.("...which start dry (irOn 0) on it, all four, with Live's mix", args !? { |a|
    [a[\irOn], a[\ll], a[\lr], a[\rl], a[\rr], a[\mix].round(1e-6), a[\in], a[\out]] },
    [0] ++ Array.fill(4, dummyAlloc !? { |i| msgs[i][1] }) ++ [0.1508, 16, 18]);
~tEq.("...and say so", [d.reverbState, d.irBuffers], [\dry, nil]);
~tEq.("...on a stub, build reads no responses itself", d.autoIR, false);
d.irReader = ~bfIrReader;
first = d.fxSynth;
Routine { d.reloadReverb(true) }.next;
replace = msgs.detect { |m| (m[0] == 9) and: { m[1] == \megaSADrumsFx } and: { m[3] == 4 } };
~tAssert.("reloadReverb: the effects synth REPLACED in place (s_new, addAction 4, the old node)",
    replace.notNil and: { replace[4] == first.nodeID } and: { d.fxSynth !== first });
args = replace !? { |m| ().putPairs(m.copyToEnd(5)) };
specs = d.irBuffers;
specNums = specs !? { |s| s.collect(_.bufnum) };
~tEq.("...on the four spectra, reverb on", args !? { |a| [a[\irOn], [a[\ll], a[\lr], a[\rl], a[\rr]]] },
    [1, specNums]);
~tEq.("...the states as it went", [states.asArray, d.reverbState], [[\dry, \loading, \ready], \ready]);
d.setReverbMix(0.4);
~tAssert.("the reverb's mix goes to the new synth", msgs.last == [15, d.fxSynth.nodeID, \mix, 0.4]);
Routine { d.reloadReverb(true) }.next;
lastReplace = msgs.indexOf(msgs.select { |m| (m[0] == 9) and: { m[1] == \megaSADrumsFx } and: { m[3] == 4 } }.last);
freesAt = msgs.detectIndex { |m| ~bfIs.(m, \b_free) and: { m[1] == (specNums !? { |n| n[0] }) } };
~tAssert.("a second load: the old spectra freed only after the synth that read them was replaced",
    freesAt.notNil and: { lastReplace.notNil } and: { freesAt > lastReplace }
        and: { d.irBuffers.collect(_.bufnum) != specNums });
nfree = msgs.size;
specs = d.irBuffers.collect(_.bufnum);
d.free;
frees = msgs.copyToEnd(nfree);
~tAssert.("free: the synths first, then their spectra and the zero one",
    (frees.detectIndex { |m| m[0] == 11 } ? 999) < (frees.detectIndex { |m| ~bfIs.(m, \b_free) and: { specs.includes(m[1]) } } ? -1)
        and: { frees.count { |m| ~bfIs.(m, \b_free) } >= 5 });
~tEq.("...and the state is back to none", d.reverbState, \none);
ctl.remove;
}.value;

// ------------------------------------------------- Beat Repeat: the grid --
// The capture points from the transport's origin: in 4/4 every 4 s here, each
// on lane step 6; in 7/8 the patterns' resyncs walk them over lane steps 6,
// 6, 14, 14, 6, 6, 14, 6, 6, 14 (the research's table).
{
var go = { |b, loopDur, result, seconds|
    var fx = ~bfMake.(90.0, loopDur, \brkit, result);
    var d = fx[\drums], seen = IdentitySet.new, out = List.new, w;
    d.repeatChance = 0;
    ~bfPattern.(d, \main, (0: (note: 42, steps: [0])));
    ~bfStart.(fx, b);
    w = fx[\wall];
    while { w < (b + seconds) } {
        w = w + 0.02;
        fx[\wall] = w;
        d.pump(w);
        d.captures.do { |cap|
            if(seen.includes(cap).not) { seen.add(cap); out.add([cap, d.playheadAt(cap[\tc] + 1e-6)]) };
        };
    };
    out
};
var c44 = go.(92.0, 2.0, nil, 41), c78 = go.(91.75, 1.75, (numerator: 7, denominator: 8, k: 1, bpm: 120, loopDur: 1.75), 41);
~tAssert.("captures were decided", (c44.size >= 10) and: { c78.size >= 10 });
~tEqArray.("4/4: a capture 6/16 into every 2 bars (8 quarter notes, 4 s at 120 BPM)",
    c44.keep(10).collect { |x| x[0][\tc] - 92.0 }, (0..9).collect { |c| 0.75 + (4 * c) }, 1e-9);
~tEq.("...each on lane step 6", c44.keep(10).collect { |x| x[1] !? { |p| p[\ls] % 16 } }.asArray, Array.fill(10, 6));
~tEqArray.("...its slice a 16th, its gate 6/16", [c44[0][0][\sliceEnd] - c44[0][0][\tc], c44[0][0][\gateEnd] - c44[0][0][\tc]],
    [0.125, 0.75], 1e-9);
~tEqArray.("7/8: the same quarter-note grid, from its origin", c78.keep(10).collect { |x| x[0][\tc] - 91.75 },
    (0..9).collect { |c| 0.75 + (4 * c) }, 1e-9);
~tEq.("...on lane steps 6, 6, 14, 14, 6, 6, 14, 6, 6, 14 (the resyncs)",
    c78.keep(10).collect { |x| x[1] !? { |p| p[\ls] % 16 } }.asArray, [6, 6, 14, 14, 6, 6, 14, 6, 6, 14]);
~tEq.("...the capture index counted from the origin", c78.keep(3).collect { |x| x[0][\c] }.asArray, [0, 1, 2]);
}.value;

// ----------------------------------------- Beat Repeat: one capture, its repeats --
// The dice forced (chance 1): every pad fires at the capture at 92.75 (the
// transport from 92.0), whose slice is 92.75..92.875 and gate ends at 93.5.
{
var times = MegaSADrumsFx.beatRepeatTimes(0.125);
var tc = 92.75, gateEnd = 93.5;
var one = { |lanes, to = 93.6|
    var fx = ~bfMake.();
    fx[\drums].repeatChance = 1;
    ~bfPattern.(fx[\drums], \main, lanes);
    ~bfStart.(fx, 92.0);
    ~bfRun.(fx, to);
    fx
};
var fx, reps, of, recs, srcs, rate, want;
// A hat on the capture point; the decided table read while it holds them all.
fx = one.((0: (note: 42, steps: [6])), 92.8);
recs = fx[\drums].decided.select { |r| r[\kind] == \repeat };
~bfRun.(fx, 93.6);
reps = ~bfRepeats.(fx[\log]);
~tAssert.("bundles were sent", (fx[\log].size > 0) and: { reps.size > 0 });
~tEq.("a hat on the capture point: 5 repeats, of its carbon layer only (buffer 42, not its layer 142)",
    [reps.size, reps.collect(_[\buf]).asSet.asArray], [5, [42]]);
~tEqArray.("...contiguous from the slice's end, at the capture's stamps (grid + 20 ms)",
    reps.collect(_[\time]), times.collect { |t| (tc + t[0]) + 0.02 }, 1e-9);
~tEqArray.("...each at its repeat's level (velocity 127 at amp 1)", reps.collect(_[\amp]),
    (1..5).collect { |k| MegaSADrumsFx.beatRepeatLevel(k) }, 1e-9);
~tEqArray.("...and rate", reps.collect(_[\rate]), (1..5).collect { |k| MegaSADrumsFx.beatRepeatRate(k) }, 1e-9);
~tEqArray.("...each the slice from its start (startFrames 0), a 16th at its rate",
    reps.collect(_[\startFrames]) ++ reps.collect(_[\dur]),
    Array.fill(5, 0) ++ (1..5).collect { |k| 0.125 / MegaSADrumsFx.beatRepeatRate(k) }, 1e-9);
~tEqArray.("...the gate closing each 6/16 after the capture: the fifth cut short",
    reps.collect { |v| (v[\time] - 0.02) + v[\gateLen] }, Array.fill(5, gateEnd), 1e-9);
~tAssert.("...(the fifth would run past it)", reps[4] !? { |v| v[\gateLen] < v[\dur] } ? false);
~tEq.("...in the repeat group (at its tail), to the steps' bus, choke-free on the scratch bus, no band (a hat)",
    [reps.collect(_[\group]).asSet.asArray, reps.collect(_[\addAction]).asSet.asArray, reps.collect(_[\out]).asSet.asArray,
        reps.collect { |v| [v[\chokeOn], v[\chokeBus]] }.asSet.asArray, reps.collect(_[\bpOn]).asSet.asArray],
    [[1002], [1], [20], [[0, 3080]], [0]]);
~tAssert.("...each its own cancel bus in the steps' ring and its own hit id",
    (reps.collect(_[\cancelBus]).asSet.size == 5) and: { reps.every { |v| (v[\cancelBus] >= 1000) and: { v[\cancelBus] < 2024 } } }
        and: { reps.collect(_[\hitId]).asSet.size == 5 });
~tEq.("...each a \\repeat record in the decided table, k 1..5", recs.collect(_[\k]).asArray.sort, [1, 2, 3, 4, 5]);
~tAssert.("...stamped grid + 20 ms like every hit", recs.every { |r| ((r[\stamp] - r[\grid]) - 0.02).abs < 1e-12 });
~tEq.("...the capture's pads: every beatRepeat pad, the dice forced", fx[\drums].captures.first !? { |c| c[\pads].size }, 16);
// A hit inside the slice: 30 ms into it.
fx = one.((0: (note: 42, steps: [6], delay: 30)));
reps = ~bfRepeats.(fx[\log]);
~tAssert.("bundles were sent", reps.size > 0);
~tEqArray.("a hit inside the slice: each repeat plays it after its offset over the repeat's rate",
    reps.collect(_[\time]), times.collect { |t, i| (tc + t[0]) + (0.03 / MegaSADrumsFx.beatRepeatRate(i + 1)) + 0.02 }, 1e-9);
~tEqArray.("...from its sample's start, for the rest of the slice at the rate",
    reps.collect(_[\startFrames]) ++ reps.collect(_[\dur]),
    Array.fill(5, 0) ++ (1..5).collect { |k| 0.095 / MegaSADrumsFx.beatRepeatRate(k) }, 1e-9);
// A tail: a hit a 16th before the capture, still sounding (0.5 s).
fx = one.((0: (note: 41, steps: [5])));
reps = ~bfRepeats.(fx[\log]);
~tAssert.("bundles were sent", reps.size > 0);
~tEqArray.("a tail: each repeat from the slice's start, from where its sample was at the capture (0.125 s in)",
    reps.collect(_[\time]) ++ reps.collect(_[\startFrames]),
    times.collect { |t| (tc + t[0]) + 0.02 } ++ Array.fill(5, 6000), 1e-6);
// A tail choked before the capture: 46 at step 5, 42 (its choke group) 30 ms after.
fx = one.((0: (note: 46, steps: [5]), 1: (note: 42, steps: [5], delay: 30)));
reps = ~bfRepeats.(fx[\log]);
~tAssert.("bundles were sent", reps.size > 0);
~tEq.("a tail choked before the capture is not in the slice; the hat that choked it is",
    reps.collect(_[\buf]).asSet.asArray, [42]);
~tEqArray.("...from where it was at the capture (95 ms in)", reps.collect(_[\startFrames]), Array.fill(5, 4560), 1e-6);
// A tail choked inside the slice: 46 at step 5, 44 at the capture + 40 ms.
fx = one.((0: (note: 46, steps: [5]), 1: (note: 44, steps: [6], delay: 40)));
reps = ~bfRepeats.(fx[\log]);
of = { |buf| reps.select { |v| v[\buf] == buf } };
~tAssert.("bundles were sent", reps.size > 0);
~tEqArray.("a tail choked inside the slice: replayed up to the newer hit, at each rate",
    of.(46).collect(_[\dur]), (1..5).collect { |k| 0.04 / MegaSADrumsFx.beatRepeatRate(k) }, 1e-9);
~tEqArray.("...and the newer hit from its offset to the slice's end",
    of.(44).collect(_[\time]) ++ of.(44).collect(_[\dur]),
    times.collect { |t, i| (tc + t[0]) + (0.04 / MegaSADrumsFx.beatRepeatRate(i + 1)) + 0.02 }
        ++ (1..5).collect { |k| 0.085 / MegaSADrumsFx.beatRepeatRate(k) }, 1e-9);
// The band filter, on the pads that have it.
fx = one.((0: (note: 36, steps: [6])));
reps = ~bfRepeats.(fx[\log]);
~tAssert.("bundles were sent", reps.size > 0);
~tEq.("a kick (repeatFilter): its repeats band-limited round 1515 Hz, 2.625 octaves, its carbon layer only",
    [reps.size, reps.collect(_[\buf]).asSet.asArray, reps.collect { |v| [v[\bpOn], v[\bpFreq].round(0.01), v[\bpRq].round(1e-6)] }.asSet.asArray],
    [5, [36], [[1, 1515.18, MegaSADrumsFx.bandRq(2.625).round(1e-6)]]]);
}.value;

// --------------------------------------- Beat Repeat: when it does not repeat --
{
var mk = { |kit, setup|
    var fx = ~bfMake.(90.0, 2.0, kit);
    fx[\drums].repeatChance = 1;
    ~bfPattern.(fx[\drums], \main, (0: (note: 42, steps: [6])));
    setup.(fx[\drums]);
    ~bfStart.(fx, 92.0);
    ~bfRun.(fx, 93.6);
    fx
};
var off = mk.(\brkit, { |d| d.setRepeats(false, 91.0) }), plain = mk.(\plainkit, { });
~tAssert.("bundles were sent", (~bfVoices.(off[\log]).size > 0) and: { ~bfVoices.(plain[\log]).size > 0 });
~tEq.("Beat Repeat switched off: no repeats, though the capture is decided",
    [~bfRepeats.(off[\log]).size, off[\drums].captures.size > 0], [0, true]);
~tEq.("a kit without Beat Repeat: no repeats, no pads at the capture",
    [~bfRepeats.(plain[\log]).size, plain[\drums].captures.first !? { |c| c[\pads] }], [0, []]);
}.value;
// Off in new drums: Live's recordings of the set hold about one stutter in
// twelve minutes of drums, where these dice would give about one a minute.
// The kit keeps its pads' Beat Repeat, the captures are decided all along, and
// the switch (the Drums tab's, a preset's) turns it on from the next.
{
var fx = ~bfMake.(90.0, 2.0, \brkit, nil, false);
var d = fx[\drums];
d.repeatChance = 1;
~bfPattern.(d, \main, (0: (note: 42, steps: [6])));
~bfStart.(fx, 92.0);
~bfRun.(fx, 93.6);
~tAssert.("bundles were sent", ~bfVoices.(fx[\log]).size > 0);
~tEq.("Beat Repeat is off in new drums: no repeats, though the capture is decided and its pads drawn",
    [d.repeats, ~bfRepeats.(fx[\log]).size, d.captures.first !? { |c| c[\pads].size }], [false, 0, 16]);
d.setRepeats(true, 93.6);
~bfRun.(fx, 97.6);
~tEq.("...switched on, the next capture repeats", ~bfRepeats.(fx[\log]).size, 5);
}.value;

// -------------------------------------- Beat Repeat: after a second Start --
// A Start makes a new epoch. Until the new epoch's first capture is decided
// (its slice end less the lead, 1.75 quarter notes in) the capture cursor
// names the old epoch; at 90 BPM that is after the old epoch would be pruned
// (1 s in). Every capture point of every later epoch must still be decided,
// after a Start, after a Stop and a Start, and after a third Start.
{
var go = { |bpm, starts, stops, runTo|
    var loopDur = (60 / bpm) * 4;
    var fx = ~bfMake.(90.0, loopDur, \brkit, (numerator: 4, denominator: 4, k: 1, bpm: bpm, loopDur: loopDur));
    var d = fx[\drums], seen = IdentitySet.new, per = Dictionary.new, w, ss = List.newFrom(starts), st = List.newFrom(stops);
    d.repeatChance = 1;
    ~bfPattern.(d, \main, (0: (note: 42, steps: (0..15))));
    w = 90.0;
    fx[\wall] = w;
    while { w < runTo } {
        w = w + 0.01;
        fx[\wall] = w;
        if(st.notEmpty and: { w >= st[0] }) { st.removeAt(0); d.transportStop(w) };
        if(ss.notEmpty and: { w >= (ss[0] - 0.1) }) { ss.removeAt(0); d.transportStart(w) };
        d.pump(w);
        d.captures.do { |cap|
            if(seen.includes(cap).not) { seen.add(cap); per[cap[\epoch]] = (per[cap[\epoch]] ? 0) + 1 };
        };
    };
    [(1 .. d.instVarAt(\epochCount)).collect { |e| per[e] ? 0 }, ~bfRepeats.(fx[\log]).count { |v| v[\time] > starts.last }]
};
var q = 60 / 90, l = q * 4, b = { |m| 90.0 + (m * l) };
// Capture points every 8 quarters from 1.5 quarters in: 3 in each 6-loop
// epoch (16 s), 4 in the 20 s after the last Start.
var two = go.(90, [b.(1), b.(7)], [], b.(7) + 20);
var stopped = go.(90, [b.(1), b.(7)], [b.(6.5)], b.(7) + 20);
var three = go.(90, [b.(1), b.(7), b.(13)], [], b.(13) + 20);
~tEq.("90 BPM, a second Start: every capture point decided in both epochs", two[0], [3, 4]);
~tEq.("...after a Stop and a Start", stopped[0], [3, 4]);
~tEq.("...and a third Start", three[0], [3, 3, 4]);
~tAssert.("...and repeats are sent after the last Start", (two[1] > 0) and: { stopped[1] > 0 } and: { three[1] > 0 },
    [two[1], stopped[1], three[1]].asString);
}.value;

// ----------------------------------------- Beat Repeat: determinism --
// The Live set's own patterns and chance, twice with one seed: the same
// repeats, at the same times; with another seed the dice are others.
{
var first;
var go = { |seed|
    var fx = ~bfMake.(), seen = IdentitySet.new;
    fx[\drums].randSeed = seed;
    ~bfStart.(fx, 92.0);
    ~bfRun.(fx, 93.0, 0.02);
    first = fx[\drums].captures.first;
    ~bfRun.(fx, 132.0, 0.02);
    ~bfRepeats.(fx[\log])
};
var a = go.(1234), b = go.(1234), want, c;
want = (36..51).select { |n| MegaSASteps.uniform(1234 + 0, \main, 0, n, \repeat) < MegaSADrumsFx.beatRepeatChance };
~tAssert.("bundles were sent (the Live patterns repeat something in 40 s)", (a.size > 0) and: { b.size > 0 });
~tEq.("one seed, the same repeats", ~bfKeys.(a), ~bfKeys.(b));
~tEq.("the pads that fire: those whose die, MegaSASteps.uniform(the epoch's seed, \\main, capture, pad, \\repeat), is under the chance",
    first !? { |cap| cap[\pads] }, want);
c = go.(99);
~tAssert.("...so another seed fires others", ~bfKeys.(a) != ~bfKeys.(c));
}.value;

// ------------------------------------- Beat Repeat: cancelled with its pattern --
{
var mk = {
    var fx = ~bfMake.();
    fx[\drums].repeatChance = 1;
    ~bfPattern.(fx[\drums], \main, (0: (note: 42, steps: [6])));
    ~bfPattern.(fx[\drums], \break, (0: (note: 41, steps: [6], delay: 50)));
    ~bfStart.(fx, 92.0);
    fx
};
var fx, reps, n, sounding;
// A stop after the capture, before the first repeat.
fx = mk.();
~bfRun.(fx, 92.85);
n = ~bfRepeats.(fx[\log]).size;
fx[\drums].transportStop(92.85);
~bfRun.(fx, 93.6);
reps = ~bfRepeats.(fx[\log]);
~tAssert.("bundles were sent (the repeats went out at the capture)", n == 5);
~tEq.("a Stop cancels the repeats still to come, all five", reps.count(_[\cancelled]), 5);
~tEq.("...and sends none after", reps.size, 5);
// A break, likewise: the main pattern's repeats go with it.
fx = mk.();
~bfRun.(fx, 92.85);
fx[\drums].breakOpened(92.85);
~bfRun.(fx, 93.6);
reps = ~bfRepeats.(fx[\log]);
~tAssert.("bundles were sent", reps.size > 0);
~tEq.("a break cancels the main pattern's repeats from its edge", reps.select { |v| v[\buf] == 42 }.count(_[\cancelled]), 5);
// The switch mid-gate: off cuts what is still to come, on brings back what still can be.
fx = mk.();
~bfRun.(fx, 93.0);
fx[\drums].setRepeats(false, 93.0);
~bfRun.(fx, 93.1);
fx[\drums].setRepeats(true, 93.1);
~bfRun.(fx, 93.6);
reps = ~bfRepeats.(fx[\log]);
sounding = ~bfSounding.(reps).collect { |v| v[\time] - 0.02 };
~tAssert.("bundles were sent", reps.size > 0);
~tEqArray.("Beat Repeat off at 93.0 and on at 93.1: repeat 1 (already playing) kept, 2 cancelled, 3..5 sent again",
    sounding, MegaSADrumsFx.beatRepeatTimes(0.125).collect { |t| 92.75 + t[0] }.reject { |t, i| i == 1 }, 1e-9);
~tEq.("...nothing twice", sounding.asSet.size, sounding.size);
// A cut inside the slice: a stomp 20 ms into it. The main hat's repeats go;
// the break's hit 50 ms into the slice, sent by the stomp, gets its own.
fx = mk.();
~bfRun.(fx, 92.79);
~tEq.("(the capture is decided, with the hat's repeats)", ~bfRepeats.(fx[\log]).size, 5);
fx[\drums].breakOpened(92.79);
~bfRun.(fx, 93.6);
reps = ~bfRepeats.(fx[\log]);
~tEq.("a stomp inside the slice: the main hat's repeats cancelled", reps.select { |v| v[\buf] == 42 }.count(_[\cancelled]), 5);
~tEqArray.("...the break's hit in the slice sent, and its repeats derived and sent with it",
    ~bfSounding.(reps).select { |v| v[\buf] == 41 }.collect(_[\time]),
    MegaSADrumsFx.beatRepeatTimes(0.125).collect { |t, i| (92.75 + t[0]) + (0.05 / MegaSADrumsFx.beatRepeatRate(i + 1)) + 0.02 },
    1e-9);
~tAssert.("...(the break's hit itself sounds)", ~bfSounding.(~bfVoices.(fx[\log])).any { |v|
    (v[\group] == 1001) and: { v[\buf] == 41 } and: { (v[\time] - 92.82).abs < 1e-9 } });
}.value;

// ---------------------------------------- Beat Repeat: a rewind of the grid --
// A rewind from the capture point (as a reading taken back would make) decides
// the capture again: what sounds is what would have sounded, nothing twice.
{
var mk = {
    var fx = ~bfMake.();
    fx[\drums].repeatChance = 1;
    ~bfPattern.(fx[\drums], \main, (0: (note: 42, steps: [6]), 1: (note: 41, steps: [5])));
    ~bfStart.(fx, 92.0);
    fx
};
var a = mk.(), r = mk.(), ka, kr;
~bfRun.(a, 93.6);
~bfRun.(r, 92.8);
r[\drums].prRequest([\rewind, 92.75]);
~bfRun.(r, 93.6);
ka = ~bfKeys.(~bfSounding.(~bfRepeats.(a[\log])));
kr = ~bfKeys.(~bfSounding.(~bfRepeats.(r[\log])));
~tAssert.("bundles were sent", (ka.size > 0) and: { kr.size > 0 });
~tEq.("a rewind into a decided capture: the same repeats sound", kr, ka);
~tEq.("...each once", kr.asSet.size, kr.size);
}.value;

// ------------------------------------------------------------------ presets --
{
var fx = ~bfMake.();
var d = fx[\drums];
var dir = ~bfDir +/+ "presets";
var slug, mainCopy, breakCopy, warnings = List.new, ok, text, data;
d.setStep(\main, \chance, 0, 3, 5);
d.setLength(\main, \velo, 1, 12);
d.setLaneParam(\main, 2, \lock, true);
d.setLaneParam(\main, 2, \globalLength, 7);
d.setLaneParam(\break, 3, \delay, 12.5);
d.setLaneParam(\main, 1, \mute, true);
d.setLaneParam(\main, 0, \note, 41);
d.setParam(\main, \clockSpeed, 4);
d.setParam(\break, \shuffle3, -12.25);
d.setParam(\break, \globalShuffle, 40);
d.setParam(\main, \autoRetrigger, false);
d.setPadTrim(\steps, 42, -3.5);
d.setGroupTrim(\steps, \layer, -6);
d.setRepeats(false, 10.0);
d.setReverbMix(0.3);
d.setOffsetMs(7.25);
d.setOn(false, 10.0);
mainCopy = d.patterns[\main].deepCopy;
breakCopy = d.patterns[\break].deepCopy;
slug = d.savePreset(dir, "My Groove!");
~tEq.("savePreset: the slug (Looper.presetSlug)", [slug, d.presetSlug("My Groove!")], ["my-groove", Looper.presetSlug("My Groove!")]);
text = File.readAllString(dir +/+ "my-groove.scd") ? "";
~tAssert.("...one SC literal, its comments first, none trailing", text.beginsWith("//") and: {
    text.stripWhiteSpace.endsWith(")") });
data = text.interpret;
~tEq.("...holding both patterns, the kits, trims, Beat Repeat, the reverb and the offset (and not on/off or the break)",
    data !? { |x| x.keys.asArray.sort }, [\break, \groupTrims, \main, \name, \offsetMs, \onsetKit, \padTrims,
        \repeats, \reverbMix, \savedAt, \stepsKit, \version]);
~tEq.("...the kits by key, the trims as [kit, key, dB]", data !? { |x| [x[\stepsKit], x[\padTrims], x[\groupTrims]] },
    ["brkit", [["brkit", 42, -3.5]], [["brkit", "layer", -6.0]]]);
d.resetPattern(\main);
d.resetPattern(\break);
d.setPadTrim(\steps, 42, 0);
d.setGroupTrim(\steps, \layer, 0);
d.setRepeats(true, 10.0);
d.setReverbMix(0.1508);
d.setOffsetMs(0);
d.setOn(true, 10.0);
ok = d.loadPreset(dir, slug, warnings);
~tAssert.("loadPreset: true, nothing to correct", (ok == true) and: { warnings.isEmpty }, warnings.asArray);
~tEq.("...both patterns exactly as saved, every field", [d.patterns[\main] == mainCopy, d.patterns[\break] == breakCopy],
    [true, true]);
~tEq.("...the trims, Beat Repeat's switch, the reverb and the offset",
    [d.padTrim(\steps, 42), d.groupTrim(\steps, \layer), d.repeats, d.reverbMix, d.offsetMs], [-3.5, -6, false, 0.3, 7.25]);
~tEq.("...and not PC 17's on/off", d.on, true);
~tEq.("presetNames: the slugs", d.presetNames(dir), ["my-groove"]);
}.value;
{
var fx = ~bfMake.();
var d = fx[\drums];
var dir = ~bfDir +/+ "presets2";
var warnings = List.new, ok, got = List.new, before, ctl, path;
var write = { |name, text| File.use(dir +/+ name, "w", { |f| f.write(text) }) };
var row = { |v| "[" ++ Array.fill(16, { |i| if(i == 0) { v } { 0 } }).join(", ") ++ "]" };
File.mkdir(dir);
write.("hand.scd", "// hand-edited\n(\n    version: 1,\n    name: \"hand\",\n    stepsKit: \"nope\",\n"
    "    onsetKit: \"plainkit\",\n    repeats: \"yes\",\n    reverbMix: 3,\n    offsetMs: \"x\",\n"
    "    padTrims: [[\"brkit\", 42, 20], [\"brkit\", \"x\", 1], 5],\n    groupTrims: [[\"brkit\", \"layer\", -4.5]],\n"
    "    tempo: 120,\n    main: (steps: (chance: [" ++ row.(9) ++ ", " ++ row.(0) ++ ", " ++ row.(0) ++ ", " ++ row.(0)
    ++ "]), clockSpeed: \\fast),\n    break: (rollRate: 99)\n)\n");
write.("newer.scd", "(version: 2, reverbMix: 0.9)");
write.("list.scd", "[1, 2, 3]");
write.("throws.scd", "(reverbMix: nil.foo)");
write.("trap.scd", "~bfTrap = 1; ()");
~bfTrap = nil;
~tEq.("presetNames lists slugs without running a file", [d.presetNames(dir), ~bfTrap],
    [["hand", "list", "newer", "throws", "trap"], nil]);
ctl = SimpleController(d).put(\kit, { |o, w, slot, key| got.add([slot, key]) });
ok = d.loadPreset(dir, "hand", warnings);
~tEq.("a hand-edited preset loads, fail-soft field by field", ok, true);
~tEq.("...a step out of range held to it, a setting not usable at the Live set's, a missing field the Live set's",
    [d.step(\main, \chance, 0, 0), d.param(\main, \clockSpeed), d.step(\main, \velo, 0, 0), d.param(\break, \rollRate)],
    [6, 3, MegaSASteps.livePattern(\main)[\steps][\velo][0][0], 8]);
~tEq.("...the mix held to 0..1, a value that is no number kept as it was",
    [d.reverbMix, d.offsetMs, d.repeats], [1, 0, true]);
~tEq.("...a trim held to -24..+12, the bad rows dropped, the group trim in",
    [d.padTrim(\steps, 42), d.groupTrim(\steps, \layer)], [12, -4.5]);
~tEq.("...a kit not here kept, one that is switched to (setKit), and loaded",
    [d.kit(\steps), d.kit(\onset), d.kitState(\onset), got.asArray], [\brkit, \plainkit, \ready, [[\onset, \plainkit]]]);
~tEq.("...every correction said once", warnings.size, 11);
~tAssert.("...naming what it was", [["main: steps chance lane 0 step 0"], ["clockSpeed"], ["rollRate 99"], ["stepsKit", "nope"],
    ["repeats"], ["reverbMix 3"], ["offsetMs"], ["tempo"], ["(dropped)"]].every { |words|
        warnings.any { |w| words.every { |x| w.contains(x) } } }, warnings.asArray);
before = [d.reverbMix, d.offsetMs, d.patterns[\main].deepCopy];
warnings = List.new;
~tEq.("a newer version is refused whole", [d.loadPreset(dir, "newer", warnings), warnings.size], [false, 1]);
~tEq.("...and so is a file that is not a preset, or that throws", [d.loadPreset(dir, "list", List.new),
    d.loadPreset(dir, "throws", List.new), d.loadPreset(dir, "none", List.new)], [false, false, false]);
~tEq.("...changing nothing", [d.reverbMix, d.offsetMs, d.patterns[\main] == before[2]], [before[0], before[1], true]);
// A file whose code throws while the literal is half built, read where the
// answer is an operand: the reader's own stack (Looper.readPresetFile) keeps
// that half-built expression off the caller's.
write.("operand.scd", "(version: 1, name: \"x\", reverbMix: nil.foo, offsetMs: 3)");
~tEq.("a preset that throws while it is read, in an expression: 1000 + loadPreset(...).binaryValue is 1000",
    1000 + (d.loadPreset(dir, "operand", List.new).binaryValue), 1000);
~tEq.("...and inside a literal the caller is building", [\before, d.loadPreset(dir, "operand", List.new), \after],
    [\before, false, \after]);
~tEq.("deletePreset: true, then the file is gone (and false again)",
    [d.deletePreset(dir, "hand"), File.exists(dir +/+ "hand.scd"), d.deletePreset(dir, "hand")], [true, false, false]);
~tEq.("no folder: nothing saved, nothing loaded", [d.savePreset(nil, "x"), d.loadPreset(nil, "x")], [nil, false]);
// Keep: one file, in a folder that does not exist yet.
path = ~bfDir +/+ "kept" +/+ "drums.scd";
d.setReverbMix(0.42);
d.setParam(\break, \rollRate, 2);
~tEq.("keep: written, its folder made", [d.keep(path), File.exists(path)], [true, true]);
d.setReverbMix(0.1);
d.resetPattern(\break);
~tEq.("loadKept: the kept drums back", [d.loadKept(path), d.reverbMix, d.param(\break, \rollRate)], [true, 0.42, 2]);
~tEq.("...false, and nothing said, when nothing was kept", d.loadKept(~bfDir +/+ "nothing.scd"), false);
~tEq.("...by default in your megalooper folder (sa/kept-drums/drums.scd), not in the repo", MegaSADrums.defaultKeptPath,
    MegaFiles.userRoot +/+ "sa" +/+ "kept-drums" +/+ "drums.scd");
ctl.remove;
}.value;
// A slot left without a kit (the Drums tab's "— none —") is kept so: a preset
// and Keep write "none", and loading one empties the slot (setKit nil), so a
// boot does not fill it with its default kit.
{
var fx = ~bfMake.();
var d = fx[\drums];
var dir = ~bfDir +/+ "presets3", path = ~bfDir +/+ "kept3" +/+ "drums.scd", text, fresh, warnings = List.new;
d.setKit(\onset, nil);
d.savePreset(dir, "quiet");
text = File.readAllString(dir +/+ "quiet.scd") ? "";
~tAssert.("a preset with the onset slot empty says so: onsetKit: \"none\"", text.contains("onsetKit: \"none\""), text);
d.setKit(\onset, \plainkit);
~tEq.("loading it empties the slot again, with nothing to correct",
    [d.loadPreset(dir, "quiet", warnings), d.kit(\onset), d.kitState(\onset), d.kitEmptied(\onset), warnings.asArray],
    [true, nil, \unset, true, []]);
~tEq.("...the other slot's kit as it was", d.kit(\steps), \brkit);
d.keep(path);
fresh = MegaSADrums((server: ~tStubServer.()));
fresh.prUseBusses;
fresh.kitDir = ~bfDir;
fresh.kitReader = ~bfReader;
~tEq.("in new drums a slot is empty but was never emptied", [fresh.kit(\onset), fresh.kitEmptied(\onset)], [nil, false]);
~tEq.("the kept drums with the slot empty: emptied, the steps kit theirs",
    [fresh.loadKept(path), fresh.kit(\onset), fresh.kitEmptied(\onset), fresh.kit(\steps)], [true, nil, true, \brkit]);
fresh.free;
}.value;

~bfDropFiles.();
[\bfDir, \bfDir441, \bfWrite, \bfPad, \bfMakeFiles, \bfDropFiles, \bfReader, \bfIrReads, \bfIrReader, \bfMake,
    \bfPattern, \bfStart, \bfRun, \bfVoices, \bfRepeats, \bfIs, \bfSounding, \bfKey, \bfKeys, \bfTrap].do { |k|
    currentEnvironment.put(k, nil) };
