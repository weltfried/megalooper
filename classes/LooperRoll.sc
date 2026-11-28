// megalooper — a roll that halves (roadmap item 24, idea 7;
// docs/dev/sampler.md): the Looper's part that turns the pedal (Looper.roll)
// into a roll in the engine (LooperSynthDefs.rollOf) and, with Drums roll too
// (Looper.rollDrums), in the drums' roller (rollerGraph, MegaSA's).
//
//   - The pedal leaving 0 arms the roll for the next beat-group head
//     (LooperGrains.groupGrid of the reading in force): the engine starts it
//     on the sample its playhead crosses the note there (its attack, from the
//     slices; the grid point with none within 60 ms), the drums' roller on
//     the grid point less 10 ms (the hit's front). The playhead runs on
//     underneath.
//   - The pedal's travel in fifths: the held group, then a unit (an eighth in
//     7/8), ½, ¼, ⅛ of one. Each window is taken on its next multiple from
//     the roll's start (the server's), so every step lands on the grid.
//   - Back to 0: it lands on the next group head, the loop where it would have
//     been. Up again before then, it rolls on.
//   - The engine holds a start or a landing asked for until its playhead
//     crosses the point (a request is a new count in rollArm / rollLand), and
//     says when it started and landed ('/looperRoll', serverSaid): what the
//     window shows is the engine's, not a timer's. (Until 2026-11-28 a timer
//     disarmed the engine 50 ms after the grid point, and a note later than
//     that was never rolled.)
//   - Refused when it would start at half-time, reversed or overdubbing, or
//     with no reading (no groups to start on); refused once a gesture, not on
//     every value the pedal sends. A stop, a new engine, a multiply, an undo
//     and the next loop cut it at once (`cut`).
//
// A part of the Looper (as LooperSlices is): it asks the Looper for its
// timeline, reading, slices and engine, and says its changes as the Looper's.
LooperRoll {
    var looper;
    // The pedal (0..1), Drums roll too, and where the roll is: \off, \armed
    // (waiting for its group head), \on, \landing; `at`: when it starts or
    // lands (SystemClock seconds) while armed or landing.
    var <amount = 0, <drums = true, <state = \off, <at;
    // The drums' rollers (Synths; MegaSA's), each sent what the engine is,
    // with its own anchor.
    var <>rollers;
    // The window step in force (1..5) and the held group's length (frames).
    var step, groupFrames;
    // The pedal was refused on this gesture: said once, until it is back at 0.
    var refusedGesture = false;
    // Requests sent, counted: each new count is a new request to the engine.
    var armCount = 0, landCount = 0;

    *new { |looper| ^super.newCopyArgs(looper) }

    // How long a message may take to reach the server, s: a group head nearer
    // than this is taken from the next.
    *margin { ^0.03 }
    // How far a window may start from its grid point to start on a note, s.
    *nearNote { ^0.06 }
    // How far before the grid point the drums' window starts, s.
    *drumsEarly { ^0.01 }

    // The pedal's step: nil at 0, then 1..5 in fifths.
    *stepOf { |x| ^if(x <= 0) { nil } { (x * 5).ceil.clip(1, 5).asInteger } }

    rolling { ^state != \off }

    // The window of step k, frames: the held group, then a unit halved.
    windowFrames { |k|
        var unit = this.prUnitFrames;
        ^if(k == 1) { groupFrames ? unit } { unit / (2 ** (k - 2)) }
    }

    // ---- The pedal --------------------------------------------------------------

    amount_ { |x|
        var was = step, why, head;
        amount = x.clip(0, 1);
        step = this.class.stepOf(amount);
        looper.changed(\roll, amount);
        if(step.isNil) {
            refusedGesture = false;
            ^switch(state,
                \armed, { this.cut },
                \on, { this.prLand },
                { this })
        };
        if(state == \off) {
            if(was.notNil and: { refusedGesture }) { ^this };
            if(looper.state != \playing and: { looper.state != \overdubbing }) { ^this };
            why = looper.prRefusal(\roll);
            if(why.notNil) {
                if(refusedGesture.not) { refusedGesture = true; looper.prRefused(\roll, why) };
                ^this
            };
            head = this.prNextHead(SystemClock.seconds);
            if(head.isNil) { refusedGesture = true; ^looper.prRefused(\roll, "the roll needs a reading") };
            ^this.prArm(head)
        };
        if(state == \landing) {
            looper.timeline.cancel(\roll);
            // rollLand back to 0 takes the landing back.
            this.prSendAll([\rollLand, 0]);
            this.prSay(\on, nil);
        };
        this.prSendAll([\rollWin, this.windowFrames(step)]);
    }

    drums_ { |flag|
        drums = flag == true;
        looper.changed(\rollDrums, drums);
    }

    // At once, no landing: the loop stopped, multiplied, undone, a new
    // engine. `engine` false: the engine is gone or new, only the rollers.
    cut { |engine = true|
        looper.timeline.cancel(\roll);
        if(state != \off) {
            if(engine) { this.prEngine([\rollCut, 1, \rollArm, 0, \rollLand, 0]) };
            this.prRollers([\rollCut, 1, \rollArm, 0, \rollLand, 0], nil);
        };
        this.prSay(\off, nil);
    }

    // Cmd-period: the routines and the nodes are gone.
    forget { state = \off; at = nil }

    // The engine says it started (1) or landed (0) ('/looperRoll').
    serverSaid { |value|
        looper.timeline.cancel(\roll);
        if(value == 1) { if(state == \armed) { this.prSay(\on, nil) } } {
            if((state == \landing) or: { state == \on }) { this.prSay(\off, nil) };
        };
    }

    // The window in force as a note value ("1/16"), or "GRP" for the held
    // group, from the reading's unit (an eighth in 7/8); nil with none.
    windowWords {
        var den = (looper.lastResult !? { |r| r[\denominator] }) ? 4;
        ^step !? { |k| if(k == 1) { "GRP" } { "1/" ++ (den * (2 ** (k - 2))).asInteger } }
    }

    // ---- Inside ---------------------------------------------------------------

    // Armed for `head` ((frame:, len:, at:)): the engine and the rollers told
    // now, disarmed after the start.
    prArm { |head|
        var anchor = this.prNoteAt(head[\frame]), win;
        groupFrames = head[\len];
        win = this.windowFrames(step);
        armCount = armCount + 1;
        this.prEngine([\rollArm, armCount, \rollAnchor, anchor, \rollWin, win, \rollLand, 0]);
        if(drums) { this.prRollers([\rollArm, armCount, \rollAnchor, this.prDrumsAt(head[\frame]), \rollWin, win, \rollLand, 0], nil) };
        this.prSay(\armed, head[\at]);
        this.prWatch(head[\at] + 0.1);
    }

    // Landing on the next group head.
    prLand {
        var head = this.prNextHead(SystemClock.seconds);
        if(head.isNil) { ^this.cut };
        landCount = landCount + 1;
        this.prEngine([\rollLand, landCount, \rollLandAt, this.prNoteAt(head[\frame])]);
        this.prRollers([\rollLand, landCount, \rollLandAt, this.prDrumsAt(head[\frame])], nil);
        this.prSay(\landing, head[\at]);
        this.prWatch(head[\at] + 0.1);
    }

    // The count's time, kept true: past the time a start or a landing was
    // due with the engine not yet saying so, the engine still holds it (its
    // playhead crosses the point a pass later): the count looks to then.
    prWatch { |when|
        looper.timeline.armAt(\roll, when, { |token|
            var ld = looper.loopDuration;
            if(looper.timeline.holds(\roll, token) and: { #[\armed, \landing].includes(state) } and: { ld > 0 }) {
                at = (at ? when) + ld;
                this.prWatch(at + 0.1);
            };
        });
    }

    prSay { |st, when|
        var changed = st != state;
        state = st;
        at = when;
        if(changed) { looper.changed(\rolling, state) };
    }

    // The next beat-group head after `now` + margin: (frame: loop frame,
    // len: the group's length in frames, at: when the playhead is there), or
    // nil with no reading.
    prNextHead { |now|
        var dur = looper.loopDuration, sr = looper.server.sampleRate ? 48000, g, pos, best;
        if(looper.lastResult.isNil or: { dur <= 0 } or: { looper.loopStartTime.isNil }) { ^nil };
        g = LooperGrains.groupGrid(looper.lastResult, dur);
        if(g[\count] == 0) { ^nil };
        pos = looper.timeline.positionAt(now, dur);
        g[\count].do { |i|
            var wait = (g[\heads][i] - pos - this.class.margin).mod(dur) + this.class.margin;
            if(best.isNil or: { wait < best[0] }) { best = [wait, i] };
        };
        ^(frame: (g[\heads][best[1]] * sr).round.asInteger, len: g[\lens][best[1]] * sr, at: now + best[0])
    }

    // Where the engine's window starts for grid frame f: the note nearest
    // within nearNote, else f. The drums': f less drumsEarly.
    prNoteAt { |f|
        var sr = looper.server.sampleRate ? 48000;
        ^looper.slicesPart.startNear(f, this.class.nearNote * sr) ? f
    }
    prDrumsAt { |f|
        var sr = looper.server.sampleRate ? 48000, n = looper.loopFrames.max(1);
        ^(f - (this.class.drumsEarly * sr)).round.asInteger.mod(n)
    }

    prUnitFrames {
        var units = MeterAnalyzer.unitsOf(looper.lastResult).max(1);
        ^looper.loopFrames / units
    }

    // To the engine; to the rollers (with drums on), `delta` seconds on (nil:
    // now). The engine's and the rollers' anchors differ, the rest is shared.
    prEngine { |args, delta|
        looper.prEngineMsg(*args) !? { |m| if(delta.isNil) { looper.server.sendMsg(*m) } { looper.server.sendBundle(delta, m) } };
    }
    prRollers { |args, delta|
        (rollers ? []).do { |r|
            if(delta.isNil) { looper.server.sendMsg(*r.setMsg(*args)) } { looper.server.sendBundle(delta, r.setMsg(*args)) };
        };
    }
    prSendAll { |args, delta|
        this.prEngine(args, delta);
        if(drums) { this.prRollers(args, delta) };
    }
}
