// The calibration wizard's model.
//
// Four numbers are set by ear per rig — overdub latency, Live sync, onset-note
// offset, onset threshold — plus chainRecOffsetMs, which has been measured since
// check-chain-align.scd existed. All of them measure THIS rig's paths, so a new
// interface, a new venue or an edited Live set invalidates them, and the moment
// you find that out is load-in.
//
// This class is the part of fixing that which can be reasoned about: the ordered
// steps, what each one needs in the room before it means anything, where the
// wizard currently is, and the arithmetic that turns two recordings into a
// number of milliseconds. It makes no sound and touches no server.
//
// The measuring itself is INJECTED — `register` hands a step the function that
// actually emits a burst and reads a buffer (scripts/calibrate-measure.scd), and
// the GUI (scripts/gui-calibrate.scd) only draws what is here. That split is
// what lets the whole wizard flow be driven by a test with stub functions, on a
// machine with no audio interface and no Ableton Live, which is most machines.
LooperCalibrator {
    var <looper;
    // Whether the rig has Live: its wizard is the seven steps below. Without
    // (SA, standalone) it is noLiveSteps, and what it finds is kept per rig
    // in your megalooper folder (keptPath, rig) instead of written down.
    var <live = true, <>keptPath, <>rig;
    var <stepIndex = 0;
    var <results;        // step key -> the Event a measurement returned
    var <status;         // step key -> \pending | \running | \done | \skipped | \failed
    var measurers;       // step key -> Function (looper, callback, this)
    var listenChannels;  // step key -> the input channel that step records

    *new { |looper, live = true|
        ^super.new.initCalibrator(looper, live)
    }

    initCalibrator { |aLooper, isLive = true|
        looper    = aLooper;
        live      = isLive != false;
        results        = IdentityDictionary.new;
        status         = IdentityDictionary.new;
        measurers      = IdentityDictionary.new;
        listenChannels = IdentityDictionary.new;
        this.reset;
        ^this
    }

    // ===================================================================
    // The steps
    // ===================================================================
    // Ordered, and the order is the point: nothing below the preflight means
    // anything if the device is not the one the profile describes, and the
    // write-down step is last because it reports what the others found.
    //
    // `needs` is what has to be true IN THE ROOM, which the wizard shows as a
    // checklist before the button. It is the difference between a step you can
    // run at home and one that needs the gig set open — see the Live column in
    // docs/dev/roadmap.md item 7.
    //
    // `field` is the Looper setter the measured value goes to, which is also the
    // profile key it is written back as. `manual` steps have no measurement:
    // they ask the player to do something and confirm.
    *steps {
        ^[
            (
                key: \preflight,
                title: "Check the rig",
                why: "Aggregate devices fail quietly — a member drops out, the "
                    "channel count changes, and a tap reads a bus nothing fills. "
                    "Everything below measures this rig's paths, so they have to "
                    "be the paths you think they are.",
                todo: [
                    "Nothing to do — this re-runs the device preflight and shows "
                    "what is actually connected."
                ],
                needs: [],
                field: nil,
                manual: false,
                optional: false
            ),
            (
                key: \threshold,
                title: "Onset threshold",
                why: "Meter detection sees onset times and nothing else. A "
                    "threshold that admits ghosts or misses real hits is the "
                    "documented reason a straight 4/4 take comes out 7/8.",
                todo: [
                    "Plug your instrument in. Ableton Live is not in this path at all.",
                    "Open the Analysis tab and play the way you are going to play.",
                    "Raise the threshold until the red marks fall only on real "
                    "hits; lower it until none of your hits are missing.",
                    "Come back here and press Done."
                ],
                needs: [\guitar],
                field: \onsetThreshold,
                manual: true,
                optional: false
            ),
            (
                key: \latency,
                title: "Overdub round trip",
                why: "How far back the buffer write head is shifted so an overdub "
                    "lands where you played it. The round trip it corrects has "
                    "Live's instrument chain inside it, so it cannot be measured "
                    "without Live running the set you will play.",
                todo: [
                    "STOP the loop. Its audio travels the same path as the burst "
                    "and would sit on top of it.",
                    "Close the path from Live's Main Out back round to whatever "
                    "feeds Live's instrument track. That stands in for 'you hear the "
                    "loop and play in response' — the only part of the round "
                    "trip with no delay of its own.",
                    "On a rig with real inputs: unplug your instrument and patch the "
                    "interface's main output into the instrument input. Mute the "
                    "instrument track's path to master first, or the cable is a "
                    "feedback loop.",
                    "On a laptop's built-in audio there is no jack to patch: the "
                    "instrument input is the built-in microphone, so the path closes "
                    "ACOUSTICALLY through the laptop's speakers, and the flight "
                    "time across a laptop is under a millisecond. Two catches. "
                    "The speakers are inches from that microphone, so with the "
                    "instrument track monitoring to Main this is a feedback loop; "
                    "break instrument-to-Main for the measurement while keeping "
                    "whatever carries the instrument to the looper's inChannel. And "
                    "a ringing loop fools the correlation, which takes the "
                    "strongest match and would happily pick a repeat over the "
                    "first arrival.",
                    "If that is a fight, SKIP this step there and dial the value "
                    "by ear: re-deriving it through an acoustic feedback loop is "
                    "poor value. The cable version on a rig with real inputs is "
                    "the one worth measuring.",
                    "Press Measure. It sends a short burst and times its return, "
                    "eight times. Plug your instrument back in afterwards."
                ],
                needs: [\live, \noLoop, \cable],
                field: \latencyMs,
                manual: false,
                optional: false
            ),
            (
                key: \sync,
                title: "Live's downbeat against the loop",
                why: "Slaved to MIDI clock Live lands 10-20 ms late. This shifts "
                    "when the clock is sent so Live's 1.1.1 falls on the music. "
                    "It needs something Live emits from ITS OWN transport, and "
                    "the metronome is exactly that — it follows Live's CUE OUT, "
                    "which is routable independently of Main Out. Give Cue Out a "
                    "loopback pair nothing else uses and the click arrives on its "
                    "own, with no loop return mixed into it.",
                todo: [
                    "Plug your instrument back in and record a loop, so Live is following "
                    "our clock.",
                    "In Live, set Cue Out (in the Main track's I/O, under Main "
                    "Out) to a loopback pair SC can read and nothing else uses — "
                    "5/6 on the \\bh* rigs, which is SC channel 4. Those pairs "
                    "are free precisely for this.",
                    "Turn the metronome on. Make sure nothing is cued or "
                    "previewing in the browser: Cue Out carries those too.",
                    "Put that SC channel in the box below — Scan finds it if you "
                    "are not sure — then press Measure."
                ],
                needs: [\live, \loop, \cueOut],
                liveOnly: true,
                field: \abletonSyncMs,
                listens: true,
                manual: false,
                optional: false
            ),
            (
                key: \noteOffset,
                title: "Drum hits against the loop",
                why: "The loop's audio crosses the virtual device and Live's "
                    "input buffer; its onset notes go straight over IAC and are "
                    "quantised to Live's next block. The remainder is a fixed "
                    "offset this rig owns. Measure it separately from Live sync "
                    "— the two shift different streams and do not track.",
                todo: [
                    "Turn Onset notes on in the Analysis tab, with a loop playing.",
                    "Set the drum rack track's Audio To = Ext. Out to a free "
                    "loopback pair — 7/8 on the \\bh* rigs, which is SC channel "
                    "6. A pair of its own means nothing else has to be muted.",
                    "If you send it to the return pair (13/14) instead, mute the "
                    "loop-return track first: our own loop comes back on that "
                    "pair and this would measure it instead of the drums.",
                    "Put the channel in the box below, then press Measure. The "
                    "looper already knows exactly where it sent every hit, so "
                    "this compares the recording against a known pattern rather "
                    "than against another recording."
                ],
                needs: [\live, \loop, \drumrack],
                liveOnly: true,
                field: \onsetNoteOffsetMs,
                listens: true,
                manual: false,
                optional: false
            ),
            (
                key: \chain,
                title: "Loop-chain alignment",
                why: "Where the chain recorder starts, so a chained loop is not "
                    "rotated inside its own buffer. Only matters if you chain "
                    "loops; skip it if you do not.",
                todo: [
                    "Record a loop, then chain another over it (Program Change 6, or Rec "
                    "next loop on the Perform tab).",
                    "Press Measure BEFORE overdubbing — an overdub takes its own "
                    "undo snapshot and overwrites the one this reads."
                ],
                needs: [\live, \loop],
                liveOnly: true,
                field: \chainRecOffsetMs,
                manual: false,
                optional: true
            ),
            (
                key: \writeback,
                title: "Write it down",
                why: "Everything measured is applied to the running session and "
                    "nothing more. The profile in scripts/setup-routing.scd is "
                    "still carrying the old numbers, so the next boot starts from "
                    "those unless you paste this in.",
                todo: [
                    "Copy the line below into ~routingProfiles in "
                    "scripts/setup-routing.scd.",
                    "Run `sclang scripts/check.scd` — it resolves every profile "
                    "and catches the channel and range mistakes that are "
                    "otherwise silent until you are on stage."
                ],
                needs: [],
                field: nil,
                manual: true,
                optional: false
            )
        ]
    }

    *stepKeys { ^this.steps.collect { |s| s[\key] } }

    *stepAt { |key| ^this.steps.detect { |s| s[\key] == key } }

    // The wizard of a rig with Live (steps), or of one without (SA,
    // standalone): four steps, none of which measures Live, and no write-down
    // step, as what they find is kept for the rig (keep).
    *stepsFor { |live = true| ^if(live != false) { this.steps } { this.noLiveSteps } }

    *noLiveSteps {
        ^[
            (
                key: \preflight,
                title: "Check the rig",
                why: "Everything below measures this rig's paths: the interface "
                    "megalooper plays through, its rate and block size, and what the "
                    "effect chains can host. This shows what it found.",
                todo: [
                    "Nothing to do: this runs the start's checks again and shows "
                    "what is connected."
                ],
                needs: [],
                field: nil,
                manual: false,
                optional: false
            ),
            (
                key: \level,
                title: "Input level",
                why: "Meter detection listens to the dry instrument. Too quiet, and soft "
                    "notes never rise above the onset threshold; clipped, and every "
                    "hit looks the same. The level is set on the interface's input "
                    "gain (or the computer's input level), not in megalooper.",
                todo: [
                    "Plug your instrument in, its volume where you play it.",
                    "Press Measure and play hard for eight seconds: the loudest you "
                    "will play.",
                    "It says how loud the loudest hit came in. Aim for -12 to -3 dBFS: "
                    "turn the input gain, and measure again."
                ],
                needs: [\guitar],
                field: nil,
                manual: false,
                optional: false
            ),
            (
                key: \threshold,
                title: "Onset threshold",
                why: "Meter detection sees onset times and nothing else. A "
                    "threshold that admits ghosts or misses real hits is the "
                    "documented reason a straight 4/4 take comes out 7/8.",
                todo: [
                    "Plug your instrument in.",
                    "On the Setup view, under Analysis, play the way you are going "
                    "to play.",
                    "Raise the threshold until the red marks fall only on real "
                    "hits; lower it until none of your hits are missing.",
                    "Come back here and press Done: the threshold is kept for this rig."
                ],
                needs: [\guitar],
                field: \onsetThreshold,
                manual: true,
                optional: false
            ),
            (
                key: \latency,
                title: "Overdub round trip",
                why: "How far back an overdub is written, so it lands where you "
                    "played it. The round trip is everything between the loop "
                    "leaving megalooper and your instrument coming back into it: the "
                    "interface both ways, and the instrument chain's effects and plugin. "
                    "Measure it with the chain as you will play it.",
                todo: [
                    "Stop the loop: its sound travels the same path as the "
                    "measurement's click.",
                    "With an interface, patch a cable from output 1 into the instrument "
                    "input. The instrument's strip is muted while it measures, so the "
                    "cable is no feedback loop.",
                    "On a computer's own speakers and microphone there is nothing to "
                    "patch: turn the volume up, keep the room quiet, keep the "
                    "microphone free.",
                    "Press Measure. It sends a short click eight times and times its "
                    "return. Press Apply: the number is used and kept for this rig.",
                    "If it cannot be measured, set it by ear: Overdub latency on the "
                    "Setup view, until overdubs land where you played them. Then "
                    "press Start with this here."
                ],
                needs: [\noLoop, \cable],
                field: \latencyMs,
                manual: false,
                optional: false
            )
        ]
    }

    // ---- Kept per rig --------------------------------------------------------------
    // A rig without Live keeps what its calibration found in your megalooper
    // folder, and every start begins with it (applyKept, from
    // setup-model.scd), so nothing has to be pasted into a profile:
    //
    //   {"format": "megalooper calibration", "version": 1,
    //    "rigs": {"saSystem": {"latencyMs": 31.2, "onsetThreshold": 0.42,
    //                          "savedAt": "261014_101500"}}}
    *keptFormat { ^"megalooper calibration" }

    *keptPathIn { |root| ^root +/+ "calibration.json" }

    *keptFields { ^[\onsetThreshold, \latencyMs, \abletonSyncMs, \onsetNoteOffsetMs, \chainRecOffsetMs] }

    // Every rig's kept numbers: rig -> (field: value, ..., savedAt:). Empty with
    // no file, or one that does not read (prReadKept says why).
    *readKept { |path| var all = this.prReadKept(path); ^if(all.isString) { IdentityDictionary.new } { all } }

    // The rigs as read, or a String: why the file there is not one to write
    // over (it does not read, or a newer megalooper wrote it).
    *prReadKept { |path|
        var text = MegaFiles.readText(path), object, version, rigs, out = IdentityDictionary.new;
        if(text.isNil) { ^out };
        object = MegaFiles.parseObject(text);
        if(object.isString) { ^object };
        version = MegaFiles.versionOf(object, this.keptFormat, 1, "megalooper calibration");
        if(version.isString) { ^version };
        rigs = object.at("rigs");
        if(rigs.isKindOf(MegaJsonObject).not) { ^out };
        rigs.keys.do { |name, i|
            var r = rigs.values[i], e = IdentityDictionary.new;
            if(r.isKindOf(MegaJsonObject)) {
                r.keys.do { |k, j|
                    var v = r.values[j];
                    case
                    { this.keptFields.includes(k.asSymbol) and: { v.isNumber } } { e.put(k.asSymbol, v) }
                    { (k == "savedAt") and: { v.isString } } { e.put(\savedAt, v) };
                };
                if(e.notEmpty) { out.put(name.asSymbol, e) };
            };
        };
        ^out
    }

    *keptText { |all|
        ^"{\"format\": " ++ MegaFiles.jsonString(this.keptFormat) ++ ", \"version\": 1,\n \"rigs\": {"
            ++ all.keys.asArray.sort.collect { |name| "\n  " ++ MegaFiles.jsonString(name.asString) ++ ": " ++ MegaFiles.json(all[name]) }
                .join(",") ++ "}}\n"
    }

    // One value kept for a rig, the file written whole: nil when it is
    // written, else why not. A file that does not read is not written over.
    *keep { |path, rig, field, value|
        var all;
        if(path.isNil or: { rig.isNil }) { ^"there is no rig to keep it for" };
        if(this.keptFields.includes(field).not or: { value.isNumber.not }) { ^"there is nothing to keep" };
        all = this.prReadKept(path);
        if(all.isString) { ^"the file there " ++ all };
        all.put(rig.asSymbol, (all[rig.asSymbol] ?? { IdentityDictionary.new }).put(field, value).put(\savedAt, Date.getDate.stamp));
        ^MegaFiles.writeNow(path, this.keptText(all), { |text| var o = MegaFiles.parseObject(text); if(o.isString) { o } })
    }

    // A rig's kept numbers forgotten: nil when done, else why not.
    *forget { |path, rig|
        var all = this.prReadKept(path);
        if(all.isString) { ^"the file there " ++ all };
        if(all.includesKey(rig.asSymbol).not) { ^nil };
        all.removeAt(rig.asSymbol);
        ^MegaFiles.writeNow(path, this.keptText(all))
    }

    // A rig's kept numbers onto a looper: answers them, or nil with none.
    *applyKept { |looper, path, rig|
        var e = rig !? { this.readKept(path)[rig.asSymbol] };
        if(looper.isNil or: { e.isNil }) { ^nil };
        this.keptFields.do { |f| e[f] !? { |v| looper.perform((f ++ "_").asSymbol, v) } };
        ^e
    }

    // At a start: a rig without Live (its profile says live: false) gets what
    // it keeps in `root`'s calibration.json. Answers the line saying so, or
    // nil when nothing was applied.
    *applyKeptAtStart { |looper, rp, rig, root|
        var e;
        if(rp.isNil or: { rp[\live] != false } or: { root.isNil }) { ^nil };
        e = this.applyKept(looper, this.keptPathIn(root), rig);
        ^e !? {
            "megalooper: this rig's calibration, as kept" ++ (e[\savedAt] !? { |t| " on " ++ t } ? "") ++ ": "
                ++ this.keptFields.select { |f| e[f].notNil }.collect { |f| f ++ " " ++ e[f].round(0.01) }.join(", ") ++ "."
        }
    }

    // What an input's level says, from a mono recording of the loudest
    // playing: its peak in dBFS, and how that stands. Under -50 dBFS nothing
    // came in; a sample at full scale clips; under -20 the soft notes are lost
    // under the onset threshold; else it is right.
    *levelOf { |raw|
        var peak = 0, clipped = 0, db;
        (raw ? []).do { |v| var a = v.abs; if(a > peak) { peak = a }; if(a >= 0.989) { clipped = clipped + 1 } };
        db = peak.max(1e-6).ampdb.round(0.1);
        ^case
        { db < -50 } { (ok: false, peakDb: db, verdict: \silent,
            why: "nothing came in (peak " ++ db ++ " dBFS): is your instrument plugged in, its volume up, and is it the input this rig reads?") }
        { clipped > 0 } { (ok: false, peakDb: db, verdict: \clipped,
            why: "it clips: " ++ clipped ++ " samples at full scale. Turn the input gain down until the loudest hit stays under -3 dBFS, and measure again.") }
        { db < -20 } { (ok: false, peakDb: db, verdict: \quiet,
            why: "too quiet: the loudest hit came in at " ++ db ++ " dBFS. Turn the input gain up until it reaches -12 to -3 dBFS, and measure again.") }
        { (ok: true, peakDb: db, verdict: \good, notes: ["The loudest hit came in at " ++ db ++ " dBFS: good."]) }
    }

    // What each `needs` token means in the room, for the checklist the wizard
    // draws above the button.
    // The two listening steps both say "give it a pair of its own", and they say
    // it because SC hears Live only on the loopback pairs and only what Live
    // routes there. The BlackHole channels the rigs leave unused (1-8, 15-16)
    // exist for exactly this: a measurement on its own pair needs nothing muted
    // and cannot be confused by our own loop coming back.
    *needLabels {
        ^(
            guitar:      "your instrument plugged in",
            cable:       "Live's Main Out fed back to whatever feeds the instrument "
                         "track — a cable on a rig with real inputs",
            noLoop:      "the looper stopped, so its own audio is not on the "
                         "path being measured",
            live:        "Ableton Live running the set you will play",
            loop:        "a loop recorded and playing",
            drumrack:    "a drum rack armed on the onset-note channel",
            cueOut:      "Live's Cue Out on a free loopback pair, metronome on, "
                         "nothing else cued",
            quietReturn: "the loop-return track muted, so that pair carries only "
                         "what is being measured",
            return:      "the source routed to the looper's return channel"
        )
    }

    *needLabel { |key, live = true|
        // With no Live (SA), the latency step's cable runs from the interface's
        // output back to the guitar's input.
        if((key == \cable) and: { live.not }) {
            ^"a cable from an output into the instrument input, or, on a computer's own speakers and microphone, nothing to patch"
        };
        ^(this.needLabels[key] ? key.asString)
    }

    // What a step needs on a rig with Live or without (SA, which says
    // live: false). The latency step measures the whole path whichever it
    // is, so without Live it needs no Live; a step that measures Live
    // itself (liveOnly) keeps saying so.
    *needsFor { |step, live = true|
        var needs = step !? { |s| s[\needs] } ? [];
        ^if(live or: { step[\liveOnly] == true }) { needs } { needs.reject { |n| n == \live } }
    }

    // Whether a step can be measured on such a rig: the ones that measure
    // Live (its sync, its drum rack, its processed return) cannot without it.
    *runsOn { |step, live = true| ^live or: { (step !? { |s| s[\liveOnly] }) != true } }

    // ===================================================================
    // Where the wizard is
    // ===================================================================
    steps { ^LooperCalibrator.stepsFor(live) }

    stepCount { ^this.steps.size }

    current { ^this.steps[stepIndex] }

    stepAt { |key| ^this.steps.detect { |s| s[\key] == key } }

    currentKey { ^this.current !? { |s| s[\key] } }

    statusOf { |key| ^(status[key] ? \pending) }

    // Which input a listening step records. It is per step because the two of
    // them want DIFFERENT pairs: Live's metronome arrives whereever Cue Out is
    // pointed, the drum rack wherever its track is routed, and giving each a
    // free loopback pair is what keeps our own loop return out of both.
    //
    // Unset means the looper's return channel, which is the only pair a rig is
    // guaranteed to already have SC listening on.
    listenChannel { |key|
        ^listenChannels[key ? this.currentKey]
            ?? { looper !? { |l| l.returnChannel } }
    }

    setListenChannel { |key, chan|
        var k = key ? this.currentKey;
        if(k.isNil or: { chan.isNil }) { ^this };
        listenChannels[k] = chan.asInteger.max(0);
        this.changed(\listen, k);
        ^this
    }

    listens { |key| ^((key !? { |k| this.stepAt(k) } ? this.current)
        !? { |s| s[\listens] == true } ? false) }

    resultOf { |key| ^results[key] }

    reset {
        stepIndex = 0;
        results.clear;
        status.clear;
        this.steps.do { |s| status[s[\key]] = \pending };
        this.changed(\reset);
        ^this
    }

    // Clamped rather than wrapped: a wizard that walks off its own end and
    // starts again is a wizard nobody trusts.
    goTo { |i|
        stepIndex = i.asInteger.clip(0, this.stepCount - 1);
        this.changed(\step, stepIndex);
        ^this
    }

    advance { ^this.goTo(stepIndex + 1) }
    back    { ^this.goTo(stepIndex - 1) }

    skip {
        var key = this.currentKey;
        key !? { status[key] = \skipped };
        this.changed(\status, key);
        ^this.advance
    }

    // Every non-optional step answered one way or the other. Skipped counts:
    // the wizard's job is to make sure nothing was passed over by accident, not
    // to insist on numbers the rig cannot produce today.
    isComplete {
        ^this.steps.every { |s|
            (s[\optional] == true) or: {
                #[\done, \skipped].includes(this.statusOf(s[\key]))
            }
        }
    }

    // ===================================================================
    // Running a step
    // ===================================================================
    // A measurer is `{ |looper, callback| … }` and answers with the Event that
    // `summarise` builds. It is injected rather than written here so that this
    // whole flow can be driven by a test with no server — see
    // scripts/tests/test-calibrator.scd.
    register { |key, fn|
        measurers[key] = fn;
        ^this
    }

    hasMeasurer { |key| ^measurers[key].notNil }

    // `action` is called with the result once it lands, which may be seconds
    // later: these read real buffers off a real server. The status goes to
    // \running first so the view can disable its own button, because a second
    // burst fired into the middle of the first one measures nothing.
    run { |action|
        var key = this.currentKey;
        var fn  = key !? { measurers[key] };
        if(key.isNil) { ^this };
        if(fn.isNil) {
            this.prFinish(key, (ok: false, why: "no measurement is wired to this step"),
                action);
            ^this
        };
        if(this.statusOf(key) == \running) {
            "LooperCalibrator: that step is already running.".warn;
            ^this
        };
        status[key] = \running;
        this.changed(\status, key);
        // A measurer that throws must not leave the wizard stuck on \running
        // with its button disabled and no way back.
        try {
            // The calibrator goes along so a measurer can read listenChannel.
            // sclang ignores arguments a function does not declare, so the stub
            // measurers in the tests are unaffected.
            fn.value(looper, { |res| this.prFinish(key, res, action) }, this);
        } { |err|
            this.prFinish(key,
                (ok: false, why: err.class.asString ++ ": " ++ (err.errorString ? "?")),
                action);
        };
        ^this
    }

    prFinish { |key, res, action|
        var r = res ? (ok: false, why: "the measurement answered nothing");
        results[key] = r;
        status[key]  = if(r[\ok] == true) { \done } { \failed };
        this.changed(\status, key);
        action !? { |fn| fn.value(r) };
        ^this
    }

    // A manual step has nothing to measure: it asks the player to do something
    // and then reads what they did straight off the looper.
    confirm {
        var key   = this.currentKey;
        var step  = this.current;
        var field = step !? { |s| s[\field] };
        var value = if(field.notNil and: { looper.notNil }) {
            looper.perform(field)
        } { nil };
        if(key.isNil) { ^this };
        results[key] = (ok: true, value: value, manual: true);
        status[key]  = \done;
        this.changed(\status, key);
        this.prKeep(field, value);
        ^this
    }

    // Write a measured value onto the running looper, so it can be heard before
    // it is believed. Separate from `run` on purpose: a measurement you can see
    // but have not applied is how you notice one that is obviously wrong.
    apply { |key|
        var k     = key ? this.currentKey;
        var step  = k !? { this.stepAt(k) };
        var field = step !? { |s| s[\field] };
        var res   = k !? { results[k] };
        var value = res !? { |r| r[\value] };
        if(field.isNil or: { value.isNil } or: { looper.isNil }) { ^this };
        looper.perform((field ++ '_').asSymbol, value);
        this.changed(\applied, k);
        this.prKeep(field, value);
        ^this
    }

    // ---- kept for the rig ----------------------------------------------------
    // Only a rig without Live keeps: its wizard has no write-down step.
    keeps { ^live.not and: { keptPath.notNil } and: { rig.notNil } }

    // What this rig keeps: (field: value, ..., savedAt:), or nil.
    kept { ^if(this.keeps) { LooperCalibrator.readKept(keptPath)[rig.asSymbol] } }

    prKeep { |field, value|
        var why;
        if(this.keeps.not or: { field.isNil } or: { value.isNil }) { ^this };
        why = LooperCalibrator.keep(keptPath, rig, field, value);
        if(why.notNil) { ("LooperCalibrator: " ++ field ++ " was not kept for " ++ rig ++ " (" ++ why ++ ").").warn };
        this.changed(\kept, field);
    }

    // Forget what this rig keeps: the next start begins with its profile's
    // numbers. Answers nil when done, else why not.
    forget {
        var why;
        if(this.keeps.not) { ^"this rig keeps nothing" };
        why = LooperCalibrator.forget(keptPath, rig);
        this.changed(\kept, nil);
        ^why
    }

    applyAll {
        this.steps.do { |s|
            if(this.statusOf(s[\key]) == \done) { this.apply(s[\key]) };
        };
        ^this
    }

    // ===================================================================
    // What to write down
    // ===================================================================
    // Every calibrated field, measured or not: the ones this run did not touch
    // are read off the looper, so the line is always complete and pasting it
    // can never silently drop a number somebody set last month.
    calibratedFields {
        ^if(live) { [\onsetThreshold, \latencyMs, \abletonSyncMs, \onsetNoteOffsetMs, \chainRecOffsetMs] }
            { [\onsetThreshold, \latencyMs] }
    }

    valueFor { |field|
        var step = this.steps.detect { |s| s[\field] == field };
        var res  = step !? { |s| results[s[\key]] };
        var measured = res !? { |r| if(r[\ok] == true) { r[\value] } { nil } };
        ^measured ?? { looper !? { |l| l.perform(field) } }
    }

    // Which of them this run actually established, for the view to mark.
    wasMeasured { |field|
        var step = this.steps.detect { |s| s[\field] == field };
        var res  = step !? { |s| results[s[\key]] };
        ^(res.notNil and: { res[\ok] == true })
    }

    profileLine {
        var parts = this.calibratedFields.collect { |f|
            var v = this.valueFor(f);
            f.asString ++ ": " ++ (v ? 0).round(0.01)
        };
        ^"    " ++ parts.join(", ") ++ ","
    }

    // ===================================================================
    // The arithmetic
    // ===================================================================
    // Pure, and kept here rather than in the measuring script so it can be
    // checked against signals whose answer is known. Everything works on peak
    // ENVELOPES rather than samples: alignment is an envelope property, it makes
    // the correlation affordable in the language, and check-chain-align.scd has
    // been measuring chainRecOffsetMs this way for long enough to trust it.

    // Peak envelope of an interleaved buffer read. `hop` is the bucket width in
    // FRAMES and `stride` subsamples inside a bucket, because a peak does not
    // need every sample to be found.
    //
    // Channels are summed as ABSOLUTE values. Summing them signed — which is
    // what the chain-align tool does — lets an out-of-phase stereo pair cancel
    // itself into a silence that never happened.
    *envelope { |raw, hop, stride = 1, chans = 2|
        var buckets = (raw.size / chans / hop).asInteger;
        ^Array.fill(buckets, { |k|
            var peak = 0;
            var base = k * hop * chans;
            (0, stride.max(1) .. hop - 1).do { |j|
                var i = base + (j * chans);
                var mag = 0;
                chans.do { |c| mag = mag + (raw[i + c] ? 0).abs };
                if(mag > peak) { peak = mag };
            };
            peak
        })
    }

    // The envelope a pattern of known hits WOULD make: one decaying blip per
    // hit. This is what makes the onset-note measurement the good one — the
    // looper knows exactly where it sent every note, so that side of the
    // correlation is exact and only the recording carries noise.
    *impulseEnvelope { |times, dur, hopSecs, decaySecs = 0.05|
        var buckets = (dur / hopSecs).roundUp.asInteger.max(1);
        var tail    = (decaySecs / hopSecs).asInteger.max(1);
        var env     = Array.fill(buckets, 0);
        (times ? []).do { |t|
            var start = (t / hopSecs).floor.asInteger;
            (0..tail).do { |j|
                var i = start + j;
                var v = (1 - (j / tail)).max(0);
                if(i >= 0 and: { i < buckets } and: { v > env[i] }) { env[i] = v };
            };
        };
        ^env
    }

    // Mean-removed and unit-length, so the correlation score below is a
    // cosine in -1..1 and a weak one can be recognised as weak.
    *normalize { |a|
        var mean = a.sum / a.size.max(1);
        var centred = a.collect { |x| x - mean };
        var mag = (centred.collect { |x| x * x }.sum).sqrt;
        ^if(mag > 0) { centred.collect { |x| x / mag } } { centred }
    }

    // Best alignment of `b` against `a`, searched over +/- maxLag buckets.
    // A POSITIVE lag means b's content arrives LATER than a's — the same sign
    // convention check-chain-align.scd reports, so the two tools cannot
    // disagree about which way to move a number.
    *bestLag { |a, b, maxLag|
        var best = 0, bestScore = -2;
        (maxLag.neg .. maxLag).do { |d|
            var sum = 0;
            a.size.do { |i|
                var j = i - d;
                if((j >= 0) and: { j < a.size } and: { i < b.size }) {
                    sum = sum + (b[i] * a[j]);
                };
            };
            if(sum > bestScore) { bestScore = sum; best = d };
        };
        ^[best, bestScore]
    }

    // Peak over mean. A click once a bar is nearly all silence, so its crest is
    // in the hundreds; a guitar loop coming back from Live is continuous and
    // sits in the low tens. That is enough to tell "the pair is carrying the
    // click I asked for" from "the pair is carrying our own loop return", which
    // is the mistake the sync and note-offset steps are most likely to make —
    // and it is a mistake that produces a confident, completely wrong number.
    *crest { |env|
        var mean = env.sum / env.size.max(1);
        ^if(mean > 0) { env.maxItem / mean } { 0 }
    }

    // Seconds from the start of a recording to the loop's next downbeat.
    //
    // The phase channel carries the loop's read position in seconds, so its
    // FIRST sample says where the loop already was and the downbeat is whatever
    // is left of that pass. No wrap has to fall inside the window — which the
    // first version of this depended on, and which is why it failed on a rig
    // whenever the recording happened to start just after a boundary.
    *anchorFromPhase { |phase, loopDur|
        var at;
        if(loopDur.isNil or: { loopDur <= 0 }) { ^0 };
        at = (phase !? { |p| p[0] }) ? 0;
        ^(loopDur - at).clip(0, loopDur)
    }

    // Did the loop actually move while we were recording? A flat phase channel
    // means nothing was playing, or we read the wrong bus — either way there is
    // nothing to line audio up against.
    *phaseMoved { |phase|
        ^(phase.notNil and: { phase.size > 1 }
            and: { (phase.maxItem - phase.minItem) > 1e-6 })
    }

    *median { |a|
        var sorted = a.asArray.copy.sort;
        var n = sorted.size;
        if(n == 0) { ^nil };
        ^if(n.odd) { sorted[n div: 2] } {
            (sorted[(n div: 2) - 1] + sorted[n div: 2]) / 2
        }
    }

    // Turn a set of trials into one number plus the reasons not to believe it.
    //
    // The SPREAD is the diagnostic that matters and the reason trials are
    // repeated at all. One reading always produces a number; a wide spread
    // across eight of them is a sample-rate mismatch or a drift-correction
    // problem inside the aggregate, and it is far better to see that at load-in
    // than to infer it from crackling later.
    *summarise { |trials, msPerBucket, minQuality = 0.3, maxSpreadMs = 4|
        var lags, quals, ms, value, spread, weakest;
        if(trials.isNil or: { trials.isEmpty }) {
            ^(ok: false, why: "nothing came back from the measurement")
        };
        lags    = trials.collect { |t| t[0] };
        quals   = trials.collect { |t| t[1] };
        ms      = lags.collect { |d| d * msPerBucket };
        value   = LooperCalibrator.median(ms);
        spread  = ms.maxItem - ms.minItem;
        weakest = quals.minItem;
        if(weakest < minQuality) {
            ^(ok: false, value: value, spread: spread, quality: weakest,
                trials: ms,
                why: "the signal was too weak to trust (correlation "
                    ++ weakest.round(0.01) ++ ", want " ++ minQuality
                    ++ "). Check the routing for this step and the level.")
        };
        if(spread > maxSpreadMs) {
            ^(ok: false, value: value, spread: spread, quality: weakest,
                trials: ms,
                why: "the readings disagree by " ++ spread.round(0.1)
                    ++ " ms. That is a clock problem, not a latency — check the "
                    "aggregate's clock source, drift correction, and that every "
                    "member is at the same sample rate.")
        };
        ^(ok: true, value: value, spread: spread, quality: weakest, trials: ms)
    }
}
