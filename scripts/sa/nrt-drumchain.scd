// megalooper SA — the drums' chain, heard offline.
//
//     sclang scripts/sa/nrt-drumchain.scd
//
// One offline render (scsynth -N on a far port; megalooper, if it runs, is
// not touched). Five copies of the drums' path side by side, each on a bus
// of its own, as MegaSA builds it: a voice plays onto the bus, then the
// chain's group (its source, which feeds nothing, and its devices, each
// working on the bus in place), then the drums' effects synth
// (\megaSADrumsFx), which reads the bus. The voice is a 1 kHz burst.
//
//   0  no chain, the reverb at mix 0: the drums as they were
//   1  an empty chain: its source alone
//   2  a Saturator on the chain, switched on
//   3  the same, the reverb at mix 1 on a unit impulse response: what the
//      reverb is given comes out 480 samples later (nrt-drums-fx.scd, 1)
//   4  a Saturator on the chain, switched off
//
// Exits 0 if every check passed, 1 otherwise.
(
var sr = 48000, dur = 1.0, paths = 5, chans = paths * 2, delay = 480;
var tmp = PathName.tmp +/+ "megalooper-nrt-drumchain-" ++ thisProcess.pid;
var osc = tmp +/+ "drumchain.osc", wav = tmp +/+ "drumchain.wav";
var pass = 0, fail = 0, fails = List.new;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln } {
        fail = fail + 1;
        fails.add(label ++ (detail !? { |d| " — " ++ d } ? ""));
        ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
    };
};
var voice = SynthDef(\nrtDrumChainVoice, { |out|
    OffsetOut.ar(out, (SinOsc.ar(1000) * EnvGen.ar(Env.perc(0.001, 0.2), doneAction: 2) * 0.5) ! 2);
});
var defs, bus = { |i| 32 + (2 * i) }, sources = 1000, chains = 1001, effects = 1002;
var deltaIr = 0, deltaSpec = 1, zeroSpec = 2, dummySpec = 3;
var specSize = { |n| PartConv.calcBufSize(MegaSADrumsFx.fftSize, (numFrames: n)).asInteger };
var fx = { |i, mix, irOn, specs|
    [0.0, [\s_new, \megaSADrumsFx, 1100 + i, 1, effects, \in, bus.(i), \out, 2 * i, \mix, mix, \irOn, irOn]
        ++ [MegaSADrumsFx.irKeys, specs].flop.flat]
};
var dry = { dummySpec ! 4 };
var score, cmd, said, sf, data, frames, chan, rmsDb, differ, finite, lagOf;

MegaSADrums.loadSynthDefs;
defs = [voice, MegaSAFx.sourceDefs.detect { |d| d.name.asSymbol == \megaSAChainOn }, MegaSAFx.deviceDef(\saturator),
    SynthDescLib.global[\megaSADrumsFx] !? { |x| x.def }];
