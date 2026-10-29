// megalooper — the Utility effects (EQ, Compressor, Noise Gate), heard offline.
//
//     sclang scripts/sa/nrt-utility.scd
//
// Each case is one device of MegaSAFx's own SynthDef, switched on, between a
// test signal written to a private bus and two taps: the signal as it went in
// and as it came out, on two output channels of its own. One render (scsynth
// -N on a far port; megalooper, if it runs, is not touched), the levels read
// over the last of each case's second and a half. A keyed case has a key
// too, a second source on a bus of its own that the Compressor is given as
// a chain's (\keyBuses), running before it in the block or after it, as a
// chain the server runs later does. Exits 0 if every check passed, 1
// otherwise. (docs/dev/rc600-picks.md, Phase 4b.)
(
var sr = 48000, dur = 1.5, from = 0.75, to = 1.45;
var tmp = PathName.tmp +/+ "megalooper-nrt-utility-" ++ thisProcess.pid;
var osc = tmp +/+ "utility.osc", wav = tmp +/+ "utility.wav";
var pass = 0, fail = 0, fails = List.new;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln } {
        fail = fail + 1;
        fails.add(label ++ (detail !? { |d| " — " ++ d } ? ""));
        ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
    };
};
// A source: a sine at `freq` and `db` dBFS peak, or noise at `db`, on both
// sides of the bus.
var srcDef = SynthDef(\nrtUtilSrc, { |bus, freq = 1000, amp = 0.1, noise = 0|
    var sig = Select.ar(noise, [SinOsc.ar(freq), WhiteNoise.ar]) * amp;
    Out.ar(bus, [sig, sig]);
});
var tapDef = SynthDef(\nrtUtilTap, { |bus, out| Out.ar(out, In.ar(bus, 1)) });
// [label, type, its settings, the source's, the key's or nil, \before or
// \after: where the key runs]. A keyed Compressor's settings: Key 4 (the
// drums' place in MegaSAFx.keyTracks) and its key's bus there, the others
// a bus nothing writes. Its source at -30 is under the threshold: only a
// key over it turns it down.
var keyed = { |i, more| [\compressorThreshold, -18, \compressorRatio, 4, \compressorKnee, 0,
    \compressorAttack, 0.001, \compressorRelease, 0.05, \compressorKey, 4,
    \keyBuses, [90, 90, 90, 400 + (i * 2), 90]] ++ more };
var cases = [
    [\eqFlat, \eq, [], [\noise, 1, \amp, 0.25]],
    [\eqMid, \eq, [\eqMid1Freq, 1000, \eqMid1Gain, 12], [\freq, 1000, \amp, -20.dbamp]],
    [\eqMidOff, \eq, [\eqMid1Freq, 1000, \eqMid1Gain, 12], [\freq, 100, \amp, -20.dbamp]],
    [\eqLowCut, \eq, [\eqLowCut, 200], [\freq, 50, \amp, -6.dbamp]],
    [\eqHighCut, \eq, [\eqHighCut, 2000], [\freq, 8000, \amp, -6.dbamp]],
    [\eqShelf, \eq, [\eqLowFreq, 300, \eqLowGain, -12], [\freq, 60, \amp, -10.dbamp]],
    [\compOver, \compressor, [\compressorThreshold, -18, \compressorRatio, 4, \compressorKnee, 0,
        \compressorAttack, 0.001, \compressorRelease, 0.05], [\freq, 1000, \amp, -6.dbamp]],
    [\compUnder, \compressor, [\compressorThreshold, -18, \compressorRatio, 4, \compressorKnee, 0],
        [\freq, 1000, \amp, -30.dbamp]],
    [\compMakeup, \compressor, [\compressorThreshold, -18, \compressorRatio, 4, \compressorKnee, 0,
        \compressorAttack, 0.001, \compressorRelease, 0.05, \compressorMakeup, 6], [\freq, 1000, \amp, -6.dbamp]],
    [\gateShut, \noiseGate, [\noiseGateThreshold, -50], [\freq, 1000, \amp, -60.dbamp]],
    [\gateOpen, \noiseGate, [\noiseGateThreshold, -50], [\freq, 1000, \amp, -40.dbamp]],
    [\gateRange, \noiseGate, [\noiseGateThreshold, -50, \noiseGateRange, -20], [\freq, 1000, \amp, -60.dbamp]],
    [\keyLoud, \compressor, keyed.(12), [\freq, 1000, \amp, -30.dbamp], [\freq, 1000, \amp, -6.dbamp], \before],
    [\keyLater, \compressor, keyed.(13), [\freq, 1000, \amp, -30.dbamp], [\freq, 1000, \amp, -6.dbamp], \after],
    [\keyQuiet, \compressor, keyed.(14), [\freq, 1000, \amp, -30.dbamp], [\freq, 1000, \amp, -40.dbamp], \before],
    [\keyItself, \compressor, keyed.(15, [\compressorKey, 0]), [\freq, 1000, \amp, -30.dbamp],
        [\freq, 1000, \amp, -6.dbamp], \before],
    [\keyUnknown, \compressor, keyed.(16).keep(12), [\freq, 1000, \amp, -30.dbamp], [\freq, 1000, \amp, -6.dbamp], \before],
    [\keyLows, \compressor, keyed.(17, [\compressorRelease, 0.5, \compressorKeyFilter, 300]), [\freq, 1000, \amp, -30.dbamp],
        [\freq, 100, \amp, -6.dbamp], \before],
    [\keyHighs, \compressor, keyed.(18, [\compressorRelease, 0.5, \compressorKeyFilter, 300]), [\freq, 1000, \amp, -30.dbamp],
        [\freq, 4000, \amp, -6.dbamp], \before]
];
var chans = cases.size * 2, score, cmd, said, sf, data, frames, chanOf, peakDb, diffDb, idx;

