// megalooper — a loop written out as labelled training data for the meter
// analysis (Setup › Analysis › Export, the E key): the loop as a 24-bit WAV,
// and beside it a JSON sidecar holding the labels the player typed (the
// ground truth), the onsets MeterAnalyzer was given and its answer, so a take
// can be analysed again offline without the audio (eval_meter_analyzer.scd,
// meter-eval.scd, test-meter-corpus.scd read the sidecars in training-data/).
//
// Until 2026-11-08 this was the Looper's (docs/dev/architecture.md 5, step 8).
// The Looper hands over what its take is, as an Event (Looper.prExportTake):
//   buffer, loopFrames, startFrame, sampleRate, onsets ([time, strength]
//   pairs as heard, from the take's start), lastResult (the reading), loopDur
//   (the take's own length, seconds), server.
// The sidecar is written whole or not at all (MegaFiles.writeEvent), and names
// its format and version since then; files from before have neither, and
// every reader reads both by key.
LooperTrainingExport {

    *format { ^"megalooper training loop" }
    *version { ^1 }

    // The fields in the file's order, after the format and the version.
    *fieldOrder {
        ^#[\version, \name, \groundTruth, \loopDurSec, \sampleRate, \loopFrames, \firstOnsetSec,
            \analyzerInput, \rawOnsets, \detected, \exportedAt,
            \numerator, \denominator, \bars, \bpm, \loopDur, \onsets, \strengths]
    }

    // A name to [A-Za-z0-9-]: '_' separates the file name's fields. Spaces,
    // '_' and '-' become '-', anything else goes; none left is "loop".
    *safeName { |name|
        var out = String.new;
        name.asString.do { |ch|
            if(ch.isAlphaNum) { out = out ++ ch } {
                if((ch == $ ) or: { ch == $_ } or: { ch == $- }) { out = out ++ $- };
            };
        };
        ^if(out.isEmpty) { "loop" } { out }
    }

    // The quarter-note tempo the labels and the measured length imply: the
    // ground truth's, never the analyser's.
    *bpmOf { |num, denom, bars, dur| ^(bars * num * (4 / denom) / dur * 60).round.asInteger }

    // The name both files share: name_num-denom_Nbars_BPMbpm_stamp.
    *baseName { |name, num, denom, bars, bpm, stamp|
        ^this.safeName(name) ++ "_" ++ num ++ "-" ++ denom ++ "_" ++ bars ++ "bars_" ++ bpm ++ "bpm_" ++ stamp
    }

    // The sidecar, as an Event (MegaFiles.writeEvent writes it). The
    // analyser's input is rebuilt from the take's onsets as the take's
    // analysis built it (Looper.stopRecordStartPlay): times from the first
    // onset, over the take's length from there, so
    // MeterAnalyzer.analyze(loopDur, onsets, strengths) replays it verbatim.
    *sidecar { |take, name, num, denom, bars, bpm, stamp|
        var onsets = take[\onsets] ? [], r = take[\lastResult];
        var sr = take[\sampleRate], dur = take[\loopFrames] / sr;
        var first = if(onsets.isEmpty) { 0 } { onsets[0][0] };
        ^(
            version: this.version,
            name: name.asString,
            groundTruth: (numerator: num, denominator: denom, bars: bars, bpm: bpm),
            loopDurSec: dur,
            sampleRate: sr,
            loopFrames: take[\loopFrames],
            firstOnsetSec: first,
            analyzerInput: (loopDur: take[\loopDur] - first,
                onsets: onsets.collect { |p| p[0] - first }.asArray,
                strengths: onsets.collect { |p| p[1] }.asArray),
            rawOnsets: onsets.collect { |p| [p[0], p[1]] }.asArray,
            // The analyser's answer at the export (it may be an error).
            detected: r !? { (numerator: r[\numerator], denominator: r[\denominator], bpm: r[\bpm], k: r[\k],
                n: r[\n], tau: r[\tau], sub: r[\sub], loopDur: r[\loopDur], onsetCount: r[\onsetCount],
                error: r[\error]) },
            exportedAt: stamp
        )
    }

    // The sidecar to `path`, whole or not at all: nil once written, else why not.
    *writeSidecar { |path, take, name, num, denom, bars, bpm, stamp|
        ^MegaFiles.writeEvent(path, this.sidecar(take, name, num, denom, bars, bpm, stamp), this.format, this.fieldOrder)
    }

    // Both files into `dir`: the WAV (the buffer's loop frames, written by
    // the server, which a Routine waits for), then the sidecar. `done` gets
    // the shared name once both are written. Answers that name at once, or
    // nil when there is no loop. Labels are whole numbers from 1.
    *export { |take, dir, name, num, denom, bars, done|
        var dur, bpm, stamp, base;
        if(take.isNil or: { (take[\loopFrames] ? 0) == 0 } or: { take[\buffer].isNil }) {
            "Export: no loop to export.".warn;
            ^nil
        };
        num = num.asInteger.max(1);
        denom = denom.asInteger.max(1);
        bars = bars.asInteger.max(1);
        dur = take[\loopFrames] / take[\sampleRate];
        bpm = this.bpmOf(num, denom, bars, dur);
        stamp = Date.getDate.stamp.replace("_", "-");
        base = this.baseName(name, num, denom, bars, bpm, stamp);
        File.mkdir(dir);
        Routine {
            var why;
            take[\buffer].write(dir +/+ base ++ ".wav", "WAV", "int24", take[\loopFrames], take[\startFrame]);
            take[\server].sync;
            why = this.writeSidecar(dir +/+ base ++ ".json", take, name, num, denom, bars, bpm, stamp);
            if(why.notNil) { ("Export: the sidecar " ++ base ++ ".json was not written (" ++ why ++ ").").warn } {
                ("Exported training loop: " ++ base).postln;
                done.value(base);
            };
        }.play(AppClock);
        ^base
    }
}
