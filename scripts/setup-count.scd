// megalooper — the loop's count: where the playhead is, what the count says
// at a moment (bar, beat, what is coming), and the count's lights on a
// controller. Moved out of the status band (gui-status.scd, which paints the
// count from these), because MIDI (the lights, setup-miditargets.scd's count
// family, setup-midimap.scd's clock) and the AI apps (the playhead,
// setup-remote.scd) read it too, and none of them should need the window to
// know where the loop is (docs/dev/architecture.md, 5, step 4).
//
// Still the window's: ~countAnchor, the last answer about the playhead that
// everything here predicts from, is set by the window's 20 Hz poll
// (gui-shell.scd). Without a window there is no anchor, and so no count.
//
// Loaded by boot.scd through parts.scd; defines only, runs nothing.
(
// When what the count shows is later than the engine plays it (0: the
// master's look-ahead and the output buffer come to about what the screen
// takes to show a repaint), and the poll's last answer: the phase, when it
// came, the length of loop it was of.
~countDelay = ~countDelay ? 0;
~countAnchor = nil;

// Where the playhead is at `now`, in seconds into the loop, from the poll's
// last answer; nil without one, or with one of a loop that has since changed
// length (a multiply, an undo, a new take: the next answer is 50 ms away).
// At half-time (Looper.speed 0.5) the playhead moves at half the wall's
// pace. A speed changes on a boundary, the engine's phase 0: an answer from
// before the change is not used across it, the playhead is counted from the
// boundary instead.
~countPosAt = { |now, delay|
    var l = ~looper, a = ~countAnchor, dur, shown, v, changed;
    dur = (l !? { |x| x.loopDuration }) ? 0;
    if(l.isNil or: { a.isNil } or: { dur <= 0 } or: { (a[\dur] - dur).abs > 1e-6 }) { nil } {
        shown = now - (delay ?? { ~countDelay ? 0 });
        v = (if(l.reverseFlag) { -1 } { 1 }) * l.speed;
        changed = l.speedChangedAt;
        if(changed.notNil and: { a[\at] < changed } and: { shown >= changed }) {
            (v * (shown - changed)).mod(dur)
        } {
            (a[\phase] + (v * (shown - a[\at]))).mod(dur)
        }
    }
};

// The count at `now` (Main.elapsedTime), shown `delay` behind the engine:
// (st:, brk:, why:, c:, near:, shown:, beatDur:). `c` is MeterDecision.beatCountAt's
// answer, nil when there is nothing to count (`why` says what); `near` the
// next event. Changes nothing: the window's count and the lights each ask.
~countAt = { |now, delay|
    var l = ~looper, out = (brk: false, why: ""), st, dur, r, pos;
    st = (l !? { |x| x.state }) ? \empty;
    out[\st] = st;
    out[\brk] = l.notNil and: { l.onBreak };
    dur = (l !? { |x| x.loopDuration }) ? 0;
    r = l !? { |x| x.countResult };
    out[\shown] = now - delay;
    pos = ~countPosAt.(now, delay);
    case
    { st == \recording } { out[\why] = "starts when\nthe loop closes" }
    { dur <= 0 } { out[\why] = "no loop" }
    { (st != \playing) and: { st != \overdubbing } } { out[\why] = "stopped" }
    { pos.isNil } { }
    { MeterDecision.beatCountAt(0, r, dur)[\group].isNil } { out[\why] = "no grid\non this take" }
    {
        // MeterDecision.beatCountAt counts in the loop's own time; at half-time a
        // wall second is half of one, and a beat lasts twice as long.
        out[\near] = l.upcoming(out[\shown]).select { |e| e[\at] > out[\shown] }.minItem { |e| e[\at] };
        out[\c] = MeterDecision.beatCountAt(pos, r, dur, out[\near] !? { |e| (e[\at] - out[\shown]) * l.speed }, l.reverseFlag);
        out[\c][\toEdge] = out[\c][\toEdge] / l.speed;
        out[\beatDur] = (r[\tau] * (r[\sub] ? 1)) / l.speed;
        out[\speed] = l.speed;
    };
    out
};

// The count on a controller's button lights (docs/dev/rc600-picks.md, Phase 2):
// the controls setup-miditargets.scd's count family makes, learned onto a
// button like any mapping, sent back to like a toggle's light (5.7 of
// docs/dev/midi-map.md), so a thru's echo is dropped and a press that lit or
// darkened the button has it put right. Nothing the button sends acts.
//   beatLight     flashes on each beat group's first beat, longer on a bar's
//   countInLight  lit through the last bar before an event the count counts in
//                 to; it goes out on the boundary
//   oddBarLight   lit through the bar before the odd one of uneven bars
// On SystemClock, not the send-back's 20 Hz tick, which would put the beat
// on its 50 ms grid: ~countLightStep sleeps to the next beat line (or the
// flash's end) and sends what changed then. The tick sends what this missed
// (a controller sent everything again, a press).
//
// ~countLightDelay is when the beat is heard after the engine plays it: the
// master's 20 ms look-ahead and a few ms of output buffer. A button lights
// at once, so the lights wait for it; the screen, which takes about as long
// to show a repaint, doesn't (~countDelay).
~countLights = (beatLight: false, countInLight: false, oddBarLight: false);
~countLightDelay = ~countLightDelay ? 0.025;
~countLightFlash = 0.1;
~countLightBarFlash = 0.25;
~countLightEdge = nil;
~countLightOff = nil;

// Is a light learned and sent back to? Then the clock works the lights out.
~countLightsBound = {
    ~midiBackList.notNil and: { ~midiBackSrcs.notNil } and: { ~midiBackSrcs.notEmpty }
        and: { ~midiBackList.().any { |e| e[\target][\kind] == \light } }
};

// What the lights show at `now`, and when to look again.
~countLightStep = { |now|
    var s, c, want, since, edge, wait, changed;
    if(~countLightsBound.().not) {
        ~countLights = (beatLight: false, countInLight: false, oddBarLight: false);
        0.25
    } {
        s = ~countAt.(now, ~countLightDelay);
        c = s[\c];
        if(c.isNil) {
            want = (beatLight: false, countInLight: false, oddBarLight: false);
            ~countLightOff = nil;
            wait = 0.1;
        } {
            // The beat line last crossed, and the flash it starts: on a
            // group's first beat, once, and only if the step is on time (a
            // late flash would say the beat was later than it was).
            since = s[\beatDur] - c[\toEdge];
            edge = now - since;
            if((c[\groupBeat] == 1) and: { since < 0.05 }
                and: { ~countLightEdge.isNil or: { (edge - ~countLightEdge).abs > 0.01 } }) {
                ~countLightEdge = edge;
                ~countLightOff = edge + if(c[\group] == 1) {
                    ~countLightBarFlash.min(c[\groups][0] * s[\beatDur] * 0.7) } { ~countLightFlash };
            };
            want = (beatLight: ~countLightOff.notNil and: { now < ~countLightOff },
                countInLight: c[\countdown].notNil, oddBarLight: c[\nextOdd]);
            wait = c[\toEdge] + 0.001;
            if(want[\beatLight]) { wait = wait.min((~countLightOff - now) + 0.001) };
            wait = wait.clip(0.002, 0.1);
        };
        changed = [\beatLight, \countInLight, \oddBarLight].select { |k| want[k] != ~countLights[k] };
        if(changed.notEmpty) {
            ~countLights = want;
            ~countLightSend.(~midiNow.(), changed);
        };
        wait
    }
};

// The lights that changed (`which`, as ~countLights names them), to each
// place each is sent back to, if it shows other than it should: the
// ~midiBackTick's light, at once. One whose place isn't known yet (a boot, a
// controller sent everything again) the tick sends.
~countLightSend = { |now, which|
    if(~midiMap.notNil and: { ~midiLearning.isNil }) {
        ~midiBackList.().do { |e|
            var t = e[\target], b = e[\slot][\binding], w, r, at;
            if((t[\kind] == \light) and: { e[\how] == \light }
                and: { which.includes(t[\id].asString.drop(6).asSymbol) }) {
                w = LooperMidiMap.backValue(b, \light, t[\get].value, nil);
                e[\addrs].do { |a|
                    if(w.notNil and: { ~midiBackOuts[a[2]] != \dead } and: { ~midiBackOwns.(e, a[4]) }) {
                        r = ~midiBackRecord.(e[\slot], a[0], a[1]);
                        if(r[\wire] != w) {
                            at = ~midiBackSend.(a[2], b, a[1], w, a[0], \light, now);
                            at !? { r[\wire] = w; r[\at] = at; ~midiBackOthers.(e, a, w) };
                        };
                    };
                };
            };
        };
    };
};

// The lights' clock: generation-guarded, so a new one stops the old; started
// with the send-back's (~midiBackClock), and cleared by Cmd-period with it.
~countLightClock = {
    var gen = (~countLightGen ? 0) + 1;
    ~countLightGen = gen;
    SystemClock.sched(0.5, {
        if(gen == ~countLightGen) {
            try { ~countLightStep.(Main.elapsedTime) } { |err|
                ("megalooper: the count's lights: " ++ err.errorString ++ ". Tried again in a second.").warn;
                1
            }
        }
    });
};
)
