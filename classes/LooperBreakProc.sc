// A cut procedure for looped *playing* — guitar, keys, anything that wants to
// be heard as itself most of the time. Where the classic breakbeat procedures
// chop continuously, this one mostly lets the loop through untouched and only
// now and then grabs a block and repeats it, like stepping on a beat-repeat
// pedal for a bar.
//
// Two things make that work:
//
//   * `cutchance` decides, per block, whether anything happens at all. A block
//     that is not cut is emitted as a SINGLE cut, and megalooper reads
//     `cuts.size > 1` as "a repetition is playing" (see LooperCutGate and the
//     mixer's ampfunc in Looper.spawnBBCutVoice). So in Mix and Insert modes an
//     uncut block is silent from the cutter and you simply hear the dry loop;
//     in Gate mode the cutter plays it straight instead. Either way the result
//     is a loop that only occasionally breaks up.
//
//   * blocks are whole pulses long and can be big (up to 16), so the repeated
//     chunk can be a phrase of playing rather than a stutter. Set min = max for
//     a fixed block size, or spread them for variety.
//
// Repeats replay the audio at the block's own grid position — `offset` is left
// nil, so BBCutBuffer uses `phrasepos % beatlength` — and Looper pins the phrase
// to a whole number of loop passes. Together that keeps the cutter aligned with
// the dry loop both before and after a repeat: a repeat steals its own length
// from the phrase and then playback carries on where the grid says it should.
//
// Every parameter is read through `.value` on each block, so all of them can be
// passed as Functions and changed live without rebuilding the cutter.
LooperBreakProc : BBCutProc {
    var <>cutchance, <>minblock, <>maxblock, <>repeats, <>rollchance;

    *new { |cutchance = 0.25, minblock = 1, maxblock = 4, repeats = 2,
        rollchance = 0.0, phraselength = 8.0, bpsd = 0.5|
        ^super.new(bpsd, phraselength)
            .initLooperBreakProc(cutchance, minblock, maxblock, repeats, rollchance)
    }

    initLooperBreakProc { |cc, minb, maxb, reps, rc|
        cutchance  = cc;
        minblock   = minb;
        maxblock   = maxb;
        repeats    = reps;
        rollchance = rc;
    }

    chooseblock {
        var beatsleft, lo, hi, len, reps;

        if(phrasepos >= currphraselength) {
            this.newPhraseAccounting;
            // A zero-length phrase would leave BBCut2 spinning on empty blocks.
            if(currphraselength <= 0) { currphraselength = 1.0 };
        };
        beatsleft = currphraselength - phrasepos;

        // Whole pulses: this procedure is for musical chunks, not stutters.
        lo  = minblock.value.max(1).round(1);
        hi  = maxblock.value.max(lo).round(1);
        len = rrand(lo, hi).min(beatsleft).max(0.25);
        reps = 1;

        if(cutchance.value.coin) {
            reps = repeats.value.round(1).asInteger.max(2);
            // A block has to fit inside its phrase — BBCutProc tiles phrases, so
            // it cannot straddle the end. Shrink in the order that costs least:
            // first the repeat count, which leaves the chunk size the player
            // dialled in intact...
            while { ((len * reps) > beatsleft) and: { reps > 2 } } { reps = reps - 1 };
            // ...then, only when even two passes won't fit, the chunk itself.
            // Dropping the repeat instead would be the obvious move, but phrase
            // ends come round often — with a 7-pulse loop and 4-pulse blocks
            // most cuts would silently vanish and Cut chance would read far
            // lower than it is set.
            if((len * reps) > beatsleft) { len = (beatsleft / reps).floor.max(1) };
            // Not even one pulse per pass: let this block through untouched.
            if((len * reps) > beatsleft) { reps = 1 };
        };

        if(reps > 1) {
            if(rollchance.value.coin) {
                // Same ground covered twice as fast — a roll instead of a plain
                // repeat. Flagged as a roll so cut synths can shape it.
                cuts = Array.fill(reps * 2, len / 2);
                roll = 1;
            } {
                cuts = Array.fill(reps, len);
                roll = 0;
            };
        } {
            // Pass-through: one cut, so the mixer and the insert gate both read
            // "no repetition" and the dry loop is what you hear.
            cuts = [len];
            roll = 0;
        };

        blocklength = cuts.sum;
        this.endBlockAccounting;
    }
}
