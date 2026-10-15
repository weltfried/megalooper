// Megalooper SA, Phase 4: the drum voices in scsynth, non-realtime (headless).
//
//     /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/sa/nrt-drum-voices.scd
//
// What MegaSADrums' scheduler takes on trust from \megaSADrumVoice1 and
// \megaSADrumVoice2 (MegaSADrums.loadSynthDefs), rendered for real and read
// back sample by sample:
//
//   1. a hit stamped at sample k starts at sample k (OffsetOut), at its full
//      level from its first sample, the same on both sides at the centre;
//      off centre the near side stays and the far side falls (a balance);
//   2. a cancelled hit (its cancel bus set before it starts) writes exactly
//      zero samples;
//   3. two hits of one choke group starting in one block: one block later
//      only the later one sounds in full, the earlier one releasing; it is gone
//      about 5 ms later (its release), without a click;
//   4. the layers of one hit (one hit id) do not choke each other;
//   5. a later-starting hit with a LOWER id still chokes the earlier one;
//   6. a hit without a choke leaves every other control bus as it was,
//      bus 0 included, and its scratch bus too;
//   7. dur ends a voice where it says; the stereo voice plays both channels;
//   8. a sample at another rate than the server's plays at its own speed
//      (BufRateScale): a 44.1 kHz and a 96 kHz file of 0.1 s each last 0.1 s
//      here (the default kits' samples are almost all 44.1 kHz, the 808,
//      909, 707 and C78 kits' 96 kHz);
//   9. drive, the One Hit Kit's pre-gain into tanh, is in dB and comes before
//      the level: tanh(x * drive.dbamp) * amp;
//  10. a cancelled hit beside a ringing hit of its own choke group leaves the
//      ringing one alone (a break, PC 17 or a stop that cancels a pending hat
//      must not cut the open hat already sounding).
//
// The busses and buffers are the score's own (DC buffers, and DC files at
// 44.1 and 96 kHz, so a level is a number); nothing reads the kits. Every
// voice is in one group and the reader in another, both emptied before the
// end with /g_freeAll: voices free themselves, and a multi-id /n_free stops at
// the first one gone, which would leave the rest running and hang scsynth for
// good at the end of the render. No audio device is touched. The score, the
// files and the render go to a folder of this run's own, deleted at the end:
// two runs at once must not share files.
//
// Prints PASS or FAIL per check and NRT DRUM VOICES PASSED at the end; exits 1
// on any failure. A missing or short render (scsynth stopped by its watchdog)
// and an error in the checks are failures too: a headless sclang that throws
// would otherwise idle for good, its exit never reached.
(
var sr = 48000, block = 64, endT = 1.0;
// Beside SuperCollider's resources on macOS, on the shell's path on Linux.
var scsynth = MegaSAPlugins.scsynthPath;
// UniqueID counts from the same number in every sclang, so it cannot tell two
// runs apart; the process id can.
var tmpDir = (Platform.defaultTempDir ? "/tmp") +/+ "megalooper-sa"
    +/+ ("nrt-drum-voices-" ++ Date.getDate.stamp ++ "-" ++ thisProcess.pid);
var oscPath = tmpDir +/+ "nrt-drum-voices.osc", outPath = tmpDir +/+ "nrt-drum-voices.wav";
var numOut = 34, watchdogSec = 60, minFrames = (endT * sr).floor.asInteger;
var voices = 1000, readers = 1001;
// The output pair each test voice writes (every voice is stereo out).
var ch = (centre: 0, panned: 2, cancelled: 4, earlier: 6, later: 8, layerA: 10, layerB: 12,
    highId: 14, lowId: 16, noChoke: 18, stereo: 20, busDiff: 23, rate44: 24, rate96: 26, drive: 28,
    ringing: 30, cancelledBeside: 32);
// Check 8's files, 0.1 s of DC 1 each: [rate, frames, buffer].
var rateFiles = [[44100, 4410, 3], [96000, 9600, 4]];
// Check 9: the onset kit's kick (one-hit, Kick Electrified) has a drive of 6.844 dB.
var driveDb = 6.844, driveAmp = 0.5, driveWant = (0.5 * driveDb.dbamp).tanh * driveAmp;
var fails = 0, passes = 0;
var check, at, voice, tail, defs, score, cmd, said, sf, data, frames, sample, full, firstNonZero, lastNonZero;
var t1, t2, t3, t4, t5a, t5b, t6, t7, t8, t9, t10a, t10b, sentinels, maxStep, relStart, relEnd, rel, n, lens, wantLen;

check = { |label, ok, detail|
    if(ok == true) { passes = passes + 1; ("  PASS  " ++ label).postln } {
        fails = fails + 1;
        ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
    };
};
// The time of sample k: a stamp that falls on it exactly.
at = { |k| k / sr };
// One voice's s_new, at the tail of the voices group. `args` come after the
// defaults, and scsynth sets controls in order: a control named in them wins.
voice = { |def, out, buf, args|
    [\s_new, def, -1, 1, voices, \out, out, \buf, buf, \rate, 1, \startFrames, 0, \drive, 0,
        \release, 0.005] ++ args
};
// The last lines scsynth printed, for a failure's message.
tail = { |text| (text ? "").split($\n).reject(_.isEmpty).keep(-4).join(" | ") };

// Busses: 0..99 hold sentinels for check 6 (98 is its cancel bus, at 0; 99 its
// scratch bus, at 777); 100..115 are cancel busses; 200..232 one slot's choke
// block (16 pad busses, 16 group busses, a scratch bus).
sentinels = Array.fill(100, { |i| 1000 + i });
sentinels[98] = 0;
sentinels[99] = 777;

t1 = (block * 75) + 21;        // 1: a mono hit mid-block, centred, and one at pan -0.5
t2 = (block * 90) + 7;         // 2: a cancelled hit
t3 = (block * 150) + 5;        // 3: two hits of group 1 in one block (the second 30 later)
t4 = (block * 200) + 40;       // 4: two layers of one hit, group 2
t5a = (block * 250) + 10;      // 5: id 31 first ...
t5b = (block * 255) + 33;      //    ... then id 30, later, on pad 36's bus
t6 = (block * 300) + 3;        // 6: a hit with no choke
t7 = (block * 350) + 50;       // 7: a stereo hit with a 20 ms dur
t8 = [(block * 400) + 13, (block * 500) + 29];   // 8: the 44.1 and the 96 kHz file
t9 = (block * 600) + 45;       // 9: a driven hit
t10a = (block * 650) + 17;     // 10: a hit of group 3 ringing ...
t10b = (block * 660) + 20;     //     ... and one of group 3 cancelled, 643 samples on

try {
    MegaSADrums.loadSynthDefs;
    defs = [\megaSADrumVoice1, \megaSADrumVoice2].collect { |name| SynthDescLib.global[name] };
    if(defs.any(_.isNil)) { Error("the voice SynthDefs did not build").throw };
    File.mkdir(tmpDir);
    rateFiles.do { |f|
        var file = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(1).sampleRate_(f[0]);
        if(file.openWrite(tmpDir +/+ ("dc-" ++ f[0] ++ ".wav")).not) { Error("cannot write a file in " ++ tmpDir).throw };
        file.writeData(Signal.fill(f[1], { 1.0 }));
        file.close;
    };

    score = [[0.0, [\d_recv, SynthDef(\nrtDrumBusDiff, { |out|
            // How far busses 0..99 are from their sentinels, summed, as audio:
            // 0 throughout means nothing touched them.
            Out.ar(out, K2A.ar((In.kr(0, 100) - sentinels).abs.sum));
        }).asBytes]]]
        ++ defs.collect { |d| [0.0, [\d_recv, d.def.asBytes]] } ++ [
        [0.0, [\g_new, voices, 0, 0]],
        [0.0, [\g_new, readers, 3, voices]],
        [0.0, [\b_alloc, 0, sr, 1]],
        [0.0, [\b_alloc, 1, sr, 2]],
        [0.0, [\b_alloc, 2, sr, 1]],
        [0.0, [\b_fill, 0, 0, sr, 1.0]],
        [0.0, [\b_fill, 1, 0, sr * 2, 1.0]],
        [0.0, [\b_fill, 2, 0, sr, 0.5]]
    ] ++ rateFiles.collect { |f| [0.0, [\b_allocRead, f[2], tmpDir +/+ ("dc-" ++ f[0] ++ ".wav"), 0, 0]] } ++ [
        [0.0, [\c_setn, 0, 100] ++ sentinels],
        [0.0, [\c_setn, 100, 16] ++ Array.fill(16, 0)],
        [0.0, [\c_setn, 200, 33] ++ Array.fill(33, 0)],
        [0.0, [\s_new, \nrtDrumBusDiff, -1, 0, readers, \out, ch[\busDiff]]],
        [at.(t1), voice.(\megaSADrumVoice1, ch[\centre], 0, [\amp, 0.5, \pan, 0, \dur, 0.01,
            \cancelBus, 100, \chokeBus, 232, \chokeOn, 0, \hitId, 1])],
        [at.(t1), voice.(\megaSADrumVoice1, ch[\panned], 0, [\amp, 0.5, \pan, -0.5, \dur, 0.01,
            \cancelBus, 104, \chokeBus, 232, \chokeOn, 0, \hitId, 2])],
        [at.(t2 - 500), [\c_set, 101, 1]],
        [at.(t2), voice.(\megaSADrumVoice1, ch[\cancelled], 0, [\amp, 1, \pan, 0, \dur, 0.05,
            \cancelBus, 101, \chokeBus, 216, \chokeOn, 1, \hitId, 3])],
        [at.(t3), voice.(\megaSADrumVoice1, ch[\earlier], 0, [\amp, 1, \pan, -1, \dur, 0.2,
            \cancelBus, 102, \chokeBus, 216, \chokeOn, 1, \hitId, 10])],
        [at.(t3 + 30), voice.(\megaSADrumVoice1, ch[\later], 0, [\amp, 1, \pan, -1, \dur, 0.2,
            \cancelBus, 103, \chokeBus, 216, \chokeOn, 1, \hitId, 11])],
        [at.(t4), voice.(\megaSADrumVoice1, ch[\layerA], 0, [\amp, 1, \pan, -1, \dur, 0.1,
            \cancelBus, 105, \chokeBus, 217, \chokeOn, 1, \hitId, 20])],
        [at.(t4), voice.(\megaSADrumVoice1, ch[\layerB], 0, [\amp, 1, \pan, -1, \dur, 0.1,
            \cancelBus, 105, \chokeBus, 217, \chokeOn, 1, \hitId, 20])],
        [at.(t5a), voice.(\megaSADrumVoice1, ch[\highId], 0, [\amp, 1, \pan, -1, \dur, 0.2,
            \cancelBus, 106, \chokeBus, 200, \chokeOn, 1, \hitId, 31])],
        [at.(t5b), voice.(\megaSADrumVoice1, ch[\lowId], 0, [\amp, 1, \pan, -1, \dur, 0.2,
            \cancelBus, 107, \chokeBus, 200, \chokeOn, 1, \hitId, 30])],
        [at.(t6), voice.(\megaSADrumVoice1, ch[\noChoke], 0, [\amp, 1, \pan, -1, \dur, 0.02,
            \cancelBus, 98, \chokeBus, 99, \chokeOn, 0, \hitId, 40])],
        [at.(t7), voice.(\megaSADrumVoice2, ch[\stereo], 1, [\amp, 0.25, \pan, 0, \dur, 0.02,
            \cancelBus, 108, \chokeBus, 232, \chokeOn, 0, \hitId, 50])],
        [at.(t8[0]), voice.(\megaSADrumVoice1, ch[\rate44], rateFiles[0][2], [\amp, 1, \pan, -1, \dur, 0,
            \cancelBus, 109, \chokeBus, 232, \chokeOn, 0, \hitId, 70])],
        [at.(t8[1]), voice.(\megaSADrumVoice1, ch[\rate96], rateFiles[1][2], [\amp, 1, \pan, -1, \dur, 0,
            \cancelBus, 110, \chokeBus, 232, \chokeOn, 0, \hitId, 71])],
        [at.(t9), voice.(\megaSADrumVoice1, ch[\drive], 2, [\amp, driveAmp, \pan, -1, \dur, 0.02,
            \drive, driveDb, \cancelBus, 111, \chokeBus, 232, \chokeOn, 0, \hitId, 72])],
        [at.(t10a), voice.(\megaSADrumVoice1, ch[\ringing], 0, [\amp, 1, \pan, -1, \dur, 0.1,
            \cancelBus, 112, \chokeBus, 218, \chokeOn, 1, \hitId, 60])],
        [at.(t10b - 500), [\c_set, 113, 1]],
        [at.(t10b), voice.(\megaSADrumVoice1, ch[\cancelledBeside], 0, [\amp, 1, \pan, -1, \dur, 0.1,
            \cancelBus, 113, \chokeBus, 218, \chokeOn, 1, \hitId, 61])],
        [endT - 0.01, [\g_freeAll, voices]],
        [endT - 0.01, [\g_freeAll, readers]],
        [endT, [\c_set, 0, 0]]
    ];
    Score(score).writeOSCFile(oscPath);

    // perl's alarm survives the exec, so the watchdog signals scsynth itself.
    // A far UDP port: an NRT scsynth binds one too, and must not take the launcher's.
    cmd = "perl -e 'alarm shift; exec @ARGV' " ++ watchdogSec ++ " " ++ scsynth.quote ++ " -u " ++ (58800 + 150.rand) ++ " -N "
        ++ oscPath.quote ++ " _ " ++ outPath.quote ++ " " ++ sr ++ " WAV float -o " ++ numOut ++ " -i 0 2>&1";
    said = cmd.unixCmdGetStdOut;
    said.split($\n).do { |line|
        if(line.contains("FAILURE") or: { line.contains("rror") } or: { line.contains("late") }) {
            ("  scsynth: " ++ line).postln;
        };
    };
    sf = SoundFile.openRead(outPath);
    if(sf.isNil) { Error("no render (scsynth: " ++ tail.(said) ++ ")").throw };
    frames = sf.numFrames;
    if(frames < minFrames) {
        sf.close;
        Error("a short render, " ++ frames ++ " of " ++ minFrames ++ " frames (scsynth: " ++ tail.(said) ++ ")").throw;
    };
    data = FloatArray.newClear(frames * sf.numChannels);
    sf.readData(data);
    sf.close;
    sample = { |c, i| if((i >= 0) and: { i < frames }) { data[(i * numOut) + c] } { 0 } };
    full = { |c, i| (sample.(c, i) - 1).abs < 1e-6 };
    firstNonZero = { |c| (0 .. (frames - 1)).detect { |i| sample.(c, i) != 0 } };
    lastNonZero = { |c| (frames - 1, frames - 2 .. 0).detect { |i| sample.(c, i) != 0 } };

    "== the drum voices ==".postln;
    // 1
    check.("a hit stamped at sample " ++ t1 ++ " starts there", firstNonZero.(ch[\centre]) == t1,
        "first sample " ++ firstNonZero.(ch[\centre]));
    check.("...at its full level from that first sample, both sides at the centre",
        (t1 .. (t1 + 100)).every { |i|
            ((sample.(ch[\centre], i) - 0.5).abs < 1e-6) and: { (sample.(ch[\centre] + 1, i) - 0.5).abs < 1e-6 }
        },
        "L " ++ (t1 .. (t1 + 3)).collect { |i| sample.(ch[\centre], i) }
            ++ ", R " ++ (t1 .. (t1 + 3)).collect { |i| sample.(ch[\centre] + 1, i) });
    check.("...and nothing before it", (0 .. (t1 - 1)).every { |i|
        (sample.(ch[\centre], i) == 0) and: { sample.(ch[\centre] + 1, i) == 0 } });
    check.("off centre (pan -0.5) the near side stays and the far one falls a quarter cosine",
        ((sample.(ch[\panned], t1 + 10) - 0.5).abs < 1e-6)
            and: { (sample.(ch[\panned] + 1, t1 + 10) - (0.5 * cos(0.25pi))).abs < 1e-5 },
        "L " ++ sample.(ch[\panned], t1 + 10) ++ ", R " ++ sample.(ch[\panned] + 1, t1 + 10));
    check.("hard left the right side is exactly silent",
        (t3 .. (t3 + 500)).every { |i| sample.(ch[\earlier] + 1, i) == 0 });
    // 2
    check.("a cancelled hit writes exactly zero samples",
        firstNonZero.(ch[\cancelled]).isNil and: { firstNonZero.(ch[\cancelled] + 1).isNil },
        "a sample at " ++ firstNonZero.(ch[\cancelled]));
    // 3
    check.("two hits of one group in one block both start (ids 10, 11)",
        (firstNonZero.(ch[\earlier]) == t3) and: { firstNonZero.(ch[\later]) == (t3 + 30) },
        "starts " ++ [firstNonZero.(ch[\earlier]), firstNonZero.(ch[\later])]);
    n = ((t3 / block).floor * block).asInteger;   // their block's first sample
    check.("...one block later only the later sounds in full, the earlier releasing",
        full.(ch[\later], n + block + 63) and: { sample.(ch[\earlier], n + block + 63) < 0.999 }
            and: { full.(ch[\earlier], n + 63) },
        "end of the next block: earlier " ++ sample.(ch[\earlier], n + block + 63)
            ++ ", later " ++ sample.(ch[\later], n + block + 63));
    relStart = (t3 .. (t3 + 2000)).detect { |i| sample.(ch[\earlier], i) < 0.999 };
    relEnd = lastNonZero.(ch[\earlier]);
    rel = relEnd !? { |e| relStart !? { |s| e - s } };
    check.("...and the earlier is gone 5 ms (its release) after it began to release",
        rel.notNil and: { (rel - (0.005 * sr)).abs <= 2 }, "release " ++ rel ++ " samples");
    maxStep = rel !? { (relStart .. (relEnd + 1)).collect { |i|
        (sample.(ch[\earlier], i) - sample.(ch[\earlier], i - 1)).abs }.maxItem } ? 1;
    check.("...without a click: no step over 1 % of the level", maxStep < 0.01, "largest step " ++ maxStep);
    check.("...while the later one plays on", full.(ch[\later], t3 + 4800),
        "later at +100 ms: " ++ sample.(ch[\later], t3 + 4800));
    // 4
    check.("two layers of one hit do not choke each other",
        full.(ch[\layerA], t4 + 3000) and: { full.(ch[\layerB], t4 + 3000) },
        "at +62 ms: " ++ [sample.(ch[\layerA], t4 + 3000), sample.(ch[\layerB], t4 + 3000)]);
    // 5
    n = ((t5b / block).floor * block).asInteger;
    check.("a later hit with a lower id still chokes the earlier one",
        (sample.(ch[\highId], n + block + 63) < 0.999) and: { sample.(ch[\highId], n + (6 * block)) == 0 }
            and: { full.(ch[\lowId], n + (6 * block)) },
        "earlier " ++ [sample.(ch[\highId], n + block + 63), sample.(ch[\highId], n + (6 * block))]
            ++ ", later " ++ sample.(ch[\lowId], n + (6 * block)));
    check.("...which played in full until then", full.(ch[\highId], t5b - 10));
    // 6
    check.("a hit with no choke sounds", full.(ch[\noChoke], t6 + 100), "at +2 ms: " ++ sample.(ch[\noChoke], t6 + 100));
    check.("...and leaves busses 0..99 as they were, bus 0 and its scratch bus included",
        firstNonZero.(ch[\busDiff]).isNil,
        "first change at " ++ firstNonZero.(ch[\busDiff]) ++ ": "
            ++ (firstNonZero.(ch[\busDiff]) !? { |i| sample.(ch[\busDiff], i) }));
    // 7
    check.("the stereo voice plays both its channels at its level",
        ((sample.(ch[\stereo], t7 + 10) - 0.25).abs < 1e-6) and: { (sample.(ch[\stereo] + 1, t7 + 10) - 0.25).abs < 1e-6 },
        [sample.(ch[\stereo], t7 + 10), sample.(ch[\stereo] + 1, t7 + 10)].asString);
    check.("...and dur ends it: gone within a block and its release after its 20 ms",
        (lastNonZero.(ch[\stereo]) ? 0) < (t7 + (0.02 * sr) + block + (0.005 * sr)),
        "last sample " ++ ((lastNonZero.(ch[\stereo]) ? 0) - t7) ++ " after its start");
    check.("check 1's voice ended after its 10 ms the same way",
        (lastNonZero.(ch[\centre]) ? 0) < (t1 + (0.01 * sr) + block + (0.005 * sr)),
        "last sample " ++ ((lastNonZero.(ch[\centre]) ? 0) - t1) ++ " after its start");
    // 8: from its first sample to its last, which is at the end of the block its
    // sample ends in (PlayBuf's done action frees the voice there).
    lens = [\rate44, \rate96].collect { |k|
        (firstNonZero.(ch[k]) !? { |first| (lastNonZero.(ch[k]) - first) + 1 }) ? 0
    };
    wantLen = rateFiles.collect { |f| ((f[1] / f[0]) * sr).round.asInteger };
    [\rate44, \rate96].do { |k, i|
        var over = lens[i] - wantLen[i];
        check.(if(i == 0) { "a 44.1 kHz sample of 0.1 s plays 0.1 s here (BufRateScale): "
            ++ wantLen[i] ++ " samples from its stamp, to the end of its last block" } { "...a 96 kHz one likewise" },
            (over >= -1) and: { over <= block } and: { firstNonZero.(ch[k]) == t8[i] },
            lens[i].asString ++ " samples from " ++ firstNonZero.(ch[k]));
    };
    check.("...both at their level throughout",
        [\rate44, \rate96].every { |k, i| (t8[i] .. (t8[i] + 4700)).every { |j| full.(ch[k], j) } },
        [\rate44, \rate96].collect { |k, i| sample.(ch[k], t8[i] + 2400) }.asString);
    // 9
    check.("drive " ++ driveDb ++ " dB on a DC 0.5 at amp " ++ driveAmp ++ ": tanh(0.5 * drive.dbamp) * amp = "
        ++ driveWant.round(1e-5) ++ ", from its first sample",
        (t9 .. (t9 + 500)).every { |i| (sample.(ch[\drive], i) - driveWant).abs < 1e-5 },
        (t9 .. (t9 + 2)).collect { |i| sample.(ch[\drive], i) }.asString);
    // 10
    check.("a cancelled hit beside a ringing hit of its own group leaves the ringing one alone",
        ((t10a .. (t10b + 2000)).every { |i| full.(ch[\ringing], i) }) and: { full.(ch[\ringing], t10a + 4700) },
        "the ringing one at the cancelled one's start + 2 blocks: " ++ sample.(ch[\ringing], t10b + 128)
            ++ ", near its own end: " ++ sample.(ch[\ringing], t10a + 4700));
    check.("...and the cancelled one writes nothing",
        firstNonZero.(ch[\cancelledBeside]).isNil and: { firstNonZero.(ch[\cancelledBeside] + 1).isNil },
        "a sample at " ++ firstNonZero.(ch[\cancelledBeside]));

    ("  measured: a choked voice released over " ++ rel ++ " samples ("
        ++ (rel !? { |r| ((r / sr) * 1000).round(0.01) }) ++ " ms), its largest step " ++ maxStep.round(1e-5)
        ++ " of a level of 1; the 44.1 and 96 kHz samples of 0.1 s lasted " ++ lens ++ " samples; the render "
        ++ frames ++ " frames").postln;
} { |err|
    fails = fails + 1;
    ("  FAIL  " ++ err.errorString.replace("ERROR: ", "")).postln;
    // Ours are plain Errors; anything else is a bug in the checks, with its stack.
    if(err.class !== Error) { err.reportError };
};
(tmpDir +/+ "*").pathMatch.do { |p| File.delete(p) };
File.delete(tmpDir);
(passes.asString ++ " passed, " ++ fails ++ " failed").postln;
if(fails == 0) { "NRT DRUM VOICES PASSED".postln; 0.exit } { "NRT DRUM VOICES FAILED".postln; 1.exit };
)