if(defs.any(_.isNil)) { "NRT DRUM CHAIN FAILED — a SynthDef is missing".postln; 1.exit } {
File.mkdir(tmp);
score = defs.collect { |d| [0.0, [\d_recv, d.asBytes]] }
    ++ [
        [0.0, [\g_new, sources, 0, 0]],
        [0.0, [\g_new, chains, 3, sources]],
        [0.0, [\g_new, effects, 3, chains]],
        [0.0, [\b_alloc, deltaIr, 2000, 1]],
        [0.0, [\b_set, deltaIr, 0, 1.0]],
        [0.0, [\b_alloc, deltaSpec, specSize.(2000), 1]],
        [0.0, [\b_gen, deltaSpec, "PreparePartConv", deltaIr, MegaSADrumsFx.fftSize]],
        [0.0, [\b_alloc, zeroSpec, specSize.(2000), 1]],
        [0.0, [\b_alloc, dummySpec, MegaSADrumsFx.fftSize, 1]],
        // The chains: a source first in its chain, then its device after it.
        [0.0, [\s_new, \megaSAChainOn, 1201, 1, chains, \bus, bus.(1)]],
        [0.0, [\s_new, \megaSAChainOn, 1202, 1, chains, \bus, bus.(2)]],
        [0.0, [\s_new, \megaSADevSaturator, 1302, 3, 1202, \bus, bus.(2), \saturatorOn, 1]],
        [0.0, [\s_new, \megaSAChainOn, 1203, 1, chains, \bus, bus.(3)]],
        [0.0, [\s_new, \megaSADevSaturator, 1303, 3, 1203, \bus, bus.(3), \saturatorOn, 1]],
        [0.0, [\s_new, \megaSAChainOn, 1204, 1, chains, \bus, bus.(4)]],
        [0.0, [\s_new, \megaSADevSaturator, 1304, 3, 1204, \bus, bus.(4), \saturatorOn, 0]],
        // The drums' effects, after every chain.
        fx.(0, 0, 0, dry.value), fx.(1, 0, 0, dry.value), fx.(2, 0, 0, dry.value),
        fx.(3, 1, 1, [deltaSpec, zeroSpec, zeroSpec, deltaSpec]), fx.(4, 0, 0, dry.value)
    ]
    // The voices, mid-block, as the drums' are stamped.
    ++ paths.collect { |i| [0.1001, [\s_new, \nrtDrumChainVoice, -1, 1, sources, \out, bus.(i)]] }
    // Every synth freed before the end: scsynth 3.14.1 hangs in its offline
    // cleanup when a synth that owns memory is still running.
    ++ [[dur - 0.05, [\g_freeAll, effects]], [dur - 0.05, [\g_freeAll, chains]], [dur - 0.05, [\g_freeAll, sources]],
        [dur, [\c_set, 0, 0]]];
Score(score.sort { |x, y| x[0] <= y[0] }).writeOSCFile(osc);
cmd = "perl -e 'alarm shift; exec @ARGV' 120 " ++ MegaSAPlugins.scsynthPath.shellQuote ++ " -u " ++ (58300 + 200.rand)
    ++ " -m 65536 -N " ++ osc.shellQuote ++ " _ " ++ wav.shellQuote ++ " " ++ sr ++ " WAV float -o " ++ chans ++ " -i 0 2>&1";
said = cmd.unixCmdGetStdOut;
sf = SoundFile.openRead(wav);
if(sf.isNil or: { sf.numFrames < ((dur - 0.2) * sr) }) {
    ("  FAIL  the render: " ++ said.split($\n).reject(_.isEmpty).keep(-4).join(" | ")).postln;
    sf !? { |f| f.close };
    [osc, wav].do { |f| if(File.exists(f)) { File.delete(f) } };
    File.delete(tmp);
    "NRT DRUM CHAIN FAILED — no render".postln;
    1.exit;
} {
    frames = sf.numFrames;
    data = FloatArray.newClear(frames * chans);
    sf.readData(data);
    sf.close;
    // One output channel between two times, in seconds, `shift` samples on.
    chan = { |c, from, to, shift = 0|
        var a = (from * sr).asInteger + shift, b = ((to * sr).asInteger + shift).min(frames);
        FloatArray.fill(b - a, { |i| data[((a + i) * chans) + c] })
    };
    rmsDb = { |x| (x.sum { |v| v * v } / x.size.max(1)).sqrt.max(1e-12).ampdb };
    differ = { |a, b| (a - b).inject(0, { |m, v| m.max(v.abs) }) };
    finite = { |x| x.every { |v| v.isNaN.not and: { v.abs < 1e6 } } };

    "== the drums' chain, offline ==".postln;
    ok.("the drums are heard with no chain: the burst, on both sides", [0, 1].every { |c| rmsDb.(chan.(c, 0.1, 0.3)) > -30 },
        [rmsDb.(chan.(0, 0.1, 0.3)), rmsDb.(chan.(1, 0.1, 0.3))].round(0.1).asString);
    ok.("an empty chain changes nothing: sample for sample the drums as they were",
        [0, 1].every { |c| differ.(chan.(c, 0, 0.9), chan.(2 + c, 0, 0.9)) == 0 },
        [differ.(chan.(0, 0, 0.9), chan.(2, 0, 0.9)), differ.(chan.(1, 0, 0.9), chan.(3, 0, 0.9))].asString);
    ok.("a Saturator on the chain is heard at the drums' output: it is not the drums as they were",
        [0, 1].every { |c| differ.(chan.(c, 0.1, 0.3), chan.(4 + c, 0.1, 0.3)) > 0.01 }
            and: { rmsDb.(chan.(4, 0.1, 0.3)) > -40 },
        [differ.(chan.(0, 0.1, 0.3), chan.(4, 0.1, 0.3)), rmsDb.(chan.(4, 0.1, 0.3))].round(0.001).asString);
    ok.("...from the hit's start, and silent before it: the chain makes no sound of its own",
        (differ.(chan.(0, 0.1, 0.102), chan.(4, 0.1, 0.102)) > 0.001) and: { rmsDb.(chan.(4, 0, 0.0995)) < -100 },
        [differ.(chan.(0, 0.1, 0.102), chan.(4, 0.1, 0.102)), rmsDb.(chan.(4, 0, 0.0995))].asString);
    // The reverb at mix 1 on a unit response gives what it was given, 480
    // samples later, less what its 80 Hz low cut takes (of a Saturator's
    // output, a little: of the 1 kHz burst itself, next to nothing).
    ok.("the reverb is given what the chain made: its output is the Saturator's, 480 samples later, its low cut aside",
        [0, 1].every { |c| differ.(chan.(4 + c, 0.1, 0.3), chan.(6 + c, 0.1, 0.3, delay)) < 0.06 },
        [differ.(chan.(4, 0.1, 0.3), chan.(6, 0.1, 0.3, delay)), differ.(chan.(5, 0.1, 0.3), chan.(7, 0.1, 0.3, delay))].round(0.0001).asString);
    ok.("...and not the drums as they were, by five times that: the chain comes before the reverb",
        differ.(chan.(0, 0.1, 0.3), chan.(6, 0.1, 0.3, delay)) > (5 * differ.(chan.(4, 0.1, 0.3), chan.(6, 0.1, 0.3, delay))),
        [differ.(chan.(0, 0.1, 0.3), chan.(6, 0.1, 0.3, delay)), differ.(chan.(4, 0.1, 0.3), chan.(6, 0.1, 0.3, delay))].round(0.0001).asString);
    ok.("a device switched off passes the drums as they were",
        [0, 1].every { |c| differ.(chan.(c, 0, 0.9), chan.(8 + c, 0, 0.9)) < 1e-6 },
        [differ.(chan.(0, 0, 0.9), chan.(8, 0, 0.9)), differ.(chan.(1, 0, 0.9), chan.(9, 0, 0.9))].asString);
    ok.("every render is finite", (0..chans - 1).every { |c| finite.(chan.(c, 0, 0.9)) });

    [osc, wav].do { |f| if(File.exists(f)) { File.delete(f) } };
    File.delete(tmp);
    "".postln;
    if(fail == 0) { ("NRT DRUM CHAIN PASSED — " ++ pass ++ " checks").postln; 0.exit } {
        ("NRT DRUM CHAIN FAILED — " ++ fail ++ " of " ++ (pass + fail)).postln;
        fails.do { |f| ("  " ++ f).postln };
        1.exit;
    };
};
};
)