File.mkdir(tmp);
score = [[0.0, [\d_recv, srcDef.asBytes]], [0.0, [\d_recv, tapDef.asBytes]]]
    ++ MegaSAFx.extraKeys.collect { |k| [0.0, [\d_recv, MegaSAFx.deviceDef(k).asBytes]] };
cases.do { |c, i|
    var bus = 100 + (i * 2), base = 10000 + (i * 10);
    score = score ++ [
        [0.05, [\s_new, \nrtUtilSrc, base, 1, 0, \bus, bus] ++ c[3]],
        [0.05, [\s_new, \nrtUtilTap, base + 1, 3, base, \bus, bus, \out, (i * 2) + 1]],
        [0.05, ([\s_new, MegaSAFx.deviceDefName(c[1]), base + 2, 3, base + 1, \bus, bus,
            MegaSAFx.switchName(c[1]), 1] ++ c[2]).asOSCArgArray],
        [0.05, [\s_new, \nrtUtilTap, base + 3, 3, base + 2, \bus, bus, \out, i * 2]],
        [dur - 0.05, [\n_free, base, base + 1, base + 2, base + 3]]
    ];
    // The key, on its own bus: before the source in the block, or after
    // the last tap.
    c[4] !? { |args|
        score = score ++ [
            [0.05, [\s_new, \nrtUtilSrc, base + 4] ++ if(c[5] == \after) { [3, base + 3] } { [2, base] }
                ++ [\bus, 400 + (i * 2)] ++ args],
            [dur - 0.05, [\n_free, base + 4]]
        ];
    };
};
score = score.sort { |a, b| a[0] <= b[0] } ++ [[dur, [\c_set, 0, 0]]];
Score(score).writeOSCFile(osc);
cmd = "perl -e 'alarm shift; exec @ARGV' 120 " ++ MegaSAPlugins.scsynthPath.shellQuote ++ " -u " ++ (58500 + 200.rand)
    ++ " -m 65536 -N " ++ osc.shellQuote ++ " _ " ++ wav.shellQuote ++ " " ++ sr ++ " WAV float -o " ++ chans
    ++ " -i 0 2>&1";
