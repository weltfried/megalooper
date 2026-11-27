// megalooper — the loop cut into slices at its own notes (roadmap item 24,
// docs/dev/sampler.md): what a sampler's Slice mode does by hand, done from
// the take's onsets. Pure class methods, as LoopKey's are: they work on the
// loop's samples and some frame numbers and need no server, so
// scripts/sampler-experiment.scd and the tests run exactly what a take runs.
//
// Two questions, apart:
//   - Where each slice starts (attackStarts). The detector reports an attack
//     10–40 ms late, and the loop's audio sits a chain's latency away from the
//     analysis tap, so a slice cut at the reported frame starts inside its
//     own attack and the slice before ends with it: reversed, that slice would
//     start on a click; gated, the attack would lose its front. So each onset
//     is searched for in the loop's own audio. First the take's constant
//     distance between the tap and the loop: the median of where the
//     steepest rise lies near each onset, over the onsets with a clear one.
//     Then each onset's own steepest rise near reported + that distance, and
//     the end of the quietest stretch just before it. An onset with no clear rise there
//     starts a little before reported + distance: early is harmless (the
//     previous note's tail), late cuts the attack in two.
//   - How the server finds the slice under the playhead (table). The starts
//     sorted round the loop, with the last two again before 0 and the first
//     two again after the end, so IndexInBetween on the table gives, at any
//     position, the slice and the one before it without a wrap of its own.
//
// Measured on two of the duo's takes (scripts/sampler-experiment.scd,
// 2026-11-27): the loop sat 27 ms and 18 ms after the reported onsets; 25 of
// 29 and 14 of 15 onsets had a clear attack, the rest took the distance.
LoopSlices {
    // The level the search reads: a window's RMS every hop, in ms.
    *hopMs { ^1 }
    *windowMs { ^3 }
    // A rise is the level's dB change over riseHops hops.
    *riseHops { ^3 }
    // The first look, for the take's distance: this far either side of each
    // reported onset, ms; a rise this steep (dB) counts as a clear attack.
    *lookMs { ^60 }
    *clearDb { ^6 }
    // The second look: this far either side of reported + distance, ms; a rise
    // under foundDb is no attack found.
    *nearMs { ^25 }
    *foundDb { ^4 }
    // Where the attack begins: the end of the quietest troughWindowMs that ends
    // within troughMs before the rise (to riseHops after its start), the
    // latest within troughDb of the quietest. A window as long as a low
    // note's period: a 3 ms one dips with the waveform's phase, and the
    // quietest of those can lie anywhere in the 20 ms. The latest of the
    // nearly quietest: before a flat floor (silence, a held note) the start
    // stays by the attack instead of wandering back.
    *troughMs { ^20 }
    *troughWindowMs { ^10 }
    *troughDb { ^1 }
    // No attack found: the start this far before reported + distance, ms.
    *earlyMs { ^10 }
    // Starts closer than this, ms, are one slice (the earlier kept).
    *minGapMs { ^30 }
    // The most slices a table holds on the server: its buffer's size, less
    // the four repeats.
    *maxSlices { ^256 }

    // The loop's stereo (or mono) samples, interleaved, as one channel (for
    // checks; attackStarts reads the channels as they are).
    *monoOf { |data, numChannels = 2|
        var m;
        if(numChannels == 1) { ^data };
        m = FloatArray.newClear(data.size div: numChannels);
        m.size.do { |f|
            var s = 0;
            numChannels.do { |c| s = s + data[(f * numChannels) + c] };
            m[f] = s / numChannels;
        };
        ^m
    }

    // Where each slice starts. `data`: the loop, its frames 0..n-1 (read
    // round: frame n is frame 0), `numChannels` interleaved (the mean is
    // heard: no one-channel copy of a long loop is made). `onsetFrames`: the
    // onsets as reported, frames from the loop's start. `pause`, if given, is
    // called after each onset's search (a Routine lets the clocks run there).
    // Answers
    //   (starts: the slices' starts, frames, sorted, nearer than minGapMs
    //    merged; offset: the take's distance, frames; found: per onset, was
    //    its attack found; moved: per onset, frames from reported to start)
    // or starts empty when there are no onsets.
    *attackStarts { |data, sr, onsetFrames, numChannels = 1, pause|
        var n = data.size div: numChannels, hop, win, nHops, rise, look, near, trough, early, envAt, cache, steepest;
        var longWin, longAt, longCache, levels, quietest, firstLook, clear, offHops, found, moved, starts, onsets;
        var k0, kRise, kLow, low, r, d, sq;
        // The square of the channels' mean at frame f (any integer, round).
        sq = if(numChannels == 1) { { |f| data[f.mod(n)].squared } } {
            { |f| var a = f.mod(n) * numChannels, m = 0; numChannels.do { |c| m = m + data[a + c] }; (m / numChannels).squared }
        };
        onsets = (onsetFrames ? []).asArray.select { |f| f.notNil };
        if(onsets.isEmpty or: { n < 2 }) { ^(starts: [], offset: 0, found: [], moved: []) };
        hop = (sr * this.hopMs / 1000).round.asInteger.max(1);
        win = (sr * this.windowMs / 1000).round.asInteger.max(1);
        nHops = (n / hop).floor.asInteger.max(1);
        rise = this.riseHops;
        look = this.lookMs div: this.hopMs;
        near = this.nearMs div: this.hopMs;
        trough = this.troughMs div: this.hopMs;
        early = this.earlyMs div: this.hopMs;
        // The level at hop k (any integer, round the loop), dB, worked out
        // only where the search looks: a long loop with few notes costs little.
        cache = IdentityDictionary.new;
        envAt = { |k|
            var kk = k.mod(nHops), a, s = 0;
            cache[kk] ?? {
                a = kk * hop;
                win.do { |i| s = s + sq.(a + i) };
                cache[kk] = (s / win).sqrt;
                cache[kk]
            }
        };
        // The level of the troughWindowMs that END at hop k, likewise.
        longWin = (sr * this.troughWindowMs / 1000).round.asInteger.max(1);
        longCache = IdentityDictionary.new;
        longAt = { |k|
            var kk = k.mod(nHops), a, s = 0;
            longCache[kk] ?? {
                a = (kk * hop) - longWin;
                longWin.do { |i| s = s + sq.(a + i) };
                longCache[kk] = (s / longWin).sqrt;
                longCache[kk]
            }
        };
        // The steepest rise within [k0 + lo, k0 + hi]: [its hop, dB].
        steepest = { |kc, lo, hi|
            var b = -inf, kr = kc, x;
            (lo .. hi).do { |dd|
                x = envAt.(kc + dd + rise).max(1e-7).ampdb - envAt.(kc + dd).max(1e-7).ampdb;
                if(x > b) { b = x; kr = kc + dd };
            };
            [kr, b]
        };
        firstLook = onsets.collect { |f|
            k0 = (f / hop).round.asInteger;
            r = steepest.(k0, look.neg, look);
            pause.value;
            [r[0] - k0, r[1]]
        };
        clear = firstLook.select { |x| x[1] >= this.clearDb }.collect(_[0]).sort;
        offHops = if(clear.isEmpty) { 0 } { clear[clear.size div: 2] };
        found = Array.newClear(onsets.size);
        moved = Array.newClear(onsets.size);
        starts = onsets.collect { |f, i|
            k0 = (f / hop).round.asInteger + offHops;
            r = steepest.(k0, near.neg, near);
            if(r[1] < this.foundDb) {
                found[i] = false;
                kLow = k0 - early;
            } {
                found[i] = true;
                kRise = r[0];
                levels = ((kRise - trough) .. (kRise + rise)).collect { |k| [k, longAt.(k)] };
                low = levels.collect(_[1]).minItem;
                quietest = levels.select { |x| x[1] <= (low * this.troughDb.dbamp) };
                kLow = quietest.last[0];
            };
            d = (kLow * hop) - f;
            moved[i] = d;
            pause.value;
            ((kLow * hop).mod(n)).asInteger
        };
        ^(starts: this.merged(starts, n, (sr * this.minGapMs / 1000).round.asInteger),
            offset: offHops * hop, found: found, moved: moved)
    }

    // Starts (frames, any order) sorted round a loop of n frames, those
    // nearer than `gap` to the one before merged into it (the earlier kept),
    // the last against the first round the seam too.
    *merged { |starts, n, gap|
        var s = starts.asArray.collect { |f| f.mod(n) }.asSet.asArray.sort, out = List.new;
        s.do { |f| if(out.isEmpty or: { (f - out.last) >= gap }) { out.add(f) } };
        // Round the seam the last start is the earlier of the two.
        if((out.size > 1) and: { ((out[0] + n) - out.last) < gap }) { out.removeAt(0) };
        ^out.asArray
    }

    // The slice table the server reads: the starts (sorted, within 0..n-1),
    // the last two again before 0 and the first two again after n, so any
    // frame p in 0..n-1 has table[j] <= p < table[j + 1] with j - 1 >= 0 and
    // j + 1 inside. nil for no starts. More than maxSlices (a loop multiplied
    // many times over) keeps every k-th, from the first: longer slices, the
    // loop's first note still a slice's start.
    *table { |starts, n|
        var s = starts.asArray.collect { |f| f.mod(n) }.asSet.asArray.sort, m, ext, k;
        if(s.size > this.maxSlices) {
            k = (s.size / this.maxSlices).roundUp.asInteger;
            s = s.select { |f, i| (i % k) == 0 };
        };
        m = s.size;
        if(m == 0) { ^nil };
        ext = (s - (2 * n)) ++ (s - n) ++ s ++ (s + n) ++ (s + (2 * n));
        ^ext.copyRange((2 * m) - 2, (3 * m) + 1)
    }

    // The table as the server's buffer holds it: maxSlices + 4 frames, the
    // rest after the table a value no frame reaches, so IndexInBetween never
    // looks past it. nil in, nil out.
    *padded { |table|
        var size = this.maxSlices + 4;
        if(table.isNil) { ^nil };
        ^(table.keep(size) ++ Array.fill((size - table.size).max(0), { 1e9 }))
    }

    // The slice under frame p (0..n-1), as the server finds it: [its start,
    // its end, the start of the one before], frames, the start possibly below
    // 0 and the end above n where a slice spans the seam.
    *sliceAt { |table, p|
        var j = 1;
        while { (j + 1) < table.size and: { table[j + 1] <= p } } { j = j + 1 };
        ^[table[j], table[j + 1], table[j - 1]]
    }
}
