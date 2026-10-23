// Megalooper SA's note sequencer (docs/dev/synth.md): one note a step, built
// from seven lanes of values that can each step on their own. It does what
// SQ Sequencer (from Live 12's Sequencers pack, the pack Rhythmic Steps came
// from) does, read from that device's patch; the names and the choices marked
// "ours" below are megalooper's. Everything is a class method that takes all
// of its inputs as arguments, as in MegaSASteps: MegaSADrums owns the clock,
// the dice's seed and the voices, and calls these for every step (its Notes
// part, on the drums' own grid).
//
// A PATTERN is an Event (read fields as pattern[\key], never pattern.key):
//
//   (steps: 16 Booleans          a step on or off
//    stepCount: 16 (8 or 16)     how many steps there are
//    first: 1, last: 16          the steps the sequence plays, 1-based
//    direction: \forward         (directions)
//    lanes: (pitch: (values: 16 Integers, own: false, first: 1, last: 16,
//                    direction: \forward, range: 12), octave: ..., ...)
//                   a lane that is not `own` follows the sequence's step;
//                   one that is has its own first, last and direction, so
//                   lanes of different lengths drift against each other.
//                   range: how far Random reaches (laneSpecs)
//    division: 4 (into divisions: 1/16), triplet: false, dotted: false,
//    swing: 0.0 (0..1)
//    scaleOn: true, root: 0 (0..11, C..B), scale: 1 (into scales: Minor)
//    octave: 0 (-3..3, the whole line), restart: \bar (restarts))
//
// What one step plays (decide): the sequence's position from its direction
// and the step count since the last restart; each lane's own position (or
// the sequence's); and then, if the step is on, its condition holds and its
// velocity is above 0, one note:
//
//   note   = 60 + root + pitch, snapped DOWN to the scale (when scaleOn),
//            + 12 * (octave lane + pattern octave), clipped to 0..127
//   vel    = the velocity lane
//   length = the length lane in % of a step (at least 1 %)
//   shift  = the time-shift lane in % of a step, late
//   ratchet r: the note r + 1 times, evenly through the step, each one as
//            long as `length` says (a mono instrument ends the one before)
//
// Ours, where SQ differs:
//   - pitch 0 is the root: SQ starts every pattern on C and only quantises
//     to the root's scale (its root then names the scale, not the note);
//   - the time shift is a share of the step, so it keeps its feel at any
//     tempo: SQ delays by 0..100 ms;
//   - Snake walks one step up or down every step, turning back at the ends:
//     SQ's walk (Max's drunk object, at its defaults) may also stand still;
//   - a direction changed while playing jumps to where the count puts the
//     lane: SQ carries on from where it was;
//   - the sequence restarts (restart) on every bar line by default, as the
//     drums' Step sequencer does (the duo's choice, 2026-10-18): SQ counts
//     from the transport's start;
//   - the transpose by incoming MIDI notes is not here (SQ: on by default).
//
// Conditions, from SQ's ConditionalTrig: c counts against the condition
// lane's pass p (0 on its first pass, one more every time it goes round,
// a restart counting as going round): c = 0 or 1 always plays, c >= 2 plays
// when p mod c = 0 (once in c passes), c = -1 never, c <= -2 plays when
// p mod -c is not 0 (all but that pass).
//
// Swing, from SQ's SwingMap: every second step of the count since the
// transport's start is late by swing * 0.498 of a step (100 % puts it at
// three quarters of the pair).
MegaSANoteSeq {

    // ---- The tables ----------------------------------------------------------

    *laneNames { ^#[\pitch, \octave, \velocity, \length, \shift, \ratchet, \condition] }

    // lo, hi, default value, default Random range (how far a draw reaches;
    // randomValues says from where).
    *laneSpecs {
        ^(pitch: [-12, 12, 0, 12], octave: [-3, 3, 0, 1], velocity: [0, 127, 100, 60],
            length: [0, 100, 74, 60], shift: [0, 100, 0, 30], ratchet: [0, 6, 0, 2],
            condition: [-10, 10, 0, 4])
    }

    *directions { ^#[\forward, \backward, \alternate, \snake, \random] }

    // Ticks per step at 480 a quarter note, for 1/1 .. 1/64.
    *divisions { ^#[1920, 960, 480, 240, 120, 60, 30] }
    *divisionNames { ^#["1/1", "1/2", "1/4", "1/8", "1/16", "1/32", "1/64"] }

    // \bar: from the first step on or after every bar line (uneven bars too);
    // \loop: from every pass of the loop; \off: only at the transport's start.
    *restarts { ^#[\bar, \loop, \off] }

    *rootNames { ^#["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"] }

    // The scales a step snaps to: a name and the semitones above the root.
    *scales {
        ^#[
            ["Major", [0, 2, 4, 5, 7, 9, 11]],
            ["Minor", [0, 2, 3, 5, 7, 8, 10]],
            ["Dorian", [0, 2, 3, 5, 7, 9, 10]],
            ["Mixolydian", [0, 2, 4, 5, 7, 9, 10]],
            ["Lydian", [0, 2, 4, 6, 7, 9, 11]],
            ["Phrygian", [0, 1, 3, 5, 7, 8, 10]],
            ["Locrian", [0, 1, 3, 5, 6, 8, 10]],
            ["Whole tone", [0, 2, 4, 6, 8, 10]],
            ["Half-whole diminished", [0, 1, 3, 4, 6, 7, 9, 10]],
            ["Whole-half diminished", [0, 2, 3, 5, 6, 8, 9, 11]],
            ["Minor blues", [0, 3, 5, 6, 7, 10]],
            ["Minor pentatonic", [0, 3, 5, 7, 10]],
            ["Major pentatonic", [0, 2, 4, 7, 9]],
            ["Harmonic minor", [0, 2, 3, 5, 7, 8, 11]],
            ["Harmonic major", [0, 2, 4, 5, 7, 8, 11]],
            ["Dorian #4", [0, 2, 3, 6, 7, 9, 10]],
            ["Phrygian dominant", [0, 1, 4, 5, 7, 8, 10]],
            ["Melodic minor", [0, 2, 3, 5, 7, 9, 11]],
            ["Lydian augmented", [0, 2, 4, 6, 8, 9, 11]],
            ["Lydian dominant", [0, 2, 4, 6, 7, 9, 10]],
            ["Super Locrian", [0, 1, 3, 4, 6, 8, 10]],
            ["Spanish eight-tone", [0, 1, 3, 4, 5, 6, 8, 10]],
            ["Bhairav", [0, 1, 4, 5, 7, 8, 11]],
            ["Hungarian minor", [0, 2, 3, 6, 7, 8, 11]],
            ["Hirajoshi", [0, 2, 3, 7, 8]],
            ["In-sen", [0, 1, 5, 7, 10]],
            ["Iwato", [0, 1, 5, 6, 10]],
            ["Kumoi", [0, 2, 3, 7, 9]],
            ["Pelog selisir", [0, 1, 3, 7, 8]],
            ["Pelog tembung", [0, 1, 5, 7, 8]],
            ["Messiaen mode 3", [0, 2, 3, 4, 6, 7, 8, 10, 11]],
            ["Messiaen mode 4", [0, 1, 2, 5, 6, 7, 8, 11]],
            ["Messiaen mode 5", [0, 1, 5, 6, 7, 11]],
            ["Messiaen mode 6", [0, 2, 4, 5, 6, 8, 10, 11]],
            ["Messiaen mode 7", [0, 1, 2, 3, 5, 6, 7, 8, 9, 11]]
        ]
    }

    // The settings of the pattern itself, and of a lane, with what each takes.
    *settingNames { ^#[\stepCount, \first, \last, \direction, \division, \triplet, \dotted, \swing,
        \scaleOn, \root, \scale, \octave, \restart] }
    *laneSettingNames { ^#[\own, \first, \last, \direction, \range] }

    // The settings that move the steps in time: an edit carries the count on
    // from the next step at the new rate (MegaSADrums.prNoteRetime).
    *timingSettings { ^#[\division, \triplet, \dotted] }

    // ---- Patterns --------------------------------------------------------------

    // A fresh install's pattern (ours): a minor line round the root, the scale
    // on, every lane following the sequence.
    *defaultPattern {
        var specs = this.laneSpecs;
        var lanes = ();
        this.laneNames.do { |name|
            lanes.put(name, (values: Array.fill(16, specs[name][2]), own: false, first: 1, last: 16,
                direction: \forward, range: specs[name][3]));
        };
        lanes[\pitch][\values] = [0, 7, 12, 7, 3, 7, 10, 7, 0, 7, 12, 10, 8, 7, 3, 2];
        ^(steps: Array.fill(16, true), stepCount: 16, first: 1, last: 16, direction: \forward,
            lanes: lanes, division: 4, triplet: false, dotted: false, swing: 0.0,
            scaleOn: true, root: 0, scale: 1, octave: 0, restart: \bar)
    }

    // A deep copy: the lanes' Events and Arrays are the pattern's own.
    *copyPattern { |pat|
        var lanes = ();
        pat[\lanes].keysValuesDo { |k, lane|
            lanes.put(k, lane.copy.put(\values, lane[\values].copy));
        };
        ^pat.copy.put(\steps, pat[\steps].copy).put(\lanes, lanes)
    }

    // A setting stored if it is one the pattern takes (clipped or rounded
    // into its range), answering the value stored, or nil (nothing changed).
    *putSetting { |pat, name, v|
        var stored = this.cleanSetting(name, v);
        if(stored.isNil) { ^nil };
        pat.put(name, stored);
        this.keepRange(pat);
        ^pat[name]
    }

    *cleanSetting { |name, v|
        var bool = { |x| if(x.isKindOf(Boolean)) { x } { nil } };
        var int = { |x, lo, hi| if(x.isNumber) { x.round.asInteger.clip(lo, hi) } { nil } };
        ^switch(name,
            \stepCount, { if(v.isNumber) { if(v.round.asInteger <= 8) { 8 } { 16 } } },
            \first, { int.(v, 1, 16) },
            \last, { int.(v, 1, 16) },
            \direction, { if(this.directions.includes(v)) { v } },
            \division, { int.(v, 0, this.divisions.size - 1) },
            \triplet, { bool.(v) },
            \dotted, { bool.(v) },
            \swing, { if(v.isNumber) { v.asFloat.clip(0, 1) } },
            \scaleOn, { bool.(v) },
            \root, { int.(v, 0, 11) },
            \scale, { int.(v, 0, this.scales.size - 1) },
            \octave, { int.(v, -3, 3) },
            \restart, { if(this.restarts.includes(v)) { v } },
            { nil })
    }

    *putLaneSetting { |pat, lane, name, v|
        var spec = this.laneSpecs[lane], l = pat[\lanes][lane], stored;
        if(l.isNil or: { spec.isNil }) { ^nil };
        stored = switch(name,
            \own, { if(v.isKindOf(Boolean)) { v } },
            \first, { if(v.isNumber) { v.round.asInteger.clip(1, 16) } },
            \last, { if(v.isNumber) { v.round.asInteger.clip(1, 16) } },
            \direction, { if(this.directions.includes(v)) { v } },
            \range, { if(v.isNumber) { v.round.asInteger.clip(0, spec[1]) } },
            { nil });
        if(stored.isNil) { ^nil };
        l.put(name, stored);
        this.keepRange(pat);
        ^l[name]
    }

    // One lane value, clipped into the lane's range; answers it, or nil.
    *putValue { |pat, lane, i, v|
        var spec = this.laneSpecs[lane], l = pat[\lanes][lane];
        if(l.isNil or: { spec.isNil } or: { v.isNumber.not } or: { i.isInteger.not }
            or: { i < 0 } or: { i > 15 }) { ^nil };
        l[\values][i] = v.round.asInteger.clip(spec[0], spec[1]);
        ^l[\values][i]
    }

    // first <= last, both within stepCount: a range that would be empty
    // shrinks from the start (the end moved last).
    *keepRange { |pat|
        var n = pat[\stepCount] ? 16;
        var fix = { |e|
            e[\last] = (e[\last] ? n).clip(1, n);
            e[\first] = (e[\first] ? 1).clip(1, e[\last]);
        };
        fix.(pat);
        pat[\lanes].do { |l| fix.(l) };
    }

    // ---- What one step plays ---------------------------------------------------

    // Ticks per step.
    *stepTicks { |pat|
        var s = this.divisions[(pat[\division] ? 4).clip(0, this.divisions.size - 1)];
        if(pat[\triplet] == true) { s = s * 2 / 3 };
        if(pat[\dotted] == true) { s = s * 1.5 };
        ^s
    }

    // How late step g of the transport's count plays, in ticks: every odd
    // one by swing * 0.498 of a step.
    *swingTicks { |pat, g, s|
        ^if(g.asInteger.odd) { ((pat[\swing] ? 0) * 0.498) * s } { 0 }
    }

    // Where a lane of `len` steps is on step `count` (from 0), 0..len - 1.
    // prev is its position the step before (Snake's walk) and u a number in
    // [0, 1) drawn for this step (Snake's and Random's).
    *position { |dir, count, len, prev, u|
        var period, m, p;
        len = (len ? 1).asInteger.max(1);
        count = (count ? 0).asInteger.max(0);
        u = u ? 0;
        ^switch(dir,
            \backward, { (len - 1) - (count % len) },
            \alternate, {
                period = 2 * (len - 1);
                if(period <= 0) { 0 } {
                    m = count % period;
                    if(m <= (len - 1)) { m } { period - m }
                }
            },
            \snake, {
                if(prev.isNil or: { count == 0 } or: { len == 1 }) { 0 } {
                    p = prev.clip(0, len - 1) + if(u < 0.5) { -1 } { 1 };
                    if(p < 0) { 1 } { if(p >= len) { len - 2 } { p } }
                }
            },
            \random, { (u * len).floor.asInteger.clip(0, len - 1) },
            { count % len })
    }

    // Does condition c play on pass p (see the header)?
    *conditionPlays { |c, p|
        c = (c ? 0).asInteger;
        p = (p ? 0).asInteger.max(0);
        ^case
        { c == -1 } { false }
        { c.abs <= 1 } { true }
        { c > 0 } { (p % c) == 0 }
        { (p % c.abs) != 0 }
    }

    // `note` snapped down to the scale `intervals` above `root`.
    *snap { |note, root, intervals|
        var x = note - root, oct = (x / 12).floor, deg = x - (oct * 12), best = 0;
        intervals.do { |iv| if(iv <= deg) { best = iv } };
        ^((root + (oct * 12)) + best).asInteger
    }

    // One step. count: steps since the last restart (0 on it). state: what
    // the step before left (nil at the transport's start): snake positions
    // and the condition lane's pass. rand.(slot, kind) answers a Float in
    // [0, 1) for this step: slot 0 is the sequence, 1..7 the lanes.
    // Answers (state:, main: 0..15, lanes: (name -> 0..15), note: nil or
    // (note:, vel:, length:, shift:, ratchet:)), length and shift as shares
    // of a step.
    *decide { |pat, count, state, rand|
        var snakes = (state !? { |st| st[\snake] }) ?? { () }, newSnakes = ();
        var pass = state !? { |st| st[\pass] };
        var lanes = (), at, main, mainLen, cond, condLen, condCount, plays, v, note, nt, scale;
        // A lane's (or the sequence's) step: first - 1 + its position.
        at = { |key, slot, e, dir|
            var len = (e[\last] - e[\first]) + 1;
            var u = if((dir == \snake) or: { dir == \random }) { rand.value(slot, dir) } { 0 };
            var p = this.position(dir, count, len, snakes[key], u);
            newSnakes.put(key, p);
            (e[\first] - 1) + p
        };
        main = at.(\main, 0, pat, pat[\direction]);
        mainLen = (pat[\last] - pat[\first]) + 1;
        this.laneNames.do { |name, i|
            var l = pat[\lanes][name];
            lanes.put(name, if(l[\own] == true) { at.(name, i + 1, l, l[\direction]) } { main });
        };
        cond = pat[\lanes][\condition];
        condLen = if(cond[\own] == true) { (cond[\last] - cond[\first]) + 1 } { mainLen };
        if(pass.isNil or: { (count % condLen.max(1)) == 0 }) { pass = (pass ? -1) + 1 };
        v = { |name| pat[\lanes][name][\values][lanes[name]] };
        plays = (pat[\steps][main] == true) and: { this.conditionPlays(v.(\condition), pass) }
            and: { v.(\velocity) > 0 };
        if(plays) {
            note = (60 + (pat[\root] ? 0)) + v.(\pitch);
            if(pat[\scaleOn] == true) {
                scale = this.scales[(pat[\scale] ? 1).clip(0, this.scales.size - 1)][1];
                note = this.snap(note, pat[\root] ? 0, scale);
            };
            note = (note + (12 * (v.(\octave) + (pat[\octave] ? 0)))).clip(0, 127).asInteger;
            nt = (note: note, vel: v.(\velocity), length: (v.(\length) / 100).max(0.01),
                shift: v.(\shift) / 100, ratchet: v.(\ratchet));
        };
        ^(state: (snake: newSnakes, pass: pass), main: main, lanes: lanes, note: nt)
    }

    // When the hits of a note go, as shares of a step after its shift.
    *ratchetTimes { |r| ^(0 .. r.asInteger.max(0)).collect { |j| j / (r.asInteger.max(0) + 1) } }

    // ---- Editing (the Synth view's tools) --------------------------------------
    // Each answers the lane's 16 new values; only the steps first..last of
    // the lane (its own, or the sequence's) change.

    // The steps a lane plays, 0-based.
    *laneSpan { |pat, lane|
        var e = if(pat[\lanes][lane][\own] == true) { pat[\lanes][lane] } { pat };
        ^((e[\first] - 1) .. (e[\last] - 1))
    }

    // Random values within the lane's range: pitch, octave and condition
    // either side of 0, velocity and length below the top, time shift and
    // ratchet above 0.
    *randomValues { |pat, lane|
        var spec = this.laneSpecs[lane], r = pat[\lanes][lane][\range] ? spec[3];
        var out = pat[\lanes][lane][\values].copy;
        this.laneSpan(pat, lane).do { |i|
            out[i] = switch(lane,
                \velocity, { rrand((spec[1] - r).max(1), spec[1]) },
                \length, { rrand((spec[1] - r).max(1), spec[1]) },
                \shift, { rrand(spec[0], (spec[0] + r).min(spec[1])) },
                \ratchet, { rrand(spec[0], (spec[0] + r).min(spec[1])) },
                { rrand(r.neg.max(spec[0]), r.min(spec[1])) });
        };
        ^out
    }

    *scrambledValues { |pat, lane|
        var span = this.laneSpan(pat, lane), out = pat[\lanes][lane][\values].copy;
        var vals = span.collect { |i| out[i] }.scramble;
        span.do { |i, k| out[i] = vals[k] };
        ^out
    }

    // Every step of the span one step later (by 1) or earlier (by -1), the
    // last coming round to the first.
    *rotatedValues { |pat, lane, by = 1|
        var span = this.laneSpan(pat, lane), out = pat[\lanes][lane][\values].copy;
        var vals = span.collect { |i| out[i] }.rotate(by);
        span.do { |i, k| out[i] = vals[k] };
        ^out
    }

    // Every step of the span up (or down) by `by`, within the range.
    *nudgedValues { |pat, lane, by = 1|
        var spec = this.laneSpecs[lane], out = pat[\lanes][lane][\values].copy;
        this.laneSpan(pat, lane).do { |i| out[i] = (out[i] + by).clip(spec[0], spec[1]) };
        ^out
    }

    *allValues { |pat, lane, v|
        var spec = this.laneSpecs[lane], out = pat[\lanes][lane][\values].copy;
        this.laneSpan(pat, lane).do { |i| out[i] = v.round.asInteger.clip(spec[0], spec[1]) };
        ^out
    }

    *resetValues { |pat, lane| ^Array.fill(16, this.laneSpecs[lane][2]) }
}
