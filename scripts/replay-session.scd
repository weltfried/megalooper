// Replay a recorded set through onset detection and the meter analyser.
//
// A set recorded with the Record-set switch leaves its files in sessions/ (see
// LooperSessionRecorder): the master, the dry tap the detector heard, on SA the
// stems and the drums' .mid, and an event log saying where every take sits in
// that tap, what the analyser made of it and what the player did about it. A
// take moved by the next-reading switch is a take the analyser got wrong, and
// the reading it settled on is the label; a take played on as heard is a weak
// label the other way. Since Phase 5 the files are renamed when the set stops,
// with its tempo and signature (261007_143012-165.04bpm-7-8-tap.wav); a set is
// still named by its stamp here, and found under either name.
//
// This script cuts each take's stretch out of the tap, renders it through the
// recorder's OWN onset chain (Looper.prOnsetTrig, in scsynth non-realtime) at a
// sweep of thresholds, runs every onset list through MeterAnalyzer and the
// Looper's own snapping, and reports which thresholds would have agreed with
// the player. It checks itself as it goes: at the threshold that was in force
// on stage, the replay should reproduce the stage reading — where it does not,
// the fidelity column says so before any tuning conclusion is drawn.
//
//     sclang scripts/replay-session.scd                  # the newest set
//     ~replaySession = "260928_183000";                  # one set, by stamp (renamed or not)
//     ~replayThresholds = [0.3, 0.5, 0.7];               # the sweep (the stage threshold is always added)
//     ~replayCsv = "/tmp/replay.csv";                    # every cell, for a spreadsheet
//     ~replaySelfTest = true;                            # a synthetic set, rendered and asserted
//     ~replayTap = "/path/x-tap.wav";                    # a tap with no log...
//     ~replayManual = [[startSec, durSec], ...];         # ...with the takes placed by hand
//     ~replayPeakWindows = [0.15, 0.25];                 # the "peak" rows' windows, seconds
//     ~replayPeakRatio = 1.4;                            # how much louder a neighbour must be
//     ~replayGaps = [0.15, 0.2];                         # the "gap" rows' gaps, seconds
//
// Under the sweep each take gets rows that choose the threshold, or thin the
// onsets, AFTER the take instead of before it: "auto" and "vote" pick among
// the sweep's readings, "peak" and "gap" filter the most liberal threshold's
// onsets (see "automatic thresholds" below). They are scored like the sweep.
// Needs scsynth (found inside the SuperCollider app) but no audio device: the
// render is non-realtime and touches no hardware, so it can run beside a
// playing instrument. First takes only: an overdub detection folds its onsets
// onto the loop's phase, which the replay does not reproduce yet; they are
// listed, not scored.
(
var repo = thisProcess.nowExecutingPath !? { |p| p.dirname.dirname } ?? { Looper.repoRoot };
var sessionsDir = ~replayDir ? (repo +/+ "sessions");
var thresholds = (~replayThresholds ? [0.2, 0.3, 0.4, 0.5, 0.6, 0.8, 1.0]).asArray.collect(_.asFloat);
var peakWindows = (~replayPeakWindows ? [0.15, 0.25]).asArray.collect(_.asFloat);
var peakRatio = (~replayPeakRatio ? 1.4).asFloat;
var gaps = (~replayGaps ? [0.15, 0.2]).asArray.collect(_.asFloat);
var maxOnsets = 4096;
// Beside SuperCollider's resources on macOS, on the shell's path on Linux.
var scsynth = MegaSAPlugins.scsynthPath;
var tmpDir = (Platform.defaultTempDir ? "/tmp") +/+ "megalooper-replay";
var headless = Platform.ideName != "scide";
var failures = 0;
var pad, padR, fmtTime, fmtReading, sameReading, gridSame, verdict, labelWord, stageWord, check;
var findEvents, selfTest, render, readSlots, readPitchSlots, analyse;
var eventsPath, events, header, audio, allTakes, takes, overdubs, inForce, tapPath, sr, tapFrames, filesEv;
var reanalysis, starvedOf, withInput;
var peakFilter, gapFilter, scoreOf, stageIndexOf, variantKeys, variantName, variants, perVariant, scoreRow;
var files, cells, savedFallback, stamp, changes, csv;
var labelled, corrected, accepted, perThr, best, stageJ, fidelitySame, fidelityGrid, fidelityCount;

// ---------------------------------------------------------------- helpers ----
pad  = { |s, n| s.asString.padLeft(n) };
padR = { |s, n| s.asString.padRight(n) };
fmtTime = { |t|
    var m = (t / 60).floor.asInteger;
    var s = t - (m * 60);
    m.asString ++ ":" ++ s.round(0.1).asString.padLeft(4, "0")
};
fmtReading = { |r|
    case
    { r.isNil } { "—" }
    { r[\numerator].isNil } { "no meter" ++ (r[\error] !? { |e| " (" ++ e ++ ")" } ? "") }
    { Looper.prReadingString(r) ++ (r[\error] !? { |e| " (" ++ e ++ ")" } ? "") }
};
// The same reading: meter and bar count, and for uneven bars the bars
// themselves (7+7+7+8 is not 7+7+8+7; a bar list from the log reads back as
// Floats, which == takes). The tempo follows from those and the loop length,
// so it is not compared separately.
sameReading = { |a, b|
    a.notNil and: { b.notNil }
        and: { a[\numerator] == b[\numerator] }
        and: { a[\denominator] == b[\denominator] }
        and: { (a[\k] ? 1) == (b[\k] ? 1) }
        and: { MeterAnalyzer.barsOf(a) == MeterAnalyzer.barsOf(b) }
};
// The same grid under another barring: the same tempo within half a percent
// and the same length in whole notes — 2/4 in two bars against 4/4 in one, 6/8
// in two against 12/8 in one. Live gets the same BPM and the loop the same
// pulse; only the bar line differs. Shown as ≈: not the answer, not the wrong
// music either. A tempo-halving reading (7/8 against 7/4) is NOT this.
gridSame = { |a, b|
    a.notNil and: { b.notNil } and: { sameReading.(a, b).not }
        and: { a[\bpm].notNil } and: { b[\bpm].notNil }
        and: { a[\numerator].notNil } and: { b[\numerator].notNil }
        and: { ((a[\bpm] - b[\bpm]).abs / a[\bpm].max(1e-6)) < 0.005 }
        and: { ((MeterAnalyzer.unitsOf(a) / a[\denominator])
            - (MeterAnalyzer.unitsOf(b) / b[\denominator])).abs < 1e-6 }
};
// A reading against a reference: \yes, \grid, \no, or nil with no reference.
verdict = { |r, ref|
    case
    { ref.isNil } { nil }
    { sameReading.(r, ref) } { \yes }
    { gridSame.(r, ref) } { \grid }
    { \no }
};
labelWord = { |v| switch(v, \yes, { "yes" }, \grid, { "≈" }, \no, { "no" }, { "—" }) };
stageWord = { |v| switch(v, \yes, { "same" }, \grid, { "≈ grid" }, \no, { "differs" }, { "—" }) };
check = { |label, cond, detail|
    if(cond == true) { ("  ok    " ++ label).postln } {
        failures = failures + 1;
        ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
    };
};

// Which log: the one named (a path, or a stamp, whatever the set was renamed
// to when it stopped), or the newest: the names start with the stamp, so they
// sort by date with or without a tempo in them.
findEvents = {
    var s = ~replaySession;
    case
    { s.notNil and: { s.asString.endsWith(".jsonl") } } { s.asString }
    { s.notNil } { LooperSessionRecorder.findEvents(sessionsDir, s.asString)
        ?? { sessionsDir +/+ s.asString ++ "-events.jsonl" } }
    { (LooperSessionRecorder.globQuote(sessionsDir) +/+ "*-events.jsonl").pathMatch.sort.last }
};

// A synthetic set: two bars of 7/8 at 100 BPM as noise bursts, accented 2+2+3,
// two seconds of silence before them, then two short empty takes — one undone,
// one played on — so every outcome the label logic knows appears once; then
// 7+7+7+8 at 120 BPM that the stage could not read (length-anchored) and whose
// bars were given by hand (Bars by hand), which makes the bars its label. The
// log is written through the recorder's own writer.
selfTest = {
    var srS = 48000;
    // The tap as a stop leaves it: renamed with the set's tempo and
    // signature, while the header still names the file it was opened as.
    var opened = tmpDir +/+ "selftest-tap.wav";
    var wav = tmpDir +/+ "selftest-100.00bpm-7-8-tap.wav";
    var ev  = tmpDir +/+ "selftest-events.jsonl";
    var total = (20.5 * srS).asInteger;
    var sig = Signal.fill(total, { 1e-4.rand2 });
    var eighth = 0.3;
    var hits = List.new;
    var base = 1000.0;
    var burst, sf, rec, r78, r74, empty, unevenHits, hand;
    burst = { |at, amp|
        var start = (at * srS).asInteger;
        var len = (0.1 * srS).asInteger;
        var attack = 0.002 * srS;
        var decay = 0.03 * srS;
        len.do { |i|
            var env = (i / attack).min(1) * exp(i.neg / decay);
            sig[start + i] = sig[start + i] + (1.0.rand2 * env * amp);
        };
    };
    14.do { |i|
        var t = 2.0 + (i * eighth);
        burst.(t, if(#[0, 2, 4, 7, 9, 11].includes(i)) { 0.6 } { 0.3 });
        hits.add(t);
    };
    // 7+7+7+8, an eighth of 0.25 s from 12.0: bar heads loud, beat-group
    // heads (2+2+3, 2+2+2+2) less, the rest soft.
    unevenHits = List.new;
    { var pos = 0;
      [7, 7, 7, 8].do { |len|
          var heads = if(len == 7) { [0, 2, 4] } { [0, 2, 4, 6] };
          len.do { |u|
              var t = 12.0 + ((pos + u) * 0.25);
              var amp = if(u == 0) { 0.8 } { if(heads.includes(u)) { 0.55 } { 0.3 } };
              burst.(t, amp);
              unevenHits.add([t - 11.9, amp]);
          };
          pos = pos + len;
      };
    }.value;
    if(File.exists(tmpDir).not) { File.mkdir(tmpDir) };
    // An older self-test's tap under the opened name would be found first.
    if(File.exists(opened)) { File.delete(opened) };
    sf = SoundFile.new;
    sf.headerFormat = "WAV";
    sf.sampleFormat = "int24";
    sf.numChannels = 1;
    sf.sampleRate = srS;
    if(sf.openWrite(wav).not) { Error("self-test: cannot write " ++ wav).throw };
    sf.writeData(sig);
    sf.close;
    r78 = (numerator: 7, denominator: 8, k: 2, sub: 1, tau: 0.3, bpm: 100, loopDur: 4.2, n: 14, score: 0.5);
    r74 = (numerator: 7, denominator: 4, k: 2, sub: 2, tau: 0.3, bpm: 200, loopDur: 4.2, n: 28, score: 0.4);
    empty = (numerator: 7, denominator: 8, k: 1, error: \lengthAnchored, loopDur: 1.0);
    rec = LooperSessionRecorder(nil, tmpDir);
    rec.instVarPut(\startedAt, base);
    rec.prOpenLog(ev);
    rec.logEvent(\session, (stamp: "selftest", sampleRate: srS, tap: opened, threshold: 0.5,
        fallback: "7/8", fallbackBars: 0, loop: r78, loopDur: 4.2,
        // A loop in force when the set began: the same 7/8 as analyser input only.
        take: (dur: 4.2, firstOnset: 0.1, threshold: 0.5, reading: 0, loopDur: 4.2,
            onsets: hits.collect { |h, i| [h - 1.9, if(#[0, 2, 4, 7, 9, 11].includes(i)) { 0.6 } { 0.3 }] },
            result: r78, candidates: [r78, r74])), base);
    rec.logEvent(\audio, (), base);
    rec.logEvent(\recordStart, (threshold: 0.5), base + 1.9);
    rec.logEvent(\take, (start: 1.9, dur: 4.2, threshold: 0.5, firstOnset: 0.1,
        onsets: hits.collect { |h, i| [h - 1.9, if(#[0, 2, 4, 7, 9, 11].includes(i)) { 0.6 } { 0.3 }] },
        result: r78, candidates: [r78, r74],
        loopDur: 4.2, applied: true, tapPeakDb: -40.0, inPeakDb: -6.0), base + 6.1);
    rec.logEvent(\readingArmed, (index: 1, of: 2, via: \next, loops: 1, restart: false,
        reading: r74), base + 6.5);
    rec.logEvent(\readingLanded, (index: 1, restart: false, reading: r74), base + 7.0);
    rec.logEvent(\clear, (), base + 7.5);
    rec.logEvent(\recordStart, (threshold: 0.5), base + 8.0);
    rec.logEvent(\take, (start: 8.0, dur: 1.0, threshold: 0.5, firstOnset: 0, onsets: [],
        result: empty, candidates: [], loopDur: 1.0, applied: true), base + 9.0);
    rec.logEvent(\undo, (state: \stopped), base + 9.5);
    rec.logEvent(\recordStart, (threshold: 0.5), base + 10.0);
    rec.logEvent(\take, (start: 10.0, dur: 1.0, threshold: 0.5, firstOnset: 0, onsets: [],
        result: empty, candidates: [], loopDur: 1.0, applied: true), base + 11.0);
    hand = MeterAnalyzer.readingOfBars(7.35, [7, 7, 7, 8], 8);
    rec.logEvent(\recordStart, (threshold: 0.5), base + 11.9);
    rec.logEvent(\take, (start: 11.9, dur: 7.35, threshold: 0.5, firstOnset: 0.1,
        onsets: unevenHits.asArray, result: MeterAnalyzer.anchorToLength(7.35, 7, 8, 29),
        candidates: [], loopDur: 7.35, applied: true), base + 19.25);
    rec.logEvent(\readingArmed, (index: 1, of: 2, via: \hand, loops: 1, restart: false,
        reading: Looper.resultForLog(hand)), base + 19.5);
    rec.logEvent(\readingLanded, (index: 1, restart: false, reading: Looper.resultForLog(hand)), base + 26.6);
    rec.logEvent(\files, (files: (tap: wav.basename, events: ev.basename),
        liveHint: LooperSessionRecorder.liveHint((bpm: 100, numerator: 7, denominator: 8), nil),
        tempo: (bpm: 100.0, numerator: 7, denominator: 8, from: \loop)), base + 27.0);
    rec.logEvent(\sessionStop, (elapsed: 27.0), base + 27.0);
    rec.prCloseLog;
    ~replaySelfTestHits = hits.asArray;
    ~replaySelfTestTap = wav;
    ev
};

// Render every take at every threshold in ONE non-realtime run. Each take's
// stretch of the tap is read into a buffer; one synth per threshold plays it
// through the recorder's chain and latches every onset's time and strength
// into a result buffer, one slot per onset, which is written out at the end
// of the take. One more synth per take tracks its pitch as the recorder does
// (Tartini, 25 Hz while it has a pitch: [time, Hz, amplitude]), which the
// uneven-bars detection reads its notes from; a set logged before the take
// event carried `pitches` has it only this way. Returns [takeIndex,
// thresholdIndex] -> result file, and [takeIndex, \pitch] -> the pitch's.
render = { |tap, takeList, thrs, audioT, rate|
    var def = SynthDef(\replayOnsets, { |bufnum = 0, threshold = 0.5, resultBuf = 1|
        var sig = PlayBuf.ar(1, bufnum, 1, 1, 0, 0);
        var trig = Looper.prOnsetTrig(sig, threshold);
        var time = Sweep.kr(1, 1);
        var strength = Looper.prOnsetStrength(sig);
        var count = Stepper.kr(trig, 0, 0, maxOnsets, 1, 0);
        BufWr.kr([Latch.kr(time, trig), Latch.kr(strength, trig), 1], resultBuf, count, 0);
    });
    var pitchDef = SynthDef(\replayPitch, { |bufnum = 0, resultBuf = 1, slots = 100|
        var sig = PlayBuf.ar(1, bufnum, 1, 1, 0, 0);
        var tartini = Tartini.kr(sig);
        var trig = Impulse.kr(25) * tartini[1];
        var time = Sweep.kr(1, 1);
        var count = Stepper.kr(trig, 0, 0, slots, 1, 0);
        BufWr.kr([Latch.kr(time, trig), Latch.kr(tartini[0], trig), Latch.kr(Amplitude.kr(sig), trig), 1],
            resultBuf, count, 0);
    });
    var score = List.new;
    var t = 0.0, bufnum = 0, node = 1000;
    var out = Dictionary.new;
    var osc = tmpDir +/+ "replay.osc";
    var dummy = tmpDir +/+ "replay-out.wav";
    var cmd, said;
    if(File.exists(tmpDir).not) { File.mkdir(tmpDir) };
    score.add([0.0, [\d_recv, def.asBytes]]);
    score.add([0.0, [\d_recv, pitchDef.asBytes]]);
    takeList.do { |tk, i|
        var tapBuf = bufnum, pitchBuf, pitchPath, slots;
        bufnum = bufnum + 1;
        score.add([t + 0.001, [\b_allocRead, tapBuf, tap, tk[\startFrame], tk[\numFrames]]]);
        pitchBuf = bufnum;
        bufnum = bufnum + 1;
        pitchPath = tmpDir +/+ "take" ++ i ++ "-pitch.wav";
        slots = ((tk[\dur] ? 1) * 25).ceil.asInteger + 16;
        score.add([t + 0.002, [\b_alloc, pitchBuf, slots + 1, 4]]);
        score.add([t + 0.01, [\s_new, \replayPitch, node, 0, 0,
            \bufnum, tapBuf, \resultBuf, pitchBuf, \slots, slots]]);
        score.add([t + 0.01 + tk[\dur], [\n_free, node]]);
        score.add([t + 0.02 + tk[\dur], [\b_write, pitchBuf, pitchPath, "wav", "float", -1, 0, 0]]);
        score.add([t + 0.03 + tk[\dur], [\b_free, pitchBuf]]);
        out[[i, \pitch]] = pitchPath;
        node = node + 1;
        thrs.do { |thr, j|
            var res = bufnum;
            var path = tmpDir +/+ "take" ++ i ++ "-thr" ++ j ++ ".wav";
            bufnum = bufnum + 1;
            score.add([t + 0.002, [\b_alloc, res, maxOnsets + 1, 3]]);
            score.add([t + 0.01, [\s_new, \replayOnsets, node, 0, 0,
                \bufnum, tapBuf, \threshold, thr, \resultBuf, res]]);
            score.add([t + 0.01 + tk[\dur], [\n_free, node]]);
            score.add([t + 0.02 + tk[\dur], [\b_write, res, path, "wav", "float", -1, 0, 0]]);
            score.add([t + 0.03 + tk[\dur], [\b_free, res]]);
            out[[i, j]] = path;
            node = node + 1;
        };
        score.add([t + 0.04 + tk[\dur], [\b_free, tapBuf]]);
        t = t + tk[\dur] + 0.1;
    };
    score.add([t + 0.1, [\c_set, 0, 0]]);
    Score(score.asArray.sort { |a, b| a[0] <= b[0] }).writeOSCFile(osc);
    // A port far from 57110-57130: even a non-realtime scsynth binds one, and
    // a stuck render on the launcher's range would keep megalooper from booting.
    cmd = scsynth.quote ++ " -N " ++ osc.quote ++ " _ " ++ dummy.quote ++ " "
        ++ rate.asInteger ++ " WAV int16 -o 1 -i 0 -u " ++ (58100 + 800.rand) ++ " 2>&1";
    said = cmd.unixCmdGetStdOut;
    if(said.contains("exception") or: { said.contains("ERROR") } or: { said.contains("FAILURE") }) {
        ("Replay: scsynth said:\n" ++ said).warn;
    };
    out
};

// The onsets a result file holds: slot k (k >= 1) is the k-th onset's
// [time, strength]; slot 0 is what the counter pointed at before the first.
readSlots = { |path|
    var sf = SoundFile.new, data, found = List.new;
    if(sf.openRead(path)) {
        data = FloatArray.newClear(sf.numFrames * sf.numChannels);
        sf.readData(data);
        sf.close;
        (1..(sf.numFrames - 1)).do { |slot|
            var time = data[slot * 3];
            var strength = data[(slot * 3) + 1];
            var flag = data[(slot * 3) + 2];
            if((flag > 0.5) and: { time > 0 }) { found.add([time, strength]) };
        };
    };
    found.asArray
};

// A pitch result file: slot k (k >= 1) the k-th reading, [time, Hz, amp].
readPitchSlots = { |path|
    var sf = SoundFile.new, data, found = List.new;
    if(path.notNil and: { sf.openRead(path) }) {
        data = FloatArray.newClear(sf.numFrames * sf.numChannels);
        sf.readData(data);
        sf.close;
        (1..(sf.numFrames - 1)).do { |slot|
            if((data[(slot * 4) + 3] > 0.5) and: { data[slot * 4] > 0 }) {
                found.add([data[slot * 4], data[(slot * 4) + 1], data[(slot * 4) + 2]]);
            };
        };
    };
    found.asArray
};

// The Looper's own path, as stopRecordStartPlay runs it: onsets relative to
// the first, the span after it analysed, the result snapped to the take. The
// pitch: what the take logged, else what the render tracked from the tap.
analyse = { |tk, onsets, pitches|
    var first = if(onsets.isEmpty) { 0 } { onsets[0][0] };
    var rel = onsets.collect { |p| p[0] - first };
    var str = onsets.collect { |p| p[1] };
    var r = MeterAnalyzer.analyze(tk[\dur] - first, rel, str, leadIn: first,
        pitches: pitches ?? { tk[\pitches] ?? { tk[\renderedPitches] } });
    Looper.snapAnalysisToLoop(r, tk[\dur])
};

// The onsets the log says the stage heard, through today's analyser: an
// analyser change shows here as a reading that moved with no audio involved.
// Nothing for an overdub-derived loop (a different analysis) or an old log.
reanalysis = { |tk|
    if(tk[\dur].isNil or: { tk[\onsets].isNil } or: { tk[\fromOverdub] == true }) { nil } {
        analyse.(tk, tk[\onsets])
    }
};

// The onsets without every one that a hit within `w` seconds is `ratio` times
// louder than: what is left are the hits that lead their neighbourhood. A run
// of even hits keeps them all, a ghost or a double trigger beside a strong hit
// goes. Strengths are the recorder's salience, so this is relative to the take
// and blind to the tap's level.
peakFilter = { |onsets, w, ratio|
    onsets.select { |p|
        onsets.every { |q| ((q[0] - p[0]).abs > w) or: { q[1] <= (p[1] * ratio) } }
    }
};
// The onsets with nothing for `g` seconds after each one kept: a longer
// mingap, applied after detection. It keeps the first hit of a cluster,
// however soft.
gapFilter = { |onsets, g|
    var last = inf.neg;
    onsets.select { |p| if((p[0] - last) >= g) { last = p[0]; true } { false } }
};
// A reading's score, or nil for one that fit no grid (length-anchored, too few
// onsets): the analyser vouches for nothing there.
scoreOf = { |r| if(r.isNil or: { r[\error].notNil } or: { r[\numerator].isNil }) { nil } { r[\score] } };
// The sweep's index of the threshold in force for a take.
stageIndexOf = { |tk|
    var thr = (tk[\threshold] ? header[\threshold] ? 0.5).asFloat;
    thresholds.detectIndex { |t| (t - thr).abs < 1e-6 }
        ?? { thresholds.indexOf(thresholds.minItem { |t| (t - thr).abs }) }
};

// The same rule the recorder warns with, on the dB figures in the log.
starvedOf = { |tk| Looper.tapStarvedFromDb(tk[\tapPeakDb], tk[\inPeakDb]) };

// ------------------------------------------------------------------ the set --
if(File.exists(scsynth).not) {
    ("Replay: scsynth not found at " ++ scsynth).warn;
    if(headless) { 1.exit };
};

if(~replaySelfTest == true) {
    "=== Replay self-test: a synthetic set ===".postln;
    eventsPath = selfTest.();
} {
    eventsPath = if(~replayTap.notNil) { nil } { findEvents.() };
};

if(eventsPath.notNil) {
    events  = LooperSessionRecorder.readEvents(eventsPath);
    header  = events.detect { |e| e[\ev] == "session" } ? ();
    audio   = events.detect { |e| e[\ev] == "audio" };
    filesEv = events.detect { |e| e[\ev] == "files" };
    stamp   = header[\stamp] ? PathName(eventsPath).fileNameWithoutExtension;
    // Where the tap is now: under the name the stop gave it, the name it was
    // opened as (a set from before the renaming, or one whose rename failed),
    // beside the log when the set was moved, or found by stamp.
    tapPath = LooperSessionRecorder.sessionPath(events, \tap, eventsPath) ? header[\tap];
    allTakes = LooperSessionRecorder.takesFrom(events);
    changes  = events.select { |e| e[\ev] == "threshold" };
} {
    if(~replayTap.notNil) {
        // A tap with no log: the takes are where the caller says they are, and
        // there is nothing to score against — the report shows readings only.
        tapPath  = ~replayTap.asString;
        stamp    = PathName(tapPath).fileNameWithoutExtension;
        header   = (threshold: ~replayStageThreshold ? 0.5, fallback: "7/8", fallbackBars: 0);
        audio    = (t: 0);
        events   = [];
        changes  = [];
        allTakes = (~replayManual ? []).collect { |pair, i|
            (kind: \take, index: i, start: pair[0].asFloat, dur: pair[1].asFloat,
                threshold: header[\threshold], onsets: [], candidates: [], readings: [],
                presses: 0, settled: 0, outcome: \unlabelled)
        };
    } {
        ("Replay: no set with an event log under " ++ sessionsDir
            ++ ". Sets recorded before the log existed can be replayed with ~replayTap and ~replayManual.").postln;
        if(headless) { 0.exit };
    };
};

if(tapPath.isNil or: { File.exists(tapPath).not }) {
    ("Replay: this set has no dry tap on disk (" ++ (tapPath ? "none in the log") ++ ").").warn;
    if(headless) { 1.exit };
};

// The tap's own facts win over the header's.
{
    var sf = SoundFile.new;
    if(sf.openRead(tapPath)) {
        sr = sf.sampleRate;
        tapFrames = sf.numFrames;
        sf.close;
        if(header[\sampleRate].notNil and: { header[\sampleRate] != sr }) {
            ("Replay: the log says " ++ header[\sampleRate] ++ " Hz, the tap is " ++ sr ++ " Hz — using the tap's.").warn;
        };
    };
}.value;

takes    = allTakes.select { |tk| tk[\kind] == \take };
overdubs = allTakes.select { |tk| tk[\kind] == \overdub };
inForce  = allTakes.select { |tk| tk[\kind] == \inForce };
// Numbered among the takes in the tap, before any is skipped, so "take 3" in
// the report is the third take of the set whatever else the log holds.
takes.do { |tk, i| tk[\number] = i + 1 };

("=== Set " ++ stamp ++ (header[\date] !? { |d| " — " ++ d } ? "")
    ++ (filesEv !? { |f| f[\tempo] !? { |t| " — " ++ LooperSessionRecorder.fixed(t[\bpm], 2) ++ " BPM, "
        ++ t[\numerator] ++ "/" ++ t[\denominator] } } ? "") ++ " ===").postln;
("tap " ++ tapPath.basename ++ ", " ++ sr ++ " Hz, " ++ fmtTime.(tapFrames / sr)
    ++ (audio !? { |a| ", audio from t=" ++ a[\t].round(0.001) ++ " s" } ? ", NO audio mark — takes cannot be placed")).postln;
("threshold at the start " ++ (header[\threshold] ? "?")
    ++ (if(changes.notEmpty) {
        ", changed " ++ changes.collect { |c| "at " ++ fmtTime.(c[\t]) ++ " to " ++ c[\value] }.join(", ")
    } { "" })
    ++ "; fallback " ++ (header[\fallback] ? "?")).postln;
(takes.size.asString ++ " take" ++ (if(takes.size == 1) { "" } { "s" })
    ++ #[\accepted, \corrected, \reverted, \discarded].collect { |o|
        var n = takes.count { |tk| tk[\outcome] == o };
        if(n > 0) { " · " ++ n ++ " " ++ o } { "" } }.join
    ++ (if(overdubs.notEmpty) { " · " ++ overdubs.size ++ " overdub detection(s), listed not replayed" } { "" })
    ++ (if(inForce.notEmpty) { " · " ++ inForce.size ++ " loop(s) in force when the set began, analyser input only" } { "" })).postln;

// Place each take in the tap; the ones that fall outside it are reported and skipped.
takes.do { |tk|
    if(audio.isNil or: { tk[\start].isNil } or: { tk[\dur].isNil }) {
        tk[\skip] = "no audio mark or no press in the log";
    } {
        tk[\startFrame] = ((tk[\start] - audio[\t]) * sr).round.asInteger;
        tk[\numFrames]  = (tk[\dur] * sr).round.asInteger;
        if(tk[\startFrame] < 0) { tk[\skip] = "pressed before the tap started" };
        if((tk[\startFrame] + tk[\numFrames]) > tapFrames) { tk[\skip] = "runs past the end of the tap" };
        if(tk[\numFrames] < 1024) { tk[\skip] = "shorter than one analysis frame" };
    };
    tk[\skip] !? { |why| ("take " ++ tk[\number] ++ " skipped: " ++ why).postln };
};
takes = takes.reject { |tk| tk[\skip].notNil };

// The stage thresholds are always in the sweep, so fidelity can be checked.
thresholds = (thresholds ++ takes.collect { |tk| tk[\threshold] }.reject(_.isNil).collect(_.asFloat))
    .asSet.asArray.sort;
("thresholds: " ++ thresholds.collect { |t| t.round(0.001) }.join(" ")).postln;

if(takes.isEmpty) {
    "Nothing to replay.".postln;
    if(headless) { 0.exit };
};

// The app's fallback meter, so a take that fits no grid is read the way the
// instrument read it.
savedFallback = [MeterAnalyzer.fallbackNum, MeterAnalyzer.fallbackDenom, MeterAnalyzer.fallbackBars];
{
    var parts = (header[\fallback] ? "7/8").asString.split($/);
    if(parts.size == 2) {
        MeterAnalyzer.fallbackNum   = parts[0].asInteger;
        MeterAnalyzer.fallbackDenom = parts[1].asInteger;
    };
    MeterAnalyzer.fallbackBars = header[\fallbackBars] ? 0;
}.value;

"rendering...".postln;
files = render.(tapPath, takes, thresholds, audio[\t], sr);
takes.do { |tk, i| tk[\renderedPitches] = readPitchSlots.(files[[i, \pitch]]) };

// cells[[i, j]] = (onsets:, reading:, label:, stage:)
cells = Dictionary.new;
takes.do { |tk, i|
    thresholds.do { |thr, j|
        var onsets = readSlots.(files[[i, j]]);
        var r = analyse.(tk, onsets, tk[\renderedPitches]);
        cells[[i, j]] = (onsets: onsets, reading: r,
            label: verdict.(r, tk[\label]), stage: verdict.(r, tk[\result]));
    };
};

// --------------------------------------------------- automatic thresholds ----
// The threshold chosen per take, after it, instead of set before the set; and
// the onsets thinned after detection instead of by it. The take is over when
// the analyser runs, so either could be done on stage. Each is a row:
//   auto      the threshold whose reading the analyser scores highest, the
//             lower on a tie; a reading that fit no grid has no score and is
//             never picked (none scored: the stage threshold's)
//   vote      the reading the most thresholds of the sweep agree on, the
//             higher score breaking a tie: depends on the sweep's spacing
//   peak W    the most liberal threshold's onsets through peakFilter, W the
//             window in seconds
//   gap G     the same onsets through gapFilter: the "no more than so many
//             notes a second" rule, G the shortest gap
// None of these changes what the instrument does; they ask whether it should.
variantKeys = [[\auto], [\vote]]
    ++ peakWindows.collect { |w| [\peak, w] } ++ gaps.collect { |g| [\gap, g] };
variantName = { |key|
    if(key.size == 1) { key[0].asString } { key[0].asString ++ key[1].asString.drop(1) } };
variants = Dictionary.new;
takes.do { |tk, i|
    var row = thresholds.collect { |thr, j| cells[[i, j]] };
    var stageJ = stageIndexOf.(tk);
    var base = row[0][\onsets];
    variantKeys.do { |key, v|
        var j = 0, onsets, r, groups, top, rr, grp;
        switch(key[0],
            \auto, {
                j = Array.series(thresholds.size)
                    .select { |jj| scoreOf.(row[jj][\reading]).notNil }
                    .maxItem { |jj| scoreOf.(row[jj][\reading]) } ? stageJ;
            },
            \vote, {
                groups = List.new;
                thresholds.size.do { |jj|
                    rr = row[jj][\reading];
                    if(scoreOf.(rr).notNil) {
                        grp = groups.detect { |gr| sameReading.(row[gr[0]][\reading], rr) };
                        if(grp.isNil) { groups.add(List[jj]) } { grp.add(jj) };
                    };
                };
                top = groups.asArray.maxItem { |gr|
                    gr.size + (gr.collect { |jj| scoreOf.(row[jj][\reading]) }.maxItem * 1e-3) };
                j = top !? { |gr| gr.maxItem { |jj| scoreOf.(row[jj][\reading]) } } ? stageJ;
            },
            \peak, { onsets = peakFilter.(base, key[1], peakRatio) },
            \gap,  { onsets = gapFilter.(base, key[1]) }
        );
        if(onsets.isNil) {
            onsets = row[j][\onsets];
            r = row[j][\reading];
        } {
            r = analyse.(tk, onsets, tk[\renderedPitches]);
        };
        variants[[i, v]] = (key: key, j: j, onsets: onsets, reading: r,
            label: verdict.(r, tk[\label]), stage: verdict.(r, tk[\result]));
    };
};

// ----------------------------------------------------------------- report ----
takes.do { |tk, i|
    var margin = if(tk[\candidates].size >= 2) {
        (tk[\candidates][0][\score] ? 0) - (tk[\candidates][1][\score] ? 0) } { nil };
    "".postln;
    ("take " ++ tk[\number] ++ "  at " ++ fmtTime.(tk[\start]) ++ "  " ++ tk[\dur].round(0.001) ++ " s"
        ++ "  threshold " ++ (tk[\threshold] ? "?")
        ++ "  — " ++ switch(tk[\outcome],
            \accepted,   { "accepted as heard" },
            \corrected,  { "corrected: settled on " ++ fmtReading.(tk[\label]) ++ " after " ++ tk[\presses] ++ " press" ++ (if(tk[\presses] > 1) { "es" } { "" }) },
            \reverted,   { "reverted: moved " ++ tk[\presses] ++ " time" ++ (if(tk[\presses] > 1) { "s" } { "" }) ++ " and back — wrong, and nothing on the list fitted" },
            \discarded,  { "discarded (undone)" },
            { "unlabelled" })).postln;
    tk[\result] !? { |st|
        ("  on stage: " ++ fmtReading.(st) ++ "  from " ++ tk[\onsets].size ++ " onsets"
            ++ (st[\score] !? { |s| ", score " ++ s.round(0.01) } ? "")
            ++ (margin !? { |m| ", margin " ++ m.round(0.01) } ? "")
            ++ (if(tk[\applied] == false) { "  (not applied: the loop had gone by then)" } { "" })).postln;
    };
    tk[\tapPeakDb] !? { |tp|
        ("  levels:   tap peak " ++ tp.round(1) ++ " dBFS, input peak " ++ (tk[\inPeakDb] ? -120).round(1) ++ " dBFS"
            ++ (starvedOf.(tk) !? { |g| "  STARVED: the tap sat " ++ g.round(1) ++ " dB under the input" } ? "")).postln;
    };
    ("  " ++ padR.("thr", 7) ++ pad.("onsets", 6) ++ "  " ++ padR.("reading", 42) ++ padR.("label", 7) ++ "stage").postln;
    reanalysis.(tk) !? { |re|
        ("  " ++ padR.("logged", 7) ++ pad.(tk[\onsets].size, 6) ++ "  " ++ padR.(fmtReading.(re), 42)
            ++ padR.(labelWord.(verdict.(re, tk[\label])), 7)
            ++ stageWord.(verdict.(re, tk[\result]))
            ++ "   the stage onsets through today's analyser").postln;
    };
    thresholds.do { |thr, j|
        var c = cells[[i, j]];
        var isStage = tk[\threshold].notNil and: { (thr - tk[\threshold]).abs < 1e-6 };
        ("  " ++ padR.(thr.round(0.001).asString ++ (if(isStage) { "*" } { "" }), 7)
            ++ pad.(c[\onsets].size, 6) ++ "  "
            ++ padR.(fmtReading.(c[\reading]), 42)
            ++ padR.(labelWord.(c[\label]), 7)
            ++ stageWord.(c[\stage])
            ++ (if(isStage) { "   * in force on stage" } { "" })).postln;
    };
    variantKeys.do { |key, v|
        var c = variants[[i, v]];
        ("  " ++ padR.(variantName.(key), 7)
            ++ pad.(c[\onsets].size, 6) ++ "  "
            ++ padR.(fmtReading.(c[\reading]), 42)
            ++ padR.(labelWord.(c[\label]), 7)
            ++ padR.(stageWord.(c[\stage]), 9)
            ++ (if(key.size == 1) { "picked " ++ thresholds[c[\j]].round(0.001) }
                { "of " ++ cells[[i, 0]][\onsets].size ++ " at " ++ thresholds[0].round(0.001) })).postln;
    };
};

overdubs.do { |od|
    "".postln;
    ("overdub detection at " ++ fmtTime.(od[\t]) ++ ": " ++ fmtReading.(od[\result])
        ++ " from " ++ od[\onsets].size ++ " folded onsets — " ++ od[\outcome]
        ++ (if(od[\outcome] == \corrected) { ", settled on " ++ fmtReading.(od[\label]) } { "" })
        ++ ". Not replayed.").postln;
};

inForce.do { |tk|
    var re = reanalysis.(tk);
    "".postln;
    ("loop in force when the set began: " ++ fmtReading.(tk[\result]) ++ " from " ++ tk[\onsets].size ++ " onsets"
        ++ (tk[\dur] !? { |d| ", a take of " ++ d.round(0.001) ++ " s" } ? "")
        ++ " — " ++ switch(tk[\outcome],
            \accepted,  { "accepted as heard" },
            \corrected, { "corrected: settled on " ++ fmtReading.(tk[\label])
                ++ (if(tk[\presses] > 0) { " after " ++ tk[\presses] ++ " press" ++ (if(tk[\presses] > 1) { "es" } { "" }) }
                    { ", already so when the set began" }) },
            \reverted,  { "reverted: moved and moved back" },
            \discarded, { "discarded (undone)" },
            { "unlabelled" })).postln;
    if(re.notNil) {
        ("  the stage onsets through today's analyser: " ++ fmtReading.(re)
            ++ switch(verdict.(re, tk[\result]),
                \yes,  { " — same as on stage" },
                \grid, { " — the stage grid under another barring" },
                { " — DIFFERS from the stage reading" })
            ++ (tk[\label] !? { |lb| switch(verdict.(re, lb),
                \yes,  { "; matches the label" },
                \grid, { "; the label's grid under another barring" },
                { "; does not match the label" }) } ? "")).postln;
    } {
        (if(tk[\fromOverdub] == true) { "  derived from an overdub; not re-analysed" }
            { "  no analyser input in the log; not re-analysed" }).postln;
    };
};

// ---------------------------------------------------------------- summary ----
corrected = takes.select { |tk| tk[\outcome] == \corrected };
accepted  = takes.select { |tk| tk[\outcome] == \accepted };
labelled  = corrected ++ accepted;
// One row of the summary: `cellOf` answers a take's cell in that row.
scoreRow = { |cellOf|
    var right     = corrected.count { |tk| cellOf.(tk)[\label] == \yes };
    var rightGrid = corrected.count { |tk| cellOf.(tk)[\label] == \grid };
    var agree     = accepted.count  { |tk| cellOf.(tk)[\label] == \yes };
    var agreeGrid = accepted.count  { |tk| cellOf.(tk)[\label] == \grid };
    var mean  = if(takes.isEmpty) { 0 } { takes.collect { |tk| cellOf.(tk)[\onsets].size }.sum / takes.size };
    (right: right, rightGrid: rightGrid, agree: agree, agreeGrid: agreeGrid, mean: mean)
};
perThr = thresholds.collect { |thr, j|
    scoreRow.({ |tk| cells[[takes.indexOf(tk), j]] }).put(\thr, thr)
};
perVariant = variantKeys.collect { |key, v|
    scoreRow.({ |tk| variants[[takes.indexOf(tk), v]] }).put(\name, variantName.(key))
};
"".postln;
("=== Summary: " ++ takes.size ++ " take" ++ (if(takes.size == 1) { "" } { "s" }) ++ " replayed, "
    ++ labelled.size ++ " labelled (" ++ corrected.size ++ " corrected, " ++ accepted.size ++ " accepted) ===").postln;
("  " ++ padR.("thr", 8) ++ padR.("right on corrected", 21) ++ padR.("agrees on accepted", 21) ++ "mean onsets").postln;
perThr.do { |p|
    ("  " ++ padR.(p[\thr].round(0.001), 8)
        ++ padR.(p[\right].asString ++ "/" ++ corrected.size
            ++ (if(p[\rightGrid] > 0) { " +" ++ p[\rightGrid] ++ "≈" } { "" }), 21)
        ++ padR.(p[\agree].asString ++ "/" ++ accepted.size
            ++ (if(p[\agreeGrid] > 0) { " +" ++ p[\agreeGrid] ++ "≈" } { "" }), 21)
        ++ p[\mean].round(0.1)).postln;
};
perVariant.do { |p|
    ("  " ++ padR.(p[\name], 8)
        ++ padR.(p[\right].asString ++ "/" ++ corrected.size
            ++ (if(p[\rightGrid] > 0) { " +" ++ p[\rightGrid] ++ "≈" } { "" }), 21)
        ++ padR.(p[\agree].asString ++ "/" ++ accepted.size
            ++ (if(p[\agreeGrid] > 0) { " +" ++ p[\agreeGrid] ++ "≈" } { "" }), 21)
        ++ p[\mean].round(0.1)).postln;
};
// Whether one threshold suits every take: each labelled take against the
// sweep. A column of y all the way down is a threshold to keep; a diagonal
// is a threshold to choose per take.
if(labelled.notEmpty) {
    "  right per labelled take (y the label, ≈ its grid under another barring, . wrong):".postln;
    ("  " ++ padR.("", 10) ++ thresholds.collect { |t| pad.(t.round(0.001), 6) }.join).postln;
    takes.select { |tk| #[\corrected, \accepted].includes(tk[\outcome]) }.do { |tk|
        var i = takes.indexOf(tk);
        ("  " ++ padR.("take " ++ tk[\number] ++ (if(tk[\outcome] == \corrected) { "c" } { "a" }), 10)
            ++ thresholds.collect { |t, j| pad.(switch(cells[[i, j]][\label], \yes, { "y" }, \grid, { "≈" }, { "." }), 6) }.join).postln;
    };
    "  (c corrected on stage, a accepted)".postln;
};
if(perThr.any { |p| (p[\rightGrid] + p[\agreeGrid]) > 0 }) {
    "  ≈ the same tempo and loop under another barring — 2/4 in two bars against 4/4 in one; Live's BPM and the pulse are the same".postln;
};

// Fidelity: the replay at the stage threshold against the stage reading.
fidelitySame = 0; fidelityGrid = 0; fidelityCount = 0;
takes.do { |tk, i|
    var j = thresholds.detectIndex { |thr| tk[\threshold].notNil and: { (thr - tk[\threshold]).abs < 1e-6 } };
    if(j.notNil and: { tk[\result].notNil }) {
        var c = cells[[i, j]];
        fidelityCount = fidelityCount + 1;
        if(c[\stage] == \yes) { fidelitySame = fidelitySame + 1 };
        if(c[\stage] == \grid) { fidelityGrid = fidelityGrid + 1 };
        if((c[\onsets].size - tk[\onsets].size).abs > 1) {
            ("  fidelity: take " ++ tk[\number] ++ " heard " ++ tk[\onsets].size ++ " onsets on stage, "
                ++ c[\onsets].size ++ " in the replay at the same threshold").postln;
        };
    };
};
if(fidelityCount > 0) {
    ("  fidelity: at the stage threshold the replay reproduced the stage reading on "
        ++ fidelitySame ++ " of " ++ fidelityCount ++ " takes"
        ++ (if(fidelityGrid > 0) { ", and the stage grid under another barring on " ++ fidelityGrid ++ " more" } { "" })
        ++ (if((fidelitySame + fidelityGrid) < fidelityCount) { " — read the tuning below with that in mind" } { "" })).postln;
};

// The stage onsets through today's analyser, over every take that carries
// them, and the starved takes — both before any threshold conclusion.
withInput = (takes ++ inForce).select { |tk| reanalysis.(tk).notNil };
if(withInput.notEmpty) {
    var same = withInput.count { |tk| sameReading.(reanalysis.(tk), tk[\result]) };
    var lab = withInput.select { |tk| tk[\outcome] == \corrected };
    var right = lab.count { |tk| sameReading.(reanalysis.(tk), tk[\label]) };
    ("  today's analyser on the stage onsets reproduces the stage reading on " ++ same ++ " of " ++ withInput.size
        ++ (if(lab.notEmpty) { " and gets " ++ right ++ " of " ++ lab.size ++ " corrected labels right" } { "" })).postln;
};
{
    var starved = takes.count { |tk| starvedOf.(tk).notNil };
    if(starved > 0) {
        ("  " ++ starved ++ " of " ++ takes.size ++ " takes STARVED: the tap sat 30 dB or more under the recorded input. "
            "Fix the tap before reading the threshold table.").postln;
    };
}.value;

// Takes no threshold gets right are the analyser's limit, not the threshold's.
if(corrected.notEmpty) {
    var never = corrected.select { |tk| thresholds.every { |thr, j| #[\yes, \grid].includes(cells[[takes.indexOf(tk), j]][\label]).not } };
    if(never.notEmpty) {
        ("  " ++ never.size ++ " of " ++ corrected.size ++ " corrected take(s) come out wrong at every threshold: "
            ++ never.collect { |tk| "take " ++ tk[\number] }.join(", ")
            ++ " — the list, not the threshold, is the limit there").postln;
    };
    best = perThr.copy.sort { |a, b|
        if(a[\right] != b[\right]) { a[\right] > b[\right] } {
            if(a[\agree] != b[\agree]) { a[\agree] > b[\agree] } {
                (a[\thr] - (header[\threshold] ? 0.5)).abs <= (b[\thr] - (header[\threshold] ? 0.5)).abs
            }
        }
    }.first;
    stageJ = perThr.detect { |p| (p[\thr] - (header[\threshold] ? 0.5)).abs < 1e-6 };
    ("  recommendation: threshold " ++ best[\thr].round(0.001) ++ " gets " ++ best[\right] ++ " of " ++ corrected.size
        ++ " corrected takes right and agrees with " ++ best[\agree] ++ " of " ++ accepted.size ++ " accepted"
        ++ (stageJ !? { |s| if((s[\thr] - best[\thr]).abs < 1e-6) { " — that is the stage threshold; keep it" }
            { "; the stage's " ++ s[\thr].round(0.001) ++ " got " ++ s[\right] ++ " and " ++ s[\agree] } } ? "")).postln;
} {
    "  no take was corrected in this set: the analyser was not contradicted, so there is nothing to tune against here.".postln;
};

// ------------------------------------------------------------------- csv -----
~replayCsv !? { |path|
    csv = File(path, "w");
    if(csv.isOpen) {
        // `method` is "threshold" for the sweep or a row of the automatic
        // thresholds, `param` its threshold, window or gap; `threshold` the
        // threshold whose onsets the row read.
        csv.write("set,take,start,dur,outcome,label,stage,threshold,onsets,numerator,denominator,k,bpm,error,matchesLabel,matchesStage,method,param,tapPeakDb,inPeakDb\n");
        takes.do { |tk, i|
            var line = { |c, thr, method, param|
                var r = c[\reading];
                csv.write([stamp, tk[\number], tk[\start], tk[\dur], tk[\outcome],
                    fmtReading.(tk[\label]).quote, fmtReading.(tk[\result]).quote, thr, c[\onsets].size,
                    r[\numerator], r[\denominator], r[\k], r[\bpm] !? { |b| b.round(0.01) }, r[\error] ? "",
                    c[\label] ? "", c[\stage] ? "", method, param, tk[\tapPeakDb] ? "", tk[\inPeakDb] ? ""].join(",") ++ "\n");
            };
            thresholds.do { |thr, j| line.(cells[[i, j]], thr, "threshold", thr) };
            variantKeys.do { |key, v|
                var c = variants[[i, v]];
                line.(c, thresholds[c[\j]], key[0], key[1] ? thresholds[c[\j]]);
            };
        };
        csv.close;
        ("wrote " ++ path).postln;
    };
};

~replayResult = (stamp: stamp, takes: takes, thresholds: thresholds, cells: cells, perThr: perThr,
    variantKeys: variantKeys, variants: variants, perVariant: perVariant);

// --------------------------------------------------------------- self-test ---
if(~replaySelfTest == true) {
    var hits = ~replaySelfTestHits;
    var j = thresholds.detectIndex { |thr| (thr - 0.5).abs < 1e-6 };
    var c = cells[[0, j]];
    var outcomes = allTakes.collect { |tk| tk[\outcome] };
    "".postln;
    "=== Self-test ===".postln;
    check.("the tap was found under the name the stop gave it", tapPath == ~replaySelfTestTap, "got " ++ tapPath);
    check.("four takes and the loop in force came out of the log", allTakes.size == 5, "got " ++ allTakes.size);
    check.("their outcomes are accepted (in force), corrected, discarded, accepted, corrected",
        outcomes == [\accepted, \corrected, \discarded, \accepted, \corrected], "got " ++ outcomes);
    check.("the loop in force is its own kind", inForce.size == 1 and: { inForce[0][\kind] == \inForce },
        "got " ++ inForce.size);
    check.("its stage onsets through today's analyser read 7/8 in two bars",
        sameReading.(reanalysis.(inForce[0]), (numerator: 7, denominator: 8, k: 2)),
        "got " ++ fmtReading.(reanalysis.(inForce[0])));
    check.("the first take is flagged starved from its logged levels",
        starvedOf.(takes[0]).notNil and: { (starvedOf.(takes[0]) - 34).abs < 1e-6 }, "got " ++ starvedOf.(takes[0]));
    check.("the empty takes are not flagged", starvedOf.(takes[1]).isNil and: { starvedOf.(takes[2]).isNil }, "flagged");
    check.("the corrected take's label is the reading it settled on",
        sameReading.(allTakes[1][\label], (numerator: 7, denominator: 4, k: 2)), "got " ++ fmtReading.(allTakes[1][\label]));
    check.("the take was placed in the tap at the press", takes[0][\startFrame] == (1.9 * 48000).asInteger,
        "got frame " ++ takes[0][\startFrame]);
    check.("the render found the fourteen hits at threshold 0.5 (13..15)",
        (c[\onsets].size >= 13) and: { c[\onsets].size <= 15 }, "got " ++ c[\onsets].size);
    check.("every detected onset sits within 45 ms after a hit",
        c[\onsets].every { |p| hits.any { |h| var d = p[0] - (h - 1.9); (d >= -0.005) and: { d <= 0.045 } } },
        "onsets " ++ c[\onsets].collect { |p| p[0].round(0.001) });
    check.("the empty takes detect nothing", cells[[1, j]][\onsets].isEmpty and: { cells[[2, j]][\onsets].isEmpty },
        "got " ++ cells[[1, j]][\onsets].size ++ " and " ++ cells[[2, j]][\onsets].size);
    check.("the analyser reads the clean 7/8 as 7/8 in two bars at 0.5",
        sameReading.(c[\reading], (numerator: 7, denominator: 8, k: 2)), "got " ++ fmtReading.(c[\reading]));
    check.("the take whose bars were given by hand has them as its label: 7+7+7+8",
        MeterAnalyzer.barsOf(allTakes[4][\label]) == [7, 7, 7, 8], "got " ++ fmtReading.(allTakes[4][\label]));
    check.("...and today's analyser finds them in its audio at 0.5 (uneven bars, detected)",
        sameReading.(cells[[3, j]][\reading], allTakes[4][\label]),
        "got " ++ fmtReading.(cells[[3, j]][\reading]));
    check.("peakFilter drops a soft hit beside a loud one and keeps even ones",
        peakFilter.([[0, 1], [0.05, 0.2], [0.3, 1], [0.4, 0.9]], 0.15, 1.4).collect { |p| p[0] } == [0, 0.3, 0.4],
        "got " ++ peakFilter.([[0, 1], [0.05, 0.2], [0.3, 1], [0.4, 0.9]], 0.15, 1.4));
    check.("gapFilter keeps the first hit of a cluster and measures from the kept one",
        gapFilter.([[0, 0.2], [0.1, 1], [0.2, 1], [0.3, 1]], 0.15).collect { |p| p[0] } == [0, 0.2],
        "got " ++ gapFilter.([[0, 0.2], [0.1, 1], [0.2, 1], [0.3, 1]], 0.15));
    check.("auto reads the clean 7/8 as 7/8 in two bars",
        sameReading.(variants[[0, 0]][\reading], (numerator: 7, denominator: 8, k: 2)),
        "got " ++ fmtReading.(variants[[0, 0]][\reading]));
    check.("vote reads it so too",
        sameReading.(variants[[0, 1]][\reading], (numerator: 7, denominator: 8, k: 2)),
        "got " ++ fmtReading.(variants[[0, 1]][\reading]));
    check.("the peak and gap rows keep its even-spaced hits, 0.3 s apart",
        variantKeys.every { |key, v| (key.size == 1)
            or: { variants[[0, v]][\onsets].size == cells[[0, 0]][\onsets].size } },
        "got " ++ variantKeys.collect { |key, v| variants[[0, v]][\onsets].size });
    "".postln;
    (if(failures == 0) { "SELF-TEST PASSED" } { "SELF-TEST FAILED — " ++ failures ++ " check(s)" }).postln;
};

MeterAnalyzer.fallbackNum   = savedFallback[0];
MeterAnalyzer.fallbackDenom = savedFallback[1];
MeterAnalyzer.fallbackBars  = savedFallback[2];

// Headless, exiting is essential: without it sclang idles forever. In the IDE
// it must NOT exit — that would kill the interpreter mid-session.
if(headless) { if(failures > 0) { 1.exit } { 0.exit } };
)
