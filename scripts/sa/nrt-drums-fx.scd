// Megalooper SA, Phase 4: the drum effects and Beat Repeat in scsynth,
// non-realtime (headless).
//
//     /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/sa/nrt-drums-fx.scd
//
// What MegaSADrumsFx's defs and MegaSADrums' Beat Repeat take on trust,
// rendered for real and read back sample by sample:
//
//   1. the drums' reverb: a click through \megaSADrumsFx at mix 1, on a unit
//      impulse response, comes out 480 samples (the 10 ms predelay) after the
//      dry click: PartConv's 448 at fft 1024 and a block of 64, plus the wet's
//      own 32;
//   2. with the set's impulse responses (presets/sa/drums/kits/_ir/, written
//      by tools/export-live-set.py kits), white noise L = R at mix 1 comes out
//      within 1 dB of the input's RMS on both sides;
//   3. mix 0, and irOn 0 on the zero spectrum MegaSADrums starts it on, give
//      the input back exactly, and that start posts no PartConv error;
//   4. its Dry/Wet is linear: at the set's 15.08 % the output is 0.8492 x the
//      dry plus 0.1508 x the wet, sample by sample (noise, on the unit
//      response); its wet's low cut is a 12 dB/oct high-pass at 80 Hz: a
//      40 Hz sine comes out 12.3 dB down, a 1 kHz one as it went in;
//   5. the onset kit's chain (\megaSAOnsetFx): a -30 dBFS kick comes out about
//      5 dB louder than through the same chain without its parallel compressor
//      (the makeup lifting what is under the threshold), and 10.71 dB over the
//      dry kick in all, as measured when the chain was built (a pin: a stage
//      lost or doubled moves it); EQ Three on its own gives 100 Hz, 1 kHz and
//      10 kHz sines at -30 dBFS what its law gives them;
//   6. ...a full-scale kick, and one 12 dB over full scale, peak under 0 dBFS,
//      and no sample anywhere is NaN or inf;
//   7. Beat Repeat's band filter in the voice (pads 36-40): a sine at its
//      centre (1515 Hz) passes within half a dB of what the two Butterworth
//      stages give there, one at 150 Hz or 15 kHz comes out more than 20 dB
//      down;
//   8. Beat Repeat end to end: MegaSADrums on a stub server, its dice forced,
//      plays a hat (hard left) and a retriggering pad (hard right) on a
//      capture point, and the bundles it sends, rendered with the real voices,
//      hold each hit and its 5 repeats at the times, levels and lengths the
//      laws give, the right side's last repeat cut at the gate.
//
// Every synth sits in a group emptied before the end (/g_freeAll), and every
// effect synth, which owns memory (PartConv, DelayN), is freed by one /n_free
// of its own: a synth like that still running at the end of a render hangs
// scsynth for good, and a multi-id /n_free stops at the first node already
// gone. No audio device is touched; the scores and renders go to a folder of
// this run's own (two runs at once must not share files), deleted at the end.
//
// Prints PASS, FAIL or SKIP per check and NRT DRUMS FX PASSED at the end;
// exits 1 on any failure. A missing or short render (scsynth stopped by its
// watchdog) and an error in the checks are failures too: a headless sclang
// that throws would otherwise idle for good, its exit never reached. A check
// that needs the impulse responses is skipped (and said so) where they have
// not been built.
(
var sr = 48000, block = 64;
// Beside SuperCollider's resources on macOS, on the shell's path on Linux.
var scsynth = MegaSAPlugins.scsynthPath;
// UniqueID counts from the same number in every sclang, so it cannot tell two
// runs apart; the process id can.
var tmpDir = (Platform.defaultTempDir ? "/tmp") +/+ "megalooper-sa"
    +/+ ("nrt-drums-fx-" ++ Date.getDate.stamp ++ "-" ++ thisProcess.pid);
var kitDir = MegaSADrums.defaultKitDir;
var fails = 0, passes = 0, skips = 0;
var check, skip, tail, render, readBack, finite, rms, peak, firstOver, windows, channel, eqLaw, highPassLaw;
var irPaths, irFrames, haveIR, specSize, score, numOut = 48, endT = 3.5, said, data, frames, ok;
// Private busses, above the render's 48 outputs.
var busA = 80, busB = 82, busC = 84, busD = 86, busE = 88, busRef = 100;
var busCut40 = 90, busCut1k = 92, eqSines = [[100, 94, 42], [1000, 96, 43], [10000, 98, 44]];
var sines = [[1515.18, 1], [1515.18, 0], [150, 1], [15000, 1]], sineBufs = (20 .. 23), band, bandAt = 2.0;
var irBufs = [0, 1, 2, 3], irSpecs = [4, 5, 6, 7], deltaIr = 8, deltaSpec = 9, zeroSpec = 10, dummySpec = 11;
var fxIds = (2001 .. 2016), sources = 1000, effects = 1001;
var clickAt = 0.2 + (21 / sr), dryAt, wetAt, a, b, c, lift, gain, peaks, nan, mixErr, cut, eqGot, eqWant;
// The effects are freed 20 ms before the end; the sources run 10 ms longer.
var until = ((endT - 0.03) * sr).asInteger;
var brDir, drums, log, wall, run, brScore, tc, times, voicesBase, res, left, right, s0;
var expectL, expectR, gateEnd;

check = { |label, cond, detail|
    if(cond == true) { passes = passes + 1; ("  PASS  " ++ label).postln } {
        fails = fails + 1;
        ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
    };
};
skip = { |label, why| skips = skips + 1; ("  SKIP  " ++ label ++ " — " ++ why).postln };
// The last lines scsynth printed, for a failure's message.
tail = { |text| (text ? "").split($\n).reject(_.isEmpty).keep(-4).join(" | ") };
// Render a score of `dur` seconds to a float WAV and read it back: [data,
// frames, what scsynth said]. No render, or a short one (scsynth stopped by its
// watchdog), throws. The entries go in time order (a stable sort: at one time
// they keep theirs, a buffer's /b_alloc before its /b_gen).
render = { |name, entries, outs, dur|
    var osc = tmpDir +/+ (name ++ ".osc"), wav = tmpDir +/+ (name ++ ".wav"), cmd, sf, buf, n;
    var want = (dur * sr).floor.asInteger;
    Score(entries.copy.sort { |x, y| x[0] <= y[0] }).writeOSCFile(osc);
    // perl's alarm survives the exec, so the watchdog signals scsynth itself.
    // A far UDP port: an NRT scsynth binds one too, and must not take the launcher's.
    cmd = "perl -e 'alarm shift; exec @ARGV' 120 " ++ scsynth.quote ++ " -u " ++ (58800 + 150.rand) ++ " -N " ++ osc.quote ++ " _ "
        ++ wav.quote ++ " " ++ sr ++ " WAV float -o " ++ outs ++ " -i 0 2>&1";
    said = cmd.unixCmdGetStdOut;
    said.split($\n).do { |line|
        if(line.contains("FAILURE") or: { line.contains("rror") } or: { line.contains("late") }) {
            ("  scsynth: " ++ line).postln;
        };
    };
    sf = SoundFile.openRead(wav);
    if(sf.isNil) { Error(name ++ ": no render (scsynth: " ++ tail.(said) ++ ")").throw };
    n = sf.numFrames;
    if(n < want) {
        sf.close;
        Error(name ++ ": a short render, " ++ n ++ " of " ++ want ++ " frames (scsynth: " ++ tail.(said) ++ ")").throw;
    };
    buf = FloatArray.newClear(n * sf.numChannels);
    sf.readData(buf);
    sf.close;
    File.delete(osc);
    File.delete(wav);
    [buf, n, said]
};
channel = { |res, outs, ch| Array.fill(res[1], { |i| res[0][(i * outs) + ch] }) };
finite = { |x| x.isNaN.not and: { x.abs != inf } };
rms = { |xs, from, to| (xs.copyRange(from, to - 1).collect(_.squared).sum / (to - from)).sqrt };
peak = { |xs| xs.collect(_.abs).maxItem };
firstOver = { |xs, level| xs.detectIndex { |x| x.abs > level } };
// Runs of samples over `level`: [first, last] each.
windows = { |xs, level|
    var out = List.new, start;
    xs.do { |x, i|
        if(x.abs > level) { if(start.isNil) { start = i } } {
            if(start.notNil) { out.add([start, i - 1]); start = nil };
        };
    };
    start !? { |s| out.add([s, xs.size - 1]) };
    out
};
// What SC's 2nd-order Butterworth filters do at f, in dB: they are the analog
// prototype at w = tan(pi f / sr) / tan(pi fc / sr) (a bilinear transform
// prewarped at fc). EQ Three as MegaSADrumsFx.eqThree builds it, with the onset
// chain's settings: full * mid + low * (lowGain - mid) + high * (highGain - mid),
// low and high two stages each. And one high-pass stage, the reverb's low cut.
eqLaw = { |f|
    var eq = MegaSADrumsFx.onsetEq, mid = eq[\midDb].dbamp;
    var wl = tan((pi * f) / sr) / tan((pi * eq[\lowFreq]) / sr);
    var wh = tan((pi * f) / sr) / tan((pi * eq[\highFreq]) / sr);
    var lp = Complex(1, 0) / Complex(1 - wl.squared, 2.sqrt * wl);
    var hp = Complex(wh.squared.neg, 0) / Complex(1 - wh.squared, 2.sqrt * wh);
    ((Complex(mid, 0) + ((lp * lp) * (eq[\lowDb].dbamp - mid))) + ((hp * hp) * (eq[\highDb].dbamp - mid))).magnitude.ampdb
};
highPassLaw = { |f, fc|
    var w = tan((pi * f) / sr) / tan((pi * fc) / sr);
    (w.squared / ((1 - w.squared).squared + (2 * w.squared)).sqrt).ampdb
};

try {
    MegaSADrums.loadSynthDefs;
    if([\megaSADrumsFx, \megaSAOnsetFx, \megaSADrumVoice1].any { |n| SynthDescLib.global[n].isNil }) {
        Error("the SynthDefs did not build").throw;
    };
    File.mkdir(tmpDir);

    // ---- 1-7: the effects ----------------------------------------------------
    // Sines for the band filter, 0.3 s at 0.5, through files (a score's messages
    // are better small).
    sines.do { |fs, i|
        var sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(1).sampleRate_(sr);
        sf.openWrite(tmpDir +/+ ("nrt-sine-" ++ i ++ ".wav"));
        sf.writeData(Signal.fill((0.3 * sr).asInteger, { |j| 0.5 * sin((2pi * fs[0]) * (j / sr)) }));
        sf.close;
    };
    irPaths = kitDir !? { |d| MegaSADrumsFx.irInfo(d) !? { |i| i[\files] } };
    irFrames = irPaths !? { |ps| ps.collect { |p| MegaSAKit.probeFile(p) !? { |h| h[\numFrames] } } };
    haveIR = irFrames.notNil and: { irFrames.every(_.notNil) };
    specSize = { |n| PartConv.calcBufSize(MegaSADrumsFx.fftSize, (numFrames: n)).asInteger };
    score = [
        SynthDef(\nrtClick, { |out, ref|
            var x = Impulse.ar(0);
            OffsetOut.ar(out, [x, x]);
            OffsetOut.ar(ref, x);
        }),
        // Seeded, so the wet level measured is the same every run.
        SynthDef(\nrtNoise, { |out, ref, amp = 0.25|
            var seed = RandSeed.ir(1, 1966);
            var n = WhiteNoise.ar(amp);
            Out.ar(out, [n, n]);
            Out.ar(ref, n);
        }),
        // A kick: a sine swept down from 150 to 45 Hz under a 400 ms decay,
        // peaking at about `amp`.
        SynthDef(\nrtKick, { |out, ref, amp = 1|
            var sig = SinOsc.ar(XLine.kr(150, 45, 0.1), 0.5pi) * EnvGen.ar(Env.perc(0.0005, 0.4), doneAction: 2) * amp;
            Out.ar(out, [sig, sig]);
            Out.ar(ref, sig);
        }),
        SynthDef(\nrtOnsetNoComp, { |in, out|
            Out.ar(out, MegaSADrumsFx.onsetChain(In.ar(in, 2), 0));
        }),
        SynthDef(\nrtSine, { |out, freq = 1000, amp = 0.25|
            var x = SinOsc.ar(freq, 0, amp);
            Out.ar(out, [x, x]);
        }),
        // EQ Three alone, as the onset chain sets it.
        SynthDef(\nrtEqThree, { |in, out|
            var eq = MegaSADrumsFx.onsetEq;
            Out.ar(out, MegaSADrumsFx.eqThree(In.ar(in, 1), eq[\lowDb], eq[\midDb], eq[\highDb], eq[\lowFreq], eq[\highFreq]));
        })
    ].collect { |d| [0.0, [\d_recv, d.asBytes]] }
        ++ [\megaSADrumsFx, \megaSAOnsetFx, \megaSADrumVoice1].collect { |n| [0.0, [\d_recv, SynthDescLib.global[n].def.asBytes]] }
        ++ sines.collect { |fs, i| [0.0, [\b_allocRead, sineBufs[i], tmpDir +/+ ("nrt-sine-" ++ i ++ ".wav"), 0, 0]] }
        ++ [[0.0, [\c_set, 100, 0]], [0.0, [\c_set, 101, 0]]]
        ++ sines.collect { |fs, i|
            [bandAt, [\s_new, \megaSADrumVoice1, -1, 1, sources, \out, 24 + (2 * i), \buf, sineBufs[i], \amp, 1, \rate, 1,
                \pan, 0, \startFrames, 0, \dur, 0, \drive, 0, \cancelBus, 100, \chokeBus, 101, \chokeOn, 0, \hitId, 1,
                \release, 0.005, \bpOn, fs[1], \bpFreq, MegaSADrumsFx.beatRepeatFilterFreq,
                \bpRq, MegaSADrumsFx.bandRq(MegaSADrumsFx.beatRepeatFilterWidth)]]
        }
        ++ [
            [0.0, [\g_new, sources, 0, 0]],
            [0.0, [\g_new, effects, 3, sources]],
            // A unit impulse response, and the zero spectra (allocated zeros).
            [0.0, [\b_alloc, deltaIr, 2000, 1]],
            [0.0, [\b_set, deltaIr, 0, 1.0]],
            [0.0, [\b_alloc, deltaSpec, specSize.(2000), 1]],
            [0.0, [\b_gen, deltaSpec, "PreparePartConv", deltaIr, MegaSADrumsFx.fftSize]],
            [0.0, [\b_alloc, zeroSpec, specSize.(2000), 1]],
            [0.0, [\b_alloc, dummySpec, MegaSADrumsFx.fftSize, 1]]
        ]
        ++ if(haveIR) {
            irPaths.collect { |p, i| [0.0, [\b_allocRead, irBufs[i], p, 0, 0]] }
                ++ irFrames.collect { |n, i| [0.0, [\b_alloc, irSpecs[i], specSize.(n), 1]] }
                ++ irSpecs.collect { |s, i| [0.0, [\b_gen, s, "PreparePartConv", irBufs[i], MegaSADrumsFx.fftSize]] }
        } { [] }
        ++ [
            // The effects, after every source.
            [0.0, [\s_new, \megaSADrumsFx, fxIds[0], 1, effects, \in, busA, \out, 0, \mix, 1, \irOn, 1,
                \ll, deltaSpec, \lr, zeroSpec, \rl, zeroSpec, \rr, deltaSpec]],
            [0.0, [\s_new, \megaSADrumsFx, fxIds[1], 1, effects, \in, busB, \out, 4, \mix, 1, \irOn, 1]
                ++ MegaSADrumsFx.irKeys.collect { |k, i| [k, if(haveIR) { irSpecs[i] } { zeroSpec }] }.flat],
            [0.0, [\s_new, \megaSADrumsFx, fxIds[2], 1, effects, \in, busB, \out, 7, \mix, 0, \irOn, 1]
                ++ MegaSADrumsFx.irKeys.collect { |k, i| [k, if(haveIR) { irSpecs[i] } { zeroSpec }] }.flat],
            [0.0, [\s_new, \megaSADrumsFx, fxIds[3], 1, effects, \in, busB, \out, 9, \mix, 0.1508, \irOn, 0]
                ++ MegaSADrumsFx.irKeys.collect { |k| [k, dummySpec] }.flat],
            [0.0, [\s_new, \megaSAOnsetFx, fxIds[4], 1, effects, \in, busC, \out, 11]],
            [0.0, [\s_new, \nrtOnsetNoComp, fxIds[5], 1, effects, \in, busC, \out, 13]],
            [0.0, [\s_new, \megaSAOnsetFx, fxIds[6], 1, effects, \in, busD, \out, 16]],
            [0.0, [\s_new, \megaSAOnsetFx, fxIds[7], 1, effects, \in, busE, \out, 18]]
        ]
        // 4: the noise through the unit response at mix 0, 1 and the set's
        // 15.08 %; sines at 40 Hz and 1 kHz through the wet alone.
        ++ [[busB, 32, 0], [busB, 34, 1], [busB, 36, 0.1508], [busCut40, 38, 1], [busCut1k, 40, 1]].collect { |s, i|
            [0.0, [\s_new, \megaSADrumsFx, fxIds[8 + i], 1, effects, \in, s[0], \out, s[1], \mix, s[2], \irOn, 1,
                \ll, deltaSpec, \lr, zeroSpec, \rl, zeroSpec, \rr, deltaSpec]]
        }
        // 5: EQ Three alone, a sine each.
        ++ eqSines.collect { |s, i| [0.0, [\s_new, \nrtEqThree, fxIds[13 + i], 1, effects, \in, s[1], \out, s[2]]] }
        ++ [
            // The sources.
            [clickAt, [\s_new, \nrtClick, -1, 1, sources, \out, busA, \ref, 2]],
            [0.1, [\s_new, \nrtNoise, -1, 1, sources, \out, busB, \ref, 6, \amp, 0.25]],
            [0.5, [\s_new, \nrtKick, -1, 1, sources, \out, busC, \ref, 15, \amp, -30.dbamp]],
            [0.5, [\s_new, \nrtKick, -1, 1, sources, \out, busD, \ref, busRef, \amp, 1]],
            [1.5, [\s_new, \nrtKick, -1, 1, sources, \out, busE, \ref, busRef, \amp, 12.dbamp]],
            [0.1, [\s_new, \nrtSine, -1, 1, sources, \out, busCut40, \freq, 40, \amp, 0.25]],
            [0.1, [\s_new, \nrtSine, -1, 1, sources, \out, busCut1k, \freq, 1000, \amp, 0.25]]
        ]
        ++ eqSines.collect { |s| [0.1, [\s_new, \nrtSine, -1, 1, sources, \out, s[1], \freq, s[0], \amp, -30.dbamp]] }
        ++ fxIds.collect { |id| [endT - 0.02, [\n_free, id]] }
        ++ [
            [endT - 0.01, [\g_freeAll, sources]],
            [endT - 0.01, [\g_freeAll, effects]],
            [endT, [\c_set, 0, 0]]
        ];
    res = render.("nrt-drums-fx", score, numOut, endT);

    "== the drums' reverb ==".postln;
    dryAt = firstOver.(channel.(res, numOut, 2), 0.5);
    wetAt = firstOver.(channel.(res, numOut, 0), 0.5);
    check.("a click at mix 1 on a unit response comes out 480 samples (10 ms) after the dry one",
        dryAt.notNil and: { wetAt.notNil } and: { ((wetAt - dryAt) - 480).abs <= 1 },
        "dry at " ++ dryAt ++ ", wet at " ++ wetAt ++ " (" ++ (wetAt !? { |w| dryAt !? { |d| w - d } }) ++ ")");
    check.("...through its own side only (in L to out L: the cross responses here are zero)",
        (channel.(res, numOut, 1)[wetAt ? 0] - channel.(res, numOut, 0)[wetAt ? 0]).abs < 1e-6);
    if(haveIR) {
        a = channel.(res, numOut, 6);
        b = [4, 5].collect { |ch| (rms.(channel.(res, numOut, ch), (0.6 * sr).asInteger, (3.0 * sr).asInteger)
            / rms.(a, (0.6 * sr).asInteger, (3.0 * sr).asInteger)).ampdb };
        check.("white noise L = R through the set's responses at mix 1: the wet within 1 dB of the input on both sides",
            b.every { |x| x.abs <= 1 }, "L " ++ b[0].round(0.01) ++ " dB, R " ++ b[1].round(0.01) ++ " dB");
        ("  measured: wet RMS re input L " ++ b[0].round(0.01) ++ " dB, R " ++ b[1].round(0.01) ++ " dB").postln;
        check.("mix 0 with the responses in: exactly the input, both sides",
            [7, 8].every { |ch| var x = channel.(res, numOut, ch); (0 .. (until - 1)).every { |i| a[i] == x[i] } });
    } {
        skip.("the set's responses: wet within 1 dB, and mix 0 exact", "no impulse responses in "
            ++ (kitDir ? "the kits folder") ++ "/_ir (python3 tools/export-live-set.py kits)");
    };
    a = channel.(res, numOut, 6);
    check.("irOn 0 on the zero spectrum MegaSADrums starts it on: exactly the input, whatever the mix",
        [9, 10].every { |ch| var x = channel.(res, numOut, ch); (0 .. (until - 1)).every { |i| a[i] == x[i] } });
    check.("...and no PartConv error from that start", res[2].contains("PartConv").not, res[2]);
    // 4: one side at a time, from 0.3 s (the wet long in) to where the effects go.
    mixErr = [0, 1].collect { |side|
        var dry = channel.(res, numOut, 32 + side), wet = channel.(res, numOut, 34 + side);
        var got = channel.(res, numOut, 36 + side);
        ((0.3 * sr).asInteger .. (until - 1)).collect { |i| (got[i] - ((dry[i] * (1 - 0.1508)) + (wet[i] * 0.1508))).abs }.maxItem
    }.maxItem;
    check.("Dry/Wet at the set's 15.08 % is linear: 0.8492 x the dry + 0.1508 x the wet, sample by sample, within 1e-4",
        mixErr < 1e-4, "largest difference " ++ mixErr);
    cut = [38, 40].collect { |ch| (rms.(channel.(res, numOut, ch), (0.5 * sr).asInteger, (3.0 * sr).asInteger) / (0.25 / 2.sqrt)).ampdb };
    check.("the wet's low cut, 12 dB/oct at 80 Hz: a 40 Hz sine " ++ highPassLaw.(40, 80).round(0.01)
        ++ " dB (within 0.1 dB), a 1 kHz one at 0 dB (within 0.05 dB)",
        ((cut[0] - highPassLaw.(40, 80)).abs < 0.1) and: { (cut[1] - highPassLaw.(1000, 80)).abs < 0.05 },
        "40 Hz " ++ cut[0].round(0.001) ++ " dB, 1 kHz " ++ cut[1].round(0.001) ++ " dB");
    ("  measured: Dry/Wet at 15.08 % off the linear law by " ++ mixErr ++ " at most; the wet's 40 Hz "
        ++ cut[0].round(0.001) ++ " dB, 1 kHz " ++ cut[1].round(0.001) ++ " dB").postln;

    "== Beat Repeat's band filter ==".postln;
    band = sines.collect { |fs, i|
        (rms.(channel.(res, numOut, 24 + (2 * i)), ((bandAt + 0.05) * sr).asInteger, ((bandAt + 0.25) * sr).asInteger)
            / (0.5 / 2.sqrt)).ampdb
    };
    check.("a sine at the band's centre through the voice's filter: within 0.5 dB of the two Butterworth stages' -0.23 dB",
        (band[0] - -0.23).abs < 0.5, band[0].round(0.01).asString ++ " dB");
    check.("...the voice without it passes the sine at its level", band[1].abs < 0.01, band[1].round(0.001).asString ++ " dB");
    check.("...and the band's outside, 150 Hz and 15 kHz, comes out more than 20 dB down", (band[2] < -20) and: { band[3] < -20 },
        [band[2], band[3]].collect { |x| x.round(0.1) }.asString ++ " dB");
    ("  measured: 1515 Hz " ++ band[0].round(0.01) ++ " dB, 150 Hz " ++ band[2].round(0.1) ++ " dB, 15 kHz "
        ++ band[3].round(0.1) ++ " dB (edges " ++ MegaSADrumsFx.bandEdges(MegaSADrumsFx.beatRepeatFilterFreq,
            MegaSADrumsFx.bandRq(MegaSADrumsFx.beatRepeatFilterWidth)).collect { |f| f.round(1) } ++ " Hz)").postln;

    "== the onset kit's chain ==".postln;
    a = channel.(res, numOut, 11);
    b = channel.(res, numOut, 13);
    c = channel.(res, numOut, 15);
    lift = (rms.(a, (0.5 * sr).asInteger, (0.9 * sr).asInteger) / rms.(b, (0.5 * sr).asInteger, (0.9 * sr).asInteger)).ampdb;
    gain = (rms.(a, (0.5 * sr).asInteger, (0.9 * sr).asInteger) / rms.(c, (0.5 * sr).asInteger, (0.9 * sr).asInteger)).ampdb;
    check.("a -30 dBFS kick: about 5 dB over the chain without its parallel compressor (the review's +5 dB)",
        (lift - 5.26).abs < 0.5, lift.round(0.01).asString ++ " dB");
    check.("...and 10.71 dB over the dry kick through the whole chain, as measured when it was built (within 0.5 dB)",
        (gain - 10.71).abs < 0.5, gain.round(0.01).asString ++ " dB");
    ("  measured: the parallel compressor's lift " ++ lift.round(0.01) ++ " dB; the whole chain's gain over the dry "
        ++ "kick " ++ gain.round(0.01) ++ " dB (nominally: drive and Utility +2.3, the compressor +5.3, EQ Three's "
        ++ "lows up to +1.8 as the kick's spectrum has them, Squash +1.2, the Limiter +1.1)").postln;
    // 5: EQ Three's bands sum to the input at 0 dB; boosted, a band adds at its
    // filters' phase, so the low band's +1.84 dB comes to +0.89 dB at 100 Hz.
    eqGot = eqSines.collect { |s|
        (rms.(channel.(res, numOut, s[2]), (0.5 * sr).asInteger, (3.0 * sr).asInteger) / (-30.dbamp / 2.sqrt)).ampdb
    };
    eqWant = eqSines.collect { |s| eqLaw.(s[0]) };
    check.("EQ Three alone, sines at -30 dBFS: 100 Hz " ++ eqWant[0].round(0.01) ++ " dB, 1 kHz "
        ++ eqWant[1].round(0.01) ++ " dB, 10 kHz " ++ eqWant[2].round(0.01) ++ " dB, as its law gives (within 0.02 dB)",
        eqGot.every { |x, i| (x - eqWant[i]).abs < 0.02 }, eqGot.collect { |x| x.round(0.001) }.asString ++ " dB");
    ("  measured: EQ Three alone " ++ eqGot.collect { |x| x.round(0.001) } ++ " dB at " ++ eqSines.collect(_.first)
        ++ " Hz; 100 Hz over 1 kHz " ++ (eqGot[0] - eqGot[1]).round(0.01) ++ " dB (the low band's "
        ++ MegaSADrumsFx.onsetEq[\lowDb] ++ " dB less its crossover's phase)").postln;
    peaks = [16, 17, 18, 19].collect { |ch| peak.(channel.(res, numOut, ch)) };
    check.("a full-scale kick through the chain peaks under 0 dBFS", peaks[0..1].every { |p| p < 1 },
        peaks[0..1].collect { |p| p.ampdb.round(0.01) }.asString ++ " dBFS");
    check.("...and one 12 dB over full scale too (the soft clip at -0.3 dBFS)", peaks[2..3].every { |p| p <= (-0.3).dbamp },
        peaks[2..3].collect { |p| p.ampdb.round(0.01) }.asString ++ " dBFS");
    ("  measured: peaks at full scale " ++ peaks[0].ampdb.round(0.01) ++ " dBFS, at +12 dB "
        ++ peaks[2].ampdb.round(0.01) ++ " dBFS").postln;
    nan = res[0].detectIndex { |x| finite.(x).not };
    check.("no sample anywhere is NaN or inf", nan.isNil, "first at " ++ nan);

    // ---- 8: Beat Repeat --------------------------------------------------------
    // A kit of two pads, each a DC sample so a level is a number: 42 (choke group
    // 1, 60 ms, hard left) and 41 (retriggering, 120 ms, hard right), no velocity
    // response. Both play step 6 of every bar: the capture point.
    "== Beat Repeat ==".postln;
    brDir = tmpDir +/+ "br";
    File.mkdir(brDir);
    [["h", 2880], ["r", 5760]].do { |f|
        var sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(1).sampleRate_(sr);
        sf.openWrite(brDir +/+ (f[0] ++ ".wav"));
        sf.writeData(Signal.fill(f[1], { 1.0 }));
        sf.close;
    };
    File.use(brDir +/+ "nrtbr.json", "w", { |f|
        f.write("{ \"version\": 1, \"key\": \"nrtbr\", \"name\": \"NRT\", \"groups\": { \"carbon\": \"Carbon\" }, \"pads\": { "
            ++ "\"42\": { \"choke\": 1, \"pan\": -1, \"beatRepeat\": true, \"layers\": [ { \"group\": \"carbon\", \"file\": \"h.wav\" } ] }, "
            ++ "\"41\": { \"retrigger\": true, \"pan\": 1, \"beatRepeat\": true, \"layers\": [ { \"group\": \"carbon\", \"file\": \"r.wav\" } ] } } }")
    });
    log = List.new;
    wall = 10.0;
    drums = MegaSADrums((server: (sampleRate: sr)));
    drums.prUseBusses(stepsBus: 0);
    drums.wallClock = { wall };
    drums.sender = { |t, msgs| log.add([t, msgs, wall]) };
    drums.randSeed = 1;
    drums.repeatChance = 1;
    // Beat Repeat starts off on SA (Live's recordings held about one stutter
    // in twelve minutes): this check is about the repeats, so switch them on.
    drums.setRepeats(true, 9.0);
    drums.kitDir = brDir;
    drums.kitReader = { |srv, path, done|
        var n = if(PathName(path).fileNameWithoutExtension == "h") { 0 } { 1 };
        done.((bufnum: n, path: path, numChannels: 1, sampleRate: sr, numFrames: if(n == 0) { 2880 } { 5760 }));
    };
    drums.setKit(\steps, \nrtbr);
    drums.setAnalysis((numerator: 4, denominator: 4, k: 1, bpm: 120, loopDur: 2.0));
    4.do { |lane|
        drums.setSteps(\main, \chance, lane, Array.fill(16, { |i| if((lane < 2) and: { i == 6 }) { 6 } { 0 } }));
        drums.setSteps(\main, \alt, lane, Array.fill(16, 0));
        drums.setSteps(\main, \roll, lane, Array.fill(16, 0));
    };
    drums.setLaneParam(\main, 0, \note, 42);
    drums.setLaneParam(\main, 1, \note, 41);
    drums.transportStart(10.0);
    while { wall < 11.9 } { wall = wall + 0.01; drums.pump(wall) };
    // The capture point: 6/16 after the transport's boundary (10.1).
    tc = 10.1 + 0.75;
    gateEnd = tc + 0.75;
    times = MegaSADrumsFx.beatRepeatTimes(0.125);
    voicesBase = 9.5;
    brScore = [\megaSADrumVoice1, \megaSADrumVoice2].collect { |n| [0.0, [\d_recv, SynthDescLib.global[n].def.asBytes]] }
        ++ [
            [0.0, [\g_new, 1000, 0, 0]],
            [0.0, [\g_new, 1001, 1, 1000]],
            [0.0, [\g_new, 1002, 1, 1000]],
            [0.0, [\g_new, 1003, 1, 1000]],
            [0.0, [\b_allocRead, 0, brDir +/+ "h.wav", 0, 0]],
            [0.0, [\b_allocRead, 1, brDir +/+ "r.wav", 0, 0]],
            [0.0, [\c_setn, 1000, 1024] ++ Array.fill(1024, 0)],
            [0.0, [\c_setn, 3048, 33] ++ Array.fill(33, 0)]
        ]
        ++ log.collect { |b| b[1].collect { |m| [(b[0] ? b[2]) - voicesBase, m] } }.flatten(1)
        ++ [
            [3.0 - 0.01, [\g_freeAll, 1001]],
            [3.0 - 0.01, [\g_freeAll, 1002]],
            [3.0 - 0.01, [\g_freeAll, 1003]],
            [3.0, [\c_set, 0, 0]]
        ];
    brScore = brScore.sort { |x, y| x[0] <= y[0] };
    res = render.("nrt-drums-br", brScore, 2, 3.0);
    left = windows.(channel.(res, 2, 0), 1e-3);
    right = windows.(channel.(res, 2, 1), 1e-3);
    s0 = ((tc + 0.02) - voicesBase) * sr;
    // What should sound up to the next bar's hit: the hit, then repeat k from
    // tc + its start, at its level, the slice's part of the sample at its rate.
    expectL = [[s0, 0.06 * sr, 1]] ++ times.collect { |t, i|
        [s0 + (t[0] * sr), (0.06 / MegaSADrumsFx.beatRepeatRate(i + 1)) * sr, MegaSADrumsFx.beatRepeatLevel(i + 1)] };
    expectR = [[s0, 0.12 * sr, 1]] ++ times.collect { |t, i|
        [s0 + (t[0] * sr), ((0.12 / MegaSADrumsFx.beatRepeatRate(i + 1)).min(t[1] + 0.005)) * sr,
            MegaSADrumsFx.beatRepeatLevel(i + 1)] };
    left = left.select { |w| w[0] < (s0 + (1.9 * sr)) };
    right = right.select { |w| w[0] < (s0 + (1.9 * sr)) };
    check.("a hat on the capture point and its 5 repeats, nothing else (left)", left.size == 6, left.size.asString ++ " windows");
    check.("...each starting where the laws put it, to the sample",
        (left.size == 6) and: { left.every { |w, i| (w[0] - expectL[i][0]).abs <= 1 } },
        left.collect { |w, i| w[0] - (expectL[i] !? { |e| e[0].round } ? 0) }.asString);
    check.("...at its level (the hit at 1, repeat k at exp(-10 * 0.29365^2 * k / 4))",
        (left.size == 6) and: { left.every { |w, i|
            var mid = channel.(res, 2, 0).copyRange(w[0] + 10, ((w[0] + w[1]) / 2).asInteger).median;
            (mid - expectL[i][2]).abs < 1e-4 } },
        left.collect { |w| channel.(res, 2, 0)[w[0] + 20].round(1e-4) }.asString);
    // A voice is freed at the end of the block in which its sample ends (PlayBuf's
    // done action), so a window may run on by up to a block.
    check.("...each lasting its 60 ms of sample at its rate (to the end of the block it ends in)",
        (left.size == 6) and: { left.every { |w, i| var over = ((w[1] - w[0]) + 1) - expectL[i][1]; (over > -2) and: { over < (block + 1) } } },
        left.collect { |w, i| ((w[1] - w[0]) + 1) - (expectL[i] !? { |e| e[1].round } ? 0) }.asString);
    check.("a retriggering pad likewise (right): the hit and 5 repeats", right.size == 6, right.size.asString ++ " windows");
    check.("...at the same starts and levels",
        (right.size == 6) and: { right.every { |w, i| ((w[0] - expectR[i][0]).abs <= 1)
            and: { (channel.(res, 2, 1)[w[0] + 20] - expectR[i][2]).abs < 1e-4 } } });
    check.("...its 120 ms at each rate, the fifth cut at the gate (6/16 after the capture, then its 5 ms release)",
        (right.size == 6) and: { right.drop(-1).every { |w, i| var over = ((w[1] - w[0]) + 1) - expectR[i][1]; (over > -2) and: { over < (block + 1) } } }
            and: { right.last[1] < (((gateEnd + 0.02 + 0.007) - voicesBase) * sr) }
            and: { right.last[1] > (((gateEnd + 0.02) - voicesBase) * sr) },
        right.collect { |w| (w[1] - w[0]) + 1 }.asString ++ " samples; the gate at "
            ++ (((gateEnd + 0.02) - voicesBase) * sr).round ++ ", the last window ends at " ++ (right.last !? { |w| w[1] }));
    ("  measured: repeat starts after the hit " ++ left.drop(1).collect { |w| ((w[0] - left[0][0]) / sr * 1000).round(0.01) }
        ++ " ms; levels " ++ left.collect { |w| channel.(res, 2, 0)[w[0] + 20].ampdb.round(0.01) } ++ " dB").postln;
    nan = res[0].detectIndex { |x| finite.(x).not };
    check.("...no sample NaN or inf", nan.isNil, "first at " ++ nan);
    drums.free;
} { |err|
    fails = fails + 1;
    ("  FAIL  " ++ err.errorString.replace("ERROR: ", "")).postln;
    // Ours are plain Errors; anything else is a bug in the checks, with its stack.
    if(err.class !== Error) { err.reportError };
};
brDir !? { |d| (d +/+ "*").pathMatch.do { |p| File.delete(p) }; File.delete(d) };
(tmpDir +/+ "*").pathMatch.do { |p| File.delete(p) };
File.delete(tmpDir);

(passes.asString ++ " passed, " ++ fails ++ " failed" ++ if(skips > 0) { ", " ++ skips ++ " skipped" } { "" }).postln;
if(fails == 0) { "NRT DRUMS FX PASSED".postln; 0.exit } { "NRT DRUMS FX FAILED".postln; 1.exit };
)