said = cmd.unixCmdGetStdOut;
sf = SoundFile.openRead(wav);
if(sf.isNil) {
    ("  FAIL  the render: " ++ said.split($\n).reject(_.isEmpty).keep(-4).join(" | ")).postln;
    "NRT UTILITY FAILED — no render".postln;
    1.exit;
} {
    frames = sf.numFrames;
    data = FloatArray.newClear(frames * chans);
    sf.readData(data);
    sf.close;
    // Case i's output (0) or input (1), over the measured stretch.
    chanOf = { |i, which| ((from * sr).asInteger .. (to * sr).asInteger).collect { |f| data[(f * chans) + (i * 2) + which] } };
    peakDb = { |xs| xs.abs.maxItem.max(1e-12).ampdb };
    diffDb = { |a, b| (a - b).abs.maxItem.max(1e-12).ampdb };
    idx = { |label| cases.detectIndex { |c| c[0] == label } };
    "== the Utility effects, offline ==".postln;
    ok.("every render is finite", data.every { |x| x.isNaN.not and: { x.abs < inf } });
    ok.("EQ at its defaults: the signal as it came (noise, within -100 dB)",
        diffDb.(chanOf.(idx.(\eqFlat), 0), chanOf.(idx.(\eqFlat), 1)) < -100,
        diffDb.(chanOf.(idx.(\eqFlat), 0), chanOf.(idx.(\eqFlat), 1)).round(0.1).asString ++ " dB off");
    ok.("EQ, +12 dB at 1 kHz: a 1 kHz sine 12 dB up (+- 0.3)",
        ((peakDb.(chanOf.(idx.(\eqMid), 0)) - peakDb.(chanOf.(idx.(\eqMid), 1))) - 12).abs < 0.3,
        (peakDb.(chanOf.(idx.(\eqMid), 0)) - peakDb.(chanOf.(idx.(\eqMid), 1))).round(0.01).asString ++ " dB");
    ok.("...a 100 Hz one left nearly alone (within 1 dB)",
        (peakDb.(chanOf.(idx.(\eqMidOff), 0)) - peakDb.(chanOf.(idx.(\eqMidOff), 1))).abs < 1,
        (peakDb.(chanOf.(idx.(\eqMidOff), 0)) - peakDb.(chanOf.(idx.(\eqMidOff), 1))).round(0.01).asString ++ " dB");
    ok.("EQ, low cut at 200 Hz: 50 Hz at least 40 dB down",
        (peakDb.(chanOf.(idx.(\eqLowCut), 0)) - peakDb.(chanOf.(idx.(\eqLowCut), 1))) < -40,
        (peakDb.(chanOf.(idx.(\eqLowCut), 0)) - peakDb.(chanOf.(idx.(\eqLowCut), 1))).round(0.1).asString ++ " dB");
    ok.("EQ, high cut at 2 kHz: 8 kHz at least 40 dB down",
        (peakDb.(chanOf.(idx.(\eqHighCut), 0)) - peakDb.(chanOf.(idx.(\eqHighCut), 1))) < -40,
        (peakDb.(chanOf.(idx.(\eqHighCut), 0)) - peakDb.(chanOf.(idx.(\eqHighCut), 1))).round(0.1).asString ++ " dB");
    ok.("EQ, low shelf -12 dB at 300 Hz: 60 Hz about 12 dB down (+- 1)",
        ((peakDb.(chanOf.(idx.(\eqShelf), 0)) - peakDb.(chanOf.(idx.(\eqShelf), 1))) + 12).abs < 1,
        (peakDb.(chanOf.(idx.(\eqShelf), 0)) - peakDb.(chanOf.(idx.(\eqShelf), 1))).round(0.01).asString ++ " dB");
    // -6 dBFS at -18, 4:1, no knee: 12 dB over comes out 3 dB over, -15 dBFS.
    ok.("Compressor, -18 dB 4:1: a sine at -6 dBFS comes out at -15 (+- 0.5)",
        (peakDb.(chanOf.(idx.(\compOver), 0)) + 15).abs < 0.5, peakDb.(chanOf.(idx.(\compOver), 0)).round(0.01).asString);
    ok.("...one under the threshold, as it came (within 0.05 dB)",
        (peakDb.(chanOf.(idx.(\compUnder), 0)) - peakDb.(chanOf.(idx.(\compUnder), 1))).abs < 0.05,
        (peakDb.(chanOf.(idx.(\compUnder), 0)) - peakDb.(chanOf.(idx.(\compUnder), 1))).round(0.001).asString ++ " dB");
    ok.("...and 6 dB of makeup puts it at -9 (+- 0.5)",
        (peakDb.(chanOf.(idx.(\compMakeup), 0)) + 9).abs < 0.5, peakDb.(chanOf.(idx.(\compMakeup), 0)).round(0.01).asString);
    ok.("Noise Gate at -50 dB: a sine at -60 shut (below -130 dBFS)",
        peakDb.(chanOf.(idx.(\gateShut), 0)) < -130, peakDb.(chanOf.(idx.(\gateShut), 0)).round(0.1).asString);
    ok.("...one at -40 through, as it came (within 0.05 dB)",
        (peakDb.(chanOf.(idx.(\gateOpen), 0)) - peakDb.(chanOf.(idx.(\gateOpen), 1))).abs < 0.05,
        (peakDb.(chanOf.(idx.(\gateOpen), 0)) - peakDb.(chanOf.(idx.(\gateOpen), 1))).round(0.001).asString ++ " dB");
    ok.("...with Range -20, the shut one 20 dB down (+- 0.5)",
        ((peakDb.(chanOf.(idx.(\gateRange), 0)) - peakDb.(chanOf.(idx.(\gateRange), 1))) + 20).abs < 0.5,
        (peakDb.(chanOf.(idx.(\gateRange), 0)) - peakDb.(chanOf.(idx.(\gateRange), 1))).round(0.01).asString ++ " dB");
    // Keyed: a sine at -30, under the threshold, and a key at -6, 12 dB
    // over it, which 4:1 turns down by 9 dB: -39 dBFS.
    ok.("Compressor keyed by another chain at -6: a sine at -30 turned down to -39 (+- 0.5)",
        (peakDb.(chanOf.(idx.(\keyLoud), 0)) + 39).abs < 0.5, peakDb.(chanOf.(idx.(\keyLoud), 0)).round(0.01).asString);
    ok.("...the same with the key's chain run after it in the block, a block late (+- 0.5)",
        (peakDb.(chanOf.(idx.(\keyLater), 0)) + 39).abs < 0.5, peakDb.(chanOf.(idx.(\keyLater), 0)).round(0.01).asString);
    [\keyQuiet, "...a key at -40, under the threshold, leaves it as it came",
        \keyItself, "...Key Itself hears the sine, under the threshold, not the loud key: as it came",
        \keyUnknown, "...with no key busses given it hears itself: as it came"].pairsDo { |label, text|
        ok.(text ++ " (within 0.05 dB)",
            (peakDb.(chanOf.(idx.(label), 0)) - peakDb.(chanOf.(idx.(label), 1))).abs < 0.05,
            (peakDb.(chanOf.(idx.(label), 0)) - peakDb.(chanOf.(idx.(label), 1))).round(0.001).asString ++ " dB");
    };
    ok.("Key Filter at 300 Hz: a 100 Hz key at -6 still turns it down to -39 (+- 0.75)",
        (peakDb.(chanOf.(idx.(\keyLows), 0)) + 39).abs < 0.75, peakDb.(chanOf.(idx.(\keyLows), 0)).round(0.01).asString);
    ok.("...a 4 kHz one doesn't: as it came (within 0.05 dB)",
        (peakDb.(chanOf.(idx.(\keyHighs), 0)) - peakDb.(chanOf.(idx.(\keyHighs), 1))).abs < 0.05,
        (peakDb.(chanOf.(idx.(\keyHighs), 0)) - peakDb.(chanOf.(idx.(\keyHighs), 1))).round(0.001).asString ++ " dB");
    [osc, wav].do { |f| if(File.exists(f)) { File.delete(f) } };
    File.delete(tmp);
    "".postln;
    if(fail == 0) { ("NRT UTILITY PASSED — " ++ pass ++ " checks").postln; 0.exit } {
        ("NRT UTILITY FAILED — " ++ fail ++ " of " ++ (pass + fail)).postln;
        fails.do { |f| ("  " ++ f).postln };
        1.exit;
    };
};
)
