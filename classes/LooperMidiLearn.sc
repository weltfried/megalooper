// One learning: a control waits for the controller message that is to drive
// it (docs/dev/midi-map.md 6.1-6.3). Pure, like LooperMidiMap: it is told every
// message as it arrives, with the time and what the router last saw of that
// CC before it (and a knob's place sent back to it since, 5.7), and the time
// passing; it says when it has learned a message, or why it won't. The router
// (setup-midimap.scd) swallows every message while a learning runs, turns the
// outcome into a binding, and asks before it takes a message another control
// has.
//
// What is learned:
//   - a note on, at once;
//   - a program change, at once;
//   - a CC once it is at least 3 steps from where it was before the arm. The
//     TSMega's pedal hops one step back and forth on its own, and replayed over
//     the MIDI log this never learns the resting pedal (6.2). A CC never seen
//     before needs a second message, since its first only shows where it is.
//     Sent a knob's place since its last message (5.7), it has to be 3 steps
//     from that place too: one that took it (an encoder) is there now, one
//     that didn't (a pedal, a fader with no motor) is where it was. A switch
//     that sends the same value every press counts when that value comes
//     again after a second of silence;
//   - pitch bend once it moves 3/128 of its range.
// Never: note offs, aftertouch. Messages less than 30 ms apart are a burst,
// judged together once it ends: a bank select (CC 0 or 32) with a program
// change is that program change; an NRPN or RPN (CC 99/98 or 101/100 with data
// entry, CC 6 or 38) is refused; and several controls that would each be
// learned, a controller sending a snapshot of its knobs, are refused.
//
// A CC learned for a trigger or a toggle asks for two presses, and counting
// its messages tells what kind of switch it is, once it has been quiet for
// 1.5 s, or 4 s after its first press at most, so a control that never goes
// quiet (a flickering pedal) can't keep the learning going (6.3). 2 messages
// are one message per press (the TSMega's CC 80 and 81). 4 alternating high
// and low, a switch's two levels, are press and release. Messages that move
// in steps are a knob or pedal: on a switch it switches at 64 and back at 56,
// so its flicker can't flip it. Anything else is one message per press, and
// `ask` says the player should be asked.
//
// The outcome: (msg:, chan:, num:, src:, switch:, ask:) once a message is
// learned (num nil for bend, switch nil unless counted), or (refused: why).
LooperMidiLearn {
    classvar <timeout = 15, <burstGap = 0.03, <quiet = 1.5, <countFor = 4, <steps = 3, <bendSteps = 384, <repeatGap = 1.0;
    var <target, <kind, <armedAt, <deadline;
    var baselines, places, counts, burst, lastAt, chosen, <chosenKey, <outcome, <refusals;

    *new { |target, kind, now|
        ^super.new.init(target, kind, now)
    }

    init { |inTarget, inKind, now|
        target = inTarget;
        kind = inKind;
        armedAt = now;
        deadline = now + timeout;
        baselines = Dictionary.new;
        places = Dictionary.new;
        counts = Dictionary.new;
        burst = List.new;
        refusals = List.new;
    }

    // Past its 15 s with nothing learned? Not while it counts presses: the
    // player is pressing.
    expired { |now| ^outcome.isNil and: { chosen.isNil } and: { now > deadline } }

    // Counting presses: the message chosen, waiting for the switch to go quiet.
    counting { ^chosen.notNil and: { outcome.isNil } }

    // A message, as the router has it: `msg` one of \noteOn, \noteOff, \cc,
    // \program, \bend, \touch, \polytouch; `last` and `lastWhen` what the router
    // last saw of this CC or bend before this message, and when (nil if never);
    // `sent` a knob's place sent back to it since then (nil if none, 5.7).
    // Answers the outcome once there is one, else nil.
    feed { |msg, chan, num, val, src, last, lastWhen, now, sent|
        var key, ev;
        if(outcome.notNil) { ^outcome };
        this.tick(now);
        if(outcome.notNil) { ^outcome };
        key = LooperMidiLearn.key(msg, chan, num, src);
        if((msg == \cc) or: { msg == \bend }) {
            (counts[key] ?? { counts.put(key, List.new); counts[key] }).add([now, val]);
        };
        if(chosen.notNil) {
            // Counting presses: only the chosen control matters now.
            lastAt = now;
            ^nil
        };
        ev = (msg: msg, chan: chan, num: num, val: val, src: src, key: key, at: now,
            hit: this.prHit(msg, key, val, last, lastWhen, now, sent));
        burst.add(ev);
        lastAt = now;
        ^nil
    }

    // Time passing, from a timer or before a message: a burst 30 ms old is
    // judged, and a switch quiet for 1.5 s is counted. Answers the outcome
    // once there is one, else nil.
    tick { |now|
        var quietSince;
        if(outcome.notNil) { ^outcome };
        if(chosen.isNil and: { burst.notEmpty } and: { (now - lastAt) >= burstGap }) {
            this.prJudgeBurst;
        };
        if(chosen.notNil and: { outcome.isNil }) {
            quietSince = counts[chosenKey] !? { |c| c.last[0] } ? chosen[\at];
            if(((now - quietSince) >= quiet) or: { (now - chosen[\at]) >= countFor }) { this.prCount };
        };
        ^outcome
    }

    // One string per control: the message type, channel, number and input.
    // Note on and off are one control.
    *key { |msg, chan, num, src|
        var m = if((msg == \noteOn) or: { msg == \noteOff }) { \note } { msg };
        ^m.asString ++ "/" ++ chan ++ "/" ++ num ++ "/" ++ src
    }

    // Would this message, alone, be learned?
    prHit { |msg, key, val, last, lastWhen, now, sent|
        var base, place, gap;
        case
        { msg == \noteOn } { ^val > 0 }
        { msg == \program } { ^true }
        { (msg == \cc) or: { msg == \bend } } {
            gap = if(msg == \bend) { bendSteps } { steps };
            if(baselines.includesKey(key).not) {
                // Where it was before the arm; a control never seen is where
                // its first message says. A place sent since is kept beside it:
                // which of the two the knob is at isn't known.
                baselines.put(key, last ? val);
                sent !? { places.put(key, sent) };
                if(last.isNil) { ^false };
            };
            base = baselines[key];
            place = places[key];
            if(((val - base).abs >= gap) and: { place.isNil or: { (val - place).abs >= gap } }) { ^true };
            // A switch sending one value per press, pressed again after a pause.
            ^(msg == \cc) and: { last.notNil } and: { val == last } and: { lastWhen.notNil }
                and: { (now - lastWhen) >= repeatGap }
        };
        ^false
    }

    prJudgeBurst {
        var hits, keys, pcs, header, nrpn;
        nrpn = burst.any { |e| (e[\msg] == \cc) and: { [99, 101].includes(e[\num]) } }
            and: { burst.any { |e| (e[\msg] == \cc) and: { [6, 38].includes(e[\num]) } } };
        pcs = burst.select { |e| e[\msg] == \program };
        header = burst.any { |e| (e[\msg] == \cc) and: { [0, 32].includes(e[\num]) } };
        hits = burst.select { |e| e[\hit] };
        // A bank select is the program change's header, not a control.
        if(pcs.notEmpty and: { header }) {
            hits = hits.reject { |e| (e[\msg] == \cc) and: { [0, 32].includes(e[\num]) } };
        };
        keys = hits.collect { |e| e[\key] }.asSet;
        burst = List.new;
        case
        { nrpn } { this.prRefuse("this control sends NRPN, which megalooper can't learn yet") }
        { keys.size > 1 } { this.prRefuse("several controls at once — move just one") }
        { keys.size == 1 } {
            chosen = hits[0];
            chosenKey = chosen[\key];
            // A CC on a switch is counted; everything else is learned now.
            if((chosen[\msg] == \cc) and: { (kind == \trigger) or: { kind == \toggle } }) {
                ^this
            };
            outcome = this.prLearned(nil, false);
        };
    }

    // A refusal is said, and the learning goes on until its time is up.
    prRefuse { |why|
        refusals.add(why);
    }

    prCount {
        var vals = (counts[chosenKey] ? []).collect { |c| c[1] };
        var n = vals.size, levels, twoLevel, alternating, sw, ask = false;
        // A switch sends two levels far apart (0 and 64, 0 and 127); a knob
        // or a pedal moves in steps.
        levels = vals.asSet.asArray.sort;
        twoLevel = (levels.size <= 2) and: { (levels.last - levels.first) >= 32 };
        alternating = (n == 4) and: { twoLevel } and: {
            (1..3).every { |i| (vals[i] >= 64) != (vals[i - 1] >= 64) }
        };
        sw = case
            { n == 2 } { \oneMessage }
            { alternating } { \pressRelease }
            { twoLevel or: { n < 2 } } { ask = true; \oneMessage }
            { \knob };
        outcome = this.prLearned(sw, ask);
    }

    prLearned { |sw, ask|
        var m = chosen[\msg], msg, num;
        msg = if(m == \noteOn) { \note } { m };
        num = if(m == \bend) { nil } { chosen[\num] };
        ^(msg: msg, chan: chosen[\chan], num: num, src: chosen[\src], switch: sw, ask: ask)
    }
}
