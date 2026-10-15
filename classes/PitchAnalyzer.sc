// Estimate the tonal center of a recorded loop from per-frame Tartini pitch
// samples. Builds an amplitude-weighted 12-bin chroma vector, then correlates
// against Krumhansl-Schmuckler key profiles (rotated for each root) to pick
// the best (root, mode) pair. Output is shaped for AbletonOSC:
//   root      — 0..11 pitch class, matches /live/song/set/root_note
//   scaleName — "Major" / "Minor", matches /live/song/set/scale_name
PitchAnalyzer {
    classvar <noteNames;
    classvar <majorProfile;
    classvar <minorProfile;
    classvar <>minSamples = 8;
    classvar <>hzLo = 30, <>hzHi = 2000;

    *initClass {
        noteNames = ["C", "C#", "D", "D#", "E", "F", "F#",
                     "G", "G#", "A", "A#", "B"];
        // Krumhansl-Schmuckler key profiles. Index 0 = tonic.
        majorProfile = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09,
                        2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
        minorProfile = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53,
                        2.54, 4.75, 3.98, 2.69, 3.34, 3.17];
    }

    *analyze { |samples|
        var chroma, bestRoot, bestMode, bestScore = -inf;
        if(samples.size < minSamples) {
            ^(root: nil, error: \insufficientPitchSamples,
                pitchSampleCount: samples.size)
        };
        chroma = this.buildChroma(samples);
        if(chroma.sum <= 0) {
            ^(root: nil, error: \noPitchEnergy,
                pitchSampleCount: samples.size)
        };
        12.do { |root|
            [\major, \minor].do { |mode|
                var profile = if(mode == \major) { majorProfile } { minorProfile };
                var score = this.pearson(chroma, profile.rotate(root));
                if(score > bestScore) {
                    bestScore = score; bestRoot = root; bestMode = mode;
                };
            };
        };
        ^(root: bestRoot,
            rootName: noteNames[bestRoot],
            scale: bestMode,
            scaleName: if(bestMode == \major) { "Major" } { "Minor" },
            keyScore: bestScore,
            chroma: chroma,
            pitchSampleCount: samples.size)
    }

    *buildChroma { |samples|
        var chroma = Array.fill(12, 0.0);
        samples.do { |pair|
            var hz = pair[0], amp = pair[1];
            if(hz > hzLo and: { hz < hzHi } and: { amp > 0 }) {
                var pc = hz.cpsmidi.round.asInteger.mod(12);
                chroma[pc] = chroma[pc] + amp;
            };
        };
        ^chroma
    }

    // Window-based segmentation. `samples` is [[t, hz, amp], ...] with `t` in
    // seconds relative to loop start. Returns a sparse chord progression:
    // adjacent windows with the same (root, scale) are merged into one segment
    // with a `start` field. The returned array spans [0, loopDur): leading and
    // trailing nil windows are filled with the nearest valid window so playback
    // scheduling always has a chord active.
    *analyzeSegments { |samples, windowDur, loopDur, minPerWindow=3|
        var winCount, windowed, raw, firstIdx, segments, last;
        if(samples.size < minSamples
            or: { windowDur <= 0 } or: { loopDur <= 0 }) {
            ^[]
        };
        winCount = (loopDur / windowDur).ceil.asInteger.max(1);
        windowed = Array.fill(winCount, { List.new });
        samples.do { |triple|
            var t = triple[0];
            if(t >= 0 and: { t < loopDur }) {
                var idx = (t / windowDur).floor.asInteger.clip(0, winCount - 1);
                windowed[idx].add([triple[1], triple[2]]);
            };
        };
        raw = windowed.collect { |bucket|
            var r;
            if(bucket.size < minPerWindow) { nil } {
                r = this.analyze(bucket.asArray);
                if(r.root.isNil) { nil } { r }
            };
        };
        firstIdx = raw.detectIndex { |w| w.notNil };
        if(firstIdx.isNil) { ^[] };
        // Forward-fill nils after first valid window.
        last = raw[firstIdx];
        raw.size.do { |i|
            if(raw[i].isNil) { raw[i] = last } { last = raw[i] };
        };
        // Backfill leading nils so the first segment starts at t=0.
        firstIdx.do { |i| raw[i] = raw[firstIdx] };
        segments = List.new;
        raw.do { |w, i|
            var startNewSeg = segments.isEmpty;
            if(startNewSeg.not) {
                var last = segments.last;
                if(last[\root] != w.root or: { last[\scale] != w.scale }) {
                    startNewSeg = true;
                };
            };
            if(startNewSeg) {
                segments.add((
                    start: i * windowDur,
                    root: w.root, rootName: w.rootName,
                    scale: w.scale, scaleName: w.scaleName,
                    keyScore: w.keyScore
                ));
            };
        };
        ^segments.asArray
    }

    *pearson { |a, b|
        var n = a.size;
        var meanA = a.sum / n;
        var meanB = b.sum / n;
        var num = 0.0, denomA = 0.0, denomB = 0.0;
        n.do { |i|
            var da = a[i] - meanA, db = b[i] - meanB;
            num = num + (da * db);
            denomA = denomA + (da * da);
            denomB = denomB + (db * db);
        };
        if(denomA == 0 or: { denomB == 0 }) { ^0 };
        ^num / (denomA * denomB).sqrt
    }
}
