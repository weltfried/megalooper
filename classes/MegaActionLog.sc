// Every change a player makes to megalooper, and every one an AI app makes:
// what changed, when, to what, and whose it was. For the set's log
// (LooperSessionRecorder: `act` lines, and a part's whole settings as a
// `state` line once it has settled) and for the AI's context (`recentWithin`:
// what the players just did). Switched on and off on Setup's MIDI & AI page
// (setup-actions.scd, docs/manual.md "Every action"); off, nothing listens.
//
// It listens to the parts, not to the keys, clicks and MIDI that move them.
// Every part already says each of its changes by name to its views
// (Looper.changed(\granularMorph, 0.4), MegaSA.changed(\level, \loop, 0.8)),
// whoever made it, so one listener a part hears all of them. A part is an
// Event:
//
//   model   the object whose `changed` is heard (nil: only `note` is told)
//   skip    notifications that are no action (an onset lamp, a dissolve's
//           position) or the consequence of one already heard
//   logged  notifications another writer already puts in the set's log
//           (LooperSessionRecorder): kept for the AI's context, not written
//   bare    ones written without their arguments, too big to write at every
//           turn of a knob (the cutter's voices): the part's state says them
//   ids     for a notification whose arguments all name what changed and
//           whose value is not its last, how many name it (see prKey)
//   state   a function answering the part's settings as a whole, written
//           `settle` seconds after its last change, and as a set's first
//           lines (writeStates). A part's state is a Dictionary or a
//           MegaJsonObject whose members are what it holds (drums:, synth:
//           ...): a later state of the same member replaces an earlier one.
//
// THE LOAD. A knob sends up to 60 changes a second. Each costs a key and a
// store here; what is written is each control's newest value at most
// `interval` apart, every control together in one write and one flush, so a
// knob turned writes ten lines a second and a click writes one, at its own
// time. A part's state is built and written only once the part has been left
// alone for `settle` seconds, only while a set is being recorded, and a slice
// at a time (prWriteState). Measured headless on an M1 (2026-10-30), three
// controls turned at 60/s took 1.6 % of the language's time and left its
// clock's 99th percentile where it was.
MegaActionLog {
    classvar <>interval = 0.1, <>settle = 2.0, <>keep = 64;
    // How long a state is written for before the clock gets its turn (see
    // prWriteState), in seconds.
    classvar <>slice = 0.001;

    // `recorder` answers the LooperSessionRecorder to write to (or nil);
    // `by` answers whose a change is ("ai", or nil for the players'); `now`
    // and `sched` are SystemClock's unless a test gives its own, and `player`
    // plays the Routine that writes states (a test runs it to its end).
    var <parts, <>recorder, <>by, <>now, <>sched, <>player;
    var watchers, pending, flushing = false, settling, <recent, <on = false;

    *new { |parts, recorder, by, now, sched|
        ^super.new.init(parts, recorder, by, now, sched)
    }

    init { |p, rec, who, clockNow, scheduler|
        parts = p ? ();
        recorder = rec;
        by = who;
        now = clockNow ? { SystemClock.seconds };
        sched = scheduler ? { |delta, fn| SystemClock.sched(delta, fn) };
        player = { |r| r.play(SystemClock) };
        pending = Dictionary.new;
        settling = IdentityDictionary.new;
        recent = List.new;
        watchers = List.new;
    }

    // Listening from now on, to every part that has a model.
    start {
        if(on) { ^this };
        on = true;
        parts.keysValuesDo { |name, part|
            part[\model] !? { |m|
                var fn = { |obj, what ... args| this.note(name, what, *args) };
                m.addDependant(fn);
                watchers.add([m, fn]);
            };
        };
    }

    // Nothing listens any more; what waits is written first. A part's state
    // not yet settled is not written.
    stop {
        if(on.not) { ^this };
        this.prFlush;
        watchers.do { |w| w[0].removeDependant(w[1]) };
        watchers = List.new;
        settling = IdentityDictionary.new;
        on = false;
    }

    // One change: `part`'s `what`, with the arguments its notification
    // carried. A part's listener calls it; so does what is no model's (the
    // window's views, its preset bars).
    // (Every change of every part comes through here, inside the part's own
    // `changed`, so it is written with plain ifs, which the compiler inlines:
    // no closure is made, and no String, per change.)
    note { |part, what ... args|
        var spec, list, written = true;
        if(on.not) { ^this };
        spec = parts[part];
        if(spec.notNil) {
            list = spec[\skip];
            if(list.notNil and: { list.includes(what) }) { ^this };
            list = spec[\bare];
            if(list.notNil and: { list.includes(what) }) { args = [] };
            list = spec[\logged];
            if(list.notNil and: { list.includes(what) }) { written = false };
        };
        pending.put(this.prKey(part, what, args, spec), [now.value, part, what, args, by.value, written]);
        if(flushing.not) {
            flushing = true;
            sched.value(interval, { this.prFlush; nil });
        };
    }

    // What a change is the newest value of: the part, the notification, and
    // its arguments up to its value, as an Array (it hashes and compares by
    // what it holds). The value is the last argument when that is a number,
    // a switch or a collection; a name there (\steps, \main: WHICH pattern
    // changed) is part of the key, so two patterns changed at once are two
    // changes. A part's `ids` says how many arguments name it where that rule
    // would be wrong.
    prKey { |part, what, args, spec|
        var ids, n, last;
        if(spec.notNil) { ids = spec[\ids] };
        if(ids.notNil) { n = ids[what] };
        if(n.isNil) {
            if(args.isEmpty) { n = 0 } {
                last = args.last;
                n = if(last.isNumber or: { last.isKindOf(Boolean) }
                    or: { last.isKindOf(Collection) and: { last.isString.not } }) { args.size - 1 } { args.size };
            };
        };
        ^if(n == 0) { [part, what] } { [part, what] ++ args.keep(n) }
    }

    // What has waited, written: oldest first, in one write; kept for the
    // AI's context; the parts it changed due a state once they settle.
    prFlush {
        var list, rec, logging, written;
        flushing = false;
        if(pending.isEmpty) { ^this };
        list = pending.values.asArray.sort { |a, b| a[0] <= b[0] };
        pending = Dictionary.new;
        list.do { |e| recent.add(e) };
        while { recent.size > keep } { recent.removeAt(0) };
        rec = recorder.value;
        logging = rec.notNil and: { rec.logging };
        if(logging) {
            written = list.select { |e| e[5] };
            if(written.notEmpty) {
                rec.logEvents(written.collect { |e| [\act, this.prFields(e), e[0]] });
            };
            list.do { |e| this.prUnsettled(e[1]) };
        };
    }

    // An `act` line's fields, as key-value pairs in the log's sorted order:
    // its arguments if any, by: "ai" for an AI app's change (a player's says
    // nothing), part, what.
    prFields { |e|
        ^(if(e[3].notEmpty) { [\args, e[3]] } { [] }) ++ (e[4] !? { |b| [\by, b] } ? [])
            ++ [\part, e[1], \what, e[2]]
    }

    // `part` changed: its state is due `settle` seconds after its last change.
    prUnsettled { |part|
        var spec = parts[part];
        if(spec.isNil or: { spec[\state].isNil }) { ^this };
        if(settling[part].isNil) {
            settling.put(part, now.value);
            this.prSettleCheck(part, settle);
        } {
            settling.put(part, now.value);
        };
    }

    prSettleCheck { |part, delta|
        sched.value(delta, {
            var last = settling[part], left;
            if(on and: { last.notNil }) {
                left = (last + settle) - now.value;
                if(left > 0.001) { this.prSettleCheck(part, left) } {
                    settling.removeAt(part);
                    this.prWriteState(part);
                };
            };
            nil
        });
    }

    // A part's state, written a slice at a time. Its JSON is several KB (the
    // drums: both patterns and the note sequence), and on a laptop whose
    // language idles between clock ticks, writing it in one go took 8 to 10
    // ms: longer than a tick of the MIDI clock, and a footswitch pressed then
    // is read that much later. So it is written in a Routine that waits after
    // every `slice` of work and lets the clocks run, and the line goes to the
    // file whole at the end. What changes meanwhile is in the next state.
    prWriteState { |part|
        this.prStatesRoutine([part]);
    }

    // Every part's state, one after the other (a set has started: its first
    // lines say how everything was set).
    writeStates {
        this.prStatesRoutine(parts.keys.asArray.select { |k| parts[k][\state].notNil }.sort);
    }

    prStatesRoutine { |which|
        player.value(Routine {
            // (No try around the writing: a wait inside one would leave
            // Exception.inProtectedFunction set for everything that runs
            // meanwhile. A state is plain data, and stateOf caught its own.)
            var rec, st, stream, mark, pause;
            which.do { |part|
                rec = recorder.value;
                if(rec.notNil and: { rec.logging }) {
                    st = this.stateOf(part);
                    st !? {
                        stream = CollStream(String.new(8192));
                        mark = Main.elapsedTime;
                        pause = { if((Main.elapsedTime - mark) > slice) { this.prYield; mark = Main.elapsedTime } };
                        LooperSessionRecorder.jsonOn(stream, st, pause);
                        rec.logEvent(\state, [\part, part, \state, Ref(stream.contents)]);
                    };
                    this.prYield;
                };
            };
        });
    }

    // Lets whatever has come due run before this Routine goes on. Not
    // `0.wait`: that puts the Routine back at its own logical time, which
    // stands still while it works, so it stays ahead of a clock tick that
    // came due meanwhile and the tick waits for the whole state anyway. This
    // waits until now, as the clock counts it, and a little more.
    prYield { ((Main.elapsedTime - thisThread.seconds).max(0) + 0.0001).wait }

    // A part's settings as a whole, or nil (it has no state, or failed to
    // say it: the log does without).
    stateOf { |part|
        ^parts[part] !? { |p| p[\state] } !? { |f| try { f.value } { nil } }
    }

    // The changes of the last `seconds`, oldest first, each
    // [seconds ago, part, what, args, by]: what the players (and the AI)
    // just did, for the AI's context.
    recentWithin { |seconds = 60|
        var t = now.value;
        ^recent.select { |e| (t - e[0]) <= seconds }.collect { |e| [t - e[0], e[1], e[2], e[3], e[4]] }.asArray
    }
}
