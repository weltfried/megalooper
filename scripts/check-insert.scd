// megalooper — why does Insert mode sound like Gate?
//
// Evaluate this file (or paste the block) in the RUNNING session, with a loop
// PLAYING and the cutter ON in Insert mode. It changes nothing: it reads model
// state and polls the duck bus.
//
//     ~insertReport.();        // one-shot state dump
//     ~insertWatch.(10);       // poll the duck bus for 10 s and report
//
// The chain that makes Insert differ from Gate has four links:
//
//   1. the mode reaches the model              -> bbcutMode == \insert
//   2. the engine is told                      -> gateMode 2 (0 pass, 1 mute)
//   3. the cut procedure emits SINGLE-cut blocks sometimes
//        -> `cuts.size > 1` is the ONLY signal for both the dry duck and the
//           cutter's own ampfunc, so a procedure (or a cutchance) that repeats
//           on every block IS Gate, faithfully rendered
//   4. LooperCutGate writes that to insertBus  -> the bus toggles 0/1
//
// Link 3 is the one that looks like a bug and usually is not. A repeat block is
// `repeats` times longer than the plain block it replaces, so cutchance 0.5
// with repeats 2 leaves the dry loop audible only about a THIRD of the time —
// which reads as "always ducked" long before the numbers say so. ~insertWatch
// measures the duty cycle instead of guessing at it.
(
// Reading the duck bus. Shared memory makes it free and synchronous; without it
// (a remote server, or supernova) fall back to an async get, which costs a
// round trip per reading and so polls slower.
~insertBusShm = {
    ~looper !? { |l| l.server.tryPerform(\hasShmInterface) == true } ? false
};
~insertBusRead = {
    var bus = ~looper !? { |l| l.instVarAt(\insertBus) };
    bus !? { |b|
        if(~insertBusShm.()) {
            b.getSynchronous
        } {
            // An async get has to wait for the reply, and only a Routine can.
            // From the top level (the one-shot report) there is nothing to
            // return, which is honest: say so rather than block the language.
            if(thisThread.isKindOf(Routine)) {
                var got = nil, cond = Condition.new;
                b.get({ |v| got = v; cond.unhang });
                cond.hang;
                got
            } {
                nil
            };
        };
    };
};

~insertReport = {
    var l = ~looper;
    var say = { |label, value| ("  " ++ label.asString.padRight(24) ++ value).postln };
    var problems = List.new;

    "".postln;
    "=== insert mode: where does it break? ===".postln;

    if(l.isNil) {
        "  ~looper is nil — nothing is running. Boot first.".postln;
    } {
        var bus     = l.instVarAt(\insertBus);
        var engine  = l.instVarAt(\engineSynth);
        var voices  = l.instVarAt(\bbcutVoices);
        var code    = l.bbcutGateCode;

        "-- 1. the mode --".postln;
        say.("bbcutMode",  l.bbcutMode);
        say.("cutter on",  l.bbcut);
        say.("state",      l.state);
        if(l.bbcutMode != \insert) {
            problems.add("Mode is " ++ l.bbcutMode ++ ", not \\insert. Nothing below "
                "applies — set Insert in the Perform tab first.");
        };
        if(l.bbcut.not) {
            problems.add("The cutter is OFF, so the engine is at gateMode 0 (dry "
                "passes) whatever the mode says.");
        };

        "-- 2. the engine --".postln;
        say.("gateMode code", code.asString
            ++ "   (0 = dry passes, 1 = dry muted, 2 = dry ducks on repeats)");
        say.("engine synth",  engine !? { |s| "node " ++ s.nodeID } ? "NONE — nothing is playing");
        say.("duck bus",      bus !? { |b| "control bus " ++ b.index } ? "NOT ALLOCATED");
        if(l.bbcut and: { code != 2 } and: { l.bbcutMode == \insert }) {
            problems.add("Mode is insert but the gate code is " ++ code
                ++ ". The engine was never told — toggle the cutter off and on.");
        };

        "-- 3. the cut procedure --".postln;
        // What the cutter is actually running, per voice, with the arc applied.
        // The arc scales the density parameter, so a heel-down pedal can turn
        // every block into a pass-through (no duck at all) and a toe-down one
        // into a repeat on every block (a permanent duck = Gate).
        (voices ? []).do { |v, i|
            if(v[\enabled]) {
                var key = l.bbcutProcSpecs[v[\proc]] !? { |sp| sp[\intensityKey] };
                say.("voice " ++ i ++ " proc", v[\proc].asString
                    ++ (if(l.bbcutProcSpecs[v[\proc]].isNil) { "   <- UNKNOWN: falls back to bbcut11" } { "" }));
                key !? {
                    say.("  " ++ key ++ " dialled", v[\params][key]);
                    say.("  " ++ key ++ " as played", l.voiceDensity(i).round(0.0001).asString
                        ++ "   (arc at " ++ l.intensity.round(0.01) ++ ")");
                    if(l.voiceDensity(i) >= 0.999) {
                        problems.add("voice " ++ i ++ ": " ++ key ++ " is at 1.0, so EVERY "
                            "block is a repeat and the dry loop is ducked the whole time. "
                            "That is Gate, correctly rendered. Lower it.");
                    };
                };
                say.("  repeats", (v[\params][\repeats] ? "n/a").asString);
            };
        };
        if((voices ? []).count { |v| v[\enabled] } == 0) {
            problems.add("No voice is enabled, so nothing writes the duck bus at all.");
        };

        "-- 4. the duck bus --".postln;
        say.("value now", ~insertBusRead.() ? "—");
        "  (a single reading proves nothing — run ~insertWatch.(10) and play)".postln;

        "".postln;
        if(problems.isEmpty) {
            "  No fault found in the state. Run ~insertWatch.(10) while playing.".postln;
        } {
            "PROBLEMS".postln;
            problems.do { |p, i| ("  " ++ (i + 1) ++ ". " ++ p).postln };
        };
    };
    "".postln;
};

// Poll the duck bus and report the DUTY CYCLE — what fraction of the time the
// dry loop is muted. That is the number that decides whether Insert sounds like
// Gate, and it is not the same as the fraction of blocks that repeat.
~insertWatch = { |seconds = 10|
    var l = ~looper;
    var bus = l !? { |lo| lo.instVarAt(\insertBus) };
    if(bus.isNil) {
        "  no duck bus — is the looper built?".postln;
    } {
        Routine {
            // 50 Hz is fast enough to catch the shortest block the procedure
            // can emit; shared memory makes each read free. Without it (a
            // remote or supernova server) fall back to a slower async poll.
            var hz = if(~insertBusShm.()) { 50 } { 20 };
            var n = (seconds * hz).asInteger;
            var ducked = 0, flips = 0, last = nil;
            ("watching the duck bus for " ++ seconds ++ " s — play now…").postln;
            n.do {
                var v = ~insertBusRead.() ? 0;
                if(v > 0.5) { ducked = ducked + 1 };
                if(last.notNil and: { (v > 0.5) != (last > 0.5) }) { flips = flips + 1 };
                last = v;
                hz.reciprocal.wait;
            };
            "".postln;
            ("  dry loop muted " ++ (ducked / n * 100).round(0.1) ++ "% of the time"
                ++ "   (" ++ flips ++ " transitions in " ++ seconds ++ " s)").postln;
            case
            { flips == 0 and: { ducked == n } } {
                ("  STUCK AT 1: the bus never went back to 0, so the dry loop is muted "
                    "for good.\n  That IS Gate. The last write was a repeat and nothing "
                    "cleared it — check that\n  a voice is enabled and that its procedure "
                    "still emits single-cut blocks.").postln;
            }
            { flips == 0 and: { ducked == 0 } } {
                ("  STUCK AT 0: the duck never fires, so Insert sounds like Mix, not "
                    "Gate.\n  LooperCutGate is not writing — check that the cutter is "
                    "actually running.").postln;
            }
            { ducked > (n * 0.8) } {
                ("  The duck works but covers " ++ (ducked / n * 100).round(0.1)
                    ++ "% of the time, which is why it reads as Gate.\n  A repeat block "
                    "is `repeats` times longer than the plain block it replaced, so\n  "
                    "cut chance 0.5 with repeats 2 already mutes the dry loop two thirds "
                    "of the\n  time. Lower Cut chance, or lower Repeats, or pull the arc "
                    "back.").postln;
            }
            { true } {
                ("  The duck is working: the dry loop is present "
                    ++ (100 - (ducked / n * 100)).round(0.1) ++ "% of the time.").postln;
            };
            "".postln;
        }.play(AppClock);
    };
};
)
