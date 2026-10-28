// Megalooper SA, Phase 4: the drums end to end in scsynth, non-realtime
// (headless). Design section 10, second bullet: the real code paths, as far as
// NRT allows, rendered and read back.
//
//     /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/sa/nrt-drums.scd
//
// Every scenario builds a real MegaSA (its prBuild: the groups, the guitar
// chain, MegaSADrums.build with its busses, voice groups and effects, the
// strips and the master) and a Looper fixture (scripts/tests/_harness.scd's
// ~tLooper with the Looper's own \looperEngine and \looperMaster), on a stub
// server that writes every message it is sent into a score instead. The
// kits and the reverb's impulse responses are read through the drums' reader
// hooks (kitReader, irReader), which put a /b_allocRead into the score; the
// drums' bundles come through their sender hook at their absolute stamps.
// Nothing here waits: time is the score's, and every routine the Looper
// starts (its MIDI clock, which sends the Start; a break's resume) is stepped
// by hand at the logical times SystemClock would have run it, so the Start
// lands where the Looper's own startMidiClock puts it, through
// MegaSATransport, as on stage. A break goes through Looper.fireBreak, its
// /c_get answered as the server would answer it.
//
//   1. Alignment, at 201.09 BPM 4/4 and 165 BPM 7/8 (two-bar loops whose
//      length is what a take at that tempo gives, not a multiple of a 16th):
//      the Looper's engine plays a loop holding a click on every 16th through
//      \looperMaster and SA's loop chain; a click kit plays the Live main
//      pattern and the onset kit an onset part on 16ths; in 4/4 a break (the
//      \break pattern for a pass), in 7/8 PC 17 off for a pass. Every sounding
//      hit's click is found in the render and set against the loop click it
//      belongs with, after the Limiter's 20 ms: 0 +- 1 sample; rolls, which
//      are off the 16ths, against where their spacing puts them; no click
//      that no sounding hit explains (a cancelled hit writes nothing). Also:
//      the reverb is in (dry at 1 - mix, the wet after its predelay), SA's
//      master is the strips' sum at their levels, the onset kit stops with a
//      break and plays through PC 17, and (a NOTE, the Looper's own) when
//      the loop's break gate closes and opens, seen on a quiet tone in the
//      loop.
//   2. Levels: every kit in presets/sa/drums/kits at velocity 127 on every
//      pad, in both slots, through the reverb and the onset chain and the
//      default strip levels: peaks <= 0 dBFS, no NaN or inf, no silent pad.
//      Also each kit sample's own attack: how long after its first frame it
//      first comes within 20 dB of its peak.
//   3. Listening renders into sessions/sa-spike/ (git-ignored): drums-live-4-4,
//      drums-live-7-8 (the default steps kit: the Live main pattern 8 bars,
//      the break pattern 2 bars through a real break, main 4 bars, through
//      the reverb at the strip level), drums-with-loop (the 29 Sep take, a
//      real loop at its own tempo, with the drums and the onset kit playing
//      the onsets the Looper detected in it), drums-kits (a bar of the main
//      pattern on each kit in turn, every voice's buffer checked against the
//      kit swaps' frees).
//   4. The CPU each render took (scsynth -N under /usr/bin/time), with three
//      baselines: the SA tree idling, the drums' effects alone, an empty score.
//
//   5. Half-time (docs/dev/rc600-picks.md, 3a), at 201.09 BPM 4/4: the
//      clicking loop of 1., half-time pressed through Looper.toggleHalfTime in
//      the third pass (it lands on the fourth's start), pressed again early in
//      the half-speed pass (it ends with it). Every loop click before, at half
//      speed (every other 16th, its peak a sample later, stretched) and after,
//      where the timing says, 0 +- 0 samples, and each on a step of the drums,
//      which slow down with it (2026-10-28): their 16ths twice as long from
//      the landing to the end, on one grid with those before and after; the
//      onset kit at half density, on the loop's clicks.
//
// NRT_DRUMS_ONLY=align,half,levels,attacks,listen,loop,kits runs only those parts.
//
// The scores free every synth before their end: one /n_free per long-lived
// node and /g_freeAll per voice group (a memory-owning synth still running at
// the end hangs scsynth 3.14.1 for good, and a multi-id /n_free stops at the
// first node already gone). No audio device is touched; scores and renders go
// to a folder of this run's own (two runs at once must not share files) and
// are deleted, the listening renders excepted.
//
// Prints PASS or FAIL per check, the measurements, and NRT DRUMS PASSED at
// the end; exits 1 on any failure. A missing or short render (scsynth stopped
// by its watchdog) and an error in a scenario are failures too: a headless
// sclang that throws would otherwise idle for good, its exit never reached.
(
var sr = 48000, block = 64, numOut = 12, numIn = 2;
var repo = (thisProcess.nowExecutingPath !? { |p| if(p[0] == $/) { p.dirname.dirname.dirname } }) ?? { Looper.repoRoot };
// Beside SuperCollider's resources on macOS, on the shell's path on Linux.
var scsynth = MegaSAPlugins.scsynthPath;
var kitDir = repo +/+ "presets" +/+ "sa" +/+ "drums" +/+ "kits";
var outDir = repo +/+ "sessions" +/+ "sa-spike";
// UniqueID counts from the same number in every sclang, so it cannot tell two
// runs apart; the process id can.
var tmpDir = (Platform.defaultTempDir ? "/tmp") +/+ "megalooper-sa"
    +/+ ("nrt-drums-" ++ Date.getDate.stamp ++ "-" ++ thisProcess.pid);
var takeTap = repo +/+ "sessions" +/+ "260929_100616-tap.wav";
var kitKeys = ['carbon-layer', 'carbon', 'one-hit', 'core-808', 'core-909', 'core-dry-session', 'core-707',
    'core-c78', 'core-flares'];
var fails = 0, passes = 0, timings = List.new, files = List.new;
var only = "NRT_DRUMS_ONLY".getenv !? { |v| v.split($,).collect(_.asSymbol) };
var wants = { |part| only.isNil or: { only.includes(part) } };
// The output channels of every render: 0-1 SA's master (the mix as it leaves
// for the interface), then taps after the master: the loop as the mixer gets
// it, the steps after the reverb, the onset kit after its chain, and the two
// voice busses dry.
var chMaster = 0, chLoop = 2, chSteps = 4, chOnset = 6, chStepsDry = 8, chOnsetDry = 10;
var check, say, db, clickFrame, makeStub, readerFor, writeWav, clickWav, clickKit, makeRig, spawnAndAnalyse;
var runTimeline, sounding, buildScore, render, readAll, chanOf, peaksOf, detectNear,
    stats, writeStereo, histo, histoStr, startOf, breakAt, freeRig, bufferLives;
var alignment, halfTimeScene, levels, kitAttacks, listening, withLoop, kitsTour, main;

// ---------------------------------------------------------------- helpers --
check = { |label, cond, detail|
    if(cond == true) { passes = passes + 1; ("  PASS  " ++ label).postln } {
        fails = fails + 1;
        ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
    };
    cond == true
};
say = { |line| ("  " ++ line).postln };
db = { |amp| if(amp <= 0) { "-inf" } { amp.ampdb.round(0.01).asString } };
// The frame a loop's 16th k starts on: the loop's clicks are written there and
// found there, with one formula.
clickFrame = { |k, frames, n16| ((k * frames) / n16).round.asInteger };

// A stub server for one scenario: it answers what MegaSA, MegaSADrums, the
// Looper and the Buffers and Busses they make ask of a server, and writes
// every message into rig[\log] as [score time, [msg, ...]]: an immediate one
// at rig[\wall] (the scenario's "now"), a bundle at now plus its delta. Node
// IDs count up from 2000 so the tree can be built from what was sent; audio
// busses start after the render's outputs and inputs, as on scsynth.
makeStub = { |rig|
    var opts = ServerOptions.new.numOutputBusChannels_(numOut).numInputBusChannels_(numIn);
    var srv = (sampleRate: sr, latency: 0.2, options: opts,
        controlBusAllocator: ContiguousBlockAllocator(16384),
        audioBusAllocator: ContiguousBlockAllocator(1024, 0, numOut + numIn),
        bufferAllocator: ContiguousBlockAllocator(1024));
    srv[\sendMsg] = { |self ... args| rig[\log].add([rig[\wall], [args]]); self };
    srv[\listSendMsg] = { |self, msg| rig[\log].add([rig[\wall], [msg.asArray]]); self };
    srv[\sendBundle] = { |self, time ... args| rig[\log].add([rig[\wall] + (time ? 0), args]); self };
    srv[\listSendBundle] = { |self, time, list| rig[\log].add([rig[\wall] + (time ? 0), list.asArray]); self };
    srv[\sync] = { |self| self };
    srv[\nextNodeID] = { |self| var id = (self[\lastNodeID] ? 1999) + 1; self[\lastNodeID] = id; id };
    srv[\nextBufferNumber] = { |self, n = 1| self[\bufferAllocator].alloc(n) };
    srv[\defaultGroup] = Group.basicNew(srv, 1);
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

// A stereo loop of `frames` with a click on every 16th: 0, 0.25, 0.5, 0.25, 0
// from frame round(k * frames / n16), so its peak is two frames in. The
// Looper's seam declick zeroes the loop's first frame; the click's is 0.
// `tone`: a quiet 750 Hz sine under the clicks (a period a block), to see the
// loop's own gate open and close.
clickWav = { |path, frames, n16, tone = 0|
    var data = FloatArray.newClear(frames * 2), shape = [0, 0.25, 0.5, 0.25, 0], c, i = 0, x;
    if(tone > 0) {
        while { i < frames } { x = tone * sin((2pi * 750) * (i / sr)); data[i * 2] = x; data[(i * 2) + 1] = x; i = i + 1 };
    };
    n16.do { |k|
        c = clickFrame.(k, frames, n16);
        shape.do { |v, j| if((c + j) < frames) { data[((c + j) * 2)] = data[((c + j) * 2)] + v;
            data[((c + j) * 2) + 1] = data[((c + j) * 2) + 1] + v } };
    };
    writeWav.(path, data, 2)
};

// A kit of clicks on every pad 36..51, no velocity response, no choke, no Beat
// Repeat: 0, 0.5, 1, 0.5, 0 at gainDb (0 dB on the steps, -20 dB for the onset
// kit, whose drive would otherwise flatten it).
clickKit = { |dir, key, gainDb|
    var wav = dir +/+ "click.wav", pads;
    if(File.exists(wav).not) {
        writeWav.(wav, FloatArray.newFrom([0, 0.5, 1, 0.5, 0] ++ Array.fill(59, 0)), 1);
    };
    pads = (36 .. 51).collect { |n|
        "\"" ++ n ++ "\": { \"name\": \"Click " ++ n ++ "\", \"layers\": [ { \"group\": \"carbon\", "
            ++ "\"file\": \"click.wav\", \"gainDb\": " ++ gainDb ++ " } ] }"
    }.join(", ");
    File.use(dir +/+ key ++ ".json", "w", { |f|
        f.write("{ \"version\": 1, \"key\": \"" ++ key ++ "\", \"name\": \"NRT clicks\", "
            ++ "\"groups\": { \"carbon\": \"clicks\" }, \"pads\": { " ++ pads ++ " } }")
    });
};

// One SA rig. cfg: loopFile (nil: an engine that plays nothing audible),
// loopFrames, result (the Looper's reading), stepsKit, onsetKit, kitDir (for
// the kits; the reverb is read from the repository's kits folder), seed,
// repeats, declickMs, breakLoops, onsets ([[secs, strength], ...] for
// prBuildOnsetPattern) and t0 (the engine's start, on a block).
makeRig = { |cfg|
    var rig = (log: List.new, wall: 0.0, seen: IdentitySet.new, routines: List.new, cfg: cfg);
    var stub, sa, d, l, outBus, insertBus, phaseBus, buf, taps;
    stub = makeStub.(rig);
    rig[\stub] = stub;
    thisThread.seconds = 0;
    sa = MegaSA(stub);
    // Its init routine would build it a second time when the clock got to it.
    sa.instVarAt(\builder) !? { |r| r.stop };
    sa.prBuild;
    d = sa.drums;
    // The pump is run by hand, at the scenario's times.
    d.instVarAt(\pumpRoutine) !? { |r| r.stop };
    d.wallClock = { rig[\wall] };
    d.sender = { |absTime, msgs| rig[\log].add([absTime ?? { rig[\wall] }, msgs]) };
    d.randSeed = cfg[\seed] ? 1;
    d.kitReader = readerFor.(rig);
    d.irReader = readerFor.(rig);
    d.reloadReverb(true);
    cfg[\kitDir] !? { |k| d.kitDir = k };
    d.setKit(\steps, cfg[\stepsKit]);
    d.setKit(\onset, cfg[\onsetKit]);
    if(cfg[\repeats] == false) { d.setRepeats(false, 0) };
    // The Looper, as ~tLooper makes it, on this stub, with what its init and
    // the setup of SA (setup-sa.scd) give it.
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
    l.metronome = false;
    l.declickMs = cfg[\declickMs] ? 3;
    l.breakLoops = cfg[\breakLoops] ? 1;
    // Looper.init's master: Synth.tail(server, ...) is the default group's tail.
    l.instVarPut(\masterSynth, Synth.tail(stub[\defaultGroup], \looperMaster,
        [\inBus, outBus.index, \out, l.outChannel, \amp, l.masterAmp]));
    sa.attachLooper(l);
    // The loop's buffer: the take as recorded, from frame 0.
    buf = Buffer.new(stub, cfg[\loopFrames], 2, stub.nextBufferNumber(1));
    cfg[\loopFile] !? { |p| rig[\log].add([0, [[\b_allocRead, buf.bufnum, p, 0, -1]]]) };
    l.instVarPut(\buffer, buf);
    l.instVarPut(\startFrame, 0);
    l.instVarPut(\loopFrames, cfg[\loopFrames]);
    // The taps, after the master.
    taps = [[sa.loopFxBus, chLoop], [sa.stepsOutBus, chSteps], [sa.onsetOutBus, chOnset],
        [sa.stepsBus, chStepsDry], [sa.onsetBus, chOnsetDry]].collect { |p|
        Synth.tail(sa.mixerGroup, \nrtDrumsTap, [\in, p[0].index, \out, p[1]])
    };
    rig.putAll((sa: sa, d: d, l: l, taps: taps, loopDur: cfg[\loopFrames] / sr));
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
    eng = if(cfg[\loopFile].notNil) {
        Synth.head(stub[\defaultGroup], defName, [
            \bufnum, l.instVarAt(\buffer).bufnum, \in, l.inChannel, \out, l.instVarAt(\outBus).index,
            \startFrame, 0, \loopFrames, l.loopFrames, \rate, if(l.reverseFlag) { -1 } { 1 },
            \recEnable, 0, \latencyFrames, l.latencyFrames, \feedback, l.feedback,
            \declickFrames, l.declickFrames, \amp, l.prLoopMix,
            \gateBus, l.instVarAt(\insertBus).index, \phaseBus, l.phaseBus.index,
            \gateMode, if(l.bbcut) { l.bbcutGateCode } { 0 }])
    } { Synth.basicNew(defName, stub) };
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

// Every step of the scenario in time order: the pump every 10 ms (its wall a
// little late, as SystemClock's is), the routines the Looper started, and the
// scenario's own events ([time, { |rig, t| }]). Each runs with the drums'
// wall clock, the stub's "now" and thisThread.seconds at its time.
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

// The epoch the Start installed: its origin.
startOf = { |rig| rig[\d].instVarAt(\epochs) !? { |e| e.notEmpty.if { e.last[\t0] } } };

// A stomp `early` seconds before the heard downbeat of the boundary b, through
// the Looper's own fireBreak; its /c_get answered 2 ms later with the engine's
// phase, as the server would; the resume routine fireBreak starts, stepped.
breakAt = { |rig, b, early|
    var stomp = (b + 0.02) - early;
    [[stomp, { |r, t| r[\l].fireBreak }],
     [stomp + 0.002, { |r, t|
        var l = r[\l], phase = ((t - 0.001) - l.loopStartTime) % r[\loopDur];
        thisProcess.recvOSCmessage(t, NetAddr("127.0.0.1", 57110), 57120, ['/c_set', l.phaseBus.index, phase]);
        l.instVarAt(\breakRoutine) !? { |br| r[\routines].add([t, br, \break]) };
     }]]
};

// The score: the log in time order (stable), the defs it uses first, then
// every long-lived node freed by an /n_free of its own and every voice group
// emptied before the end. /c_get (the break's phase query) is the server's to
// answer and is left out. `drop`: SynthDef name prefixes to leave out, with
// every message to their nodes (the CPU baselines).
buildScore = { |rig, endT, drop|
    var d = rig[\d], entries = List.new, defs = IdentitySet.new, live = List.new, seq = 0, out, voiceGroups;
    var isNew = { |m| (m[0] == 9) or: { m[0] == \s_new } or: { m[0] == "/s_new" } };
    var gone = { |m| isNew.(m) and: { (drop ? []).any { |pre| m[1].asString.beginsWith(pre) } } };
    var goneIds = IdentitySet.new;
    rig[\log].do { |e| e[1].do { |m| if(gone.(m) and: { m[2] > 0 }) { goneIds.add(m[2]) } } };
    // A prefix that drops no node at all is a baseline that measures nothing
    // it says it does (a SynthDef renamed under it): said, and counted.
    (drop ? []).do { |pre|
        check.("the baseline's filter '" ++ pre ++ "' drops what it names",
            rig[\log].any { |e| e[1].any { |m| isNew.(m) and: { m[1].asString.beginsWith(pre) } } });
    };
    rig[\log].do { |e|
        var msgs = e[1].reject { |m| (m[0] == \c_get) or: { m[0] == "/c_get" } or: { gone.(m) }
            or: { [11, 15, \n_free, \n_set].includes(m[0]) and: { goneIds.includes(m[1]) } } };
        msgs.do { |m|
            if((m[0] == 9) or: { m[0] == \s_new } or: { m[0] == "/s_new" }) {
                defs.add(m[1].asSymbol);
                if(m[2] > 0) { live.add(m[2]) };
                if(m[3] == 4) { live.remove(m[4]) };
            };
            if((m[0] == 11) or: { m[0] == \n_free } or: { m[0] == "/n_free" }) { m.drop(1).do { |id| live.remove(id) } };
        };
        if(msgs.notEmpty) { entries.add([e[0], seq] ++ [msgs]); seq = seq + 1 };
    };
    entries = entries.asArray.sort { |a, b| (a[0] < b[0]) or: { (a[0] == b[0]) and: { a[1] <= b[1] } } };
    out = defs.asArray.sort.collect { |n|
        var desc = SynthDescLib.global[n];
        if(desc.isNil) { Error("no SynthDef " ++ n).throw };
        [0.0, [\d_recv, desc.def.asBytes]]
    };
    out = out ++ entries.collect { |e| [e[0].max(0)] ++ e[2] };
    voiceGroups = [d.stepsGroup, d.repeatGroup, d.onsetGroup].collect(_.nodeID);
    live.reject { |id| voiceGroups.includes(id) }.do { |id| out = out.add([endT - 0.02, [\n_free, id]]) };
    voiceGroups.do { |g| out = out.add([endT - 0.01, [\g_freeAll, g]]) };
    out.add([endT, [\c_set, 0, 0]])
};

// Render a score; time it (perl's alarm survives the exec and signals
// scsynth itself; /usr/bin/time reports what it cost). No render, or one
// shorter than the score (scsynth stopped by its watchdog), throws.
render = { |name, score, endT|
    var osc = tmpDir +/+ name ++ ".osc", wav = tmpDir +/+ name ++ ".wav", cmd, said, t0, el, nums, bad, sf, n;
    var want = (endT * sr).floor.asInteger;
    Score(score).writeOSCFile(osc);
    // A far UDP port (an NRT scsynth binds one too, and must not take the
    // launcher's), and the real-time pool the \sa profile asks for.
    cmd = "/usr/bin/time -p perl -e 'alarm shift; exec @ARGV' 900 " ++ scsynth.quote
        ++ " -u " ++ (58800 + 150.rand) ++ " -m 65536 -N " ++ osc.quote
        ++ " _ " ++ wav.quote ++ " " ++ sr ++ " WAV float -o " ++ numOut ++ " -i " ++ numIn ++ " 2>&1";
    t0 = Main.elapsedTime;
    said = cmd.unixCmdGetStdOut;
    el = Main.elapsedTime - t0;
    nums = (real: nil, user: nil, sys: nil);
    bad = List.new;
    said.split($\n).do { |line|
        [\real, \user, \sys].do { |k|
            if(line.beginsWith(k.asString ++ " ")) { nums[k] = line.split($ ).last.asFloat };
        };
        // An allocation that fails inside a UGen only says "alloc failed".
        if(line.contains("FAILURE") or: { line.contains("rror") } or: { line.contains("late ") }
            or: { line.contains("alloc") } or: { line.contains("memory") }) { bad.add(line) };
    };
    bad.do { |line| ("  scsynth: " ++ line).postln };
    timings.add([name, endT, nums[\real] ? el, nums[\user], nums[\sys]]);
    File.delete(osc);
    sf = SoundFile.openRead(wav);
    n = sf !? { |f| var k = f.numFrames; f.close; k };
    if(n.isNil or: { n < want }) {
        Error(name ++ ": " ++ (n !? { |k| "a short render, " ++ k ++ " of " ++ want ++ " frames" } ? "no render")
            ++ " (scsynth: " ++ said.split($\n).reject(_.isEmpty).keep(-4).join(" | ") ++ ")").throw;
    };
    (wav: wav, bad: bad, said: said)
};

readAll = { |path|
    var sf = SoundFile.openRead(path), data, n, ch;
    if(sf.isNil) { Error("no render at " ++ path).throw };
    n = sf.numFrames;
    ch = sf.numChannels;
    data = FloatArray.newClear(n * ch);
    sf.readData(data);
    sf.close;
    (data: data, frames: n, chans: ch)
};

chanOf = { |res, c|
    var n = res[\frames], nch = res[\chans], d = res[\data], out = FloatArray.newClear(n), i = 0;
    while { i < n } { out[i] = d[(i * nch) + c]; i = i + 1 };
    out
};

// Local maxima over `thresh`.
peaksOf = { |xs, thresh|
    var out = List.new, i = 1, n = xs.size - 1;
    while { i < n } {
        if((xs[i] > thresh) and: { xs[i] > xs[i - 1] } and: { xs[i] >= xs[i + 1] }) { out.add(i) };
        i = i + 1;
    };
    out.asArray
};

// The peak in `peaks` (sorted) nearest to e, within tol; or nil.
detectNear = { |peaks, e, tol|
    var lo = 0, hi = peaks.size - 1, mid, best;
    while { lo <= hi } {
        mid = (lo + hi) div: 2;
        if(peaks[mid] < e) { lo = mid + 1 } { hi = mid - 1 };
    };
    [lo - 1, lo].do { |i|
        if((i >= 0) and: { i < peaks.size } and: { (peaks[i] - e).abs <= tol }) {
            if(best.isNil or: { (peaks[i] - e).abs < (best - e).abs }) { best = peaks[i] };
        };
    };
    best
};

// Peak, RMS and the samples at SA's master clip, of channels a and a + 1 from
// frame `from`; and NaN/inf.
stats = { |res, a, from = 0|
    var n = res[\frames], nch = res[\chans], d = res[\data], pk = 0, sq = 0, clip = 0, bad = 0, i = from, x, c;
    while { i < n } {
        c = 0;
        while { c < 2 } {
            x = d[(i * nch) + a + c];
            if(x.isNaN or: { x.abs == inf }) { bad = bad + 1 } {
                if(x.abs > pk) { pk = x.abs };
                sq = sq + (x * x);
                if(x.abs >= 0.9799) { clip = clip + 1 };
            };
            c = c + 1;
        };
        i = i + 1;
    };
    (peak: pk, rms: (sq / ((n - from).max(1) * 2)).sqrt, clip: clip, bad: bad, secs: (n - from) / sr)
};

// Channels a, a + 1 from frame `from` to their own file.
writeStereo = { |res, a, from, path|
    var n = res[\frames] - from, nch = res[\chans], d = res[\data], out = FloatArray.newClear(n * 2), i = 0;
    while { i < n } {
        out[i * 2] = d[((i + from) * nch) + a];
        out[(i * 2) + 1] = d[((i + from) * nch) + a + 1];
        i = i + 1;
    };
    writeWav.(path, out, 2);
    files.add([path, n / sr]);
    path
};

histo = { |xs| var h = Dictionary.new; xs.do { |x| h[x] = (h[x] ? 0) + 1 }; h };
histoStr = { |h| h.keys.asArray.sort.collect { |k| (if(k > 0) { "+" } { "" }) ++ k ++ ": " ++ h[k] }.join(", ") };

// The scenario's server side goes; what it sent at free is not rendered.
freeRig = { |rig|
    rig[\routines].do { |e| e[1].stop };
    rig[\l].instVarAt(\midiClockRoutine) !? { |r| r.stop };
    rig[\l].instVarAt(\breakRoutine) !? { |r| r.stop };
    rig[\sa].free;
};

// Every voice the drums sent against the buffers the score holds: its buffer
// read before it starts and not freed until its sound and release are over
// (MegaSADrums frees a kit's buffers a second after their last voice can
// end). Answers [voices, buffers freed, problems].
bufferLives = { |rig|
    var events = Dictionary.new, voices = List.new, heads = Dictionary.new, bad = List.new, freed = 0;
    rig[\log].do { |e|
        e[1].do { |m|
            var k = m[0].asString;
            case
            { k.contains("b_allocRead") } { events[m[1]] = (events[m[1]] ? List.new).add([e[0], \alloc, m[2]]) }
            { k.contains("b_free") } { events[m[1]] = (events[m[1]] ? List.new).add([e[0], \free]); freed = freed + 1 }
            { (k == "s_new") and: { m[1].asString.beginsWith("megaSADrumVoice") } } { voices.add([e[0], m]) };
        };
    };
    voices.do { |v|
        var t = v[0], a = ().putPairs(v[1].copyToEnd(5)), evs = events[a[\buf]] ? [], alloc, next, head, len, end;
        evs.do { |x| if(x[0] <= t) { if(x[1] == \alloc) { alloc = x } { alloc = nil } } };
        next = evs.detect { |x| (x[0] > t) and: { x[1] == \free } };
        if(alloc.isNil) { bad.add("a voice at " ++ t.round(0.001) ++ " plays buffer " ++ a[\buf] ++ ", not read then") } {
            head = heads[alloc[2]] ?? { var sf = SoundFile.openRead(alloc[2]);
                var h = [sf.numFrames, sf.sampleRate]; sf.close; heads[alloc[2]] = h; h };
            len = ((head[0] - (a[\startFrames] ? 0)).max(0)) / (head[1] * (a[\rate] ? 1));
            if((a[\dur] ? 0) > 0) { len = len.min(a[\dur]) };
            if((a[\gateLen] ? 0) > 0) { len = len.min(a[\gateLen]) };
            end = t + len + (a[\release] ? 0.005);
            if(next.notNil and: { next[0] < end }) {
                bad.add("buffer " ++ a[\buf] ++ " freed at " ++ next[0].round(0.001) ++ " under a voice sounding until "
                    ++ end.round(0.001));
            };
        };
    };
    [voices.size, freed, bad]
};

// ------------------------------------------------------------- alignment --
alignment = { |label, bpm, num, den, withBreak|
    var k = 2, beats = (k * num * 4) / den, frames = ((beats * (60 / bpm)) * sr).asInteger;
    var n16 = MegaSADrums.sixteenthsFor((numerator: num, denominator: den, k: k));
    var clickDir = tmpDir +/+ "clicks", loopPath = tmpDir +/+ (label ++ "-loop.wav");
    var t0 = 0.5, tau, result, rig, d, l, b1, events, endT, passes8, res, loopCh, stepsCh, onsetCh;
    var loopPeaks, stepPeaks, onsetPeaks, hits, off = List.new, offRoll = List.new, offOnset = List.new;
    var offStamp = List.new, expectLoop, missingLoop = 0, extra, matched = IdentitySet.new, missing = List.new;
    var engineLag = List.new, nan, rendered, s16f, breakFrom, breakTo, wrongPattern = 0, srcOf, onsetIdx, ties = List.new;
    var tone = if(withBreak) { 0.02 } { 0 }, dryCh, first, ratio, wetAt, mixErr, stomp, mask, bmax, closeB, openB, nb;
    var onsetInBreak, onsetBack, masterL, wetEnergy, pcOff, pcOn, offHits, onsetWhile, backOn;
    ("== alignment " ++ label ++ ": " ++ bpm ++ " BPM " ++ num ++ "/" ++ den ++ ", a loop of " ++ frames
        ++ " frames (" ++ n16 ++ " sixteenths of " ++ (frames / n16).round(0.01) ++ ")"
        ++ if(withBreak) { ", a break of one pass" } { ", PC 17 off for one pass" } ++ " ==").postln;
    if(File.exists(clickDir).not) { File.mkdir(clickDir) };
    clickKit.(clickDir, "nrtclick", 0);
    clickKit.(clickDir, "nrtclickquiet", -20);
    clickWav.(loopPath, frames, n16, tone);
    tau = if(den == 8) { 30 / bpm } { 60 / bpm };
    result = (bpm: bpm, numerator: num, denominator: den, k: k, sub: 1, tau: tau, n: k * num,
        loopDur: frames / sr, phase: 0, downbeatOffset: 0, score: 1, accent: 1);
    // An onset part on 16ths, as a take's detected onsets would come.
    onsetIdx = if(n16 >= 32) { [0, 3, 6, 10, 13, 19, 22, 27, 30] } { [0, 3, 6, 10, 13, 17, 20, 24] };
    rig = makeRig.((loopFile: loopPath, loopFrames: frames, result: result, stepsKit: \nrtclick,
        onsetKit: \nrtclickquiet, kitDir: clickDir, seed: 11, declickMs: 0, breakLoops: 2,
        onsets: onsetIdx.collect { |i, j| [(i * (frames / n16)) / sr, 0.4 + (0.6 * ((j % 3) / 2))] }));
    d = rig[\d];
    l = rig[\l];
    spawnAndAnalyse.(rig, t0, t0 + 0.05);
    passes8 = 7;
    // Without a break, PC 17 instead: the steps off 30 ms before the heard
    // downbeat of the fourth pass, on again 30 ms before the fifth's.
    events = if(withBreak) { breakAt.(rig, t0 + (4 * rig[\loopDur]), 0.03) } {
        [[(t0 + (3 * rig[\loopDur])) - 0.01, { |r, t| r[\d].toggleOn }],
         [(t0 + (4 * rig[\loopDur])) - 0.01, { |r, t| r[\d].toggleOn }]]
    };
    endT = t0 + (passes8 * rig[\loopDur]) + 1.0;
    runTimeline.(rig, t0 + 0.05, endT - 0.6, events);
    b1 = startOf.(rig);
    check.(label ++ ": the Looper's own startMidiClock started the drums on the loop boundary after its "
        ++ "pre-roll (t0 + 1 loop), through MegaSATransport",
        b1.notNil and: { (b1 - (t0 + rig[\loopDur])).abs < 1e-9 },
        "epoch at " ++ b1 ++ ", boundary " ++ (t0 + rig[\loopDur]));
    check.(label ++ ": nothing dropped as late", d.dropped == 0, d.dropped.asString ++ " dropped");
    rendered = render.("align-" ++ label, buildScore.(rig, endT), endT);
    check.(label ++ ": scsynth said nothing went wrong", rendered[\bad].isEmpty, rendered[\bad].join("; "));
    res = readAll.(rendered[\wav]);
    loopCh = chanOf.(res, chLoop);
    stepsCh = chanOf.(res, chSteps);
    onsetCh = chanOf.(res, chOnset);
    nan = res[\data].detectIndex { |x| x.isNaN or: { x.abs == inf } };
    check.(label ++ ": no sample NaN or inf", nan.isNil, "first at " ++ nan);

    // The loop: every click the engine plays comes out of SA's loop path (the
    // Looper's master, its Limiter, the loop's effects) 960 samples later.
    loopPeaks = peaksOf.(loopCh, 0.1);
    s16f = frames / n16;
    expectLoop = List.new;
    passes8.do { |p|
        n16.do { |kk|
            var e = (((t0 * sr).round.asInteger + (p * frames)) + clickFrame.(kk, frames, n16)) + 2;
            var g = (t0 + (p * rig[\loopDur])) + ((kk * s16f) / sr);
            var inBreak = withBreak and: { g >= ((t0 + (4 * rig[\loopDur])) - 0.06) } and: { g < (t0 + (5 * rig[\loopDur]) + 0.01) };
            if(inBreak.not) { expectLoop.add(e) };
        };
    };
    expectLoop.do { |e|
        var m = detectNear.(loopPeaks, e + 960, 40);
        if(m.isNil) { missingLoop = missingLoop + 1 } { engineLag.add((m - e).asInteger) };
    };
    say.("loop clicks measured " ++ engineLag.size ++ " of " ++ expectLoop.size ++ "; heard after the engine plays them by "
        ++ histoStr.(histo.(engineLag)) ++ " samples");
    check.(label ++ ": the loop is heard 960 samples (20 ms, MegaSADrums.loopAudioDelay) after the engine plays it, every click",
        (missingLoop == 0) and: { engineLag.every { |x| x == 960 } },
        missingLoop.asString ++ " missing, lags " ++ histoStr.(histo.(engineLag)));

    // The drums.
    stepPeaks = peaksOf.(stepsCh, 0.35);
    onsetPeaks = peaksOf.(onsetCh, 0.1);
    hits = sounding.(rig);
    srcOf = IdentityDictionary.new;
    rig[\seen].do { |r| srcOf.put(r[\id], r) };
    breakFrom = (t0 + (4 * rig[\loopDur])) - 0.03;
    breakTo = t0 + (5 * rig[\loopDur]);
    hits.do { |h|
        var e = ((h[\stamp] * sr).round.asInteger) + 2, peaks, m, lp, src, er;
        peaks = if(h[\slot] == \onset) { onsetPeaks } { stepPeaks };
        m = detectNear.(peaks, e, 6);
        if(m.isNil) { missing.add(h) } {
            matched.add(m + (if(h[\slot] == \onset) { 0.5 } { 0 }));
            offStamp.add((m - e).asInteger);
            if(m != e) { ties.add([h[\kind], h[\note], ((h[\stamp] * sr) % block).round(1e-4), (m - e).asInteger]) };
            lp = detectNear.(loopPeaks, m, 40);
            case
            { h[\kind] == \roll } {
                src = srcOf[h[\src]];
                er = src !? { |s| detectNear.(loopPeaks, ((s[\stamp] * sr).round.asInteger) + 2, 40) };
                // where the roll spacing puts it from its note's loop click
                er !? { |x| offRoll.add((m - (x + ((h[\grid] - src[\grid]) * sr)).round).asInteger) };
            }
            { lp.notNil } {
                if(h[\slot] == \onset) { offOnset.add((m - lp).asInteger) } { off.add((m - lp).asInteger) };
            }
            {
                // in the break the loop is muted: against the grid's own click position
                er = ((((h[\grid] - t0) * sr).round.asInteger) + ((t0 * sr).round.asInteger)) + 962;
                if(h[\slot] == \onset) { offOnset.add((m - er).asInteger) } { off.add((m - er).asInteger) };
            };
        };
        if(withBreak and: { h[\slot] == \steps }) {
            if((h[\grid] >= (breakFrom - 1e-9)) and: { h[\grid] < (breakTo - 1e-9) }) {
                if(h[\which] != \break) { wrongPattern = wrongPattern + 1 };
            } { if(h[\which] != \main) { wrongPattern = wrongPattern + 1 } };
        };
    };
    extra = (stepPeaks.size - (hits.select { |h| h[\slot] == \steps }.collect { |h| (h[\stamp] * sr).round }.asSet.size))
        + (onsetPeaks.size - (hits.select { |h| h[\slot] == \onset }.collect { |h| (h[\stamp] * sr).round }.asSet.size));
    say.("hits that sounded: " ++ hits.count { |h| h[\kind] == \step } ++ " steps, "
        ++ hits.count { |h| h[\kind] == \roll } ++ " roll hits, " ++ hits.count { |h| h[\kind] == \onset }
        ++ " onset hits; " ++ rig[\seen].count { |h| h[\cancelled] == true } ++ " cancelled, "
        ++ d.dropped ++ " dropped");
    say.("steps on the grid vs their loop click: " ++ histoStr.(histo.(off)) ++ " (samples: count)");
    say.("onset kit vs its loop click: " ++ histoStr.(histo.(offOnset)));
    say.("roll hits vs their note's loop click plus the roll spacing: " ++ histoStr.(histo.(offRoll))
        ++ " (" ++ offRoll.size ++ " of " ++ hits.count { |h| h[\kind] == \roll } ++ "; a roll whose note is in a "
        ++ "break, where the loop is muted, has no loop click to go by)");
    say.("every hit vs its own stamp (OffsetOut, the voice, the effects): " ++ histoStr.(histo.(offStamp)));
    check.(label ++ ": every sounding hit was found in the render (none missing)", missing.isEmpty,
        missing.size.asString ++ " missing, first " ++ (missing.first !? { |h| [h[\kind], h[\note], h[\stamp]] }));
    check.(label ++ ": no click in the render that no sounding hit explains (nothing doubled, no cancelled hit heard)",
        extra == 0, extra.asString ++ " unexplained peaks");
    check.(label ++ ": every step on the grid lands on its loop click, 0 +- 1 sample",
        off.notEmpty and: { off.every { |x| x.abs <= 1 } }, histoStr.(histo.(off)));
    check.(label ++ ": every onset-kit hit lands on its loop click, 0 +- 1 sample",
        offOnset.notEmpty and: { offOnset.every { |x| x.abs <= 1 } }, histoStr.(histo.(offOnset)));
    check.(label ++ ": every roll hit lands where its spacing puts it, 0 +- 1 sample",
        offRoll.every { |x| x.abs <= 1 }, histoStr.(histo.(offRoll)));
    // scsynth rounds a bundle's time to the nearest sample of its block, and
    // a time in the block's last half sample rounds to 64, which it clamps to
    // 63: such a hit starts one sample early. A time ON a half sample (to
    // 1e-4, as the steps of 7/8 here can be) rounds either way: which, the
    // OSC time tag's last bit decides, not the stamp this side computed.
    ties.do { |t| say.("off its stamp's sample: " ++ t[0] ++ " " ++ t[1] ++ ", stamped " ++ t[2]
        ++ " samples into its block, by " ++ t[3]) };
    check.(label ++ ": every hit starts on the sample its stamp rounds to (OffsetOut, through the effects), "
        ++ "but in a block's last half sample, which scsynth clamps one early",
        offStamp.notEmpty and: { ties.every { |t| ((t[2] >= (block - 0.5)) and: { t[3] == -1 })
            or: { ((t[2].frac - 0.5).abs < 1e-3) and: { t[3].abs == 1 } } } },
        histoStr.(histo.(offStamp)));
    if(withBreak) {
        check.(label ++ ": through the break the \\break pattern alone plays, the main pattern on either side",
            wrongPattern == 0, wrongPattern.asString ++ " hits of the wrong pattern");
    };

    // The reverb is in (its spectra read through irReader, Synth.replace'd):
    // the first steps hit after the Start, alone, comes out at the dry's
    // 1 - 0.1508, its wet after the 10 ms predelay.
    dryCh = chanOf.(res, chStepsDry);
    first = hits.detect { |h| (h[\slot] == \steps) and: { h[\kind] == \step } };
    first = ((first[\stamp] * sr).round.asInteger) + 2;
    ratio = stepsCh[first] / dryCh[first];
    wetAt = ((first - 2) .. (first + 3000)).detect { |i| (stepsCh[i] - (dryCh[i] * (1 - d.reverbMix))).abs > (1e-4 * dryCh[first]) };
    wetEnergy = ((first + 400) .. (first + 3000)).sum { |i| (stepsCh[i] - (dryCh[i] * (1 - d.reverbMix))).squared };
    say.("the reverb (" ++ d.reverbState ++ "): dry at " ++ ratio.round(1e-5) ++ " of the voices, its wet from "
        ++ (wetAt !? { |w| w - (first - 2) }) ++ " samples after the hit");
    check.(label ++ ": the steps go through the real reverb: dry at 1 - mix, the wet no sooner than the 480-sample predelay",
        (d.reverbState == \ready) and: { (ratio - (1 - d.reverbMix)).abs < 1e-4 } and: { wetAt.notNil }
            and: { (wetAt - (first - 2)) >= 480 } and: { wetEnergy > 0 },
        "state " ++ d.reverbState ++ ", ratio " ++ ratio ++ ", wet at " ++ wetAt);

    // SA's mixer: the master is the loop's strip, the drums' and the onset
    // kit's, at their levels, and nothing else, through its clip at 0.98 (four
    // clicks of this kit at once go over it).
    mixErr = 0;
    [0, 1].do { |side|
        var mst = chanOf.(res, chMaster + side), lp = chanOf.(res, chLoop + side), st = chanOf.(res, chSteps + side);
        var on = chanOf.(res, chOnset + side), i = 0, x;
        while { i < res[\frames] } {
            x = (mst[i] - ((lp[i] + (st[i] * rig[\sa].level(\drums))) + (on[i] * rig[\sa].level(\onsetKit))).clip2(0.98)).abs;
            if(x > mixErr) { mixErr = x };
            i = i + 1;
        };
    };
    check.(label ++ ": SA's master is loop + drums x " ++ rig[\sa].level(\drums).round(1e-4) ++ " + onset kit x "
        ++ rig[\sa].level(\onsetKit).round(1e-4) ++ " (clipped at 0.98), to " ++ mixErr.round(1e-8), mixErr < 1e-5, mixErr.asString);

    if(withBreak.not) {
        // PC 17: no steps hit from its off edge (the heard moment less 20 ms)
        // to its on edge; the onset kit, which PC 17 leaves alone, all through.
        pcOff = (t0 + (3 * rig[\loopDur])) - 0.03;
        pcOn = (t0 + (4 * rig[\loopDur])) - 0.03;
        offHits = hits.count { |h| (h[\slot] == \steps) and: { h[\grid] >= (pcOff - 1e-9) } and: { h[\grid] < (pcOn - 1e-9) } };
        onsetWhile = hits.count { |h| (h[\slot] == \onset) and: { h[\grid] >= pcOff } and: { h[\grid] < pcOn } };
        backOn = hits.count { |h| (h[\slot] == \steps) and: { h[\grid] >= pcOn } and: { h[\grid] < (pcOn + (rig[\loopDur] / 2)) } };
        say.("PC 17 off for a pass: " ++ offHits ++ " steps hits in it (" ++ rig[\seen].count { |h| h[\cancelled] == true }
            ++ " cancelled), " ++ onsetWhile ++ " onset-kit hits, " ++ backOn ++ " steps hits in the bar after it is on again");
        check.(label ++ ": PC 17 silences the steps from the moment heard and brings them back, the onset kit playing on",
            (offHits == 0) and: { onsetWhile > 0 } and: { backOn > 0 }, [offHits, onsetWhile, backOn].asString);
    };
    if(withBreak) {
        // The onset kit across the break: the Looper stops its onset notes at
        // the stomp and starts them again at the break's end.
        stomp = ((t0 + (4 * rig[\loopDur])) + 0.02) - 0.03;
        onsetInBreak = hits.count { |h| (h[\slot] == \onset) and: { h[\grid] > (stomp - 0.014) }
            and: { h[\grid] < ((t0 + (5 * rig[\loopDur])) - 1e-6) } };
        onsetBack = hits.detect { |h| (h[\slot] == \onset) and: { (h[\grid] - (t0 + (5 * rig[\loopDur]))).abs < 1e-6 } };
        check.(label ++ ": the onset kit stops with the break (the Looper's stopOnsetNotes) and is back on its downbeat",
            (onsetInBreak == 0) and: { onsetBack.notNil }, onsetInBreak.asString ++ " in the break, back: " ++ onsetBack.notNil);
        // The loop's own gate (\looperMaster's breakAmp, after its Limiter),
        // seen on the quiet tone: when it closes after the stomp and opens
        // again, against the drums, whose main pattern is heard again at the
        // boundary plus 20 ms.
        mask = Array.fill(res[\frames], false);
        loopPeaks.do { |c| ((c - 8) .. (c + 8)).do { |j| if((j >= 0) and: { j < mask.size }) { mask[j] = true } } };
        nb = res[\frames] div: block;
        bmax = Array.fill(nb, { |bi|
            var mx = 0, j = bi * block, x;
            while { j < ((bi + 1) * block) } {
                if(mask[j].not) { x = loopCh[j].abs; if(x > mx) { mx = x } };
                j = j + 1;
            };
            mx
        });
        closeB = ((((stomp * sr) / block).floor.asInteger) .. (nb - 1)).detect { |bi| bmax[bi] < (0.5 * (0.7 * tone)) };
        openB = closeB !? { |c| ((c + 1) .. (nb - 1)).detect { |bi| bmax[bi] > (0.5 * (0.7 * tone)) } };
        // Not a check: the gate is the Looper's (Looper.fireBreak/endBreak), and
        // this is what it does, for the record.
        say.("NOTE  the loop's own gate (Looper's breakAmp, after its Limiter): shut "
            ++ (((closeB * block / sr) - stomp) * 1000).round(0.1) ++ " ms after the stomp, where the drums' break pattern "
            ++ "is heard from; open again " ++ (((openB * block / sr) - ((t0 + (5 * rig[\loopDur])) + 0.02)) * 1000).round(0.1)
            ++ " ms from the heard downbeat the drums' main pattern comes back on (block resolution, 1.3 ms)");
        rig[\gate] = [closeB !? { |c| (c * block / sr) - stomp }, openB !? { |o| (o * block / sr) - ((t0 + (5 * rig[\loopDur])) + 0.02) }];
    };
    File.delete(rendered[\wav]);
    File.delete(loopPath);
    freeRig.(rig);
    (steps: off, onset: offOnset, roll: offRoll, stamp: offStamp, loop: engineLag, gate: rig[\gate])
};

// ------------------------------------------------------------- half-time --
halfTimeScene = { |label, bpm, num, den|
    var k = 2, beats = (k * num * 4) / den, frames = ((beats * (60 / bpm)) * sr).asInteger;
    var n16 = MegaSADrums.sixteenthsFor((numerator: num, denominator: den, k: k));
    var clickDir = tmpDir +/+ "clicks", loopPath = tmpDir +/+ ("half-" ++ label ++ "-loop.wav");
    var t0 = 0.5, tau, result, rig, d, l, ld, landAt, endAt, events, endT, rendered, res, loopCh, stepsCh, onsetCh;
    var loopPeaks, stepPeaks, onsetPeaks, expect = List.new, missing = List.new, offLoop = List.new, onGrid = List.new;
    var g0, s16f, offGrid, gridOf, inHalf, hits, offOnset = List.new, onsetIdx, nan, speeds = List.new, valid = List.new;
    var landS, endS, halfSteps;
    var f0, press, lastFrame;
    ("== half-time " ++ label ++ ": " ++ bpm ++ " BPM " ++ num ++ "/" ++ den ++ ", a loop of " ++ frames
        ++ " frames, pressed in the third pass, again in the half-speed one ==").postln;
    if(File.exists(clickDir).not) { File.mkdir(clickDir) };
    clickKit.(clickDir, "nrtclick", 0);
    clickKit.(clickDir, "nrtclickquiet", -20);
    clickWav.(loopPath, frames, n16, 0);
    tau = if(den == 8) { 30 / bpm } { 60 / bpm };
    result = (bpm: bpm, numerator: num, denominator: den, k: k, sub: 1, tau: tau, n: k * num,
        loopDur: frames / sr, phase: 0, downbeatOffset: 0, score: 1, accent: 1);
    onsetIdx = [0, 3, 6, 10, 13, 17, 20, 24];
    rig = makeRig.((loopFile: loopPath, loopFrames: frames, result: result, stepsKit: \nrtclick,
        onsetKit: \nrtclickquiet, kitDir: clickDir, seed: 11, declickMs: 0,
        onsets: onsetIdx.collect { |i, j| [(i * (frames / n16)) / sr, 0.4 + (0.6 * ((j % 3) / 2))] }));
    d = rig[\d];
    l = rig[\l];
    ld = rig[\loopDur];
    spawnAndAnalyse.(rig, t0, t0 + 0.05);
    SimpleController(l).put(\speed, { |o, w, v| speeds.add([thisThread.seconds, v]) });
    landAt = t0 + (3 * ld);
    endAt = t0 + (5 * ld);
    // A press, through the Looper's own gesture; the routine it starts for
    // the landing (or the end), stepped at its logical times.
    press = { |r, t|
        r[\l].toggleHalfTime;
        r[\l].instVarAt(\halfTimeRoutine) !? { |hr| r[\routines].add([t, hr, \halfTime]) };
    };
    events = [[t0 + (2.3 * ld), press], [t0 + (3.6 * ld), press]]
        ++ [2.5, 4.0, 6.5].collect { |p| [t0 + (p * ld), { |r, t| valid.add([p, r[\d].prLoopValid]) }] };
    endT = t0 + (7 * ld) + 1.0;
    runTimeline.(rig, t0 + 0.05, endT - 0.6, events);
    check.("half-time " ++ label ++ ": it landed on the fourth pass's start and ended with the half-speed pass",
        (speeds.size == 2) and: { (speeds[0][0] - landAt).abs < 1e-6 } and: { speeds[0][1] == 0.5 }
            and: { (speeds[1][0] - endAt).abs < 1e-6 } and: { speeds[1][1] == 1 },
        speeds.asArray.asString);
    check.("half-time " ++ label ++ ": the drums' loop model (their drift probe) off at half-time only",
        valid.asArray == [[2.5, true], [4.0, false], [6.5, true]], valid.asArray.asString);
    check.("half-time " ++ label ++ ": nothing dropped as late", d.dropped == 0, d.dropped.asString ++ " dropped");
    rendered = render.("half-" ++ label, buildScore.(rig, endT), endT);
    check.("half-time " ++ label ++ ": scsynth said nothing went wrong", rendered[\bad].isEmpty, rendered[\bad].join("; "));
    res = readAll.(rendered[\wav]);
    loopCh = chanOf.(res, chLoop);
    stepsCh = chanOf.(res, chSteps);
    onsetCh = chanOf.(res, chOnset);
    nan = res[\data].detectIndex { |x| x.isNaN or: { x.abs == inf } };
    check.("half-time " ++ label ++ ": no sample NaN or inf", nan.isNil, "first at " ++ nan);

    // Where the engine plays each click's peak (frame 2 of its five): three
    // passes at speed 1, one half-speed pass (frame c at 2c from its start),
    // two passes at speed 1; heard 960 samples later.
    f0 = (t0 * sr).round.asInteger;
    3.do { |p| n16.do { |kk| expect.add(f0 + (p * frames) + clickFrame.(kk, frames, n16) + 2) } };
    n16.do { |kk| expect.add(f0 + (3 * frames) + (2 * (clickFrame.(kk, frames, n16) + 2))) };
    2.do { |p| n16.do { |kk| expect.add(f0 + ((5 + p) * frames) + clickFrame.(kk, frames, n16) + 2) } };
    // The seven passes heard; the render's last second plays an eighth.
    lastFrame = f0 + (7 * frames) + 960;
    loopPeaks = peaksOf.(loopCh, 0.1).select { |x| x < lastFrame };
    stepPeaks = peaksOf.(stepsCh, 0.35).select { |x| x < lastFrame };
    onsetPeaks = peaksOf.(onsetCh, 0.1);
    expect.do { |e|
        var m = detectNear.(loopPeaks, e + 960, 40);
        if(m.isNil) { missing.add(e) } { offLoop.add((m - (e + 960)).asInteger) };
    };
    say.("loop clicks found " ++ offLoop.size ++ " of " ++ expect.size ++ " (" ++ loopPeaks.size
        ++ " peaks in the loop's channel); off where the timing says: " ++ histoStr.(histo.(offLoop)));
    check.("half-time " ++ label ++ ": every loop click where the timing says, at speed 1, at half speed and after, 0 samples",
        missing.isEmpty and: { offLoop.every { |x| x == 0 } } and: { loopPeaks.size == expect.size },
        missing.size.asString ++ " missing, " ++ (loopPeaks.size - expect.size) ++ " more peaks than clicks, off "
            ++ histoStr.(histo.(offLoop)));
    // The drums slow down with the loop (the duo's choice, 2026-10-28): every
    // step they play (not a roll's hits, which are off the 16ths) sits on its
    // first step's 16th grid up to the landing, on 16ths twice as long from
    // there to the end, and on 16ths again after it, both edges on a step of
    // the grid before. A click's peak is its frame 2.
    s16f = frames / n16;
    hits = sounding.(rig).select { |h| (h[\kind] == \step) and: { h[\stamp] < (t0 + (7 * ld)) } }
        .collect { |h| detectNear.(stepPeaks, ((h[\stamp] * sr).round.asInteger) + 2, 6) };
    g0 = hits.first;
    // The edges as heard, on the grid before them (the loop's 960 samples late).
    landS = ((((landAt * sr) + 960) - g0) / s16f).round * s16f + g0;
    endS = landS + ((endAt - landAt) * sr);
    gridOf = { |x|
        case
        { x < (landS - (s16f / 2)) } { (((x - g0) / s16f).round * s16f) + g0 }
        { x < (endS - (s16f / 2)) } { (((x - landS) / (2 * s16f)).round * (2 * s16f)) + landS }
        { (((x - endS) / s16f).round * s16f) + endS }
    };
    offGrid = hits.collect { |x| x !? { (x - gridOf.(x)).round.asInteger } };
    say.("the drums' steps against their grid, " ++ hits.size ++ " of them: " ++ histoStr.(histo.(offGrid.reject(_.isNil))));
    check.("half-time " ++ label ++ ": the drums' steps on their 16ths, twice as long at half-time, +- 1 sample",
        (hits.size > 40) and: { offGrid.every { |x| x.notNil and: { x.abs <= 1 } } },
        offGrid.count(_.isNil).asString ++ " not found, " ++ histoStr.(histo.(offGrid.reject(_.isNil))));
    // (one per step: two lanes on a step are one peak)
    halfSteps = hits.reject(_.isNil).asSet.asArray.sort.select { |x| (x >= (landS - 2)) and: { x < (endS - 2) } };
    check.("half-time " ++ label ++ ": at half-time the drums play at half tempo (no two steps closer than two 16ths)",
        (halfSteps.size > 4) and: { halfSteps.differentiate.drop(1).every { |dx| dx >= ((2 * s16f) - 2) } },
        halfSteps.size.asString ++ " steps, gaps " ++ halfSteps.differentiate.drop(1).asSet.asArray.sort);
    // The loop on that grid: at speed 1 its click's peak on it; at half
    // speed the click is stretched, its peak (frame 2) two samples later
    // than the grid point its start is on, at every 16th of the drums' then.
    inHalf = { |x| (x >= ((landAt * sr) + 960)) and: { x < ((endAt * sr) + 960) } };
    loopPeaks.do { |x| onGrid.add((x - gridOf.(x)).round.asInteger - (if(inHalf.(x)) { 2 } { 0 })) };
    say.("the loop's clicks against the drums' grid (at half speed less the stretched peak's 2): "
        ++ histoStr.(histo.(onGrid)));
    check.("half-time " ++ label ++ ": the loop stays on the drums' grid, at half speed on each of their 16ths, +- 1 sample",
        onGrid.notEmpty and: { onGrid.every { |x| x.abs <= 1 } } and: { loopPeaks.any(inHalf) },
        histoStr.(histo.(onGrid)));
    // The onset kit at half density: each hit on one of the loop's clicks
    // (at half speed, the stretched peak's 2 samples after it).
    hits = sounding.(rig).select { |h| (h[\slot] == \onset) and: { h[\stamp] < (t0 + (7 * ld)) } };
    hits.do { |h|
        var e = ((h[\stamp] * sr).round.asInteger) + 2, m = detectNear.(onsetPeaks, e, 6), lp;
        m !? { lp = detectNear.(loopPeaks, m, 40);
            lp !? { offOnset.add(((m - lp) + (if(inHalf.(lp)) { 2 } { 0 })).asInteger) } };
    };
    say.("the onset kit's hits against the loop's clicks: " ++ histoStr.(histo.(offOnset)));
    check.("half-time " ++ label ++ ": the onset kit plays on the loop's clicks, at half speed too, 0 +- 1 sample",
        (offOnset.size == hits.size) and: { hits.any { |h| (h[\stamp] > landAt) and: { h[\stamp] < endAt } } }
            and: { offOnset.every { |x| x.abs <= 1 } },
        offOnset.size.asString ++ " of " ++ hits.size ++ " found, " ++ histoStr.(histo.(offOnset)));
    freeRig.(rig);
};

// --------------------------------------------------------------- levels --
// One kit in both slots, every pad at velocity 127: on the steps through the
// lane-0 note (Live main pattern replaced by one hit a bar), on the onset kit
// through MegaSATransport's noteOn a second later.
levels = { |key|
    var bpm = 120, frames = (2 * sr).asInteger, t0 = 0.5, rig, d, l, pads, events, b1, endT, rendered, res;
    var steps, onset, master, stepsAmp, onsetAmp, rows = List.new, nanCount = 0, silent = List.new, hits;
    var result = (bpm: bpm, numerator: 4, denominator: 4, k: 1, sub: 1, tau: 0.5, n: 4, loopDur: 2.0);
    rig = makeRig.((loopFrames: frames, result: result, stepsKit: key, onsetKit: key, seed: 3, repeats: false));
    d = rig[\d];
    l = rig[\l];
    pads = d.pads(\steps);
    4.do { |lane|
        d.setSteps(\main, \chance, lane, Array.fill(16, { |i| if((lane == 0) and: { i == 0 }) { 6 } { 0 } }));
        d.setSteps(\main, \velo, lane, Array.fill(16, 6));
        d.setSteps(\main, \alt, lane, Array.fill(16, 0));
        d.setSteps(\main, \roll, lane, Array.fill(16, 0));
    };
    spawnAndAnalyse.(rig, t0, t0 + 0.05);
    b1 = t0 + 2.0;
    events = pads.collect { |note, i|
        [[(b1 + (i * 2)) - 0.5, { |r, t| r[\d].setLaneParam(\main, 0, \note, note) }],
         [(b1 + (i * 2) + 1) - 0.1, { |r, t| r[\d].transport.noteOn(1, note, 127) }]]
    }.flatten(1);
    endT = b1 + (pads.size * 2) + 0.5;
    runTimeline.(rig, t0 + 0.05, endT - 0.4, events, 0);
    rendered = render.("levels-" ++ key, buildScore.(rig, endT), endT);
    res = readAll.(rendered[\wav]);
    nanCount = res[\data].count { |x| x.isNaN or: { x.abs == inf } };
    stepsAmp = rig[\sa].level(\drums);
    onsetAmp = rig[\sa].level(\onsetKit);
    hits = sounding.(rig);
    pads.do { |note, i|
        var s = b1 + (i * 2) + 0.02, o = b1 + (i * 2) + 1, win, pk, pkm, pko, hs, ho;
        win = { |c, from, secs|
            var a = (from * sr).round.asInteger, b = ((from + secs) * sr).round.asInteger.min(res[\frames]), m = 0, x, j = a;
            while { j < b } {
                x = res[\data][(j * res[\chans]) + c].abs.max(res[\data][(j * res[\chans]) + c + 1].abs);
                if(x > m) { m = x };
                j = j + 1;
            };
            m
        };
        pk = win.(chSteps, s, 0.98) * stepsAmp;
        pko = win.(chOnset, o, 0.98) * onsetAmp;
        pkm = win.(chMaster, s, 0.98).max(win.(chMaster, o, 0.98));
        hs = hits.detect { |h| (h[\slot] == \steps) and: { h[\note] == note } };
        ho = hits.detect { |h| (h[\slot] == \onset) and: { h[\note] == note } };
        if(hs.isNil or: { pk < -70.dbamp }) { silent.add([\steps, note]) };
        if(ho.isNil or: { pko < -70.dbamp }) { silent.add([\onset, note]) };
        rows.add([note, d.padName(\steps, note), pk, pko, pkm]);
    };
    File.delete(rendered[\wav]);
    freeRig.(rig);
    (key: key, rows: rows, nan: nanCount, silent: silent, bad: rendered[\bad], stepsAmp: stepsAmp, onsetAmp: onsetAmp)
};

// Each kit sample's own attack: frames before it first comes within 20 dB of
// its peak (any channel), read from the files the kits name.
kitAttacks = {
    var out = List.new, seen = Set.new;
    kitKeys.do { |key|
        var kit = MegaSAKit.read(MegaSAKit.fileFor(kitDir, key), List.new);
        kit !? {
            kit.notes.do { |note|
                kit.pad(note)[\layers].do { |layer|
                    var path = kit.pathFor(layer, kitDir), sf, data, pk, first, ch, n;
                    if(seen.includes(path).not) {
                        seen.add(path);
                        sf = SoundFile.openRead(path);
                        sf !? {
                            ch = sf.numChannels;
                            n = sf.numFrames.min((sf.sampleRate * 0.5).asInteger);
                            data = FloatArray.newClear(n * ch);
                            sf.readData(data);
                            sf.close;
                            pk = data.abs.maxItem;
                            first = data.detectIndex { |x| x.abs >= (pk * 0.1) } !? { |i| i div: ch };
                            out.add((kit: key, note: note, file: PathName(path).fileName, rate: sf.sampleRate,
                                ms: (first ? 0) / sf.sampleRate * 1000, firstAny: (data.detectIndex { |x| x.abs > 1e-4 } ? 0) div: ch));
                        };
                    };
                };
            };
        };
    };
    out
};

// ------------------------------------------------------------ listening --
// The default steps kit: main for 8 bars, a break (Looper.fireBreak, struck
// 30 ms before the heard downbeat of bar 9, breakLoops 2: one pass of the
// two-bar loop), then main for 4 bars; the reverb and the strip.
listening = { |name, bpm, num, den|
    var k = 2, beats = (k * num * 4) / den, frames = ((beats * (60 / bpm)) * sr).asInteger, t0 = 0.5;
    var tau = if(den == 8) { 30 / bpm } { 60 / bpm }, result, rig, d, b1, events, endT, rendered, res, st, hits;
    var bfrom, bto, wrong = 0, keys, dup = 0, misplaced = 0, bars = List.new, barDur, perBar, path;
    result = (bpm: bpm, numerator: num, denominator: den, k: k, sub: 1, tau: tau, n: k * num, loopDur: frames / sr);
    rig = makeRig.((loopFrames: frames, result: result, stepsKit: 'carbon-layer', onsetKit: 'one-hit', seed: 5,
        breakLoops: 2));
    d = rig[\d];
    spawnAndAnalyse.(rig, t0, t0 + 0.05);
    b1 = t0 + rig[\loopDur];
    events = breakAt.(rig, b1 + (4 * rig[\loopDur]), 0.03);
    endT = b1 + (7 * rig[\loopDur]) + 1.5;
    runTimeline.(rig, t0 + 0.05, endT - 0.7, events);
    check.(name ++ ": the Start on the boundary after the pre-roll", ((startOf.(rig) ? 0) - b1).abs < 1e-9);
    if(name == "drums-live-4-4") {
        // CPU baselines: the same score with no drum voice (the SA tree
        // idling), then without the two chains too, their sources and every
        // device's synth (left: the drums' reverb and onset chain, the
        // Looper's master, the strips),
        // and an empty score of the same length (scsynth's own cost).
        File.delete(render.(name ++ " (no hits)", buildScore.(rig, endT, ["megaSADrumVoice"]), endT)[\wav]);
        File.delete(render.(name ++ " (drum fx only)", buildScore.(rig, endT,
            ["megaSADrumVoice", "megaSAChain", "megaSADev"]), endT)[\wav]);
        File.delete(render.("empty score", [[0.0, [\c_set, 0, 0]], [endT, [\c_set, 0, 0]]], endT)[\wav]);
        // scsynth's start (its plugins) and end: a one-second empty score.
        File.delete(render.("empty score, 1 s", [[0.0, [\c_set, 0, 0]], [1.0, [\c_set, 0, 0]]], 1.0)[\wav]);
    };
    rendered = render.(name, buildScore.(rig, endT), endT);
    res = readAll.(rendered[\wav]);
    path = writeStereo.(res, chMaster, ((b1 - 0.1) * sr).round.asInteger, outDir +/+ name ++ ".wav");
    st = stats.(res, chMaster, ((b1 - 0.1) * sr).round.asInteger);
    hits = sounding.(rig);
    bfrom = (b1 + (4 * rig[\loopDur])) - 0.03;
    bto = b1 + (5 * rig[\loopDur]);
    keys = Dictionary.new;
    hits.do { |h|
        var key;
        if(h[\slot] == \steps) {
            if((h[\grid] >= (bfrom - 1e-9)) and: { h[\grid] < (bto - 1e-9) }) {
                if(h[\which] != \break) { wrong = wrong + 1 } } { if(h[\which] != \main) { wrong = wrong + 1 } };
            key = [h[\kind], h[\which], h[\epoch], h[\lane], h[\n], h[\j] ? 0, h[\k] ? 0, h[\note]];
            if(keys[key].notNil) { dup = dup + 1 } { keys[key] = h };
            if(h[\kind] != \repeat) {
                if(((h[\stamp] - h[\grid]) - 0.02).abs > 1e-9) { misplaced = misplaced + 1 };
            };
        };
    };
    barDur = rig[\loopDur] / k;
    perBar = (0 .. 13).collect { |i|
        var a = ((b1 + (i * barDur)) * sr).round.asInteger, b = ((b1 + ((i + 1) * barDur)) * sr).round.asInteger;
        var s = 0, j = a, x;
        while { j < b } { x = res[\data][(j * res[\chans]) + chMaster]; s = s + (x * x); j = j + 1 };
        (s / (b - a)).sqrt.ampdb.round(0.1)
    };
    say.(PathName(path).fileName ++ ": " ++ st[\secs].round(0.01) ++ " s, peak " ++ db.(st[\peak]) ++ " dBFS, RMS "
        ++ db.(st[\rms]) ++ " dBFS, " ++ st[\clip] ++ " samples at the master's clip (0.98)");
    say.("  bars' RMS (dBFS), bars 9-10 the break: " ++ perBar);
    say.("  hits: " ++ hits.count { |h| (h[\kind] == \step) and: { h[\which] == \main } } ++ " main steps, "
        ++ hits.count { |h| (h[\kind] == \step) and: { h[\which] == \break } } ++ " break steps, "
        ++ hits.count { |h| h[\kind] == \roll } ++ " roll hits, " ++ hits.count { |h| h[\kind] == \repeat }
        ++ " Beat Repeat repeats (" ++ d.captures.size ++ " captures kept); "
        ++ rig[\seen].count { |h| h[\cancelled] == true } ++ " cancelled by the break, " ++ d.dropped ++ " dropped");
    check.(name ++ ": the break pattern alone in the break, the main pattern outside it", wrong == 0, wrong.asString);
    check.(name ++ ": no hit doubled", dup == 0, dup.asString);
    check.(name ++ ": every step and roll stamped at grid + 20 ms exactly", misplaced == 0, misplaced.asString);
    check.(name ++ ": no NaN or inf, peak under the master's clip", (st[\bad] == 0) and: { st[\peak] < 0.98 },
        "peak " ++ db.(st[\peak]) ++ ", " ++ st[\bad] ++ " bad");
    check.(name ++ ": no bar is silent", perBar.every { |x| x > -60 }, perBar.asString);
    check.(name ++ ": scsynth said nothing went wrong", rendered[\bad].isEmpty, rendered[\bad].join("; "));
    File.delete(rendered[\wav]);
    freeRig.(rig);
    (stats: st, perBar: perBar, hits: hits)
};

// The 29 Sep 2026 take (sessions/260929_100616): 1.579 s recorded from the
// press at 3.0757 s of the session (the dry tap's frame 0 is 0.0417 s in), the
// Looper's reading 152.0 BPM 2/4, two bars, and the onsets it detected, as the
// take's log has them. The dry tap is the guitar before Bias FX: the Looper
// recorded the processed guitar, which no file of this take holds.
withLoop = {
    var press = 3.0757 - 0.0417, frames = (1.5789252364726 * sr).asInteger, t0 = 0.5, src, seg, sf, n, i, x;
    var loopPath = tmpDir +/+ "take-loop.wav", result, onsets, rig, d, l, b1, endT, rendered, res, st, hits, path;
    var loopSt, onsetPat;
    sf = SoundFile.openRead(takeTap);
    if(sf.isNil) { Error("no take at " ++ takeTap).throw };
    src = FloatArray.newClear(frames * sf.numChannels);
    sf.seek((press * sr).round.asInteger, 0);
    sf.readData(src);
    n = sf.numChannels;
    sf.close;
    // The Looper records both sides of the guitar chain, which is dual mono:
    // the same sample on each.
    seg = FloatArray.newClear(frames * 2);
    i = 0;
    while { i < frames } { x = src[i * n]; seg[i * 2] = x; seg[(i * 2) + 1] = x; i = i + 1 };
    writeWav.(loopPath, seg, 2);
    result = (accent: 0.95325697807519, bpm: 152.00213059877, denominator: 4, downbeatOffset: 0.0, k: 2,
        loopDur: 1.5789252364726, n: 8, numerator: 2, onsetCount: 5, phase: 0, score: 0.1993642502353, sub: 2,
        tau: 0.19736565455907);
    onsets = [[0.0053333332762122, 0.0054669147357345], [0.79466664791107, 0.44974148273468],
        [1.1840000152588, 0.47710266709328], [1.3919999599457, 0.24308228492737], [1.5839999914169, 0.31388169527054]];
    rig = makeRig.((loopFile: loopPath, loopFrames: frames, result: result, stepsKit: 'carbon-layer',
        onsetKit: 'one-hit', seed: 9, onsets: onsets));
    d = rig[\d];
    l = rig[\l];
    spawnAndAnalyse.(rig, t0, t0 + 0.05);
    b1 = t0 + rig[\loopDur];
    endT = b1 + (10 * rig[\loopDur]) + 1.5;
    runTimeline.(rig, t0 + 0.05, endT - 0.7, []);
    onsetPat = l.instVarAt(\onsetNotePattern);
    rendered = render.("drums-with-loop", buildScore.(rig, endT), endT);
    res = readAll.(rendered[\wav]);
    path = writeStereo.(res, chMaster, (t0 * sr).round.asInteger, outDir +/+ "drums-with-loop.wav");
    st = stats.(res, chMaster, (t0 * sr).round.asInteger);
    loopSt = stats.(res, chLoop, (t0 * sr).round.asInteger);
    hits = sounding.(rig);
    say.("drums-with-loop.wav: " ++ st[\secs].round(0.01) ++ " s (the loop alone for a pass, then 10 passes with "
        ++ "the drums), peak " ++ db.(st[\peak]) ++ " dBFS, RMS " ++ db.(st[\rms]) ++ " dBFS, " ++ st[\clip]
        ++ " samples at the master's clip; the loop alone: peak " ++ db.(loopSt[\peak]) ++ ", RMS " ++ db.(loopSt[\rms]));
    say.("  the onset part the Looper built: " ++ onsetPat.collect { |p| [p[0].round(0.001), p[1].round(0.01)] }
        ++ ", velocities " ++ onsetPat.collect { |p| l.onsetVelocity(p[1]) });
    say.("  hits: " ++ hits.count { |h| h[\kind] == \step } ++ " steps, " ++ hits.count { |h| h[\kind] == \roll }
        ++ " roll hits, " ++ hits.count { |h| h[\kind] == \repeat } ++ " repeats, "
        ++ hits.count { |h| h[\kind] == \onset } ++ " onset hits, " ++ d.dropped ++ " dropped");
    check.("drums-with-loop: the onset kit plays the take's onsets every pass, on the loop's time",
        hits.select { |h| h[\kind] == \onset }.every { |h|
            var ph = ((h[\grid] - t0) % rig[\loopDur]);
            onsetPat.any { |p| ((p[0] - ph).abs < 1e-6) or: { ((p[0] - ph).abs - rig[\loopDur]).abs < 1e-6 } }
                and: { ((h[\stamp] - h[\grid]) - 0.02).abs < 1e-9 }
        } and: { hits.count { |h| h[\kind] == \onset } >= (10 * onsetPat.size) });
    check.("drums-with-loop: no NaN or inf, peak under the master's clip", (st[\bad] == 0) and: { st[\peak] < 0.98 },
        "peak " ++ db.(st[\peak]));
    check.("drums-with-loop: scsynth said nothing went wrong", rendered[\bad].isEmpty, rendered[\bad].join("; "));
    File.delete(rendered[\wav]);
    File.delete(loopPath);
    freeRig.(rig);
    (stats: st)
};

// One bar of the main pattern on each kit in turn, switched (setKit) shortly
// before each bar line, as a menu change would be.
kitsTour = {
    var bpm = 201.09, frames = ((8 * (60 / bpm)) * sr).asInteger, t0 = 0.5, result, rig, d, b1, barDur, events;
    var endT, rendered, res, st, hits, path, perBar, byKit, lives;
    result = (bpm: bpm, numerator: 4, denominator: 4, k: 2, sub: 1, tau: 60 / bpm, n: 8, loopDur: frames / sr);
    rig = makeRig.((loopFrames: frames, result: result, stepsKit: kitKeys[0], onsetKit: 'one-hit', seed: 13));
    d = rig[\d];
    spawnAndAnalyse.(rig, t0, t0 + 0.05);
    b1 = t0 + rig[\loopDur];
    barDur = rig[\loopDur] / 2;
    events = kitKeys.drop(1).collect { |key, i|
        [(b1 + ((i + 1) * barDur)) - 0.115, { |r, t| r[\d].setKit(\steps, key) }]
    };
    // After the last bar the transport stops, from the moment its downbeat
    // would be heard (the explicit-time core: a Stop told ahead of its time),
    // so no tenth bar starts; the tails ring.
    events = events.add([(b1 + (kitKeys.size * barDur)) - 0.105, { |r, t|
        r[\d].transportStop((b1 + (kitKeys.size * barDur)) + 0.02) }]);
    endT = b1 + (kitKeys.size * barDur) + 1.5;
    runTimeline.(rig, t0 + 0.05, endT - 0.7, events);
    rendered = render.("drums-kits", buildScore.(rig, endT), endT);
    res = readAll.(rendered[\wav]);
    path = writeStereo.(res, chMaster, ((b1 - 0.1) * sr).round.asInteger, outDir +/+ "drums-kits.wav");
    st = stats.(res, chMaster, ((b1 - 0.1) * sr).round.asInteger);
    hits = sounding.(rig);
    perBar = kitKeys.collect { |key, i|
        var a = ((b1 + (i * barDur)) * sr).round.asInteger, b = ((b1 + ((i + 1) * barDur)) * sr).round.asInteger;
        var s = 0, pk = 0, j = a, x;
        while { j < b } { x = res[\data][(j * res[\chans]) + chMaster]; s = s + (x * x); pk = pk.max(x.abs); j = j + 1 };
        [key, (s / (b - a)).sqrt.ampdb.round(0.1), pk.ampdb.round(0.1),
            hits.count { |h| (h[\slot] == \steps) and: { h[\kit] == key } }]
    };
    // A step plays the kit of its bar; a roll hit or a repeat may sound in the
    // first moments of a bar on its note's kit, or (decided after the swap) on
    // the next bar's.
    byKit = hits.select { |h| h[\slot] == \steps }.every { |h|
        var bar = ((h[\grid] - b1) / barDur).floor.asInteger.clip(0, kitKeys.size - 1);
        (h[\kit] == kitKeys[bar]) or: { (h[\kind] != \step)
            and: { ((bar > 0) and: { h[\kit] == kitKeys[bar - 1] })
                or: { ((bar + 1) < kitKeys.size) and: { h[\kit] == kitKeys[bar + 1] } } } }
    };
    say.("drums-kits.wav: " ++ st[\secs].round(0.01) ++ " s, peak " ++ db.(st[\peak]) ++ " dBFS, RMS " ++ db.(st[\rms])
        ++ " dBFS, " ++ st[\clip] ++ " samples at the master's clip");
    perBar.do { |row| say.("  bar " ++ (kitKeys.indexOf(row[0]) + 1) ++ " " ++ row[0] ++ ": RMS " ++ row[1] ++ " dBFS, peak "
        ++ row[2] ++ " dBFS, " ++ row[3] ++ " hits of that kit") };
    check.("drums-kits: each bar's steps on the kit switched in for it", byKit);
    lives = bufferLives.(rig);
    say.("  buffers: " ++ lives[0] ++ " voices against their buffers, " ++ lives[1] ++ " buffers freed as kits went");
    check.("drums-kits: every voice's buffer read before it and freed only after it (kit swaps)", lives[2].isEmpty,
        lives[2].keep(3).join("; "));
    check.("drums-kits: no NaN or inf, peak under the master's clip, every bar sounding",
        (st[\bad] == 0) and: { st[\peak] < 0.98 } and: { perBar.every { |r| r[1] > -60 } });
    check.("drums-kits: scsynth said nothing went wrong", rendered[\bad].isEmpty, rendered[\bad].join("; "));
    File.delete(rendered[\wav]);
    freeRig.(rig);
    (stats: st, perBar: perBar)
};

// ----------------------------------------------------------------- main --
main = Routine {
    var al = IdentityDictionary.new, lv = List.new, att, ls = IdentityDictionary.new, t;
    try {
        (repo +/+ "scripts" +/+ "tests" +/+ "_harness.scd").load;
        MegaSA.loadSynthDefs;
        Looper.newCopyArgs.loadSynthDefs;
        SynthDef(\nrtDrumsTap, { |in, out| Out.ar(out, In.ar(in, 2)) }).add;
        File.mkdir(tmpDir);
        if(File.exists(outDir).not) { File.mkdir(outDir) };

        if(wants.(\align)) {
            al[\fourFour] = alignment.("4-4", 201.09, 4, 4, true);
            al[\sevenEight] = alignment.("7-8", 165, 7, 8, false);
        };
        if(wants.(\half)) { halfTimeScene.("4-4", 201.09, 4, 4) };

        if(wants.(\levels)) {
        "== levels: every kit at velocity 127, every pad, both slots, the default strips ==".postln;
        kitKeys.do { |key| lv.add(levels.(key)) };
        say.("kit                 pads  steps strip (dBFS) max / min       onset strip (dBFS) max / min    master max  NaN");
        lv.do { |r|
            var s = r[\rows].collect { |row| row[2] }, o = r[\rows].collect { |row| row[3] }, m = r[\rows].collect { |row| row[4] };
            var smax = r[\rows][s.maxIndex], smin = r[\rows][s.minIndex], omax = r[\rows][o.maxIndex], omin = r[\rows][o.minIndex];
            say.(r[\key].asString.padRight(19) ++ " " ++ r[\rows].size.asString.padLeft(3) ++ "   "
                ++ (db.(smax[2]) ++ " (" ++ smax[0] ++ ") / " ++ db.(smin[2]) ++ " (" ++ smin[0] ++ ")").padRight(30)
                ++ (db.(omax[3]) ++ " (" ++ omax[0] ++ ") / " ++ db.(omin[3]) ++ " (" ++ omin[0] ++ ")").padRight(31)
                ++ db.(m.maxItem).padLeft(7) ++ "  " ++ r[\nan]);
        };
        lv.do { |r|
            var s = r[\rows].collect { |row| row[2].max(row[3]) };
            check.(r[\key].asString ++ ": every pad at 127 under 0 dBFS through its strip, both slots, and the master under its clip",
                (s.maxItem <= 1) and: { r[\rows].every { |row| row[4] < 0.98 } },
                "loudest " ++ db.(s.maxItem) ++ " dBFS");
            check.(r[\key].asString ++ ": no NaN or inf, no silent pad", (r[\nan] == 0) and: { r[\silent].isEmpty },
                r[\nan].asString ++ " bad samples; silent " ++ r[\silent]);
            check.(r[\key].asString ++ ": scsynth said nothing went wrong", r[\bad].isEmpty, r[\bad].join("; "));
        };
        };

        if(wants.(\attacks)) {
        "== the kit samples' own attacks ==".postln;
        att = kitAttacks.();
        say.(att.size.asString ++ " files; their first frame within 20 dB of the peak: median "
            ++ att.collect { |a| a[\ms] }.median.round(0.01) ++ " ms, max " ++ att.collect { |a| a[\ms] }.maxItem.round(0.01) ++ " ms");
        att.select { |a| a[\ms] > 2 }.sort { |a, b| a[\ms] >= b[\ms] }.do { |a|
            say.("  " ++ a[\kit] ++ " " ++ a[\note] ++ " " ++ a[\file] ++ ": " ++ a[\ms].round(0.01) ++ " ms (first frame over -80 dBFS: "
                ++ a[\firstAny] ++ ")");
        };
        };

        "== listening renders (sessions/sa-spike) ==".postln;
        if(wants.(\listen)) {
            ls[\fourFour] = listening.("drums-live-4-4", 201.09, 4, 4);
            ls[\sevenEight] = listening.("drums-live-7-8", 165, 7, 8);
        };
        if(wants.(\loop)) { ls[\loop] = withLoop.() };
        if(wants.(\kits)) { ls[\kits] = kitsTour.() };
    } { |err|
        fails = fails + 1;
        ("  FAIL  the scenarios threw: " ++ err.errorString).postln;
        err.reportError;
    };

    "== what each render cost (scsynth -N; real = wall, user + sys = CPU; net = less a 1 s empty score's) ==".postln;
    t = timings.detect { |row| row[0] == "empty score, 1 s" } !? { |row| (row[3] ? 0) + (row[4] ? 0) };
    timings.do { |row|
        var cpu = (row[3] ? 0) + (row[4] ? 0);
        say.(row[0].asString.padRight(30) ++ " " ++ row[1].round(0.01).asString.padLeft(6) ++ " s of audio: real "
            ++ (row[2] ? 0).round(0.01) ++ " s, user " ++ (row[3] ? 0).round(0.01) ++ " s, sys " ++ (row[4] ? 0).round(0.01)
            ++ " s" ++ (t !? { |base| ", net " ++ (((cpu - base).max(0) / row[1]) * 1000).round(0.1)
                ++ " ms of CPU a second of audio" } ? ""));
    };
    "== files ==".postln;
    files.do { |f| say.(f[0] ++ " (" ++ f[1].round(0.01) ++ " s)") };
};
main.next;

(tmpDir +/+ "clicks" +/+ "*").pathMatch.do { |p| File.delete(p) };
File.delete(tmpDir +/+ "clicks");
(tmpDir +/+ "*").pathMatch.do { |p| File.delete(p) };
File.delete(tmpDir);
(passes.asString ++ " passed, " ++ fails ++ " failed").postln;
if(fails == 0) { "NRT DRUMS PASSED".postln; 0.exit } { "NRT DRUMS FAILED".postln; 1.exit };
)
