// Megalooper SA, Phase 5: a recorded set end to end in scsynth, non-realtime
// (headless): the session recorder with SA's stems, the drums' hit log and the
// set's MIDI file, on the real code paths, rendered and read back.
//
//     /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/sa/nrt-session.scd
//
// Each set builds what scripts/sa/nrt-drums.scd builds: a real MegaSA (its
// prBuild: the groups, the guitar chain, MegaSADrums with its busses, voice
// groups and effects, the strips with their stem busses and the master) and
// the Looper fixture (scripts/tests/_harness.scd's ~tLooper with the Looper's
// own \looperEngine and \looperMaster), on a stub server that writes every
// message and bundle it is sent into a score. ~setupSALooper (setup-sa.scd)
// attaches the Looper and hands its session recorder SA's stems. The drums
// play the default kits (~saDrumsDefaultKits) and the Live patterns; the loop
// is a take of real guitar (the 29 Sep 2026 set's dry tap, which also plays
// as the guitar's input all through the set), with onset notes on.
//
// The set is recorded by the REAL LooperSessionRecorder: its start (inline:
// the buffers, the WAVs left open — the master and the tap int24, the stems
// 32-bit float — and the ONE timestamped bundle that starts every DiskOut
// synth go into the score) and its stop (inline: the ONE bundle that frees
// them, stamped the start's latency after the stop, at stopAt; the set's
// tail, in which its log stays open and the drums go on telling it what was
// heard before stopAt; then, closeWait after stopAt, the closes). The stub
// runs scsynth -N on the score at the moment the last of a set's buffers is
// freed, so the DiskOut synths really write the master, the dry tap and the
// four stems before the recorder reads their length (the interface's clock
// against the Mac's), decides the set's tempo and names, ends its log,
// renames every file and writes the .mid, as it does on stage once the server
// has let go of the files. Between start and stop: the drums' Start through
// the Looper's own MIDI clock, a break (Looper.fireBreak), PC 17 off for two
// passes and on again, and the stop 30 ms after a steps hit was heard (the
// last moments of a set; the 0.2 s after the stop are its tail).
//
// Then it checks what a player takes into Live:
//   1. every file under its final name (<stamp>-<bpm>bpm-<num>-<den>-<role>),
//      the log's files event naming them, the readers finding them;
//   2. the WAVs: frame 0 at the start of the control block the start bundle
//      runs in, their end at the start of the block the stamped free (stopAt)
//      runs in, every frame as the server computed it (the float stems bit
//      for bit), the stems summing to the master (before its clip), the drums
//      stem silent while PC 17 has the steps off; no DiskOut synth that
//      outlives its set (the record group's node tree, dumped in-score); the
//      files event's end, length and clock against the WAVs;
//   3. every note of the .mid, at ticks / 480 * 60 / bpm, on its hit's onset
//      in the drums stem (the onset notes in the onset stem), within half a
//      block and half a tick (the recorder's wavTime: frame 0 half a block
//      before audioAt, the interface's clock from the WAVs' length), all
//      through the set; every hit the WAVs hold in it, the break's and the
//      tail's too, the cancelled ones not, nothing heard at or after stopAt;
//   4. every hit line of the log on its onset the same way; every hit heard
//      from the stomp to stopAt logged once (the last ones before the stop
//      and the tail's too), and nothing else;
//   5. the Live hint (bar 1's place in the files, the shift) against the
//      drums' downbeat as it really is in the drums stem;
//   6. an independent parse of the .mid in python3 (standard library only)
//      agreeing with what the hits say it must hold, and with LooperMidiFile.
// An onset is measured, not assumed: a matched filter on the first
// difference of the stem against each voice group's own attack (its kit
// sample read from disk, at its rate, gain and pan), over +-96 samples round
// where its stamp puts it.
//
// Four sets:
//   4-4     201.09 BPM 4/4, the recorder started before the take, Beat Repeat
//           on; its start bundle 10 samples into a control block.
//   7-8     165.04 BPM 7/8, the recorder started while the drums play (the
//           .mid's first marker "drums playing"); 58 samples in.
//   clock   123.45 BPM 4/4, started while the drums play, on an interface
//           whose crystal runs 500 ppm fast: the stub's score time is
//           t0 + (t - t0) * (1 + 500e-6) of every host time it records
//           (t0 = 0), so the render is what that crystal would have recorded
//           against the Mac's clock. The recorder must read that clock from
//           the WAVs' length and keep the .mid on the stems with it, about
//           thirty seconds long; at the Mac's clock the notes would be more
//           than a block off by the end. The drums' drift probe gets no server
//           replies here, so their dHat stays 0: the drums follow the Mac's
//           clock, not the loop's, which is all this set needs.
//   double  165.04 BPM 7/8, a double press: a start, a stop 80 ms later
//           (inside the start bundle's 0.2 s), then a set of some five
//           seconds on the same recorder and stub. Rendered at each set's
//           close (the second render sends the first set's DiskOuts to scratch
//           files, the first set's files being renamed by then): no "Node not
//           found", no DiskOut node that outlives its set, the second set's
//           WAVs exactly as long as their stamps say and holding what the
//           server computed, the first set's a valid tiny set.
//
// NRT_SESSION_ONLY=44, 78, clock or double (or several, comma-separated) runs
// those sets; NRT_SESSION_KEEP=1 keeps every file (the temporary folder is
// posted); NRT_SESSION_BURNS=n burns time with n synths (default 12) from
// each stop's stopAt to its closes, and NRT_SESSION_RECBURNS=n with n
// (default 4) while each set records, for the render's disk thread (see
// buildScore); NRT_SESSION_RING=n gives DiskOut a ring of n frames
// (LooperSessionRecorder.bufFrames, default 2^20 here, see `ring`). The
// scores free every synth before their end (one /n_free per
// long-lived node, /g_freeAll per voice group). Nothing is written outside
// the run's own temporary folder.
//
// Prints PASS / FAIL per check, NOTEs and the measurements, a summary per set,
// and NRT SESSION PASSED at the end; exits 1 on any failure. An error in a
// set is a failure too: a headless sclang that throws would otherwise idle for
// good.
(
var sr = 48000, block = 64, numOut = 14, numIn = 2;
// The real-time pool, in KB: the \sa profile's, unless NRT_SESSION_MEMKB
// says otherwise (scripts/sa/nrt-memory.sh bisects it to find what a set
// takes, for MegaSA.memReserve).
var memKB = ("NRT_SESSION_MEMKB".getenv ? "65536").asInteger;
var repo = (thisProcess.nowExecutingPath !? { |p| if(p[0] == $/) { p.dirname.dirname.dirname } }) ?? { Looper.repoRoot };
// Beside SuperCollider's resources on macOS, on the shell's path on Linux.
var scsynth = MegaSAPlugins.scsynthPath;
// UniqueID counts from the same number in every sclang; the process id and
// the time tell two runs apart.
var tmpDir = (Platform.defaultTempDir ? "/tmp") +/+ "megalooper-sa"
    +/+ ("nrt-session-" ++ Date.getDate.stamp ++ "-" ++ thisProcess.pid);
var takeTap = repo +/+ "sessions" +/+ "260929_100616-tap.wav";
var keep = "NRT_SESSION_KEEP".getenv == "1";
// How many synths burn time between a stop's stopAt and its closes, and while
// a set records (buildScore).
var burns = ("NRT_SESSION_BURNS".getenv ? "12").asInteger;
var recBurns = ("NRT_SESSION_RECBURNS".getenv ? "4").asInteger;
// DiskOut's ring for the render: 2^20 frames (22 s at 48 k), where the rig's
// is 65536 (1.4 s). The rig's server writes in real time, so 1.4 s is slack
// no disk-thread stall uses up; the render writes up to forty times faster,
// so the same ring gives the disk thread tens of ms, and the burns while
// recording (buildScore) only made a lapped ring rarer: the clock set still
// failed one run of the full checks in about six, 2026-10-27. Sized to the
// render's speed, the ring is the same machinery with the same slack.
var ring = ("NRT_SESSION_RING".getenv ? "1048576").asInteger;
var only = "NRT_SESSION_ONLY".getenv !? { |v| v.split($,) };
var wants = { |part| only.isNil or: { only.any { |x| x == part } } };
// The render's outputs: SA's master (the mix as it leaves for the interface),
// then the busses the recorder records from, read in the render too, so each
// WAV can be held against what the server computed: the four stem busses,
// and the two voice busses dry (before the reverb and the onset chain).
var chMaster = 0, chLoop = 2, chDrums = 4, chOnset = 6, chGuitar = 8, chStepsDry = 10, chOnsetDry = 12;
// scsynth -N's control block in OSC time (2 ** 32 a second), truncated as
// SC_World.cpp has it: a bundle at t runs before the block whose end is the
// first at or after t, the voices' OffsetOut from its offset into it.
var oscInc = ((64 * 4294967296.0) / 48000).floor;
var lsb = 2 ** -23;
// The recorder's constants as its design states them: the latency its start
// and its stop are stamped with, the wait from stopAt to the closes, and
// frame 0 expected half a block before audioAt, less half a sample
// (frame0Lead), here worked out on its own.
var latency = LooperSessionRecorder.startLatency, closeWait = LooperSessionRecorder.closeWait;
var lead = ((block - 1) / 2) / sr;
// A log time is rounded to 0.1 ms, so a difference of two is good to 4.8 samples.
var logRound = (2 * 0.00005) * sr;
var fails = 0, passes = 0, notes = List.new, timings = List.new, sets = List.new, kept = List.new;
var check, note, say, histo, histoStr, fixed, spread, tryPart;
var makeStub, readerFor, writeWav, makeAudio, makeRig, spawnAndAnalyse, runTimeline, sounding, startOf, breakAt;
var buildScore, render, readAll, readWav, chanOf, wavDiff, tapDiff, freeRig, rmTree, dumpCheck;
var blockOf, startSample, fileCache = Dictionary.new, fileOf, cubic, biquad, templateOf, voicesOf, detect, voiceEnd;
var pyLines, runPython, noteOffs, readLog, numAfter, recStart, recStop, renderSet, captureSet, freesOf, startOfSet;
var playSet, checkRun, checkFiles, prepare, checkWavs, checkClock, measure, checkLog, checkMidi, checkHint, checkDouble, checkFirstSet;
var runSet, summarize, main;

LooperSessionRecorder.bufFrames = ring;

// ---------------------------------------------------------------- helpers --
check = { |label, cond, detail|
    if(cond == true) { passes = passes + 1; ("  PASS  " ++ label).postln } {
        fails = fails + 1;
        ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
    };
    cond == true
};
note = { |line| notes.add(line); ("  NOTE  " ++ line).postln };
say = { |line| ("  " ++ line).postln };
histo = { |xs| var h = Dictionary.new; xs.do { |x| h[x] = (h[x] ? 0) + 1 }; h };
histoStr = { |h| h.keys.asArray.sort.collect { |k| (if(k > 0) { "+" } { "" }) ++ k ++ ": " ++ h[k] }.join(", ") };
// x with exactly d decimals (Float:asString drops trailing zeros).
fixed = { |x, d = 2|
    var scale = (10 ** d).round.asInteger, n = (x.abs * scale).round.asInteger;
    (if((x < 0) and: { n > 0 }) { "-" } { "" }) ++ (n div: scale).asString
        ++ (if(d > 0) { "." ++ (n % scale).asString.padLeft(d, "0") } { "" })
};
spread = { |xs|
    if(xs.isEmpty) { "none" } {
        xs.minItem.round(0.01).asString ++ " .. " ++ xs.maxItem.round(0.01) ++ " (mean " ++ xs.mean.round(0.01)
            ++ ", " ++ xs.size ++ ")"
    }
};
// A part of a set's checks that throws is a failure of its own; the others run.
tryPart = { |label, fn|
    try { fn.value } { |err|
        fails = fails + 1;
        ("  FAIL  " ++ label ++ " threw: " ++ err.errorString).postln;
        err.reportError;
    };
};

// A stub server for one set: it answers what MegaSA, MegaSADrums, the Looper,
// the session recorder and the Buffers and Busses they make ask of a server,
// and writes every message into rig[\log] as [host time, [msg, ...]]: an
// immediate one at rig[\wall] (the set's "now"), a bundle at now plus its
// delta. Its score puts each at rig[\toScore] of that time (the interface's
// clock). Every message is also shown to rig[\onMsg], which renders the score
// once the recorder has freed the last of a set's buffers. Node IDs count up
// from 2000; audio busses start after the render's outputs and inputs, as on
// scsynth.
makeStub = { |rig|
    var opts = ServerOptions.new.numOutputBusChannels_(numOut).numInputBusChannels_(numIn);
    var srv = (sampleRate: sr, latency: 0.2, options: opts,
        controlBusAllocator: ContiguousBlockAllocator(16384),
        audioBusAllocator: ContiguousBlockAllocator(1024 - (numOut + numIn), 0, numOut + numIn),
        bufferAllocator: ContiguousBlockAllocator(1024));
    var told = { |msg| rig[\onMsg] !? { |f| f.value(msg) } };
    srv[\sendMsg] = { |self ... args| rig[\log].add([rig[\wall], [args]]); told.(args); self };
    srv[\listSendMsg] = { |self, msg| var m = msg.asArray; rig[\log].add([rig[\wall], [m]]); told.(m); self };
    srv[\sendBundle] = { |self, time ... args| rig[\log].add([rig[\wall] + (time ? 0), args]); self };
    srv[\listSendBundle] = { |self, time, list| rig[\log].add([rig[\wall] + (time ? 0), list.asArray]); self };
    srv[\sync] = { |self| self };
    srv[\nextNodeID] = { |self| var id = (self[\lastNodeID] ? 1999) + 1; self[\lastNodeID] = id; id };
    srv[\nextBufferNumber] = { |self, n = 1| self[\bufferAllocator].alloc(n) };
    srv[\defaultGroup] = Group.basicNew(srv, 1);
    srv[\asTarget] = { |self| self[\defaultGroup] };
    srv
};

// The drums' kitReader and irReader: a Buffer on the stub, its file read
// into it by the score at the time the read was asked for.
readerFor = { |rig|
    { |srv, path, done|
        var sf = SoundFile.openRead(path), buf;
        if(sf.isNil) { done.(nil) } {
            buf = Buffer.new(srv, sf.numFrames, sf.numChannels, srv.nextBufferNumber(1));
            buf.sampleRate = sf.sampleRate;
            buf.path = path;
            sf.close;
            rig[\log].add([rig[\wall], [[\b_allocRead, buf.bufnum, path, 0, -1]]]);
            done.(buf);
        };
    }
};

writeWav = { |path, data, chans|
    var sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(chans).sampleRate_(sr);
    if(sf.openWrite(path).not) { Error("cannot write " ++ path).throw };
    sf.writeData(data.as(FloatArray));
    sf.close;
    path
};

// The guitar the set is played with (the input file's first channel: the
// guitar's own input, which the chain and the dry tap read) and the loop's
// take, both from the 29 Sep 2026 set's dry tap (3 s in, the take's press
// 34 ms later), at a peak of 0.3; plucked tones without it. Answers the
// input's samples, for the dry tap to be held against.
makeAudio = { |cfg, frames, secs|
    var n = (secs * sr).ceil.asInteger, mono = FloatArray.newClear(n), sf, src, nch, i = 0, gain, input, loop, off, ph, f;
    sf = SoundFile.openRead(takeTap);
    if(sf.notNil) {
        nch = sf.numChannels;
        src = FloatArray.newClear(n * nch);
        sf.seek((3.0 * sf.sampleRate).round.asInteger, 0);
        sf.readData(src);
        sf.close;
        while { i < n } { mono[i] = src[i * nch]; i = i + 1 };
    } {
        note.("no " ++ takeTap.basename ++ ": the guitar and the loop are plucked tones");
        while { i < n } {
            ph = (i % 17760) / sr;
            f = [196, 247, 294, 330, 392][(i div: 17760) % 5];
            mono[i] = (sin((2pi * f) * ph) * exp(-6 * ph)) * 0.3;
            i = i + 1;
        };
    };
    gain = 0.3 / mono.abs.maxItem.max(1e-6);
    input = FloatArray.newClear(n * 2);
    i = 0;
    while { i < n } { mono[i] = mono[i] * gain; input[i * 2] = mono[i]; i = i + 1 };
    writeWav.(cfg[\inPath], input, 2);
    off = (0.034 * sr).round.asInteger;
    loop = FloatArray.newClear(frames * 2);
    i = 0;
    while { i < frames } { loop[i * 2] = mono[off + i]; loop[(i * 2) + 1] = mono[off + i]; i = i + 1 };
    writeWav.(cfg[\loopPath], loop, 2);
    mono
};

// One SA rig, as boot.scd and setup-sa.scd leave it: MegaSA built, the drums
// with the default kits from the repository's kits folder, the Looper with
// SA's channels (it records the guitar chain and plays into the mixer; the
// analysis and the session's dry tap read the guitar's own input; the
// session's master is the mix), then ~setupSALooper: the loop's effects, the
// recorder moved after the mixer, the drums on the Looper, and the stems.
// The interface's clock is `clockE` fast against the Mac's (0: the same).
makeRig = { |cfg|
    var e = cfg[\clockE] ? 0;
    var rig = (log: List.new, wall: 0.0, seen: IdentitySet.new, routines: List.new, cfg: cfg, e: e,
        renders: List.new, renderedPaths: List.new, dumps: List.new, starts: List.new, stops: List.new);
    var stub, sa, d, l, outBus, insertBus, phaseBus, buf, taps;
    rig[\toScore] = { |t| t * (1 + e) };
    stub = makeStub.(rig);
    rig[\stub] = stub;
    thisThread.seconds = 0;
    sa = MegaSA(stub);
    // Its init routine would build it a second time when the clock got to it.
    sa.instVarAt(\builder) !? { |r| r.stop };
    sa.prBuild;
    d = sa.drums;
    // The pump is run by hand, at the set's times.
    d.instVarAt(\pumpRoutine) !? { |r| r.stop };
    d.wallClock = { rig[\wall] };
    d.sender = { |absTime, msgs| rig[\log].add([absTime ?? { rig[\wall] }, msgs]) };
    d.randSeed = cfg[\seed] ? 1;
    d.kitReader = readerFor.(rig);
    d.irReader = readerFor.(rig);
    d.reloadReverb(true);
    d.kitDir = ~saDrumsKitDir.();
    d.setKit(\steps, ~saDrumsDefaultKits[\steps]);
    d.setKit(\onset, ~saDrumsDefaultKits[\onset]);
    if(cfg[\repeats] == true) {
        d.setRepeats(true, 0);
        cfg[\repeatChance] !? { |c| d.repeatChance = c };
    };
    l = ~tLooper.(sr);
    l.instVarPut(\server, stub);
    outBus = Bus.audio(stub, 2);
    insertBus = Bus.control(stub, 1);
    phaseBus = Bus.control(stub, 1);
    l.instVarPut(\outBus, outBus);
    l.instVarPut(\insertBus, insertBus);
    l.instVarPut(\phaseBus, phaseBus);
    l.instVarPut(\outChannel, sa.loopBus.index);
    l.instVarPut(\inChannel, sa.looperInChannel);
    // Both sides of the guitar chain, as the \sa profile records them.
    l.inChannelCount = 2;
    l.instVarPut(\analysisChannel, 0);
    l.instVarPut(\sessionChannel, sa.recordInChannel);
    l.metronome = false;
    l.declickMs = 3;
    l.breakLoops = cfg[\breakLoops] ? 2;
    // Looper.init's master: Synth.tail(server, ...) is the default group's tail.
    l.instVarPut(\masterSynth, Synth.tail(stub[\defaultGroup], \looperMaster,
        [\inBus, outBus.index, \out, l.outChannel, \amp, l.masterAmp]));
    l.sessionDir = cfg[\setDir];
    ~looper = l;
    ~megaSA = sa;
    ~rp = (sa: true);
    ~setupSALooper.();
    // The loop's buffer: the take as recorded, from frame 0.
    buf = Buffer.new(stub, cfg[\loopFrames], 2, stub.nextBufferNumber(1));
    rig[\log].add([0, [[\b_allocRead, buf.bufnum, cfg[\loopFile], 0, -1]]]);
    l.instVarPut(\buffer, buf);
    l.instVarPut(\startFrame, 0);
    l.instVarPut(\loopFrames, cfg[\loopFrames]);
    // The taps, after the master: what the server computed, to hold the WAVs
    // against.
    taps = [[sa.stemBus(\loop), chLoop], [sa.stemBus(\drums), chDrums], [sa.stemBus(\onsetKit), chOnset],
        [sa.stemBus(\guitar), chGuitar], [sa.stepsBus, chStepsDry], [sa.onsetBus, chOnsetDry]].collect { |p|
        Synth.tail(sa.mixerGroup, \nrtSessionTap, [\in, p[0].index, \out, p[1]])
    };
    rig.putAll((sa: sa, d: d, l: l, taps: taps, loopDur: cfg[\loopFrames] / sr));
    // A bus nothing reads, for the score's burn synths (buildScore).
    rig[\burnBus] = Bus.audio(stub, 1);
    rig
};

// The take ends: the engine starts at t0 exactly as spawnEngine sends it
// (Synth(defName) is the default group's head), then the analysis a moment
// later hands the reading to SA (setup-model.scd's onAnalysis) and to the
// Looper's startTempoClocks, which starts its MIDI clock: the routine that
// sends the Start, stepped from here on at its own logical times.
spawnAndAnalyse = { |rig, t0, ta|
    var l = rig[\l], stub = rig[\stub], cfg = rig[\cfg], defName, eng, r;
    defName = if(l.inChannelCount == 1) { \looperEngineMono } { \looperEngine };
    rig[\wall] = t0;
    thisThread.seconds = t0;
    eng = Synth.head(stub[\defaultGroup], defName, [
        \bufnum, l.instVarAt(\buffer).bufnum, \in, l.inChannel, \out, l.instVarAt(\outBus).index,
        \startFrame, 0, \loopFrames, l.loopFrames, \rate, if(l.reverseFlag) { -1 } { 1 },
        \recEnable, 0, \latencyFrames, l.latencyFrames, \feedback, l.feedback,
        \declickFrames, l.declickFrames, \amp, l.prLoopMix,
        \gateBus, l.instVarAt(\insertBus).index, \phaseBus, l.phaseBus.index,
        \gateMode, if(l.bbcut) { l.bbcutGateCode } { 0 }]);
    l.instVarPut(\engineSynth, eng);
    l.instVarPut(\loopStartTime, t0);
    l.startOnsetNotes;
    l.prSetState(\playing);
    rig[\wall] = ta;
    thisThread.seconds = ta;
    l.instVarPut(\lastResult, cfg[\result]);
    l.instVarPut(\analysedResult, cfg[\result]);
    cfg[\onsets] !? { |pairs| l.prBuildOnsetPattern(pairs, l.loopFrames / sr) };
    rig[\sa].setAnalysis(cfg[\result]);
    if(cfg[\onsets].notNil) { l.instVarPut(\onsetNotes, true) };
    l.startTempoClocks(cfg[\result]);
    r = l.instVarAt(\midiClockRoutine);
    r !? { rig[\routines].add([ta, r, \midiClock]) };
};

// Every step of the set in time order: the pump every 10 ms (its wall a
// little late, as SystemClock's is), the routines the Looper and the
// recorder started, and the set's own events ([time, { |rig, t| }]). Each
// runs with the drums' wall clock, the stub's "now" and thisThread.seconds
// at its time.
runTimeline = { |rig, from, to, events, jitter = 0.003|
    var d = rig[\d], evs = (events ? []).copy.sort { |a, b| a[0] <= b[0] }, ei = 0;
    var pumpAt = from, going = true, t, kind, which, entry, dt, guard = 0;
    while { going and: { guard < 2000000 } } {
        guard = guard + 1;
        t = pumpAt;
        kind = \pump;
        if((ei < evs.size) and: { evs[ei][0] <= t }) { t = evs[ei][0]; kind = \event };
        which = nil;
        rig[\routines].do { |e, i| if(e[0] < t) { t = e[0]; kind = \routine; which = i } };
        if(t > to) { going = false } {
            rig[\wall] = t;
            thisThread.seconds = t;
            switch(kind,
                \pump, {
                    rig[\wall] = t + jitter.rand;
                    d.pump(rig[\wall]);
                    d.decided.do { |rec| rig[\seen].add(rec) };
                    pumpAt = pumpAt + 0.01;
                },
                \event, {
                    evs[ei][1].value(rig, t);
                    ei = ei + 1;
                },
                \routine, {
                    entry = rig[\routines][which];
                    dt = entry[1].next;
                    if(dt.isNumber) { entry[0] = t + dt } { rig[\routines].removeAt(which) };
                }
            );
        };
    };
    d.decided.do { |rec| rig[\seen].add(rec) };
};

// What sounded: every hit record that ended emitted (a cancel sets it false).
sounding = { |rig| rig[\seen].asArray.select { |r| r[\emitted] == true }.sort { |a, b| a[\stamp] <= b[\stamp] } };

// The epoch the Start installed: its origin on the grid.
startOf = { |rig| rig[\d].instVarAt(\epochs) !? { |e| e.notEmpty.if { e.last[\t0] } } };

// A stomp `early` seconds before the heard downbeat of the boundary b, through
// the Looper's own fireBreak; its /c_get answered 2 ms later with the engine's
// phase, as the server would (on the interface's clock); the resume routine
// fireBreak starts, stepped.
breakAt = { |rig, b, early|
    var stomp = (b + 0.02) - early;
    [[stomp, { |r, t| r[\l].fireBreak; r[\breakStomp] = t }],
     [stomp + 0.002, { |r, t|
        var l = r[\l], phase = (r[\toScore].(t - 0.001) - r[\toScore].(l.loopStartTime)) % r[\loopDur];
        thisProcess.recvOSCmessage(t, NetAddr("127.0.0.1", 57110), 57120, ['/c_set', l.phaseBus.index, phase]);
        l.instVarAt(\breakRoutine) !? { |br| r[\routines].add([t, br, \break]) };
     }]]
};

// The score: the log in time order (stable) up to the set's end, each at its
// time on the interface's clock (rig[\toScore]), the defs it uses first, the
// record group's node tree dumped where rig[\dumps] asks, then every
// long-lived node freed by an /n_free of its own and every voice group
// emptied before the end. /c_get (the break's phase query) is the server's to
// answer and is left out. A set rendered before has its files on disk under
// their final names by now: here its DiskOuts write scratch files instead.
buildScore = { |rig, endT|
    var d = rig[\d], s = rig[\toScore], entries = List.new, defs = IdentitySet.new, live = List.new, seq = 0, out, voiceGroups;
    var isNew = { |m| (m[0] == 9) or: { m[0] == \s_new } or: { m[0] == "/s_new" } };
    var done = rig[\renderedPaths], writes = List.new, endS = s.(endT), k = rig[\renders].size, burnId;
    rig[\log].do { |e|
        var msgs, p;
        if(e[0] < (endT - 0.03)) {
            msgs = e[1].reject { |m| (m[0] == \c_get) or: { m[0] == "/c_get" } };
            msgs = msgs.collect { |m|
                if(m[0].asString.contains("b_write")) {
                    p = m[2].asString;
                    if(done.includesEqual(p)) {
                        m = m.copy;
                        m.put(2, tmpDir +/+ ("scratch-" ++ (k + 1) ++ "-" ++ p.basename));
                    } { writes.add(p) };
                };
                m
            };
            msgs.do { |m|
                if(isNew.(m)) {
                    defs.add(m[1].asSymbol);
                    if(m[2] > 0) { live.add(m[2]) };
                    if(m[3] == 4) { live.remove(m[4]) };
                };
                if((m[0] == 11) or: { m[0] == \n_free } or: { m[0] == "/n_free" }) { m.drop(1).do { |id| live.remove(id) } };
            };
            if(msgs.notEmpty) { entries.add([s.(e[0]), seq, msgs]); seq = seq + 1 };
        };
    };
    rig[\dumps].do { |dp|
        if(dp[0] < (endT - 0.03)) {
            entries.add([s.(dp[0]), seq, [["/g_dumpTree", rig[\sa].recordGroup.nodeID, 0]]]);
            seq = seq + 1;
        };
    };
    // NRT computes far faster than its disk thread writes (the rig renders
    // at some 40 times real time, so the 0.3 s from stopAt to the closes are
    // about 8 ms), and a DiskOut's last partial buffer goes to that thread
    // when the synth is freed: closed under it, a WAV loses it (seen here:
    // three of six files a partial buffer short, so the recorder rightly
    // found no clock in their length). From each stop's stopAt to its
    // closes, synths that only burn time slow the render, as a realtime
    // server's 0.3 s give its disk thread time to write. Nothing hears them;
    // each is freed before the end.
    rig[\stops].do { |st, i|
        if(st[\stopAt].notNil and: { (st[\stopAt] + closeWait) < (endT - 0.03) }) {
            burns.do { |j|
                burnId = (990000 + (i * 100)) + j;
                entries.add([s.(st[\stopAt]) - 0.001, seq, [[\s_new, \nrtSessionBurn, burnId, 0, 0, \out, rig[\burnBus].index]]]);
                entries.add([s.(st[\stopAt] + closeWait) + 0.01, seq + 1, [[\n_free, burnId]]]);
                seq = seq + 2;
            };
            defs.add(\nrtSessionBurn);
        };
    };
    // ...and while a set records. A DiskOut hands each half of its ring
    // (LooperSessionRecorder.bufFrames) to the disk thread as it fills; at
    // forty times real time a stall of that thread longer than a few tens of
    // ms lets the ring come round before a half is written, and the WAV then
    // holds, for a stretch, the sound one ring later. Seen 2026-10-27 in the
    // clock set, which writes eight WAVs for half a minute: four runs in five,
    // the tap wrong at 16 and 21 rings in, each stretch exactly 65536 frames
    // ahead of the input, and the stems and the master with it. recBurns
    // synths from each set's audioAt to its stopAt slow the render there.
    rig[\starts].do { |st, i|
        var from = st[\audioAt], to = (rig[\stops][i] !? { |x| x[\stopAt] }) ? (endT - 0.03);
        if(from.notNil and: { recBurns > 0 } and: { from < (endT - 0.03) } and: { to > from }) {
            recBurns.do { |j|
                burnId = (980000 + (i * 100)) + j;
                entries.add([s.(from) + 0.001, seq, [[\s_new, \nrtSessionBurn, burnId, 0, 0, \out, rig[\burnBus].index]]]);
                entries.add([s.(to.min(endT - 0.03)) - 0.002, seq + 1, [[\n_free, burnId]]]);
                seq = seq + 2;
            };
            defs.add(\nrtSessionBurn);
        };
    };
    rig[\scoreWrites] = writes;
    entries = entries.asArray.sort { |a, b| (a[0] < b[0]) or: { (a[0] == b[0]) and: { a[1] <= b[1] } } };
    out = defs.asArray.sort.collect { |n|
        var desc = SynthDescLib.global[n];
        if(desc.isNil) { Error("no SynthDef " ++ n).throw };
        [0.0, [\d_recv, desc.def.asBytes]]
    };
    out = out ++ entries.collect { |e| [e[0].max(0)] ++ e[2] };
    voiceGroups = [d.stepsGroup, d.repeatGroup, d.onsetGroup].collect(_.nodeID);
    live.reject { |id| voiceGroups.includes(id) }.do { |id| out = out.add([endS - 0.02, [\n_free, id]]) };
    voiceGroups.do { |g| out = out.add([endS - 0.01, [\g_freeAll, g]]) };
    out.add([endS, [\c_set, 0, 0]])
};

// Render a score with an input file; time it (perl's alarm survives the exec
// and signals scsynth itself; /usr/bin/time reports what it cost). No render,
// or one shorter than the score (scsynth stopped by its watchdog), throws.
// Answers what scsynth said, its complaints, and every node tree it dumped
// (the record group's: [[id, def], ...] each).
render = { |name, score, endS, inPath|
    var osc = tmpDir +/+ name ++ ".osc", wav = tmpDir +/+ name ++ ".wav", cmd, said, t0, el, nums, bad, sf, n, dumps, cur;
    var want = (endS * sr).floor.asInteger;
    Score(score).writeOSCFile(osc);
    // A far UDP port, and the real-time pool the \sa profile asks for.
    cmd = "/usr/bin/time -p perl -e 'alarm shift; exec @ARGV' 600 " ++ scsynth.quote
        ++ " -u " ++ (58800 + 150.rand) ++ " -m " ++ memKB ++ " -N " ++ osc.quote
        ++ " " ++ (inPath !? { |p| p.quote } ? "_") ++ " " ++ wav.quote ++ " " ++ sr ++ " WAV float -o " ++ numOut
        ++ " -i " ++ numIn ++ " 2>&1";
    t0 = Main.elapsedTime;
    said = cmd.unixCmdGetStdOut;
    el = Main.elapsedTime - t0;
    nums = (real: nil, user: nil, sys: nil);
    bad = List.new;
    dumps = List.new;
    said.split($\n).do { |line|
        var toks;
        [\real, \user, \sys].do { |k|
            if(line.beginsWith(k.asString ++ " ")) { nums[k] = line.split($ ).last.asFloat };
        };
        // An allocation that fails inside a UGen only says "alloc failed": the
        // effect is silent, the rest renders.
        if(line.contains("FAILURE") or: { line.contains("rror") } or: { line.contains("late ") }
            or: { line.contains("not found") } or: { line.contains("alloc") } or: { line.contains("memory") }) { bad.add(line) };
        if(line.contains("NODE TREE")) { cur = List.new; dumps.add(cur) } {
            toks = line.stripWhiteSpace.split($ ).reject(_.isEmpty);
            if(cur.notNil and: { line.beginsWith(" ") } and: { toks.size >= 2 }
                and: { toks[0].every { |c| c.isDecDigit } }) { cur.add([toks[0].asInteger, toks[1]]) } { cur = nil };
        };
    };
    bad.do { |line| ("  scsynth: " ++ line).postln };
    timings.add([name, endS, nums[\real] ? el, nums[\user], nums[\sys]]);
    if(keep.not) { File.delete(osc) };
    sf = SoundFile.openRead(wav);
    n = sf !? { |f| var k = f.numFrames; f.close; k };
    if(n.isNil or: { n < want }) {
        Error(name ++ ": " ++ (n !? { |k| "a short render, " ++ k ++ " of " ++ want ++ " frames" } ? "no render")
            ++ " (scsynth: " ++ said.split($\n).reject(_.isEmpty).keep(-4).join(" | ") ++ ")").throw;
    };
    (wav: wav, bad: bad, said: said, frames: n, dumps: dumps)
};

readAll = { |path|
    var sf = SoundFile.openRead(path), data, n, ch;
    if(sf.isNil) { Error("no file at " ++ path).throw };
    n = sf.numFrames;
    ch = sf.numChannels;
    data = FloatArray.newClear(n * ch);
    sf.readData(data);
    sf.close;
    (data: data, frames: n, chans: ch)
};

// A WAV's header and samples, or nil where there is no sound file.
readWav = { |path|
    var sf = (path.notNil and: { File.exists(path) }).if { SoundFile.openRead(path) }, data, out;
    if(sf.isNil) { nil } {
        data = FloatArray.newClear(sf.numFrames * sf.numChannels);
        sf.readData(data);
        out = (chans: sf.numChannels, rate: sf.sampleRate, format: sf.sampleFormat, header: sf.headerFormat,
            frames: sf.numFrames, data: data);
        sf.close;
        out
    }
};

chanOf = { |res, c|
    var n = res[\frames], nch = res[\chans], d = res[\data], out = FloatArray.newClear(n), i = 0;
    while { i < n } { out[i] = d[(i * nch) + c]; i = i + 1 };
    out
};

// The largest difference between a WAV and the render's outputs from channel
// `ch` on, the WAV's frame 0 at the render's frame b0.
wavDiff = { |w, res, b0, ch|
    var m = 0, j = 0, c, y, n = w[\frames], nch = w[\chans], rc = res[\chans], rd = res[\data], wd = w[\data];
    while { j < n } {
        c = 0;
        while { c < nch } {
            y = (wd[(j * nch) + c] - rd[((b0 + j) * rc) + ch + c]).abs;
            if(y > m) { m = y };
            c = c + 1;
        };
        j = j + 1;
    };
    m
};

// ...and between the dry tap and the guitar's input.
tapDiff = { |tap, input, b0|
    var m = 0, i = 0, x;
    while { i < tap.size } { x = (tap[i] - input[b0 + i]).abs; if(x > m) { m = x }; i = i + 1 };
    m
};

freeRig = { |rig|
    rig[\routines].do { |e| e[1].stop };
    rig[\l].instVarAt(\midiClockRoutine) !? { |r| r.stop };
    rig[\l].instVarAt(\breakRoutine) !? { |r| r.stop };
    rig[\sa].free;
};

rmTree = { |p|
    (p +/+ "*").pathMatch.do { |x| if(x.last == $/) { rmTree.(x.drop(-1)) } { File.delete(x) } };
    File.delete(p);
};

// The block a bundle stamped t (score time) runs before (its index), and the
// sample a voice stamped t starts on with OffsetOut: its offset into that
// block, rounded, held to the block (a stamp in a block's last half sample
// starts on its last sample, one early).
blockOf = { |t| ((t * 4294967296.0).floor / oscInc).ceil - 1 };
startSample = { |t|
    var tag = (t * 4294967296.0).floor, b = (tag / oscInc).ceil - 1;
    var off = ((((tag - (b * oscInc)) * sr) / 4294967296.0) + 0.5).floor.clip(0, block - 1);
    ((b * block) + off).asInteger
};

// The recorder's bundles in the stub's log: the one that started a set's
// DiskOut synths (the last of them so far), and those that free exactly
// these synths (n_free each, nothing else).
startOfSet = { |rig|
    rig[\log].reverse.detect { |e|
        e[1].notEmpty and: { e[1].every { |m| (m[0] == 9) and: { m[1].asString.beginsWith("looperSession") } } }
    }
};
freesOf = { |rig, ids|
    var want = (ids ? []).asArray.sort;
    rig[\log].select { |e|
        e[1].notEmpty and: { e[1].every { |m| m[0] == 11 } } and: { e[1].collect { |m| m[1] }.asArray.sort == want }
    }.asArray
};

// The record group's node trees as each render dumped them, against what it
// must hold then: a set's DiskOut synths while it records, nothing from its
// stopAt on. Answers [all as wanted, one line per dump].
dumpCheck = { |rig|
    var ok = true, rows = List.new;
    rig[\renders].do { |r, k|
        var want = rig[\dumps].select { |dp| dp[0] < ((r[\endT] ? 0) - 0.03) }.asArray.sort { |a, b| a[0] <= b[0] };
        var got = r[\dumps] ? [], ids, exp;
        if(want.size != got.size) {
            ok = false;
            rows.add("render " ++ (k + 1) ++ ": " ++ got.size ++ " trees dumped, " ++ want.size ++ " asked for");
        } {
            want.do { |dp, i|
                ids = got[i].select { |n| n[1].beginsWith("looperSession") }.collect { |n| n[0] }.asArray.sort;
                exp = (dp[2] ? []).asArray.sort;
                if((ids != exp) or: { got[i].size != ids.size }) { ok = false };
                rows.add("render " ++ (k + 1) ++ ", " ++ dp[1] ++ ": " ++ (if(got[i].isEmpty) { "empty" } {
                    got[i].collect { |n| n[0].asString ++ " " ++ n[1] }.join(", ") }));
            };
        };
    };
    [ok, rows]
};

// ------------------------------------------------- the voices' own attacks --
fileOf = { |path|
    fileCache[path] ?? {
        var sf = SoundFile.openRead(path), data, f;
        if(sf.isNil) { Error("cannot read " ++ path).throw };
        data = FloatArray.newClear(sf.numFrames * sf.numChannels);
        sf.readData(data);
        f = (data: data, frames: sf.numFrames, chans: sf.numChannels, rate: sf.sampleRate);
        sf.close;
        fileCache.put(path, f);
        f
    }
};

// PlayBuf's interpolation (SC's cubicinterp, 4-point Hermite).
cubic = { |x, y0, y1, y2, y3|
    var c1 = 0.5 * (y2 - y0), c2 = (y0 - (2.5 * y1)) + ((2 * y2) - (0.5 * y3)), c3 = (0.5 * (y3 - y0)) + (1.5 * (y1 - y2));
    (((((c3 * x) + c2) * x) + c1) * x) + y1
};

// SC's LPF and HPF (2-pole Butterworth, SC_FilterUGens.cpp) at a fixed
// frequency, from rest: Beat Repeat's band filter on a repeat's voice.
biquad = { |xs, lp, freq|
    var pf = (pi * freq) / sr, c = if(lp) { 1 / tan(pf) } { tan(pf) }, c2 = c * c, s2c = c * 2.sqrt;
    var a0 = 1 / ((1 + s2c) + c2), b1 = ((if(lp) { -2 } { 2 }) * (1 - c2)) * a0, b2 = ((1 - s2c) + c2).neg * a0;
    var y1 = 0, y2 = 0, out = FloatArray.newClear(xs.size), i = 0, y0;
    while { i < xs.size } {
        y0 = (xs[i] + (b1 * y1)) + (b2 * y2);
        out[i] = a0 * (if(lp) { (y0 + (2 * y1)) + y2 } { (y0 - (2 * y1)) + y2 });
        y2 = y1;
        y1 = y0;
        i = i + 1;
    };
    out
};

// The first k samples one voice plays, both sides, from its /s_new: its kit
// sample from startFrames at BufRateScale * rate, the drive, Beat Repeat's
// band filter, the gain and the balance, as \megaSADrumVoice has them.
templateOf = { |a, k, paths|
    var f = fileOf.(paths[a[\buf]]), n = f[\frames], nch = f[\chans], data = f[\data];
    var rateEff = (a[\rate] ? 1) * (f[\rate] / sr), start = a[\startFrames] ? 0, amp = a[\amp] ? 1;
    var pan = (a[\pan] ? 0).clip(-1, 1), far = cos(pan * 0.5pi).max(0);
    var gl = amp * (if(pan > 0) { far } { 1 }), gr = amp * (if(pan < 0) { far } { 1 });
    var drive = a[\drive] ? 0, outL = FloatArray.newClear(k), outR = FloatArray.newClear(k);
    var at = { |i, c| if(i >= n) { 0 } { data[(i.max(0) * nch) + c] } };
    var j = 0, ph, ip, x, yl, yr, band;
    while { j < k } {
        ph = start + (j * rateEff);
        ip = ph.floor.asInteger;
        x = ph - ip;
        yl = cubic.(x, at.(ip - 1, 0), at.(ip, 0), at.(ip + 1, 0), at.(ip + 2, 0));
        yr = if(nch >= 2) { cubic.(x, at.(ip - 1, 1), at.(ip, 1), at.(ip + 1, 1), at.(ip + 2, 1)) } { yl };
        if(drive > 0) { yl = (yl * drive.dbamp).tanh; yr = (yr * drive.dbamp).tanh };
        outL[j] = yl * gl;
        outR[j] = yr * gr;
        j = j + 1;
    };
    if((a[\bpOn] ? 0) > 0) {
        band = MegaSADrumsFx.bandEdges((a[\bpFreq] ? 1515).clip(20, 20000), (a[\bpRq] ? 2).clip(0.05, 8)).collect(_.clip(20, 20000));
        outL = biquad.(biquad.(outL, false, band[0]), true, band[1]);
        outR = biquad.(biquad.(outR, false, band[0]), true, band[1]);
    };
    [outL, outR]
};

// When a voice has stopped sounding at the latest (score time): its sample to
// the end, or its dur or gateLen, then its release (a choke only ends it
// sooner).
voiceEnd = { |v, paths|
    var a = v[\args], f = fileOf.(paths[a[\buf]]), len;
    len = ((f[\frames] - (a[\startFrames] ? 0)).max(0)) / (f[\rate] * (a[\rate] ? 1)).max(1e-9);
    if((a[\dur] ? 0) > 0) { len = len.min(a[\dur]) };
    if((a[\gateLen] ? 0) > 0) { len = len.min(a[\gateLen]) };
    (v[\t] + len) + (a[\release] ? 0.005)
};

// Every drum voice the score starts that sounded (its hit emitted at the end,
// by slot and hit id): (slot:, t: its time in the score, host: its stamp,
// s: its start sample in the render, args:).
voicesOf = { |rig, soundIds|
    var out = List.new, stepsIdx = rig[\sa].stepsBus.index, onsetIdx = rig[\sa].onsetBus.index, s = rig[\toScore];
    rig[\log].do { |e|
        e[1].do { |m|
            var a, slot, ts;
            if((m[0] == \s_new) and: { m[1].asString.beginsWith("megaSADrumVoice") }) {
                a = ().putPairs(m.copyToEnd(5));
                slot = case { a[\out] == stepsIdx } { \steps } { a[\out] == onsetIdx } { \onset } { nil };
                if(slot.notNil and: { soundIds.includesKey(slot.asString ++ "-" ++ a[\hitId]) }) {
                    ts = s.(e[0]);
                    out.add((slot: slot, t: ts, host: e[0], s: startSample.(ts), args: a));
                };
            };
        };
    };
    out
};

// Where each group of voices that start on one sample (s, in the render's
// frames) begins in a signal whose frame 0 is the render's frame b0: the lag
// within +-w of s - b0 at which the first difference of the signal (both
// sides) best matches the first difference of the group's own attack (the
// sum of its voices' first k samples), by normalised correlation. The first
// difference leaves out what rings on from before (low, smooth), not a new
// voice's start. Answers s -> (onset: frame in the signal, lag:, ncc:, gain:,
// second: the best correlation more than 4 samples off).
detect = { |yl, yr, voices, b0, paths, k = 64, w = 96|
    var n = yl.size, dl = FloatArray.newClear(n), dr = FloatArray.newClear(n), groups = Dictionary.new;
    var found = Dictionary.new, i = 1;
    dl[0] = yl[0];
    dr[0] = yr[0];
    while { i < n } { dl[i] = yl[i] - yl[i - 1]; dr[i] = yr[i] - yr[i - 1]; i = i + 1 };
    voices.do { |v| groups.put(v[\s], (groups[v[\s]] ? List.new).add(v)) };
    groups.keysValuesDo { |s, vs|
        var tl = FloatArray.newClear(k), tr = FloatArray.newClear(k), dtl = FloatArray.newClear(k), dtr = FloatArray.newClear(k);
        var et = 0, sf = s - b0, best, second = -1, lag, base, c, e, a, b, j, q, ncc, scores;
        vs.do { |v|
            var t = templateOf.(v[\args], k, paths), p = 0;
            while { p < k } { tl[p] = tl[p] + t[0][p]; tr[p] = tr[p] + t[1][p]; p = p + 1 };
        };
        q = 0;
        while { q < k } {
            dtl[q] = tl[q] - (if(q > 0) { tl[q - 1] } { 0 });
            dtr[q] = tr[q] - (if(q > 0) { tr[q - 1] } { 0 });
            et = et + ((dtl[q] * dtl[q]) + (dtr[q] * dtr[q]));
            q = q + 1;
        };
        if(((sf - w) >= 1) and: { ((sf + w) + k) <= n } and: { et > 0 }) {
            scores = Array.newClear((2 * w) + 1);
            lag = w.neg;
            while { lag <= w } {
                base = sf + lag;
                c = 0;
                e = 0;
                j = 0;
                while { j < k } {
                    a = dl[base + j];
                    b = dr[base + j];
                    c = (c + (a * dtl[j])) + (b * dtr[j]);
                    e = (e + (a * a)) + (b * b);
                    j = j + 1;
                };
                ncc = c / ((e * et).sqrt + 1e-30);
                scores[lag + w] = ncc;
                if(best.isNil or: { ncc > best[0] }) { best = [ncc, lag, c / et] };
                lag = lag + 1;
            };
            q = 0;
            while { q < scores.size } {
                if((((q - w) - best[1]).abs > 4) and: { scores[q] > second }) { second = scores[q] };
                q = q + 1;
            };
            found.put(s, (onset: sf + best[1], lag: best[1], ncc: best[0], gain: best[2], second: second,
                voices: vs.size, slot: vs[0][\slot]));
        } {
            found.put(s, (onset: nil, voices: vs.size, slot: vs[0][\slot]));
        };
    };
    found
};

// ------------------------------------------------- an independent MIDI parse --
// Python 3, standard library only, written to the run's folder: one line per
// thing it finds, tokens split by spaces (spaces in texts become _).
pyLines = [
    "import struct, sys",
    "def vlq(d, i):",
    "    v = 0",
    "    for _ in range(4):",
    "        b = d[i]",
    "        i += 1",
    "        v = (v << 7) | (b & 0x7F)",
    "        if b < 0x80:",
    "            return v, i",
    "    raise ValueError('a VLQ longer than four bytes')",
    "d = open(sys.argv[1], 'rb').read()",
    "if d[:4] != b'MThd':",
    "    print('BAD no_MThd')",
    "    sys.exit(1)",
    "hl, fmt, nt, div = struct.unpack('>IHHH', d[4:14])",
    "print('HEAD', hl, fmt, nt, div, len(d))",
    "i = 8 + hl",
    "for k in range(nt):",
    "    if d[i:i + 4] != b'MTrk':",
    "        print('BAD no_MTrk', k)",
    "        sys.exit(1)",
    "    (tl,) = struct.unpack('>I', d[i + 4:i + 8])",
    "    j = i + 8",
    "    end = j + tl",
    "    tick = 0",
    "    on = {}",
    "    while j < end:",
    "        dt, j = vlq(d, j)",
    "        tick += dt",
    "        b = d[j]",
    "        if b == 0xFF:",
    "            ty = d[j + 1]",
    "            ln, j2 = vlq(d, j + 2)",
    "            data = d[j2:j2 + ln]",
    "            j = j2 + ln",
    "            txt = data.decode('latin-1').replace(' ', '_')",
    "            if ty == 0x03:",
    "                print('NAME', k, tick, txt)",
    "            elif ty == 0x06:",
    "                print('MARK', k, tick, txt)",
    "            elif ty == 0x51:",
    "                print('TEMPO', k, tick, int.from_bytes(data, 'big'))",
    "            elif ty == 0x58:",
    "                print('TSIG', k, tick, data[0], data[1], data[2], data[3])",
    "            elif ty == 0x2F:",
    "                print('EOT', k, tick, int(j == end))",
    "            else:",
    "                print('META', k, tick, ty)",
    "        elif b in (0xF0, 0xF7):",
    "            ln, j2 = vlq(d, j + 1)",
    "            j = j2 + ln",
    "            print('SYSEX', k, tick)",
    "        elif b < 0x80:",
    "            print('RUNNING', k, tick)",
    "            sys.exit(1)",
    "        else:",
    "            hi = b & 0xF0",
    "            ch = b & 0x0F",
    "            n = 1 if hi in (0xC0, 0xD0) else 2",
    "            data = d[j + 1:j + 1 + n]",
    "            j += 1 + n",
    "            if hi == 0x90 and data[1] > 0:",
    "                key = (ch, data[0])",
    "                if key in on:",
    "                    print('OVERLAP', k, tick, ch, data[0])",
    "                on[key] = (tick, data[1])",
    "            elif hi == 0x80 or hi == 0x90:",
    "                key = (ch, data[0])",
    "                if key in on:",
    "                    t0, v = on.pop(key)",
    "                    print('NOTE', k, ch, data[0], v, t0, tick)",
    "                else:",
    "                    print('ORPHAN', k, tick, ch, data[0])",
    "            else:",
    "                print('MSG', k, tick, hi, ch)",
    "    if j != end:",
    "        print('BADLEN', k, j, end)",
    "    for key in on:",
    "        print('UNCLOSED', k, key[0], key[1])",
    "    i = end",
    "print('TAIL', len(d) - i)"
];

runPython = { |midPath|
    var py = tmpDir +/+ "check_mid.py", out = "";
    File.use(py, "w", { |f| f.write(pyLines.join("\n") ++ "\n") });
    ["python3", "/usr/bin/python3"].do { |exe|
        if(out.contains("HEAD").not) {
            out = ("perl -e 'alarm shift; exec @ARGV' 60 " ++ exe ++ " " ++ py.quote ++ " " ++ midPath.quote
                ++ " 2>&1").unixCmdGetStdOut;
        };
    };
    out
};

// Notes as [tick, chan, note, vel, dur] into [on, off, chan, note, vel], as a
// set's .mid must hold them (design section 5): one note per key and tick
// (the louder velocity, the longer length), each ending `dur` after it starts
// or a tick before its key starts again, and at least a tick long. Written
// here from the design, not from LooperMidiFile.
noteOffs = { |list|
    var merged = Dictionary.new, byKey = Dictionary.new, out = List.new;
    list.do { |n|
        var key = [n[0], n[1], n[2]].asString, m = merged[key];
        merged.put(key, if(m.isNil) { n } { [m[0], m[1], m[2], m[3].max(n[3]), m[4].max(n[4])] });
    };
    merged.values.do { |n| var kk = [n[1], n[2]].asString; byKey.put(kk, (byKey[kk] ? List.new).add(n)) };
    byKey.values.do { |ns|
        var sorted = ns.asArray.sort { |a, b| a[0] <= b[0] };
        sorted.do { |n, i|
            var off = n[0] + n[4];
            if((i + 1) < sorted.size) { off = off.min(sorted[i + 1][0] - 1) };
            out.add([n[0], off.max(n[0] + 1), n[1], n[2], n[3]]);
        };
    };
    out.asArray.sort { |a, b| (a[0] < b[0]) or: { (a[0] == b[0]) and: { (a[2] < b[2]) or: { (a[2] == b[2]) and: { a[3] <= b[3] } } } } }
};

// The log, one parseJSON per line (every scalar a String).
readLog = { |path|
    File.readAllString(path).split($\n).reject { |x| x.stripWhiteSpace.isEmpty }.collect { |x| x.parseJSON }
};

// The number written after `marker` in a sentence, or nil.
numAfter = { |str, marker|
    var i = str.find(marker), j, s;
    if(i.isNil) { nil } {
        s = str.copyToEnd(i + marker.size);
        j = s.detectIndex { |c| (c.isDecDigit or: { (c == $.) or: { c == $- } }).not };
        (if(j.isNil) { s } { s.copyRange(0, j - 1) }).asFloat
    }
};

// ---------------------------------------------------------------- the set --
// Looper.startSessionRecording, with the recorder's inline start: its files
// and the one bundle go to the stub at once, then the notification that gives
// the drums their first look at the set. The record group's tree is dumped
// 40 ms after its frame 0: the set's DiskOut synths, all of them.
recStart = { |rig|
    var l = rig[\l], rec = l.sessionRec, ok, st, ids;
    ok = rec.start(l.sessionChannel, l.analysisIn, l.prSessionContext, true);
    if(ok == true) { l.changed(\sessionRecording, true) };
    rig[\recOk] = ok;
    st = (ok: ok, press: rig[\wall], stamp: rec.stamp, audioAt: rec.audioAt);
    if(ok == true) {
        ids = startOfSet.(rig) !? { |e| e[1].collect { |m| m[2] }.asArray };
        st.put(\ids, ids);
        rec.audioAt !? { |a| rig[\dumps].add([a + 0.04, "while " ++ rec.stamp ++ " records", ids]) };
    };
    rig[\starts].add(st);
};

// Looper.stopSessionRecording, with the recorder's inline stop: its first
// half at once (the frees, stamped stopAt; its tail begins), the
// notification, then its second half stepped when it asks (once the WAVs
// have ended at stopAt and closeWait more: the closes; the render, by the
// stub; the clock, the log's end, the renames, the .mid, the post window).
// The record group's tree is dumped 10 ms after stopAt: nothing of the set.
recStop = { |rig, t|
    var rec = rig[\l].sessionRec, rt = Routine { rec.stop(true) }, dt;
    dt = rt.next;
    rig[\l].changed(\sessionRecording, false);
    rig[\stopPress] = t;
    rig[\stopFirst] = dt;
    rig[\stopRoutine] = rt;
    rig[\stops].add((press: t, first: dt, stamp: rec.stamp, stopAt: rec.stopAt, logging: rec.logging,
        undecided: (rec.finalPaths.isNil and: { rec.tempoInfo.isNil } and: { rec.liveHint.isNil } and: { rec.settled == false })));
    rec.stopAt !? { |sa| rig[\dumps].add([sa + 0.01, "10 ms after " ++ rec.stamp ++ "'s stopAt", []]) };
    if(dt.isNumber) { rig[\routines].add([t + dt, rt, \recStop]) };
};

// The server lets go of a set's files: the score so far, rendered, with the
// record group's tree dumped once more 40 ms before its end.
renderSet = { |rig, cfg|
    var endT = rig[\wall] + 0.25, c0 = Main.elapsedTime, k = rig[\renders].size, score, res;
    rig[\endT] = endT;
    rig[\dumps].add([endT - 0.04, "the end of render " ++ (k + 1) ++ "'s score", []]);
    res = try {
        score = buildScore.(rig, endT);
        rig[\scoreLen] = score.size;
        render.("set-" ++ cfg[\label] ++ (if(k > 0) { "-" ++ (k + 1) } { "" }), score, rig[\toScore].(endT), cfg[\inPath])
    } { |err| rig[\renderError] = err.errorString; (error: err.errorString) };
    res.put(\endT, endT);
    rig[\renders].add(res);
    rig[\rendered] = res;
    rig[\renderedPaths].addAll(rig[\scoreWrites] ? []);
    rig[\renderWall] = (rig[\renderWall] ? 0) + (Main.elapsedTime - c0);
    rig[\renderEnd] = Main.elapsedTime;
};

// What the recorder holds of the set it last stopped, taken when the next
// one starts (the double press's first set).
captureSet = { |rig|
    var rec = rig[\l].sessionRec;
    (stamp: rec.stamp, paths: rec.paths !? { |p| p.copy }, finalPaths: rec.finalPaths !? { |p| p.copy },
        audioAt: rec.audioAt, stopAt: rec.stopAt, startedAt: rec.startedAt, stoppedAt: rec.stoppedAt,
        frames: rec.wavFrames, rate: rec.clockRate, tempo: rec.tempoInfo, hint: rec.liveHint, settled: rec.settled,
        recording: rec.recording, logging: rec.logging, hits: rec.loggedHits !? { |h| h.copy },
        start: rig[\starts].last, stop: rig[\stops].last, renders: rig[\renders].size)
};

playSet = { |cfg|
    var ctx = (cfg: cfg), label = cfg[\label], bpm = cfg[\bpm], num = cfg[\num], den = cfg[\den], k = 2;
    var t0 = 0.5, ta = 0.55, c0 = Main.elapsedTime, beats, frames, n16, loopDur, s16, result, onsetIdx;
    var rig, d, l, rec, ll, b1, events, tPre, ts, cand, guard = 0, secs, rest = 0, how;
    // The pumps' jitter, the one draw that is not the drums' own dice: seeded,
    // so a run is the run before.
    thisThread.randSeed = cfg[\seed] ? 1;
    beats = ((k * num) * 4) / den;
    frames = ((beats * (60 / bpm)) * sr).asInteger;
    n16 = MegaSADrums.sixteenthsFor((numerator: num, denominator: den, k: k));
    loopDur = frames / sr;
    s16 = loopDur / n16;
    ctx.putAll((label: label, num: num, den: den, frames: frames, n16: n16, loopDur: loopDur, s16: s16,
        bpmExact: 15 / s16, t0: t0));
    ctx[\bpmR] = ((15 / s16) * 100).round / 100;
    ctx[\tag] = fixed.(ctx[\bpmR], 2) ++ "bpm-" ++ num ++ "-" ++ den;
    how = if(cfg[\midRun] == true) { "while the drums play" } { "before the take" };
    if(cfg[\double].notNil) { how = how ++ ", stopped " ++ (cfg[\double][\stopAfter] * 1000).round ++ " ms later and started again" };
    if((cfg[\clockE] ? 0) != 0) { how = how ++ ", the interface's clock " ++ ((cfg[\clockE] * 1e6).round(0.1)) ++ " ppm fast" };
    ("== a set at " ++ bpm ++ " BPM " ++ num ++ "/" ++ den ++ " (the drums' exact tempo " ++ (15 / s16).round(0.0001)
        ++ " BPM: a loop of " ++ frames ++ " frames, " ++ n16 ++ " sixteenths), the recorder started " ++ how ++ " ==").postln;
    secs = (t0 + ((cfg[\stopPass] + 3) * loopDur)) + 2;
    ctx[\input] = makeAudio.(cfg, frames, secs);
    result = (bpm: bpm, numerator: num, denominator: den, k: k, sub: 1, tau: if(den == 8) { 30 / bpm } { 60 / bpm },
        n: k * num, loopDur: loopDur, phase: 0, downbeatOffset: 0, score: 1, accent: 1);
    onsetIdx = if(n16 >= 32) { [0, 3, 6, 10, 13, 19, 22, 27, 30] } { [0, 3, 6, 10, 13, 17, 20, 24] };
    rig = makeRig.((loopFile: cfg[\loopPath], loopFrames: frames, result: result, seed: cfg[\seed],
        repeats: cfg[\repeats], repeatChance: cfg[\repeatChance], breakLoops: 2, setDir: cfg[\setDir],
        clockE: cfg[\clockE] ? 0,
        onsets: onsetIdx.collect { |i, j| [(i * (frames / n16)) / sr, 0.4 + (0.6 * ((j % 3) / 2))] }));
    d = rig[\d];
    l = rig[\l];
    rec = l.sessionRec;
    ctx.putAll((rig: rig, rec: rec, d: d, l: l));
    rec.onChange = { |r| if(r.settled and: { r.recording.not } and: { r.finalPaths.notNil }) { rig[\settledAt] = Main.elapsedTime } };
    // A render each time the recorder has freed the last of a set's buffers.
    rig[\recBufs] = Set.new;
    rig[\onMsg] = { |msg|
        var key = msg[0].asString;
        if(key.contains("b_write") and: { msg[2].asString.beginsWith(cfg[\setDir]) }) { rig[\recBufs].add(msg[1]) };
        if(key.contains("b_free") and: { rig[\recBufs].includes(msg[1]) }) {
            rig[\recBufs].remove(msg[1]);
            if(rig[\recBufs].isEmpty) { renderSet.(rig, cfg) };
        };
    };
    if(cfg[\midRun] != true) {
        rig[\wall] = cfg[\recAt];
        thisThread.seconds = cfg[\recAt];
        recStart.(rig);
    };
    spawnAndAnalyse.(rig, t0, ta);
    ll = rig[\loopDur];
    b1 = t0 + ll;
    ctx[\b1] = b1;
    // A break of one pass (breakLoops 2 of this two-bar loop), struck 30 ms
    // before a heard downbeat; PC 17 off 30 ms before a heard downbeat for two
    // passes, then on again the same way.
    events = [];
    cfg[\breakPass] !? { |p| events = events ++ breakAt.(rig, b1 + (p * ll), 0.03) };
    cfg[\pcOffPass] !? { |p| events = events.add([(b1 + (p * ll)) - 0.01, { |r, t| r[\d].toggleOn; r[\pcOff] = t }]) };
    cfg[\pcOnPass] !? { |p| events = events.add([(b1 + (p * ll)) - 0.01, { |r, t| r[\d].toggleOn; r[\pcOn] = t }]) };
    if(cfg[\midRun] == true) { events = events.add([cfg[\recAt], { |r, t| recStart.(r) }]) };
    // A double press: the second press `stopAfter` after the first, inside the
    // start bundle's latency; a new set `again` after the first press, on the
    // same recorder.
    cfg[\double] !? { |dbl|
        events = events.add([cfg[\recAt] + dbl[\stopAfter], { |r, t| recStop.(r, t) }]);
        events = events.add([cfg[\recAt] + dbl[\again], { |r, t| ctx[\setA] = captureSet.(r); recStart.(r) }]);
    };
    tPre = b1 + (cfg[\stopPass] * ll);
    runTimeline.(rig, ta, tPre, events);
    // The stop, 30 ms after a steps hit was heard: the drums tell the log of
    // a hit once it is logLag (50 ms) old, so this one is in the WAVs and not
    // yet in the log when the set stops, as the last hit of a set can be; and
    // the hits of the next 0.2 s (the set's tail, up to stopAt) are in the
    // WAVs too.
    // With `tailHit`, a steps hit is passed by unless a note is to sound in
    // the first 80 ms after the stop it would give (the drums decide 0.1 s
    // ahead, so 15 ms before that stop they are known): a set whose tail
    // holds a note to check.
    while { ts.isNil and: { guard < 400 } } {
        cand = d.decided.select { |r| (r[\slot] == \steps) and: { r[\emitted] == true } and: { r[\kind] == \step }
            and: { r[\stamp] > (tPre + 0.005) } }.asArray.sort { |a, b| a[\stamp] <= b[\stamp] }.first;
        if(cand.isNil) { runTimeline.(rig, tPre, tPre + 0.05, []); tPre = tPre + 0.05 } {
            if(cfg[\tailHit] == true) {
                runTimeline.(rig, tPre, (cand[\stamp] + 0.03) - 0.015, []);
                tPre = (cand[\stamp] + 0.03) - 0.015;
                if(d.decided.any { |r| (r[\emitted] == true) and: { #[\step, \roll, \onset].includes(r[\kind]) }
                    and: { r[\stamp] > (cand[\stamp] + 0.03) } and: { r[\stamp] < (cand[\stamp] + 0.11) } }) { ts = cand[\stamp] + 0.03 };
            } { ts = cand[\stamp] + 0.03 };
        };
        guard = guard + 1;
    };
    ts = ts ? (tPre + 0.03);
    ctx[\lastHit] = cand;
    // On until the stop's second half has run (stopAt, then closeWait), the
    // drums playing on.
    runTimeline.(rig, tPre, ((ts + latency) + closeWait) + 0.05, [[ts, { |r, t| recStop.(r, t) }]]);
    // A second half still paced (prBreathe waits from Main.elapsedTime, which
    // the score's clock is not) is run to its end.
    rig[\routines].select { |e| e[2] == \recStop }.do { |e|
        while { e[1].next.notNil and: { rest < 100000 } } { rest = rest + 1 };
    };
    ctx[\playWall] = Main.elapsedTime - c0;
    ctx[\ts] = ts;
    ctx[\dHat] = d.dHat;
    ctx[\setA] !? { |a| ctx[\otherNames] = a[\paths].values.asArray.collect { |p| p.basename } };
    ctx
};

// ------------------------------------------------------------- the checks --
checkRun = { |ctx|
    var label = ctx[\label], rec = ctx[\rec], rig = ctx[\rig], r = rig[\rendered], st = rig[\starts].last, fr, dumped;
    check.(label ++ ": the recorder started (inline) and stopped", (rig[\recOk] == true) and: { rec.recording.not },
        [rig[\recOk], rec.recording].asString);
    check.(label ++ ": ~setupSALooper handed the recorder SA's five stems (MegaSA.stemSpecs) and put it after the mixer",
        (rec.stems.collect { |s| [s[\role], s[\channel], s[\numChannels]] }
            == rig[\sa].stemSpecs.collect { |s| [s[\role], s[\channel], s[\numChannels]] })
        and: { rec.stems.collect(_[\role]) == [\guitar, \loop, \drums, \onset, \synth] }
        and: { rec.target === rig[\sa].recordGroup },
        rec.stems.asString);
    check.(label ++ ": the stop's first half waited until the WAVs end (the start latency, " ++ latency ++ " s) and closeWait ("
        ++ closeWait ++ " s) more before closing the files, its log open meanwhile (the set's tail) and nothing decided yet "
        ++ "(names, tempo, hint: once the WAVs have ended and their length is read)",
        ((rig[\stopFirst] ? 0) - (latency + closeWait)).abs < 1e-9 and: { rig[\stops].every { |x| (x[\logging] == true) and: { x[\undecided] == true } } },
        rig[\stops].collect { |x| [x[\first], x[\logging], x[\undecided]] }.asString);
    fr = freesOf.(rig, st !? { |x| x[\ids] });
    check.(label ++ ": ONE bundle frees every DiskOut synth (" ++ (st !? { |x| x[\ids] }).asString ++ "), stamped the start latency after the stop: stopAt "
        ++ (rec.stopAt - rec.startedAt).round(0.0001) ++ " s on the log's axis, as frame 0 was after the start",
        (fr.size == 1) and: { (fr[0][0] - (rig[\stopPress] + latency)).abs < 1e-9 }
            and: { (rec.stopAt - (rig[\stopPress] + latency)).abs < 1e-9 } and: { fr[0][0] > rec.audioAt },
        fr.collect(_[0]).asString ++ " against stopAt " ++ rec.stopAt);
    check.(label ++ ": scsynth rendered the set when the server was told to let go of its files (the last /b_free)"
        ++ (if(rig[\renders].size > 1) { ", each set at its own" } { "" }),
        rig[\renders].notEmpty and: { rig[\renders].every { |x| x[\error].isNil } }, rig[\renderError] ? "no render");
    check.(label ++ ": scsynth said nothing went wrong (no FAILURE, no \"not found\", nothing late, no allocation failed)",
        rig[\renders].notEmpty and: { rig[\renders].every { |x| (x[\bad] ? [1]).isEmpty } },
        rig[\renders].collect { |x| (x[\bad] ? []).join("; ") }.join(" | "));
    dumped = dumpCheck.(rig);
    say.("the record group's node tree, dumped in the score: " ++ dumped[1].join("; "));
    check.(label ++ ": no DiskOut synth outlives its set: the record group holds a set's synths while it records and nothing from 10 ms after its stopAt on (its tree dumped in the score"
        ++ (if(rig[\renders].size > 1) { ", in every render" } { "" }) ++ ")", dumped[0], dumped[1].join("; "));
    check.(label ++ ": the stop's second half ran to its end: the files have their final names", rec.settled == true);
    check.(label ++ ": nothing dropped as late", ctx[\d].dropped == 0, ctx[\d].dropped.asString);
    ctx[\audioAt] = rec.audioAt;
    say.("set " ++ rec.stamp ++ ": stomp at " ++ rec.startedAt.round(0.0001) ++ " s, frame 0 (audioAt) " ++ rec.audioAt.round(0.000001)
        ++ " s, stopped at " ++ rec.stoppedAt.round(0.0001) ++ " s, its WAVs' end (stopAt) " ++ rec.stopAt.round(0.0001)
        ++ " s (host time; the score's is " ++ (if(rig[\e] == 0) { "the same" } { "that x (1 + " ++ rig[\e] ++ ")" }) ++ "), "
        ++ rig[\scoreLen] ++ " bundles rendered to " ++ rig[\endT].round(0.01) ++ " s");
};

checkFiles = { |ctx|
    var label = ctx[\label], rec = ctx[\rec], rig = ctx[\rig], stamp = rec.stamp, tag = ctx[\tag];
    var roles = [\master, \tap, \guitar, \loop, \drums, \onset, \synth, \events, \midi];
    var parts = [["master", "wav"], ["tap", "wav"], ["guitar", "wav"], ["loop", "wav"], ["drums", "wav"], ["onset", "wav"],
        ["synth", "wav"], ["events", "jsonl"], ["drums", "mid"]];
    var want = parts.collect { |p| stamp ++ "-" ++ tag ++ "-" ++ p[0] ++ "." ++ p[1] };
    var dir = ctx[\cfg][\setDir], other = ctx[\otherNames] ? [], got, log, filesEv, header, left, found, stems, events;
    got = roles.collect { |r| (rec.finalPaths ? ())[r] !? { |p| p.basename } };
    check.(label ++ ": every file of the set is named <stamp>-" ++ tag ++ "-<role> (" ++ want[0] ++ ", ...)", got == want, got.asString);
    check.(label ++ ": ...and is on disk under that name, the recorder saying so (paths == finalPaths)",
        roles.every { |r| (rec.paths[r] == rec.finalPaths[r]) and: { File.exists(rec.finalPaths[r] ? "") } },
        roles.reject { |r| File.exists(rec.finalPaths[r] ? "") }.asString);
    left = (dir +/+ "*").pathMatch.collect(_.basename).reject { |b| want.includesEqual(b) or: { other.includesEqual(b) } };
    check.(label ++ ": no file is left under its stamp name, and nothing else is in the set's folder"
        ++ (if(other.notEmpty) { " (beside the first set's " ++ other.size ++ " files)" } { "" }), left.isEmpty, left.asString);
    log = readLog.(rec.paths[\events]);
    ctx[\log] = log;
    header = log.first ? ();
    filesEv = log.detect { |e| e["ev"] == "files" };
    ctx[\filesEv] = filesEv;
    check.(label ++ ": the log is the session header first and files, then sessionStop, last",
        (header["ev"] == "session") and: { log.keep(-2).collect { |e| e["ev"] } == ["files", "sessionStop"] },
        log.keep(-3).collect { |e| e["ev"] }.asString);
    check.(label ++ ": the files event names every file by the name it has now",
        filesEv.notNil and: { roles.every { |r, i| ((filesEv["files"] ? ())[r.asString]) == want[i] } },
        filesEv !? { |f| f["files"].asString });
    stems = header["stems"] ? [];
    check.(label ++ ": the header lists the five stems (role, SoundIn channel, channels) at the stamp paths they were opened at",
        stems.collect { |s| [s["role"], s["channel"].asInteger, s["numChannels"].asInteger, s["path"].basename] }
            == rig[\sa].stemSpecs.collect { |s| [s[\role].asString, s[\channel], s[\numChannels], stamp ++ "-" ++ s[\role] ++ ".wav"] },
        stems.asString);
    events = LooperSessionRecorder.readEvents(rec.paths[\events]);
    found = roles.collect { |r| LooperSessionRecorder.sessionPath(events, r, rec.paths[\events]) };
    check.(label ++ ": the readers find the set by its stamp, and every file of it from its log",
        (LooperSessionRecorder.findEvents(dir, stamp) == rec.paths[\events]) and: { found == roles.collect { |r| rec.paths[r] } },
        found.collect { |p| p !? { |x| x.basename } }.asString);
    say.("files: " ++ roles.collect { |r| rec.paths[r].basename ++ " (" ++ File.fileSize(rec.paths[r]) ++ " bytes)" }.join(", "));
};

// The sounding hits, their voices in the score and the kit files those play.
prepare = { |ctx|
    var rig = ctx[\rig], paths = Dictionary.new, soundIds = Dictionary.new, hits;
    rig[\log].do { |e| e[1].do { |m| if(m[0] == \b_allocRead) { paths.put(m[1], m[2]) } } };
    hits = sounding.(rig);
    hits.do { |r| r[\hitId] !? { |id| soundIds.put(r[\slot].asString ++ "-" ++ id, r) } };
    ctx.putAll((paths: paths, soundIds: soundIds, hits: hits));
    ctx[\voices] = voicesOf.(rig, soundIds);
    say.("hits that sounded: " ++ hits.count { |h| h[\kind] == \step } ++ " steps ("
        ++ hits.count { |h| (h[\kind] == \step) and: { h[\which] == \break } } ++ " of the break pattern), "
        ++ hits.count { |h| h[\kind] == \roll } ++ " roll hits, " ++ hits.count { |h| h[\kind] == \repeat } ++ " Beat Repeat repeats, "
        ++ hits.count { |h| h[\kind] == \onset } ++ " onset hits; " ++ rig[\seen].count { |h| (h[\cancelled] == true) and: { h[\emitted] != true } }
        ++ " cancelled; " ++ ctx[\voices].size ++ " voices");
};

checkWavs = { |ctx|
    var label = ctx[\label], rec = ctx[\rec], rig = ctx[\rig], s = rig[\toScore], audioAt = rec.audioAt, input = ctx[\input];
    var specs = [[\master, 2, chMaster, "int24"], [\tap, 1, nil, "int24"], [\guitar, 2, chGuitar, "float"],
        [\loop, 2, chLoop, "float"], [\drums, 2, chDrums, "float"], [\onset, 2, chOnset, "float"]];
    var wavs = IdentityDictionary.new, heads = List.new, res, b0, xa, best, e0, want, diffs, tapErr, sumErr = 0, clipped = 0;
    var tap, offAt, onAt, tailEnd, a, z, maxIn = 0, lastNz, onsetIn = 0, stepsIn, i, x, y, gl = 0, peak = 0;
    specs.do { |sp|
        var w = readWav.(rec.paths[sp[0]]);
        heads.add([sp[0], w !? { |f| [f[\chans], f[\rate], f[\format], f[\header], f[\frames]] }]);
        w !? { |f| wavs.put(sp[0], f) };
    };
    ctx[\wavs] = wavs;
    check.(label ++ ": the WAVs are WAV at 48 kHz, the master and the tap int24, the four stems 32-bit float (a strip can run over full scale); "
        ++ "the tap mono, the master and every stem stereo",
        heads.every { |h, j| h[1].notNil and: { h[1].keep(4) == [specs[j][1], sr, specs[j][3], "WAV"] } }, heads.asString);
    // Frame 0: where the dry tap, the guitar's own input, starts in the input.
    xa = s.(audioAt) * sr;
    tap = wavs[\tap][\data];
    ((xa - 200).floor.asInteger .. (xa + 64).ceil.asInteger).do { |b|
        var m = 0, k = 0, n = tap.size.min(24000), yy;
        while { (k < n) and: { m < 1e-3 } } { yy = (tap[k] - input[b + k]).abs; if(yy > m) { m = yy }; k = k + 1 };
        if(best.isNil or: { m < best[1] }) { best = [b, m] };
    };
    b0 = best[0];
    ctx[\b0] = b0;
    tapErr = tapDiff.(tap, input, b0);
    check.(label ++ ": the dry tap is the guitar's input, every frame, from the render's frame " ++ b0 ++ " (int24, "
        ++ (tapErr / lsb).round(0.01) ++ " LSB)", tapErr <= (1.01 * lsb), (tapErr / lsb).asString ++ " LSB");
    check.(label ++ ": frame 0 of every WAV is the first sample of the control block the start bundle (audioAt) is performed in",
        b0 == (blockOf.(s.(audioAt)) * block).asInteger, "frame 0 at " ++ b0 ++ ", the block's start " ++ (blockOf.(s.(audioAt)) * block));
    ctx[\frame0Lag] = xa - b0;
    note.(label ++ ": audioAt is " ++ (xa - b0).round(0.01) ++ " samples (" ++ ((xa - b0) * (1000 / sr)).round(0.001)
        ++ " ms) after the WAVs' real frame 0 (DiskOut records whole blocks, from the start of the block its bundle runs in); "
        ++ "the recorder puts frame 0 " ++ (lead * sr) ++ " samples before audioAt, so it is " ++ ((lead * sr) - (xa - b0)).round(0.01) ++ " samples off at frame 0");
    e0 = (blockOf.(s.(rec.stopAt)) * block).asInteger;
    ctx[\e0] = e0;
    ctx[\endLag] = (s.(rec.stopAt) * sr) - e0;
    want = e0 - b0;
    ctx[\frames] = want;
    check.(label ++ ": every WAV runs from frame 0 to the start of the control block that holds the stamped free (stopAt), "
        ++ want ++ " frames (" ++ (want / sr).round(0.001) ++ " s), all the same length",
        specs.every { |sp| (wavs[sp[0]] !? { |w| w[\frames] == want }) ? false },
        specs.collect { |sp| wavs[sp[0]] !? { |w| w[\frames] } }.asString);
    note.(label ++ ": the WAVs end " ++ ctx[\endLag].round(0.01) ++ " samples before stopAt (DiskOut stops at the start of the block its free runs in)");
    res = readAll.(rig[\rendered][\wav]);
    ctx[\res] = res;
    diffs = specs.reject { |sp| sp[2].isNil }.collect { |sp| [sp[0], wavDiff.(wavs[sp[0]], res, b0, sp[2]), sp[3]] };
    check.(label ++ ": every WAV holds what the server computed on its bus, every frame from frame 0 to its end: the float stems bit for bit, the int24 master to its rounding",
        diffs.every { |p| if(p[2] == "float") { p[1] == 0 } { p[1] <= (1.01 * lsb) } },
        diffs.collect { |p| p[0] ++ " " ++ (p[1] / lsb).round(0.01) ++ " LSB" }.join(", "));
    say.("the WAVs against the render's own float outputs of the same busses, largest difference: "
        ++ diffs.collect { |p| p[0] ++ " " ++ (p[1] / lsb).round(0.01) ++ " LSB" }.join(", ") ++ " (int24's own rounding is half of one)");
    i = 0;
    while { i < res[\frames] } {
        x = (res[\data][(i * res[\chans]) + chGuitar] - res[\data][(i * res[\chans]) + chGuitar + 1]).abs;
        if(x > gl) { gl = x };
        i = i + 1;
    };
    check.(label ++ ": today's guitar chain is dual mono: both sides of its strip, and so of its stem, are the same", gl == 0, gl.asString);
    // The stems against the master, each side its own, as far as the shortest
    // of them, should one be short (that is checked above).
    [0, 1].do { |c|
        var m = wavs[\master][\data], g = wavs[\guitar][\data], lp = wavs[\loop][\data], dr = wavs[\drums][\data];
        var on = wavs[\onset][\data], j = 0, sm, yy;
        var upTo = [want, wavs[\master][\frames], wavs[\guitar][\frames], wavs[\loop][\frames], wavs[\drums][\frames],
            wavs[\onset][\frames]].minItem;
        while { j < upTo } {
            sm = ((g[(j * 2) + c] + lp[(j * 2) + c]) + dr[(j * 2) + c]) + on[(j * 2) + c];
            if(m[(j * 2) + c].abs > peak) { peak = m[(j * 2) + c].abs };
            if(sm.abs < 0.9799) {
                yy = (m[(j * 2) + c] - sm).abs;
                if(yy > sumErr) { sumErr = yy };
            } { clipped = clipped + 1 };
            j = j + 1;
        };
    };
    check.(label ++ ": the stem WAVs sum to the master WAV (guitar + loop + drums + onset kit, before the master's clip at 0.98), to "
        ++ (sumErr / lsb).round(0.01) ++ " LSB of int24 (the master's rounding and the server's float sum)", sumErr <= (2 * lsb),
        (sumErr / lsb).asString ++ " LSB");
    // The same in the render's float outputs, where only float error is left.
    sumErr = 0;
    [0, 1].do { |c|
        var dd = res[\data], rc = res[\chans], j = b0, sm, yy;
        while { j < e0 } {
            sm = ((dd[(j * rc) + chGuitar + c] + dd[(j * rc) + chLoop + c]) + dd[(j * rc) + chDrums + c]) + dd[(j * rc) + chOnset + c];
            if(sm.abs < 0.9799) {
                yy = (dd[(j * rc) + chMaster + c] - sm).abs;
                if(yy > sumErr) { sumErr = yy };
            };
            j = j + 1;
        };
    };
    check.(label ++ ": ...and in the server's own float outputs of those busses, to " ++ sumErr.asStringPrec(3)
        ++ " (float error)", sumErr <= 2e-7, sumErr.asString);
    say.("master: peak " ++ peak.ampdb.round(0.01) ++ " dBFS, " ++ clipped ++ " samples where the stems' sum reaches the clip (left out above)");
    // PC 17: off from offAt to onAt as heard (the toggle's time: its grid edge
    // 20 ms before, plus the stamp's 20 ms), on the interface's clock.
    if(rig[\pcOff].notNil and: { rig[\pcOn].notNil }) {
        offAt = s.(rig[\pcOff]);
        onAt = s.(rig[\pcOn]);
        tailEnd = ctx[\voices].select { |v| (v[\slot] == \steps) and: { v[\host] < rig[\pcOff] } }.collect { |v| voiceEnd.(v, ctx[\paths]) }.maxItem;
        tailEnd = (tailEnd ? offAt) + (MegaSADrumsFx.fftSize / sr) + 0.3;
        a = ((tailEnd * sr).ceil.asInteger - b0).max(0);
        z = ((onAt * sr).floor.asInteger - b0).min(want);
        i = ((offAt * sr).floor.asInteger - b0).max(0);
        while { i < z } {
            x = wavs[\drums][\data][i * 2].abs.max(wavs[\drums][\data][(i * 2) + 1].abs);
            if(x > 0) { lastNz = i };
            if((i >= a) and: { x > maxIn }) { maxIn = x };
            y = wavs[\onset][\data][i * 2].abs;
            if(y > onsetIn) { onsetIn = y };
            i = i + 1;
        };
        stepsIn = ctx[\hits].count { |h| (h[\slot] == \steps) and: { h[\stamp] >= rig[\pcOff] } and: { h[\stamp] < rig[\pcOn] } };
        say.("PC 17 off from " ++ offAt.round(0.001) ++ " s to " ++ onAt.round(0.001) ++ " s (heard, in the render): the drums stem rings on for "
            ++ (lastNz !? { |q| ((((q + b0) / sr) - offAt) * 1000).round(0.1).asString ++ " ms" } ? "-") ++ " (the voices sounding then end by "
            ++ ((tailEnd - offAt) - (MegaSADrumsFx.fftSize / sr) - 0.3).round(0.001) ++ " s, then the reverb; from "
            ++ (((tailEnd - offAt) * 1000).round(0.1)) ++ " ms it peaks at " ++ (if(maxIn > 0) { maxIn.ampdb.round(0.1).asString ++ " dBFS" } { "exactly 0" })
            ++ "), then is exactly 0 for " ++ ((z - (lastNz ? z)) / sr).round(0.001) ++ " s; the onset stem peaks at " ++ onsetIn.ampdb.round(0.1) ++ " dBFS meanwhile");
        check.(label ++ ": the drums stem is silent while PC 17 has the steps off: once what sounded before has rung out it stays under half an LSB of int24 "
            ++ "(what an int24 stem holds as 0) and then is exactly 0 for a second or more; no steps hit sounds then, and the onset kit plays on",
            (a < z) and: { maxIn <= (0.5 * lsb) } and: { ((z - (lastNz ? 0)) / sr) >= 1.0 } and: { stepsIn == 0 } and: { onsetIn > 0.001 },
            [a, z, maxIn, lastNz, stepsIn, onsetIn].asString);
    };
};

// What the files event says of the WAVs' end, length and clock, against the
// WAVs themselves; the clock against the interface's own.
checkClock = { |ctx|
    // The WAVs' own count (checkWavs holds every WAV to it and to its stamps).
    var label = ctx[\label], rec = ctx[\rec], rig = ctx[\rig], fe = ctx[\filesEv] ? (), e = rig[\e];
    var frames = ctx[\wavs][\master] !? { |w| w[\frames] } ? ctx[\frames];
    var nominal = (rec.stopAt - rec.audioAt) * sr, rate = frames / nominal, res = block / nominal, ppm = (rate - 1) * 1e6;
    var audioEnd = fe["audioEnd"] !? { |x| x.asFloat }, fFrames = fe["frames"] !? { |x| x.asInteger };
    var fPpm = fe["clockPpm"] !? { |x| x.asFloat }, wantEnd = ((rig[\stopPress] + latency) - rec.startedAt).round(0.0001);
    ctx.putAll((rate: rate, ppm: ppm, ppmRes: res * 1e6, nominal: nominal));
    check.(label ++ ": the files event says where the WAVs end on the log's axis: audioEnd " ++ audioEnd ++ " s, stopAt (the stop plus the start latency)",
        audioEnd.notNil and: { (audioEnd - wantEnd).abs < 1e-9 } and: { ((rec.stopAt - rec.startedAt).round(0.0001) - wantEnd).abs < 1e-9 },
        [audioEnd, wantEnd].asString);
    check.(label ++ ": ...how many frames they hold: " ++ fFrames ++ ", the WAVs' own count", fFrames == frames, [fFrames, frames].asString);
    check.(label ++ ": ...and the clock that makes: clockPpm " ++ fPpm ++ ", frames / ((stopAt - audioAt) * sr), as the recorder holds it too (wavFrames, clockRate)",
        fPpm.notNil and: { (fPpm - ppm.round(0.01)).abs < 1e-6 } and: { rec.wavFrames == frames } and: { ((rec.clockRate ? 0) - rate).abs < 1e-12 },
        [fPpm, ppm, rec.wavFrames, rec.clockRate].asString);
    check.(label ++ ": the clock read from the WAVs is the interface's, "
        ++ (if(e == 0) { "here the Mac's own (a render has one clock)" } { "+" ++ (e * 1e6).round(0.1) ++ " ppm against the Mac's" })
        ++ ", within what a set of this length can tell (a block over its length, " ++ (res * 1e6).round(0.1) ++ " ppm): "
        ++ ppm.round(0.01) ++ " ppm", (rate - (1 + e)).abs <= res, ((rate - (1 + e)) * 1e6).round(0.01).asString ++ " ppm off");
    note.(label ++ ": the WAVs hold " ++ frames ++ " frames for " ++ nominal.round(0.01) ++ " of the Mac's samples from audioAt to stopAt: "
        ++ (if(ppm >= 0) { "+" } { "" }) ++ ppm.round(0.01) ++ " ppm (to " ++ (res * 1e6).round(0.1) ++ "; the interface's clock "
        ++ (if(e == 0) { "is the Mac's" } { "runs +" ++ (e * 1e6).round(0.1) ++ " ppm" }) ++ ")");
};

// The onsets: the drums and onset stems (frame 0 at b0), and the dry voice
// busses of the render (to see the matched filter on the voices alone).
measure = { |ctx|
    var label = ctx[\label], b0 = ctx[\b0], res = ctx[\res], wavs = ctx[\wavs], c0 = Main.elapsedTime;
    // The voices the WAVs hold, from their frame 0 to their end.
    var rendered = ctx[\voices].select { |v| (v[\s] >= b0) and: { v[\s] < ctx[\e0] } };
    var vSteps = rendered.select { |v| v[\slot] == \steps }, vOnset = rendered.select { |v| v[\slot] == \onset };
    var side = { |w, c| var n = w[\frames], out = FloatArray.newClear(n), j = 0; while { j < n } { out[j] = w[\data][(j * 2) + c]; j = j + 1 }; out };
    var onD, onO, dryS, dryO, rows, gs, want, weak;
    onD = detect.(side.(wavs[\drums], 0), side.(wavs[\drums], 1), vSteps, b0, ctx[\paths]);
    onO = detect.(side.(wavs[\onset], 0), side.(wavs[\onset], 1), vOnset, b0, ctx[\paths]);
    dryS = detect.(chanOf.(res, chStepsDry), chanOf.(res, chStepsDry + 1), vSteps, 0, ctx[\paths]);
    dryO = detect.(chanOf.(res, chOnsetDry), chanOf.(res, chOnsetDry + 1), vOnset, 0, ctx[\paths]);
    ctx.putAll((onD: onD, onO: onO));
    rows = [["the dry steps bus", dryS, 0], ["the dry onset bus", dryO, 0], ["the drums stem", onD, 1], ["the onset stem", onO, 2]];
    rows.do { |row|
        var gs = row[1].values.select { |g| g[\onset].notNil }, lags = gs.collect { |g| g[\lag] };
        say.("onsets in " ++ row[0] ++ ": " ++ gs.size ++ " voice groups (" ++ (row[1].size - gs.size) ++ " too near an end); "
            ++ "against the sample their stamps put them on, by " ++ histoStr.(histo.(lags)) ++ "; correlation "
            ++ spread.(gs.collect { |g| g[\ncc].round(0.001) }) ++ ", next best more than 4 samples off "
            ++ spread.(gs.collect { |g| g[\second].round(0.001) })
            ++ if(row[2] == 1) { "; gain " ++ spread.(gs.collect { |g| g[\gain].round(0.0001) }) ++ " (the strip x the dry, "
                ++ (ctx[\rig][\sa].level(\drums) * (1 - ctx[\d].reverbMix)).round(0.0001) ++ ")" } { "" });
        row[1].keysValuesDo { |s, g|
            var vs, recs;
            if(g[\onset].notNil and: { (g[\lag].abs > 2) or: { g[\ncc] < 0.6 } }) {
                vs = rendered.select { |v| v[\s] == s };
                recs = vs.collect { |v| ctx[\soundIds][v[\slot].asString ++ "-" ++ v[\args][\hitId]] };
                say.("  an outlier there: the voices starting at render frame " ++ s ++ " (" ++ (s / sr).round(0.0001) ++ " s), lag "
                    ++ g[\lag] ++ ", correlation " ++ g[\ncc].round(0.001) ++ ": " ++ recs.collect { |r|
                        [r[\kind], r[\note], r[\which], r[\vel], (r[\stamp] - ctx[\rec].stoppedAt).round(0.0001)] }.asString
                    ++ " (the last number: from the recorder's stop)");
            };
        };
    };
    // A group whose own attack does not match what it plays (correlation
    // under 0.6: a repeat over a hat its voice chokes, whose release the
    // template does not have) is not measured: its onset is left out here and
    // below. A voice that started late would match, late, so it would still
    // be seen. Such groups must stay few.
    weak = [onD, onO].collect { |found|
        var n = 0;
        found.values.do { |g| if(g[\onset].notNil and: { g[\ncc] < 0.6 }) { g.put(\weak, g[\onset]); g.removeAt(\onset); n = n + 1 } };
        n
    };
    check.(label ++ ": every voice group starts where its stamp puts it, measured in the drums stem (the matched filter, +-1 sample; "
        ++ weak[0] ++ " of " ++ onD.size ++ " groups unmeasured, their attack not their template, listed above)",
        onD.values.select { |g| g[\onset].notNil }.every { |g| g[\lag].abs <= 1 } and: { onD.values.any { |g| g[\onset].notNil } }
            and: { weak[0] <= (0.1 * onD.size) },
        histoStr.(histo.(onD.values.select { |g| g[\onset].notNil }.collect { |g| g[\lag] })));
    check.(label ++ ": ...and in the onset stem, through the onset kit's chain (+-2 samples; " ++ weak[1] ++ " unmeasured)",
        onO.values.select { |g| g[\onset].notNil }.every { |g| g[\lag].abs <= 2 } and: { onO.values.any { |g| g[\onset].notNil } }
            and: { weak[1] <= (0.1 * onO.size) },
        histoStr.(histo.(onO.values.select { |g| g[\onset].notNil }.collect { |g| g[\lag] })));
    gs = onD.values.select { |g| (g[\onset].notNil) and: { g[\ncc] > 0.99 } }.collect { |g| g[\gain] };
    want = ctx[\rig][\sa].level(\drums) * (1 - ctx[\d].reverbMix);
    say.("the drums stem's attacks (correlation over 0.99) against the voices: gain " ++ spread.(gs.collect { |x| ((x / want) - 1) * 100 })
        ++ " % off the drums strip's level x the reverb's dry, " ++ want.round(0.00001));
    check.(label ++ ": the drums stem is post-fader: each clean attack in it is the voices at the drums strip's level x the reverb's dry ("
        ++ want.round(0.0001) ++ "), to 2 %", gs.notEmpty and: { gs.every { |x| (x - want).abs <= (0.02 * want) } },
        spread.(gs.collect { |x| ((x / want) - 1) * 100 }) ++ " %");
    ctx[\measureWall] = Main.elapsedTime - c0;
};

// The log's hits against the hits that sounded and against the stems.
checkLog = { |ctx|
    var label = ctx[\label], rec = ctx[\rec], rig = ctx[\rig], s = rig[\toScore], log = ctx[\log], b0 = ctx[\b0], e0 = ctx[\e0];
    var tAudio = (log.detect { |e| e["ev"] == "audio" } ? ())["t"] !? { |t| t.asFloat };
    // A reader places a log time in the WAVs as the recorder does: from the
    // audio line, at the clock the files event gives, frame 0 half a block
    // before audioAt.
    var fe = ctx[\filesEv] ? (), rateLog = 1 + (((fe["clockPpm"] ? "0").asFloat) / 1e6);
    var lines = log.select { |e| e["ev"] == "hit" }, byKey = Dictionary.new, used = IdentitySet.new, unmatched = List.new;
    // parseJSON's Dictionaries take no new key (their array is full), so each
    // line's hit is kept beside it.
    var recOf = IdentityDictionary.new;
    var offs = List.new, raws = List.new, heard, notLogged, tail, lastMoments, after, loggedAfter, early, cancelled, memOk;
    var placedTol = (32 + logRound) + 2, rawTol = (block + logRound) + 2, partBlock;
    var keyOf = { |slot, kind, note, t| [slot.asString, kind.asString, note.asInteger, (t * 10000).round.asInteger].asString };
    // A repeat's lane is the lane of the hit it repeats.
    var laneOf = { |r| r[\lane] ?? { r[\source] !? { |x| x[\lane] } } };
    ctx[\tAudio] = tAudio;
    check.(label ++ ": the audio line puts frame 0 at audioAt on the log's axis", tAudio.notNil and: {
        (tAudio - (rec.audioAt - rec.startedAt).round(0.0001)).abs < 1e-9 }, tAudio.asString);
    ctx[\hits].do { |r|
        var k = keyOf.(r[\slot], r[\kind], r[\note], r[\stamp] - rec.startedAt);
        byKey.put(k, (byKey[k] ? List.new).add(r));
    };
    lines.do { |e|
        var t = e["t"].asFloat, r, ks;
        ks = [-1, 0, 1].collect { |dk| keyOf.(e["slot"], e["kind"], e["note"], t + (dk * 0.0001)) };
        ks.do { |k|
            (byKey[k] ? []).do { |c|
                if(r.isNil and: { used.includes(c).not } and: { ((c[\stamp] - rec.startedAt) - t).abs <= 0.000051 }
                    and: { (e["vel"] ? "").asFloat == c[\vel].asFloat } and: { (e["lane"] !? { |x| x.asInteger }) == laneOf.(c) }) { r = c };
            };
        };
        if(r.isNil) { unmatched.add(e) } {
            used.add(r);
            recOf.put(e, r);
        };
    };
    check.(label ++ ": every hit line in the log is a hit that sounded (slot, kind, note, velocity, lane, time), each once",
        unmatched.isEmpty and: { lines.notEmpty }, unmatched.size.asString ++ " unmatched of " ++ lines.size ++ ", first "
            ++ (unmatched.first !? { |e| [e["t"], e["kind"], e["note"]] }));
    // The set's hits: heard from the stomp to the WAVs' stamped end.
    heard = ctx[\hits].select { |r| (r[\stamp] >= rec.startedAt) and: { r[\stamp] < rec.stopAt } };
    notLogged = heard.reject { |r| used.includes(r) };
    lastMoments = heard.select { |r| (r[\stamp] < rec.stoppedAt) and: { r[\stamp] >= (rec.stoppedAt - 0.06) } };
    tail = heard.select { |r| r[\stamp] >= rec.stoppedAt };
    after = ctx[\hits].select { |r| r[\stamp] >= rec.stopAt };
    loggedAfter = after.select { |r| used.includes(r) };
    partBlock = heard.select { |r| (s.(r[\stamp]) * sr) >= e0 };
    early = lines.select { |e| e["t"].asFloat < tAudio };
    cancelled = ctx[\rig][\seen].select { |r| (r[\cancelled] == true) and: { r[\emitted] != true } };
    say.("the log: " ++ lines.size ++ " hit lines (" ++ lines.count { |e| e["kind"] == "repeat" } ++ " repeats, " ++ early.size
        ++ " heard between the stomp and frame 0); " ++ heard.size ++ " hits heard from the stomp to stopAt, " ++ lastMoments.size
        ++ " of them in the last 60 ms before the stop, " ++ tail.size ++ " in the tail (the stop to stopAt: "
        ++ tail.collect { |r| r[\kind] ++ " " ++ r[\note] ++ " +" ++ ((r[\stamp] - rec.stoppedAt) * 1000).round(0.1) ++ " ms" }.join(", ")
        ++ "), " ++ partBlock.size ++ " after the WAVs' last whole block; " ++ after.size ++ " sounded at or after stopAt (the drums play on); "
        ++ cancelled.size ++ " cancelled, none of them logged: " ++ cancelled.every { |r| used.includes(r).not });
    if(notLogged.notEmpty) {
        say.("hits heard but not logged: " ++ notLogged.collect { |r| r[\kind] ++ " " ++ r[\note] ++ " heard "
            ++ ((rec.stoppedAt - r[\stamp]) * 1000).round(0.1) ++ " ms before the stop" }.join(", "));
    };
    check.(label ++ ": every drum hit heard from the stomp to stopAt is in its log (and so can be in its .mid), the last ones before the stop ("
        ++ lastMoments.size ++ ") and the tail's (" ++ tail.size ++ ") too",
        notLogged.isEmpty and: { tail.notEmpty }, notLogged.size.asString ++ " missing, the tail holding " ++ tail.size);
    check.(label ++ ": ...and nothing heard at or after stopAt (" ++ after.size ++ " hits sounded then, the drums playing on)",
        loggedAfter.isEmpty and: { after.notEmpty }, loggedAfter.size.asString ++ " logged");
    memOk = (rec.loggedHits.size == lines.size) and: { rec.loggedHits.every { |h, i|
        (((h[\at] - rec.startedAt) - lines[i]["t"].asFloat).abs <= 0.000051) and: { h[\kind].asString == lines[i]["kind"] }
            and: { h[\note].asInteger == lines[i]["note"].asInteger } } };
    check.(label ++ ": the recorder kept exactly the log's hit lines for the .mid (loggedHits)", memOk,
        [rec.loggedHits.size, lines.size].asString);
    // The logged times on the stems.
    lines.do { |e|
        var r = recOf[e], g, t;
        r !? {
            g = (if(r[\slot] == \onset) { ctx[\onO] } { ctx[\onD] })[startSample.(s.(r[\stamp]))];
            if(g.notNil and: { g[\onset].notNil }) {
                t = e["t"].asFloat - tAudio;
                offs.add(((((t * rateLog) + lead) * sr) - g[\onset]));
                raws.add(((t * sr) - g[\onset]));
            };
        };
    };
    say.("logged times on their onsets in the stems, placed as the files event says ((t - t of audio) x its clock + the lead) less the onset, samples: "
        ++ spread.(offs) ++ "; at face value ((t - t of audio) * sr): " ++ spread.(raws));
    check.(label ++ ": every hit line's time, placed in the WAVs as the files event says (its clock, the lead), is on its hit's onset within half a block and the log's 0.1 ms ("
        ++ placedTol.round(0.1) ++ " samples), all through the set",
        offs.notEmpty and: { offs.every { |x| x.abs <= placedTol } }, spread.(offs));
    if(rig[\e] == 0) {
        check.(label ++ ": ...and at face value, from the audio line alone, within a block and the log's rounding (one clock here)",
            raws.notEmpty and: { raws.every { |x| x.abs <= rawTol } }, spread.(raws));
    };
    ctx.putAll((logOffs: offs, logRaws: raws, notLogged: notLogged, tail: tail, after: after, partBlock: partBlock));
};

checkMidi = { |ctx|
    var label = ctx[\label], rec = ctx[\rec], rig = ctx[\rig], s = rig[\toScore], path = rec.paths[\midi], audioAt = rec.audioAt;
    var bpmR = ctx[\bpmR], rate = ctx[\rate] ? 1, b0 = ctx[\b0], e0 = ctx[\e0];
    var said, lines, head, names = Dictionary.new, tempos = List.new, tsigs = List.new, marks = List.new, eots = List.new;
    var pyNotes = [List.new, List.new, List.new], problems = List.new, tail, tickAt, tickOf, tick1Of, stepsIn = List.new, onsetsIn = List.new;
    var want, wantMarks, endTick, sc, scOns, pyOns, offs = List.new, offsOnset = List.new, missingAudio = List.new;
    var byNote = Dictionary.new, breakNotes = 0, breakHits, cancelledIn = 0, bpmName, ambiguous = 0, inWavs, absent, early;
    var halfTick, bound, rows = List.new, setLen, firstRows, lastRows, lastTwo, endTk, past, nAfter, firstMark, midRun;
    var noteOrder = { |a, b| (a[0] < b[0]) or: { (a[0] == b[0]) and: { (a[2] < b[2]) or: { (a[2] == b[2]) and: { a[3] <= b[3] } } } } };
    var onOrder = { |a, b| (a[0] < b[0]) or: { (a[0] == b[0]) and: { (a[1] < b[1]) or: { (a[1] == b[1]) and: { a[2] <= b[2] } } } } };
    tickAt = { |sec| ((sec * (bpmR / 60)) * 480).round.asInteger };
    // Where the recorder must put a moment of the log's clock: in the WAVs,
    // at the clock their own length gives (checkClock), frame 0 half a block
    // before audioAt; and where it would at the Mac's clock (rate 1).
    tickOf = { |t| tickAt.(((t - audioAt) * rate) + lead) };
    tick1Of = { |t| tickAt.((t - audioAt) + lead) };
    halfTick = (((60 / bpmR) / 480) / 2) * sr;
    bound = (32 + halfTick) + 2;
    midRun = ctx[\cfg][\midRun] == true;
    said = runPython.(path);
    lines = said.split($\n).collect { |x| x.split($ ) }.reject { |x| x.isEmpty or: { x[0].isEmpty } };
    lines.do { |t|
        switch(t[0],
            "HEAD", { head = t.drop(1).collect(_.asInteger) },
            "NAME", { names.put(t[1].asInteger, t[3]) },
            "TEMPO", { tempos.add(t.drop(1).collect(_.asInteger)) },
            "TSIG", { tsigs.add(t.drop(1).collect(_.asInteger)) },
            "MARK", { marks.add([t[1].asInteger, t[2].asInteger, t[3]]) },
            "EOT", { eots.add(t.drop(1).collect(_.asInteger)) },
            "NOTE", { pyNotes[t[1].asInteger].add([t[5].asInteger, t[6].asInteger, t[2].asInteger, t[3].asInteger, t[4].asInteger]) },
            "TAIL", { tail = t[1].asInteger },
            { problems.add(t.join(" ")) }
        );
    };
    check.(label ++ ": python3 reads the .mid: format 1, 3 tracks, 480 ticks a quarter, nothing after the last track",
        (head !? { |h| h.keep(4) } == [6, 1, 3, 480]) and: { tail == 0 }, said.split($\n).keep(3).join(" | "));
    check.(label ++ ": ...every event with its own status byte, every note closed before its key sounds again, no stray off",
        problems.isEmpty, problems.keep(5).join("; "));
    check.(label ++ ": ...track names: \"megalooper <stamp>\", \"Step sequencer\", \"Onset notes\"",
        [0, 1, 2].collect { |k| names[k] } == ["megalooper_" ++ rec.stamp, "Step_sequencer", "Onset_notes"], names.asString);
    check.(label ++ ": ...one tempo, at tick 0, of the file name's " ++ fixed.(bpmR, 2) ++ " BPM (" ++ (60e6 / bpmR).round.asInteger
        ++ " us a quarter), and one time signature at 0, " ++ ctx[\num] ++ "/" ++ ctx[\den],
        (tempos.asArray == [[0, 0, (60e6 / bpmR).round.asInteger]])
            and: { tsigs.asArray == [[0, 0, ctx[\num], ctx[\den].log2.round.asInteger, 24, 8]] }, [tempos, tsigs].asString);
    // What the .mid must hold: the hits the log holds (the recorder's own
    // memory of them, exact), placed in the WAVs, at the file name's tempo.
    rec.loggedHits.do { |h|
        var tk = tickOf.(h[\at]);
        if(tk >= 0) {
            case
            { (h[\kind] == \step) or: { h[\kind] == \roll } } {
                stepsIn.add([tk, ((h[\lane] ? 0) + 1).clip(1, 15), h[\note].round.asInteger, h[\vel].round.asInteger.clip(1, 127), 120]);
            }
            { h[\kind] == \onset } {
                onsetsIn.add([tk, 1, h[\note].round.asInteger, h[\vel].round.asInteger.clip(1, 127), tickAt.(h[\gate] ? 0.02).max(1)]);
            };
        };
    };
    want = [stepsIn, onsetsIn].collect { |x| noteOffs.(x) };
    check.(label ++ ": the step sequencer's track is every logged step and roll hit (no repeat), at its place in the WAVs, lane + 2 as MIDI channel, a 16th long "
        ++ "or to a tick before its key comes again: " ++ want[0].size ++ " notes",
        pyNotes[1].asArray.sort(noteOrder) == want[0], "python " ++ pyNotes[1].size ++ " notes, want " ++ want[0].size ++ "; first difference "
            ++ (pyNotes[1].asArray.detect { |n| want[0].includesEqual(n).not }).asString);
    check.(label ++ ": the Onset notes track is every logged onset hit on MIDI channel 2, its gate long: " ++ want[1].size ++ " notes",
        pyNotes[2].asArray.sort(noteOrder) == want[1], "python " ++ pyNotes[2].size ++ ", want " ++ want[1].size ++ "; first difference "
            ++ (pyNotes[2].asArray.detect { |n| want[1].includesEqual(n).not }).asString);
    check.(label ++ ": no note on the conductor track", pyNotes[0].isEmpty);
    wantMarks = ctx[\log].select { |e| #["drumsStart", "drumsSegment", "drumsStop", "drumsOn", "breakStart", "breakEnd"].includesEqual(e["ev"]) }
        .collect { |e|
            var inForce = (e["inForce"] == true) or: { e["inForce"] == "true" };
            var txt = switch(e["ev"],
                "drumsStart", { (if(inForce) { "drums playing " } { "drums start " }) ++ e["numerator"] ++ "/" ++ e["denominator"]
                    ++ " " ++ fixed.(((e["bpm"].asFloat * 100).round / 100), 2) ++ " BPM" },
                "drumsSegment", { "reading " ++ e["numerator"] ++ "/" ++ e["denominator"] ++ " " ++ fixed.(((e["bpm"].asFloat * 100).round / 100), 2) ++ " BPM" },
                "drumsStop", { "drums stop" },
                "drumsOn", { if((e["on"] == true) or: { e["on"] == "true" }) { "drums on" } { "drums off" } },
                "breakStart", { "break" },
                "breakEnd", { "back" });
            [tickOf.(rec.startedAt + e["t"].asFloat).max(0), txt.replace(" ", "_")]
        };
    check.(label ++ ": the conductor's markers are the drums' transport as logged (" ++ wantMarks.collect(_[1]).join(", ") ++ "), each where it is in the WAVs",
        (marks.size == wantMarks.size) and: { marks.every { |m, i| (m[0] == 0) and: { (m[1] - wantMarks[i][0]).abs <= 1 } and: { m[2] == wantMarks[i][1] } } },
        marks.asString ++ " want " ++ wantMarks.asString);
    firstMark = marks.first;
    check.(label ++ ": the first marker says how the drums were when the set began: "
        ++ (if(midRun) { "\"drums playing\" at tick 0 (they were already playing)" } { "\"drums start\" where they started" }),
        firstMark.notNil and: { firstMark[2].beginsWith(if(midRun) { "drums_playing_" } { "drums_start_" }) }
            and: { midRun.not or: { firstMark[1] == 0 } }, firstMark.asString);
    endTk = tickOf.(rec.stopAt);
    endTick = ([endTk] ++ want.flatten(1).collect(_[1]) ++ wantMarks.collect(_[0])).maxItem;
    check.(label ++ ": every track ends (End of Track, the last event of each) at the set's end, where the WAVs end (stopAt, tick " ++ endTk
        ++ ") or its last note's end: tick " ++ endTick,
        (eots.size == 3) and: { eots.every { |e| (e[1] == endTick) and: { e[2] == 1 } } }, eots.asString);
    // LooperMidiFile's own reading of the same bytes agrees with python's.
    sc = LooperMidiFile.read(path);
    scOns = (sc[\tracks] ? []).collect { |tr| tr.select { |e| (e[\status] == 0x90) and: { e[\vel] > 0 } }.collect { |e| [e[\tick], e[\chan], e[\note], e[\vel]] } };
    pyOns = pyNotes.collect { |ns| ns.collect { |n| [n[0], n[2], n[3], n[4]] }.asArray.sort(onOrder) };
    check.(label ++ ": LooperMidiFile.read and python3 read the same note-ons (tick, channel, note, velocity) on every track",
        scOns.collect { |x| x.asArray.sort(onOrder) } == pyOns,
        sc[\error] ? (scOns.collect(_.size) ++ pyOns.collect(_.size)).asString);
    // Every note against its hit's onset in the stems, at ticks / 480 * 60 / bpm.
    bpmName = ((rec.paths[\midi].basename.split($-).detect { |p| p.endsWith("bpm") } ? "0bpm").drop(-3)).asFloat;
    rec.loggedHits.do { |h|
        var tk = tickOf.(h[\at]), k, r;
        if((tk >= 0) and: { #[\step, \roll, \onset].includes(h[\kind]) }) {
            k = [if(h[\kind] == \onset) { 2 } { 1 }, tk, if(h[\kind] == \onset) { 1 } { ((h[\lane] ? 0) + 1).clip(1, 15) }, h[\note].round.asInteger].asString;
            r = ctx[\hits].detect { |x| (x[\stamp] == h[\at]) and: { x[\kind] == h[\kind] } and: { x[\note] == h[\note] } };
            byNote.put(k, (byNote[k] ? List.new).add([r, h]));
        };
    };
    [1, 2].do { |track|
        pyNotes[track].do { |n|
            var k = [track, n[0], n[2], n[3]].asString, rs = (byNote[k] ? []).reject { |p| p[0].isNil }, m, g, best, bestP, bestG, m1;
            m = ((n[0] / 480) * (60 / bpmName)) * sr;
            if(rs.size > 1) { ambiguous = ambiguous + 1 };
            rs.do { |p|
                g = (if(p[0][\slot] == \onset) { ctx[\onO] } { ctx[\onD] })[startSample.(s.(p[0][\stamp]))];
                if(g.notNil and: { g[\onset].notNil } and: { best.isNil or: { (m - g[\onset]).abs < best.abs } }) {
                    best = m - g[\onset];
                    bestP = p;
                    bestG = g;
                };
                if((p[0][\which] == \break) and: { track == 1 }) { breakNotes = breakNotes + 1 };
            };
            if(best.isNil) { missingAudio.add(n) } {
                if(track == 1) { offs.add(best) } { offsOnset.add(best) };
                m1 = ((tick1Of.(bestP[1][\at]) / 480) * (60 / bpmName)) * sr;
                rows.add([bestP[1][\at] - audioAt, best, m1 - bestG[\onset]]);
            };
        };
    };
    setLen = rec.stopAt - audioAt;
    firstRows = rows.select { |rw| rw[0] < (setLen * 0.2) };
    lastRows = rows.select { |rw| rw[0] >= (setLen * 0.8) };
    ctx.putAll((midiOffs: offs, midiOffsOnset: offsOnset, midiBound: bound, midiRows: rows));
    say.("notes against their onsets, (tick / 480 * 60 / " ++ fixed.(bpmName, 2) ++ ") * sr less the onset in the stem, samples: step sequencer "
        ++ spread.(offs) ++ ", Onset notes " ++ spread.(offsOnset) ++ "; histogram in 8-sample bins " ++ histoStr.(histo.((offs ++ offsOnset).collect { |x| (x / 8).floor.asInteger * 8 })));
    say.("...which is half a block at most (frame 0 is 0 to 64 samples before audioAt, the recorder puts it " ++ (lead * sr) ++ " before; audioAt is "
        ++ ctx[\frame0Lag].round(0.01) ++ " after it here, the WAVs' end " ++ ctx[\endLag].round(0.01) ++ " before stopAt) and the tick's rounding (+-"
        ++ halfTick.round(0.1) ++ " samples); " ++ missingAudio.size ++ " notes with no onset to hold them against (too near an end), "
        ++ ambiguous ++ " notes of two hits");
    say.("...over the set: in its first fifth " ++ spread.(firstRows.collect(_[1])) ++ ", in its last " ++ spread.(lastRows.collect(_[1]))
        ++ "; at the Mac's clock instead (rate 1, the lead kept): " ++ spread.(firstRows.collect(_[2])) ++ ", and " ++ spread.(lastRows.collect(_[2])));
    check.(label ++ ": every note-on of the step sequencer's track, at ticks / 480 * 60 / bpm, is on its hit's onset in the drums stem within half a block and half a tick ("
        ++ bound.round(0.1) ++ " samples: inside a block), all through the set",
        offs.notEmpty and: { offs.every { |x| x.abs <= bound } } and: { bound < block }, spread.(offs) ++ "; " ++ offs.count { |x| x.abs > bound } ++ " beyond");
    check.(label ++ ": every note of the Onset notes track is on its onset hit in the onset stem, the same",
        offsOnset.notEmpty and: { offsOnset.every { |x| x.abs <= bound } }, spread.(offsOnset) ++ "; " ++ offsOnset.count { |x| x.abs > bound } ++ " beyond");
    if(rig[\e] != 0) {
        lastTwo = rows.select { |rw| rw[0] >= (setLen - 2) };
        ctx[\uncorrected] = lastTwo.collect(_[2]);
        check.(label ++ ": ...which the clock read from the WAVs makes so: at the Mac's clock (rate 1) the notes of the set's last 2 s would be "
            ++ spread.(lastTwo.collect(_[2])) ++ " samples off their onsets, more than a block (" ++ ((rig[\e] * setLen) * sr).round(0.1)
            ++ " samples of +" ++ (rig[\e] * 1e6).round(0.1) ++ " ppm by the end)",
            lastTwo.notEmpty and: { lastTwo.every { |rw| rw[2].abs > block } }, spread.(lastTwo.collect(_[2])));
    };
    if(ctx[\cfg][\breakPass].notNil) {
        breakHits = rec.loggedHits.count { |h| ((h[\kind] == \step) or: { h[\kind] == \roll }) and: {
            (ctx[\hits].detect { |x| (x[\stamp] == h[\at]) and: { x[\note] == h[\note] } } ? ())[\which] == \break } };
        check.(label ++ ": the break's hits are in the .mid (" ++ breakNotes ++ " notes of " ++ breakHits ++ " break hits)",
            (breakHits > 0) and: { breakNotes >= breakHits }, [breakNotes, breakHits].asString);
    };
    // A cancelled hit is in the .mid only if a hit that sounded has its key
    // and tick: there are none.
    ctx[\rig][\seen].select { |r| (r[\cancelled] == true) and: { r[\emitted] != true } and: { r[\kind] != \repeat } }.do { |r|
        var tk = tickOf.(r[\stamp]), k;
        k = [if(r[\kind] == \onset) { 2 } { 1 }, tk, if(r[\kind] == \onset) { 1 } { ((r[\lane] ? 0) + 1).clip(1, 15) }, r[\note]];
        if(pyNotes[k[0]].any { |n| (n[0] == k[1]) and: { n[2] == k[2] } and: { n[3] == k[3] } }
            and: { byNote[k.asString].isNil }) { cancelledIn = cancelledIn + 1 };
    };
    check.(label ++ ": no cancelled hit (the break's, PC 17's) is in the .mid", cancelledIn == 0, cancelledIn.asString);
    // Every step, roll and onset hit the WAVs hold (from their frame 0 to
    // their end) is in the .mid, where the recorder places it.
    inWavs = ctx[\hits].select { |r| var xs = s.(r[\stamp]) * sr; #[\step, \roll, \onset].includes(r[\kind]) and: { xs >= b0 } and: { xs < e0 } };
    absent = inWavs.reject { |r|
        var tk = tickOf.(r[\stamp]), chan = if(r[\kind] == \onset) { 1 } { ((r[\lane] ? 0) + 1).clip(1, 15) };
        pyNotes[if(r[\kind] == \onset) { 2 } { 1 }].any { |n| (n[0] == tk) and: { n[2] == chan } and: { n[3] == r[\note] } }
    };
    early = inWavs.select { |r| tickOf.(r[\stamp]) < 0 };
    say.("hits in the WAVs before the .mid's zero (between their real frame 0 and the lead before audioAt), so left out of it as early: " ++ early.size
        ++ "; hits after the WAVs' last whole block but before stopAt, in the log and at the .mid's end: " ++ (ctx[\partBlock] ? []).size);
    check.(label ++ ": every step, roll and onset hit the WAVs hold (" ++ inWavs.size ++ ", from frame 0 to their end, the tail's too) is a note in the .mid",
        absent.isEmpty, absent.size.asString ++ " missing: " ++ absent.collect { |r| r[\kind] ++ " " ++ r[\note] ++ " "
            ++ (rec.stopAt - r[\stamp]).round(0.0001) ++ " s before stopAt" }.join(", "));
    nAfter = ctx[\hits].count { |r| #[\step, \roll, \onset].includes(r[\kind]) and: { r[\stamp] >= rec.stopAt } };
    past = (pyNotes[1] ++ pyNotes[2]).select { |n| n[0] > endTk };
    check.(label ++ ": nothing heard at or after stopAt is in the .mid: no note-on past tick " ++ endTk ++ " (stopAt), though "
        ++ nAfter ++ " hits sounded after it",
        past.isEmpty and: { nAfter > 0 }, past.size.asString ++ " past it");
};

// The hint against the drums' downbeat in the drums stem.
checkHint = { |ctx|
    var label = ctx[\label], rec = ctx[\rec], rig = ctx[\rig], s = rig[\toScore], hint = rec.liveHint ? "", b0 = ctx[\b0], og = startOf.(rig);
    var rate = ctx[\rate] ? 1;
    var barExact = ((16 * ctx[\num]) / ctx[\den]) * ctx[\s16], barR = (ctx[\num] * (4 / ctx[\den])) * (60 / ctx[\bpmR]);
    var bar1 = numAfter.(hint, "bar 1 is at ") ?? { numAfter.(hint, "first bar line in the files is at ") };
    var shift = numAfter.(hint, "move everything right by ") ?? { if(hint.contains("on the DAW's bar lines there")) { 0 } };
    var fe = ctx[\filesEv] ? (), heard = og + MegaSADrums.loopAudioDelay, truth = heard - rec.audioAt, onBar, hit, g;
    var onsetSec, j, err, k2, err2, tol = (block / sr) + 0.0005, truthLine, placed, really, barW;
    say.("the post window's hint: " ++ hint);
    onBar = { |r| var q = (r[\grid] - og) / barExact; ((q - q.round).abs < 1e-6) and: { q > -1e-9 } };
    check.(label ++ ": the hint names " ++ fixed.(ctx[\bpmR], 2) ++ " BPM and " ++ ctx[\num] ++ "/" ++ ctx[\den] ++ ", bar 1 and the shift",
        hint.beginsWith("In a DAW: " ++ fixed.(ctx[\bpmR], 2) ++ " BPM, " ++ ctx[\num] ++ "/" ++ ctx[\den] ++ ".")
            and: { bar1.notNil } and: { shift.notNil }, hint);
    // The drums' bar 1 as the drums have it: their epoch's origin, heard, on
    // the log's clock from audioAt; or, already playing, the first of their
    // bar lines from audioAt. The recorder places it in the files as it does
    // a note (wavTime); where it really is there, the render says.
    truthLine = if(truth >= 0) { truth } { truth.mod(barExact) };
    placed = (truthLine * rate) + lead;
    really = s.(rec.audioAt + truthLine) - (b0 / sr);
    check.(label ++ ": the files event carries the same hint, bar 1 on the log's clock from audioAt (" ++ truth.round(0.001)
        ++ "), its place in the files (firstBar " ++ placed.round(0.001) ++ ") and the shift",
        (fe["liveHint"] == hint) and: { ((fe["bar1"] !? { |x| x.asFloat } ? inf) - truth.round(0.001)).abs < 1e-9 }
            and: { ((fe["firstBar"] !? { |x| x.asFloat } ? inf) - placed.round(0.001)).abs < 1e-9 }
            and: { ((fe["shift"] !? { |x| x.asFloat } ? inf) - (shift ? -1)).abs <= 0.0011 },
        [fe["bar1"], fe["firstBar"], fe["shift"]].asString);
    check.(label ++ ": the hint's " ++ (if(truth >= 0) { "bar 1" } { "first bar line in the files" })
        ++ " is the drums' (their origin, heard, from audioAt" ++ (if(truth < 0) { ", stepped at their own bar" } { "" })
        ++ ") placed in the files as the .mid's notes are (at the WAVs' clock, after the lead), to the ms",
        bar1.notNil and: { (bar1 - placed).abs <= 0.0005 }, [bar1, placed].asString);
    check.(label ++ ": ...which is where that bar line really is in the WAVs, within half a block and the ms ("
        ++ (((bar1 ? 0) - really) * sr).round(0.1) ++ " samples)",
        bar1.notNil and: { (bar1 - really).abs <= (0.0005 + (32.5 / sr)) }, [bar1, really].asString);
    // The first downbeat the drums stem holds whose onset was measured.
    hit = ctx[\hits].select { |r| (r[\slot] == \steps) and: { r[\kind] == \step } and: { onBar.(r) }
        and: { (s.(r[\stamp]) * sr) >= (b0 + (0.004 * sr)) } and: { (s.(r[\stamp]) * sr) < (ctx[\e0] - (0.004 * sr)) }
        and: { (ctx[\onD][startSample.(s.(r[\stamp]))] ? ())[\onset].notNil } }.asArray.sort { |a, b| a[\stamp] <= b[\stamp] }.first;
    g = hit !? { |h| ctx[\onD][startSample.(s.(h[\stamp]))] };
    if(g.isNil or: { g[\onset].isNil }) {
        check.(label ++ ": a drums downbeat sounds in the files to hold the hint against", false, "none found");
    } {
        onsetSec = g[\onset] / sr;
        // The drums' bar in the files: theirs, at the WAVs' clock.
        barW = barExact * rate;
        j = ((onsetSec - bar1) / barW).round;
        err = onsetSec - (bar1 + (j * barW));
        say.("the first downbeat the drums stem holds: " ++ hit[\note] ++ " (" ++ hit[\which] ++ ", bar "
            ++ (((hit[\grid] - og) / barExact).round.asInteger + 1) ++ " of the drums) at " ++ onsetSec.round(0.000001) ++ " s into the files; the hint's bar line "
            ++ (bar1 + (j * barW)).round(0.000001) ++ " s; " ++ (err * sr).round(0.01) ++ " samples apart");
        check.(label ++ ": the drums' downbeat is in the drums stem where the hint says their bar lines are (within a block and the hint's ms)",
            (err.abs <= tol) and: { (truth < 0) or: { j == ((hit[\grid] - og) / barExact).round } }, (err * sr).round(0.01).asString ++ " samples");
        k2 = ((onsetSec + shift) / barR).round;
        err2 = (onsetSec + shift) - (k2 * barR);
        check.(label ++ ": moved right by the hint's " ++ fixed.(shift, 3) ++ " s, that downbeat is on a bar line of Live's at "
            ++ fixed.(ctx[\bpmR], 2) ++ " BPM (" ++ (err2 * 1000).round(0.001) ++ " ms off)",
            err2.abs <= (tol + (k2 * (barW - barR).abs)), (err2 * sr).round(0.01).asString ++ " samples");
        ctx[\hintErr] = err * sr;
    };
};

// The double press's first set, and what the second found: the first's
// frees after its start, its files valid and as long as their stamps say,
// holding what its render computed.
checkDouble = { |ctx|
    if(ctx[\setA].isNil) { check.(ctx[\label] ++ ": the double press's first set was recorded", false, "nothing captured") } {
        checkFirstSet.(ctx);
    };
};
checkFirstSet = { |ctx|
    var label = ctx[\label], rig = ctx[\rig], s = rig[\toScore], a = ctx[\setA], input = ctx[\input];
    var specs = [[\master, 2, chMaster, "int24"], [\tap, 1, nil, "int24"], [\guitar, 2, chGuitar, "float"],
        [\loop, 2, chLoop, "float"], [\drums, 2, chDrums, "float"], [\onset, 2, chOnset, "float"]];
    var fr, b0, e0, want, res, wavs = IdentityDictionary.new, heads = List.new, diffs, tapErr, logA, filesA, ok;
    check.(label ++ ": the double press: the second press came " ++ ((a[\stop][\press] - a[\start][\press]) * 1000).round(0.1)
        ++ " ms after the first, before its frame 0 (audioAt " ++ ((a[\audioAt] - a[\start][\press]) * 1000).round(0.1) ++ " ms after it); the first set had ended (settled) when the next began, "
        ++ ((a[\renders] ? 0)) ++ " render(s) in",
        (a[\stop][\press] > a[\start][\press]) and: { a[\stop][\press] < a[\audioAt] } and: { a[\settled] == true }
            and: { a[\recording] == false } and: { a[\logging] == false } and: { (a[\renders] ? 0) == 1 },
        [a[\stop][\press], a[\audioAt], a[\settled], a[\recording], a[\logging], a[\renders]].asString);
    fr = freesOf.(rig, a[\start][\ids]);
    check.(label ++ ": ...its synths are freed by ONE bundle stamped the start latency after the stop, so after the bundle that starts them ("
        ++ ((fr.first !? { |f| f[0] - a[\audioAt] } ? 0) * 1000).round(0.1) ++ " ms after it)",
        (fr.size == 1) and: { (fr[0][0] - (a[\stop][\press] + latency)).abs < 1e-9 } and: { fr[0][0] > a[\audioAt] },
        fr.collect(_[0]).asString ++ " against audioAt " ++ a[\audioAt]);
    check.(label ++ ": scsynth found every node it was told to free, in both renders (no \"Node not found\")",
        rig[\renders].every { |r| (r[\said] ? "").contains("not found").not and: { (r[\said] ? "").contains("FAILURE").not } },
        rig[\renders].collect { |r| (r[\bad] ? []).join("; ") }.join(" | "));
    // Its WAVs, from its own render: valid, as long as their stamps say.
    b0 = (blockOf.(s.(a[\audioAt])) * block).asInteger;
    e0 = (blockOf.(s.(a[\stopAt])) * block).asInteger;
    want = e0 - b0;
    specs.do { |sp|
        var w = readWav.(a[\paths][sp[0]]);
        heads.add([sp[0], w !? { |f| [f[\chans], f[\rate], f[\format], f[\header], f[\frames]] }]);
        w !? { |f| wavs.put(sp[0], f) };
    };
    check.(label ++ ": the first set's WAVs are valid WAVs under their final names (" ++ (a[\paths][\master] ? "").basename
        ++ ", ...), each " ++ want ++ " frames (" ++ ((want / sr) * 1000).round(0.1) ++ " ms): from the block of its audioAt to the block of its stopAt",
        heads.every { |h, j| h[1].notNil and: { h[1] == [specs[j][1], sr, specs[j][3], "WAV", want] } } and: { want > 0 },
        heads.asString);
    res = readAll.(rig[\renders][0][\wav]);
    ok = wavs.size == specs.size;
    if(ok) {
        diffs = specs.reject { |sp| sp[2].isNil }.collect { |sp| [sp[0], wavDiff.(wavs[sp[0]], res, b0, sp[2]), sp[3]] };
        tapErr = tapDiff.(wavs[\tap][\data], input, b0);
        check.(label ++ ": ...holding what its render computed: the tap the guitar's input, the master to int24's rounding, the stems bit for bit",
            (tapErr <= (1.01 * lsb)) and: { diffs.every { |p| if(p[2] == "float") { p[1] == 0 } { p[1] <= (1.01 * lsb) } } },
            "tap " ++ (tapErr / lsb).round(0.01) ++ " LSB, " ++ diffs.collect { |p| p[0] ++ " " ++ (p[1] / lsb).round(0.01) ++ " LSB" }.join(", "));
    };
    logA = readLog.(a[\paths][\events]);
    filesA = logA.detect { |e| e["ev"] == "files" } ? ();
    check.(label ++ ": ...and its log ends with files, then sessionStop; the files event's length is its WAVs' and its end its stopAt",
        (logA.keep(-2).collect { |e| e["ev"] } == ["files", "sessionStop"])
            and: { (filesA["frames"] !? { |x| x.asInteger }) == want }
            and: { ((filesA["audioEnd"] !? { |x| x.asFloat } ? inf) - (a[\stopAt] - a[\startedAt]).round(0.0001)).abs < 1e-9 },
        [logA.keep(-2).collect { |e| e["ev"] }, filesA["frames"], filesA["audioEnd"]].asString);
    note.(label ++ ": the first set (" ++ a[\stamp] ++ ") is " ++ want ++ " frames; its clock reads " ++ (filesA["clockPpm"] ? "nothing")
        ++ " ppm, which a set of " ++ ((want / sr) * 1000).round(0.1) ++ " ms can tell to " ++ ((block / ((a[\stopAt] - a[\audioAt]) * sr)) * 1e6).round(0.1)
        ++ " ppm; its log has " ++ logA.count { |e| e["ev"] == "hit" } ++ " hit lines; files: "
        ++ a[\paths].values.asArray.collect { |p| p.basename }.sort.join(", "));
    ctx[\firstFrames] = want;
};

runSet = { |cfg|
    var ctx, c0 = Main.elapsedTime, c1, rig;
    cfg[\setDir] = tmpDir +/+ ("sessions-" ++ cfg[\label]);
    cfg[\loopPath] = tmpDir +/+ (cfg[\label] ++ "-loop.wav");
    cfg[\inPath] = tmpDir +/+ (cfg[\label] ++ "-in.wav");
    File.mkdir(cfg[\setDir]);
    ctx = playSet.(cfg);
    rig = ctx[\rig];
    c1 = Main.elapsedTime;
    tryPart.(cfg[\label] ++ ": the run", { checkRun.(ctx) });
    if(rig[\rendered].notNil and: { rig[\rendered][\error].isNil } and: { ctx[\rec].settled == true }) {
        tryPart.(cfg[\label] ++ ": the files", { checkFiles.(ctx) });
        tryPart.(cfg[\label] ++ ": the hits", { prepare.(ctx) });
        tryPart.(cfg[\label] ++ ": the WAVs", { checkWavs.(ctx) });
        if(ctx[\b0].notNil) {
            tryPart.(cfg[\label] ++ ": the clock", { checkClock.(ctx) });
            tryPart.(cfg[\label] ++ ": the onsets", { measure.(ctx) });
            tryPart.(cfg[\label] ++ ": the log", { checkLog.(ctx) });
            tryPart.(cfg[\label] ++ ": the .mid", { checkMidi.(ctx) });
            tryPart.(cfg[\label] ++ ": the hint", { checkHint.(ctx) });
        };
        if(cfg[\double].notNil) { tryPart.(cfg[\label] ++ ": the double press", { checkDouble.(ctx) }) };
    };
    say.("the drums' drift estimate (dHat) at the end: " ++ ctx[\dHat] ++ " s (their probe gets no server replies here)");
    ctx[\checkWall] = Main.elapsedTime - c1;
    say.("time: the set played in the language in " ++ ((ctx[\playWall] ? 0) - (rig[\renderWall] ? 0)).round(0.01)
        ++ " s (the render" ++ (if(rig[\renders].size > 1) { "s" } { "" }) ++ " inside it " ++ (rig[\renderWall] ? 0).round(0.01)
        ++ " s), the stop's second half after the render (clock, log, renames, .mid, post) "
        ++ (if(rig[\settledAt].notNil and: { rig[\renderEnd].notNil }) { (rig[\settledAt] - rig[\renderEnd]).round(0.001) } { "?" })
        ++ " s, the matched filter " ++ (ctx[\measureWall] ? 0).round(0.01) ++ " s, all the checks " ++ ctx[\checkWall].round(0.01) ++ " s");
    freeRig.(rig);
    if(keep) { kept.add(cfg[\setDir]) };
    ctx
};

// One set's numbers, for the summary.
summarize = { |c|
    var rig = c[\rig];
    say.(c[\label] ++ ": audioAt " ++ (c[\frame0Lag] ? 0).round(0.01) ++ " samples after the WAVs' real frame 0, the WAVs' end "
        ++ (c[\endLag] ? 0).round(0.01) ++ " before stopAt; " ++ c[\frames] ++ " frames; clock " ++ (c[\ppm] ? 0).round(0.01)
        ++ " ppm (to " ++ (c[\ppmRes] ? 0).round(0.1) ++ "; the interface's " ++ ((rig[\e] ? 0) * 1e6).round(0.1) ++ ")");
    say.("    .mid on its onsets: steps " ++ spread.(c[\midiOffs] ? []) ++ ", onsets " ++ spread.(c[\midiOffsOnset] ? [])
        ++ " samples (bound " ++ (c[\midiBound] ? 0).round(0.1) ++ ")"
        ++ (c[\uncorrected] !? { |u| "; at the Mac's clock, its last 2 s " ++ spread.(u) } ? ""));
    say.("    the log on its onsets: placed " ++ spread.(c[\logOffs] ? []) ++ ", at face value " ++ spread.(c[\logRaws] ? []));
    say.("    the tail: " ++ (c[\tail] ? []).size ++ " hits between the stop and stopAt, all logged, the notes among them in the .mid; "
        ++ (c[\partBlock] ? []).size ++ " of them after the WAVs' last whole block; " ++ (c[\after] ? []).size ++ " sounded after stopAt, none logged");
    c[\firstFrames] !? { |n| say.("    the double press's first set: " ++ n ++ " frames, valid") };
};

// ----------------------------------------------------------------- main --
main = Routine {
    var t0 = Main.elapsedTime;
    try {
        (repo +/+ "scripts" +/+ "tests" +/+ "_harness.scd").load;
        (repo +/+ "scripts" +/+ "setup-sa.scd").load;
        MegaSA.loadSynthDefs;
        Looper.newCopyArgs.loadSynthDefs;
        SynthDef(\nrtSessionTap, { |in, out| Out.ar(out, In.ar(in, 2)) }).add;
        // Time, burnt: 300 oscillators, to slow the render where its disk
        // thread must catch up (buildScore).
        SynthDef(\nrtSessionBurn, { |out| Out.ar(out, Mix(SinOsc.ar(Array.fill(300, { |i| 100 + i }))) * 0.0001) }).add;
        File.mkdir(tmpDir.dirname);
        File.mkdir(tmpDir);
        if(wants.("44")) {
            // The recorder at 0.2895 s, so its start bundle falls 10 samples
            // into a block; the take ends at 0.5 s and the drums start a pass
            // later; Beat Repeat on, every capture firing.
            sets.add(runSet.((label: "4-4", bpm: 201.09, num: 4, den: 4, seed: 11, midRun: false,
                recAt: ((367 * 64) + 10) / sr - 0.2, repeats: true, repeatChance: 1.0,
                breakPass: 2, pcOffPass: 4, pcOnPass: 6, stopPass: 8)));
        };
        if(wants.("78")) {
            // The recorder in the drums' second pass, its bundle 58 samples
            // into a block.
            sets.add(runSet.((label: "7-8", bpm: 165.04, num: 7, den: 8, seed: 5, midRun: true,
                recAt: ((5048 * 64) + 58) / sr - 0.2, repeats: true, repeatChance: 1.0,
                breakPass: 3, pcOffPass: 5, pcOnPass: 7, stopPass: 9)));
        };
        if(wants.("clock")) {
            // The interface's crystal 500 ppm fast: the score's time is the
            // host's x (1 + 500e-6). The recorder in the drums' second pass,
            // its bundle 40 samples into a block of the render; some thirty
            // seconds of set.
            sets.add(runSet.((label: "clock", bpm: 123.45, num: 4, den: 4, seed: 7, midRun: true, clockE: 500e-6,
                recAt: ((((6750 * 64) + 40) / sr) / (1 + 500e-6)) - 0.2, repeats: true, repeatChance: 1.0,
                breakPass: 3, pcOffPass: 5, pcOnPass: 7, stopPass: 9, tailHit: true)));
        };
        if(wants.("double")) {
            // A start while the drums play, its bundle 33 samples into a
            // block; the second press 80 ms later; the next set a second
            // after the first press (its bundle 63 samples in), stopped some
            // five seconds later as the others are.
            sets.add(runSet.((label: "double", bpm: 165.04, num: 7, den: 8, seed: 3, midRun: true,
                recAt: (((3300 * 64) + 33) / sr) - 0.2, double: (stopAfter: 0.08, again: 1.0 + (30 / sr)),
                repeats: true, repeatChance: 1.0, stopPass: 3, tailHit: true)));
        };
    } { |err|
        fails = fails + 1;
        ("  FAIL  the sets threw: " ++ err.errorString).postln;
        err.reportError;
    };
    "== what each render cost (scsynth -N; real = wall, user + sys = CPU) ==".postln;
    timings.do { |row|
        say.(row[0].asString.padRight(14) ++ " " ++ row[1].round(0.01).asString.padLeft(6) ++ " s of audio: real "
            ++ (row[2] ? 0).round(0.01) ++ " s, user " ++ (row[3] ? 0).round(0.01) ++ " s, sys " ++ (row[4] ? 0).round(0.01) ++ " s");
    };
    if(notes.notEmpty) {
        "== notes ==".postln;
        notes.do { |n| say.(n) };
    };
    "== the sets ==".postln;
    sets.do { |c| tryPart.("the summary of " ++ c[\label], { summarize.(c) }) };
    say.("all in " ++ (Main.elapsedTime - t0).round(0.1) ++ " s");
    if(kept.notEmpty) { say.("kept: " ++ tmpDir) };
};
main.next;

if(keep.not and: { File.exists(tmpDir) }) { rmTree.(tmpDir) };
(passes.asString ++ " passed, " ++ fails ++ " failed").postln;
LooperSessionRecorder.bufFrames = 65536;
if(fails == 0) { "NRT SESSION PASSED".postln; 0.exit } { "NRT SESSION FAILED".postln; 1.exit };
)
