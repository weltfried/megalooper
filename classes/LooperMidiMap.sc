// A MIDI map: which controller message drives which of megalooper's controls,
// and the rules for what each message does to them. This is the pure half of
// the MIDI router, with no ~ variables, no MIDI and no server, so the tests
// call it directly. scripts/setup-midimap.scd holds the other half: the
// controls themselves (the registry), the responders and the boot glue.
// docs/dev/midi-map.md is the design.
//
// A binding is an Event, with the fields a map file will have:
//   msg       \note, \cc, \program or \bend (required)
//   num       0-127; none for \bend (required otherwise)
//   chan      0-15, as MIDIdef reports it; missing is any channel
//   device, port  the input's two names (MIDIEndPoint); missing is any input
//   target    the control's id, a Symbol (required)
//   min, max  the range a knob covers, in the control's own units; missing is
//             the control's whole range, and min > max inverts it
//   inLo, inHi  the controller's own range; missing is 0-127 (0-16383 for bend)
//   hysteresis  steps a CC must turn back before it counts (*hysteresis); 0
//             is none; missing is the router's default (settings.json: one
//             step unless changed)
//   switch    what a CC on a switch is: \oneMessage, \pressRelease or \knob
//   mode      a toggle's: \press, \hold or \follow
//   takeover  what a knob does to a control it is not at (*takeover):
//             \none, \pickup or \scale; missing is the router's default
//             (none unless changed)
//   layer     true lets it share its message with another binding
LooperMidiMap {
    var <name, <bindings, <problems, table, <slots, <basedOn, <revision;

    *msgTypes { ^#[\note, \cc, \program, \bend] }
    *switchTypes { ^#[\oneMessage, \pressRelease, \knob] }
    *modes { ^#[\press, \hold, \follow] }
    *takeovers { ^#[\none, \pickup, \scale] }

    // The bindings, checked: one that can't be used is dropped, and said in
    // `problems`, as is a message bound twice (both stay). `basedOn` and
    // `revision` say which shipped map, at which revision, a map of one's own
    // started from (docs/dev/midi-map.md 8.3).
    *new { |bindings, name, basedOn, revision|
        ^super.new.init(bindings, name, basedOn, revision)
    }

    init { |inBindings, inName, inBasedOn, inRevision|
        var kept = List.new, byMessage = Dictionary.new, all = List.new;
        name = inName;
        basedOn = inBasedOn;
        revision = inRevision;
        problems = List.new;
        table = IdentityDictionary.new;
        (inBindings ? []).do { |b, i|
            var why = LooperMidiMap.bindingProblem(b);
            if(why.notNil) {
                problems.add("binding " ++ (i + 1) ++ " (" ++ LooperMidiMap.describe(b) ++ ") is left out: " ++ why);
            } {
                kept.add(b);
            };
        };
        bindings = kept.asArray;
        bindings.do { |b, i|
            var key = LooperMidiMap.key(b[\msg], b[\chan], b[\num]);
            var slot = (binding: b, index: i, states: IdentityDictionary.new);
            var message = LooperMidiMap.key(b[\msg], nil, b[\num]);
            table.put(key, (table[key] ? []).add(slot));
            all.add(slot);
            // Two bindings one message can reach both act. Said, unless one
            // of them says it is meant (layer).
            (byMessage[message] ? []).do { |other|
                if(LooperMidiMap.overlap(b, other) and: { (b[\layer] == true).not }
                    and: { (other[\layer] == true).not }) {
                    problems.add(LooperMidiMap.describe(b) ++ " is bound twice: to " ++ other[\target]
                        ++ " and to " ++ b[\target] ++ "; both act (set layer to say that is meant)");
                };
            };
            byMessage.put(message, (byMessage[message] ? []).add(b));
        };
        slots = all.asArray;
    }

    // What the router keeps of each knob, carried over from `from`, the map
    // in force before this one, so an edit doesn't make every knob start
    // again (a pick-up knob would let go of the control it holds). That
    // includes what was last sent back to its controller (states' \back,
    // setup-midimap.scd), so an edit sends nothing again. A binding
    // both maps have goes on from where it was, and so does one changed only
    // in how it acts (*sameKnob). Any other starts afresh, as does one `from`
    // doesn't have: what this map kept of it dates from before it was swapped
    // out, and the knob may have moved since. The router calls it on a map
    // it swaps in. Only the states change; the map is the same. Answers the
    // map.
    adopt { |from|
        var theirs, used = IdentitySet.new, rest = List.new;
        if(from.isNil or: { from === this }) { ^this };
        theirs = from.slots;
        slots.do { |slot|
            var o = theirs.detect { |x| used.includes(x).not and: { x[\binding] === slot[\binding] } };
            if(o.notNil) { used.add(o); slot[\states] = o[\states] } { rest.add(slot) };
        };
        rest.do { |slot|
            var o = theirs.detect { |x| used.includes(x).not and: { LooperMidiMap.sameKnob(x[\binding], slot[\binding]) } };
            if(o.notNil) { used.add(o); slot[\states] = o[\states] } {
                slot[\states] = IdentityDictionary.new;
                // Where its message came from, it still comes from: the
                // places it was sent back to are kept, with what they show
                // not known, so they are sent its new place (*placesOf).
                theirs.detect { |x| LooperMidiMap.sameMessage(x[\binding], slot[\binding]) and: { x[\states][\back].notNil } }
                    !? { |x| slot[\states].put(\back, LooperMidiMap.placesOf(x[\states][\back])) };
            };
        };
    }

    // Two bindings of one message from one input: the same type, number,
    // channel, device and port.
    *sameMessage { |a, b|
        ^#[\msg, \chan, \num, \device, \port].every { |k| a[k] == b[k] }
    }

    // The places a binding was sent back to (states' \back: input uid -> one
    // record per channel), with nothing known of what they show.
    *placesOf { |back|
        var out = IdentityDictionary.new;
        back.keysValuesDo { |src, byChan| out.put(src, byChan.collect { |r| r !? { () } }) };
        ^out
    }

    // Two bindings of the same message on the same control, over the same
    // ranges, as one switch or knob: they may differ only in its hysteresis,
    // takeover, mode or layer, which leave what the router keeps of it true
    // (a takeover changed starts its own part afresh: *takeover).
    *sameKnob { |a, b|
        ^#[\msg, \chan, \num, \device, \port, \target, \min, \max, \inLo, \inHi, \switch].every { |k| a[k] == b[k] }
    }

    // What the router keeps of every knob, forgotten: each starts afresh, as
    // at the first boot (after a Cmd-period, MIDI was dead). Answers the map.
    forgetStates {
        slots.do { |slot| slot[\states] = IdentityDictionary.new };
    }

    // What a binding kept of a knob on a control of `kind`, once the router
    // has missed some of its messages (a learning took them, its input wasn't
    // listened to, its control wasn't there): the knob may have moved
    // meanwhile. Its last position and a takeover's catch and place go. The
    // hysteresis's last value stays: a stale one holds back a step or two at
    // most, and without it a resting pedal's next flicker would take back a
    // control the mouse set. A knob on a toggle keeps its side for the same
    // reason. A knob on a trigger is disarmed: a press made unseen must not
    // fire later. A place it was sent (*sentBack) goes too: where it went
    // since isn't known.
    *forget { |state, kind|
        var s;
        if(state.isKindOf(Event)) {
            s = state.copy;
            [\k, \caught, \pos, \readBack, \sent, \sentFor].do { |x| s.removeAt(x) };
            ^s
        };
        ^if(kind == \trigger) { nil } { state }
    }

    // Can one message reach both bindings (of the same type and number)? It
    // can when their channels and their inputs overlap: the same, or either
    // one any.
    *overlap { |a, b|
        var same = { |k| a[k].isNil or: { b[k].isNil } or: { a[k] == b[k] } };
        ^same.(\chan) and: { same.(\device) } and: { same.(\port) }
    }

    // ---- finding a message's bindings -------------------------------------------

    // One integer per type, channel and number: the table's key. A nil channel
    // is "any channel"; bend has no number. nil for a type that is not one.
    *key { |msg, chan, num|
        var t = this.msgTypes.indexOf(msg);
        if(t.isNil) { ^nil };
        ^(((t * 17) + (chan ? 16)) * 128) + (num ? 0)
    }

    // The bindings a message reaches, as slots (binding:, index:, states:),
    // in the map's order: those on its channel and those on any channel. A
    // binding that names a device is still in; the router asks deviceMatches.
    // `msg` is the binding's type: \note for both note on and note off.
    lookup { |msg, chan, num|
        var exact, any = table[LooperMidiMap.key(msg, nil, num)];
        // No channel is any channel's bindings alone, not those twice.
        if(chan.isNil) { ^any ? #[] };
        exact = table[LooperMidiMap.key(msg, chan, num)];
        if(exact.isNil) { ^any ? #[] };
        if(any.isNil) { ^exact };
        ^(exact ++ any).sort { |a, b| a[\index] < b[\index] }
    }

    // Is a message from this input one the binding answers? `source` is the
    // input as [device, port] (its MIDIEndPoint's two names), nil if unknown.
    *deviceMatches { |binding, source|
        if(binding[\device].isNil) { ^true };
        if(source.isNil) { ^false };
        ^(source[0] == binding[\device]) and: { binding[\port].isNil or: { source[1] == binding[\port] } }
    }

    // ---- checking ------------------------------------------------------------------

    // Why a binding can't be used, or nil. Its target is not looked up here:
    // a binding to a control this build doesn't know is kept and does nothing.
    *bindingProblem { |b|
        var msg, isNum = { |x, lo, hi| x.isInteger and: { x.inclusivelyBetween(lo, hi) } };
        if(b.isKindOf(Dictionary).not) { ^"it is not a binding" };
        msg = b[\msg];
        if(this.msgTypes.includes(msg).not) { ^"its message type " ++ msg.asCompileString ++ " is not one of note, cc, program, bend" };
        if(msg == \bend) {
            if(b[\num].notNil) { ^"pitch bend has no number" };
        } {
            if(isNum.(b[\num], 0, 127).not) { ^"its number must be 0-127" };
        };
        if(b[\chan].notNil and: { isNum.(b[\chan], 0, 15).not }) { ^"its channel must be 0-15 (MIDI's 1-16)" };
        if(b[\target].isKindOf(Symbol).not) { ^"it names no control" };
        [\device, \port].do { |k|
            if(b[k].notNil and: { b[k].isString.not }) { ^"its " ++ k ++ " must be a name" };
        };
        if(b[\port].notNil and: { b[\device].isNil }) { ^"it names a port but no device" };
        [\min, \max].do { |k|
            if(b[k].notNil and: { b[k].isNumber.not or: { b[k].isNaN } or: { b[k].abs == inf } }) {
                ^"its " ++ k ++ " must be a number"
            };
        };
        if(b[\inLo].notNil or: { b[\inHi].notNil }) {
            if(isNum.(b[\inLo] ? 0, 0, this.top(msg)).not or: { isNum.(b[\inHi] ? this.top(msg), 0, this.top(msg)).not }) {
                ^"its input range must be within 0-" ++ this.top(msg)
            };
            if((b[\inLo] ? 0) == (b[\inHi] ? this.top(msg))) { ^"its input range is empty" };
        };
        if(b[\hysteresis].notNil and: { isNum.(b[\hysteresis], 0, 64).not }) { ^"its hysteresis must be 0-64 steps" };
        if(b[\switch].notNil and: { this.switchTypes.includes(b[\switch]).not }) { ^"its switch must be oneMessage, pressRelease or knob" };
        if(b[\mode].notNil and: { this.modes.includes(b[\mode]).not }) { ^"its mode must be press, hold or follow" };
        if(b[\takeover].notNil and: { this.takeovers.includes(b[\takeover]).not }) { ^"its takeover must be none, pickup or scale" };
        if(b[\layer].notNil and: { b[\layer] != true } and: { b[\layer] != false }) { ^"its layer must be true or false" };
        ^nil
    }

    // On rigs where the proxy sends Live every program change as a CC of the
    // same number, a binding on the program whose number is the break macro's
    // CC is one Live would not get as that CC (the proxy leaves it out, so the
    // macro is not flipped). The bindings it concerns, said.
    *proxyProblems { |bindings, breakMacroCc|
        ^(bindings ? []).select { |b| (b[\msg] == \program) and: { b[\num] == breakMacroCc } }
            .collect { |b| this.describe(b) ++ " reaches " ++ b[\target]
                ++ " but not Live: its CC " ++ breakMacroCc ++ " is the break's macro" }
    }

    // A binding in words, for the post window: "PC 8 (any channel)".
    *describe { |b|
        var msg, chan;
        if(b.isKindOf(Dictionary).not) { ^b.asCompileString };
        msg = b[\msg];
        chan = if(b[\chan].isNil) { "" } { " ch " ++ (b[\chan] + 1) };
        ^case
            { msg == \note } { "note " ++ b[\num] ++ chan }
            { msg == \cc } { "CC " ++ b[\num] ++ chan }
            { msg == \program } { "PC " ++ b[\num] ++ chan }
            { msg == \bend } { "pitch bend" ++ chan }
            { "a message " ++ msg.asCompileString }
    }

    // ---- editing ---------------------------------------------------------------------
    // A map is never changed in place: an edit answers a new map, which the
    // router swaps in with one assignment, so it never sees half an edit
    // (docs/dev/midi-map.md 5.2). The bindings themselves are shared, not copied.

    // The same map with `binding` added at the end.
    adding { |binding|
        ^LooperMidiMap(bindings ++ [binding], name, basedOn, revision)
    }

    // The same map without these bindings (by identity).
    removing { |gone|
        ^LooperMidiMap(bindings.reject { |b| gone.includes(b) }, name, basedOn, revision)
    }

    // The same map with `old` replaced by `new`, in its place.
    replacing { |old, new|
        ^LooperMidiMap(bindings.collect { |b| if(b === old) { new } { b } }, name, basedOn, revision)
    }

    // The same bindings under another name, or based on another shipped map.
    renamed { |newName, newBasedOn, newRevision|
        ^LooperMidiMap(bindings, newName, newBasedOn ? basedOn, newRevision ? revision)
    }

    // The bindings that drive a control.
    bindingsFor { |target|
        ^bindings.select { |b| b[\target] == target }
    }

    // The bindings a message meant for `binding` would also reach, driving
    // another control: what learning it would take over (docs/dev/midi-map.md 6.4).
    conflicts { |binding|
        ^bindings.select { |b|
            (b[\msg] == binding[\msg]) and: { b[\num] == binding[\num] }
                and: { b[\target] != binding[\target] } and: { LooperMidiMap.overlap(b, binding) }
        }
    }

    // ---- map files ---------------------------------------------------------------------
    // A map file is JSON, data only (docs/dev/midi-map.md 8.1): maps are meant to be
    // shared, and a file loaded at every boot should run nothing. parseJSON is
    // the YAML parser: it answers every number and boolean as a String, so
    // nothing is taken on trust. A field must look like what it is, or its
    // binding is left out and said; a field this build doesn't know is ignored.
    //
    //   {"format": "megalooper midi map", "version": 1, "name": "TSMega",
    //    "basedOn": "tsmega", "revision": 1,
    //    "bindings": [
    //     {"msg": "program", "num": 4, "device": "TSMEGA", "target": "looper.trigger"},
    //     {"msg": "cc", "num": 7, "device": "TSMEGA", "target": "looper.onsetThreshold", "hysteresis": 1}
    //    ]}

    *fileFormat { ^"megalooper midi map" }
    *fileVersion { ^1 }

    // The order a binding's fields are written in, one binding a line, so a
    // diff shows which binding changed.
    *fieldOrder { ^#[\msg, \chan, \num, \device, \port, \target, \min, \max, \inLo, \inHi,
        \hysteresis, \takeover, \switch, \mode, \layer] }

    // A map file's text, read: answers (name:, basedOn:, revision:, bindings:,
    // problems:), or a String saying why the whole file is refused: it is not
    // a map, it is from a newer megalooper (a version it doesn't know), or it
    // can't be read. A missing version is 1. Every format in megalooper has
    // that rule.
    *parse { |text|
        var d, version, list, problems = List.new, kept = List.new;
        if(text.isNil or: { text.isEmpty }) { ^"it is empty" };
        // parseJSON reads YAML too; a map is JSON.
        if(text.stripWhiteSpace.first != ${) { ^"it is not JSON" };
        d = try { text.parseJSON } { nil };
        if(d.isKindOf(Dictionary).not) { ^"it is not JSON" };
        if(d["format"] != this.fileFormat) { ^"it is not a megalooper MIDI map" };
        if(d.keys.size < d.size) { problems.add("a field is written twice; the last one counts") };
        version = d["version"];
        if(version.notNil) {
            version = this.prInt(version);
            if(version.isNil) { ^"its version can't be read" };
            if(version > this.fileVersion) {
                ^"it is from a newer megalooper (map version " ++ version ++ "; this one reads "
                    ++ this.fileVersion ++ ")"
            };
        };
        list = d["bindings"] ? [];
        if(list.isKindOf(Array).not) { ^"its bindings are not a list" };
        list.do { |x, i|
            var r = this.prBinding(x);
            if(r.isString) {
                problems.add("binding " ++ (i + 1) ++ " is left out: " ++ r);
            } {
                kept.add(r);
            };
        };
        ^(name: (d["name"] ? "").asString, basedOn: d["basedOn"] !? { |x| x.asString },
            revision: d["revision"] !? { |x| this.prInt(x) },
            bindings: kept.asArray, problems: problems.asArray)
    }

    // One binding from parseJSON's Dictionary: an Event, or why it can't be
    // used.
    *prBinding { |d|
        var b = (), why;
        if(d.isKindOf(Dictionary).not) { ^"it is not a binding" };
        [\msg, \target, \takeover, \switch, \mode].do { |k|
            d[k.asString] !? { |x| b.put(k, x.asString.asSymbol) };
        };
        [\device, \port].do { |k|
            d[k.asString] !? { |x| b.put(k, x.asString) };
        };
        [\chan, \num, \inLo, \inHi, \hysteresis].do { |k|
            d[k.asString] !? { |x|
                var n = this.prInt(x);
                if(n.isNil) { ^"its " ++ k ++ " must be a whole number" };
                b.put(k, n);
            };
        };
        [\min, \max].do { |k|
            d[k.asString] !? { |x|
                var n = this.prNumber(x);
                if(n.isNil) { ^"its " ++ k ++ " must be a number" };
                b.put(k, n);
            };
        };
        d["layer"] !? { |x|
            case
            { x.asString == "true" } { b.put(\layer, true) }
            { x.asString == "false" } { b.put(\layer, false) }
            { ^"its layer must be true or false" };
        };
        why = this.bindingProblem(b);
        if(why.notNil) { ^why };
        ^b
    }

    // A whole number as parseJSON hands it over ("7"), or nil.
    *prInt { |x|
        var s = x.asString;
        if("^-?[0-9]+$".matchRegexp(s).not) { ^nil };
        ^s.asInteger
    }

    // A number ("0.25", "-3", "1e-05"), or nil.
    *prNumber { |x|
        var s = x.asString;
        if("^-?[0-9]+(\\.[0-9]+)?([eE][-+]?[0-9]+)?$".matchRegexp(s).not) { ^nil };
        ^if("^-?[0-9]+$".matchRegexp(s)) { s.asInteger } { s.asFloat }
    }

    // The map as a file's text.
    fileString {
        ^LooperMidiMap.fileString(bindings, name, basedOn, revision)
    }

    *fileString { |bindings, name, basedOn, revision|
        var head = "{\"format\": " ++ this.jsonString(this.fileFormat) ++ ", \"version\": "
            ++ this.fileVersion ++ ",\n \"name\": " ++ this.jsonString(name ? "")
            ++ (basedOn !? { |x| ", \"basedOn\": " ++ this.jsonString(x) } ? "")
            ++ (revision !? { |x| ", \"revision\": " ++ x } ? "")
            ++ ",\n \"bindings\": [";
        var lines = (bindings ? []).collect { |b, i|
            "  " ++ this.bindingJson(b) ++ if(i < (bindings.size - 1)) { "," } { "" }
        };
        ^([head] ++ lines ++ [" ]}"]).join("\n") ++ "\n"
    }

    // One binding as a JSON object, its fields in fieldOrder.
    *bindingJson { |b|
        ^"{" ++ this.fieldOrder.select { |k| b[k].notNil }.collect { |k|
            var v = b[k], text;
            text = if(v.isKindOf(Boolean) or: { v.isNumber }) { v.asString } { this.jsonString(v.asString) };
            this.jsonString(k.asString) ++ ": " ++ text
        }.join(", ") ++ "}"
    }

    *jsonString { |s| ^MegaFiles.jsonString(s) }

    // ---- what a message does --------------------------------------------------------

    // The top of a message type's value range: 16383 for pitch bend, 127 else.
    *top { |msg| ^if(msg == \bend) { 16383 } { 127 } }

    // Where a value sits in the controller's range, 0..1. With the whole range
    // (no inLo, no inHi) it is exactly val / 127, which is what every CC binding
    // has always done.
    *position { |val, inLo, inHi, top = 127|
        if(inLo.isNil and: { inHi.isNil }) { ^val / top };
        ^((val - (inLo ? 0)) / ((inHi ? top) - (inLo ? 0))).clip(0, 1)
    }

    // A control's value at position c of the binding's range, along the
    // control's own law (fromPos, and toPos back): with no min and no max that
    // is fromPos(c) itself.
    *valueAt { |c, fromPos, toPos, min, max|
        var p0, p1;
        if(min.isNil and: { max.isNil }) { ^fromPos.value(c) };
        p0 = if(min.isNil) { 0 } { toPos.value(min) };
        p1 = if(max.isNil) { 1 } { toPos.value(max) };
        ^fromPos.value(p0 + (c * (p1 - p0)))
    }

    // Where a control's value sits in a binding's range, as the knob position
    // 0..1 that would set it: valueAt backwards. Beyond 0..1 when the value is
    // outside the binding's min and max.
    *knobAt { |value, toPos, min, max|
        var p0, p1, p = toPos.value(value);
        if(min.isNil and: { max.isNil }) { ^p };
        p0 = if(min.isNil) { 0 } { toPos.value(min) };
        p1 = if(max.isNil) { 1 } { toPos.value(max) };
        if(p1 == p0) { ^0.5 };
        ^(p - p0) / (p1 - p0)
    }

    // What a knob at position c (0..1 of the binding's range) does to a
    // control it may not be at (docs/dev/midi-map.md 5.4), by `mode`:
    //   \none    the control jumps to the knob, as it always did;
    //   \pickup  nothing happens until the knob gets to the control: until
    //            it is within a step and a half of it (`step`: one step of
    //            the binding's input range), or at the control's value as the
    //            control rounds it (`same`, for a count or a choice: the
    //            knob's whole band of the item), or crosses it between two
    //            messages (a fast turn skips over a value, and a test of
    //            nearness alone would miss it). A step and a half, as a
    //            controller sent the control's place (*backValue) is put
    //            within half a step of it, and its first step from there
    //            must take it, either way. Near an end, two steps on either
    //            side will do, as a pedal that stops short of 127 never gets
    //            there.
    //            Once caught it follows. If something else moves
    //            the control (the mouse, a preset), the control's value is no
    //            longer what was read back right after the last set, and the
    //            knob has to catch it again;
    //   \scale   the knob and the control meet at the ends: turning up moves
    //            the control up by the same share of the room left above it,
    //            turning down of the room below it. It goes on from where it
    //            put the control, unrounded, so a count or a choice moves as
    //            smoothly as a level. A knob's first message only says where
    //            it is, and so does its first once something else has moved
    //            the control: a pedal's flicker at its end can't then slam a
    //            control the mouse just set to that end.
    // `current` is where the control is, as a knob position (*knobAt), and
    // `value` its value, both read when the message arrived; with no current
    // (a control that can't be read) the control jumps. `s` is what this
    // binding keeps for the input and channel the message came from: the
    // knob's last position (\k), the takeover that kept the rest (\mode),
    // whether pick-up has caught the control (\caught), where scale put it
    // (\pos), and the value the router read back after the last set
    // (\readBack). A takeover changed (the Knobs row, the mapping's menu)
    // starts afresh: pick-up has to catch the control again, and scale's
    // first message only says where the knob is. Answers the position to set
    // the control to, or nil; s is brought up to date.
    *takeover { |mode, c, s, current, value, same, step|
        var k = s[\k], cur, moved, base;
        s[\k] = c;
        if((mode == \none) or: { mode.isNil } or: { current.isNil }) { s[\mode] = \none; ^c };
        if(s[\mode] != mode) {
            s[\mode] = mode;
            s[\caught] = nil;
            s[\pos] = nil;
            if(mode == \scale) { k = nil };
        };
        cur = current.clip(0, 1);
        // A hair over a step: a law's way there and back can leave one.
        step = (step ? (1 / 127)) + 1e-9;
        moved = s[\readBack].notNil and: { s[\readBack] != value };
        if(mode == \pickup) {
            if(moved) { s[\caught] = false };
            if((s[\caught] != true) and: {
                ((c - cur).abs <= (1.5 * step))
                    or: { same.notNil and: { same.value(c) == true } }
                    or: { k.notNil and: { (c - cur).sign != (k - cur).sign } }
                    or: { (cur >= (1 - (2 * step))) and: { c >= (1 - (2 * step)) } }
                    or: { (cur <= (2 * step)) and: { c <= (2 * step) } }
            }) {
                s[\caught] = true;
            };
            ^if(s[\caught] == true) { c }
        };
        if(k.isNil or: { moved }) {
            s[\pos] = nil;
            s[\readBack] = value;
            ^nil
        };
        if(c == k) { ^nil };
        base = s[\pos] ? cur;
        s[\pos] = (if(c > k) { base + ((1 - base) * (c - k) / (1 - k).max(1e-9)) }
            { base - (base * (k - c) / k.max(1e-9)) }).clip(0, 1);
        ^s[\pos]
    }

    // Which of n items position c picks: the range spread evenly over them.
    *choiceIndex { |c, n|
        ^(c * n).floor.asInteger.clip(0, n - 1)
    }

    // Does `value` move a control that a CC last moved to `last`, going in
    // `dir` (1 up, -1 down, 0 not known yet)? A move of more than `steps`
    // always does. A smaller one does only if it goes on the way the last one
    // went, so a value hopping back and forth by a step (a, b, a, b) moves
    // nothing, and turning round costs `steps` steps. The first value a CC
    // sends always moves (`last` is nil), and the direction is known after the
    // first move of more than `steps`. The same value again never moves.
    // `steps` 0 lets every change through.
    //
    // The TSMega's expression pedal is why: at rest it hops by one step on its
    // own, a few times a second and then not for seconds, and each hop set
    // whatever the pedal drives (docs/dev/midi-map.md, 3.2).
    //
    // Answers the move as [value, direction], to be passed back in as `last`
    // and `dir` with the next value, or nil when nothing moves.
    *hysteresis { |last, dir, value, steps = 1|
        var step;
        if(last.isNil) { ^[value, 0] };
        step = value - last;
        if(step == 0) { ^nil };
        if((step.abs > steps) or: { step.sign == dir }) { ^[value, step.sign] };
        ^nil
    }

    // What one message does to a binding's control, by the control's kind
    // (\trigger, \toggle, \continuous, \step or \choice): the table in 5.3 of
    // docs/dev/midi-map.md. `msg` is what arrived: \noteOn, \noteOff, \cc,
    // \program or \bend; `val` its velocity or value. `state` is what the last
    // message from the same input and channel left for this binding (nil at
    // first). `knob`, for a knob or a pedal on a level, a count or a choice:
    // the router's defaults for a binding that names none, (hysteresis:,
    // takeover:), and where the control is now, (current:, value:, same:),
    // for its takeover (*takeover); missing, there is no hysteresis and no
    // takeover.
    // Answers [action, state], the action nil or one of
    //   [\fire]            a trigger fires
    //   [\flip]            a toggle flips; a continuous or step control jumps
    //                      between the binding's two ends
    //   [\set, on]         a toggle goes on (true) or off (false)
    //   [\position, c]     a continuous, step or choice control goes to c, 0..1
    //   [\end, \min or \max]  a continuous or step control goes to one end
    //   [\next]            a choice goes to its next item
    *decide { |kind, binding, msg, val, state, knob|
        var high, sw;
        case
        { msg == \noteOn } { ^[this.prPress(kind, binding[\mode]), state] }
        { msg == \noteOff } {
            if((kind == \toggle) and: { binding[\mode] == \hold }) { ^[[\set, false], state] };
            ^[nil, state]
        }
        // A program change has no release, so a "hold" toggle flips on it.
        { msg == \program } { ^[this.prPress(kind, \press), state] }
        { msg == \bend } {
            if((kind == \trigger) or: { kind == \toggle }) { ^[nil, state] };
            ^this.prKnob(binding, val, 16383, state, knob, false)
        }
        { msg == \cc } {
            sw = binding[\switch] ? \knob;
            high = val >= 64;
            if(sw == \oneMessage) {
                // Every message is a press, as the TSMega's CC 80 and 81 send.
                if((kind == \toggle) and: { binding[\mode] == \follow }) { ^[[\set, high], state] };
                ^[this.prPress(kind, \press), state]
            };
            if(sw == \pressRelease) {
                case
                { kind == \trigger } { ^[if(high) { [\fire] }, state] }
                { kind == \toggle } {
                    if(binding[\mode] == \hold) { ^[[\set, high], state] };
                    ^[if(high) { [\flip] }, state]
                }
                { kind == \choice } { ^[if(high) { [\next] }, state] };
                ^[[\end, if(high) { \max } { \min }], state]
            };
            // A knob or pedal. On a switch it switches at 64 and up, and again
            // only once it is back at 56 or below, so resting near 64 can't
            // chatter. On a trigger its first message only says where it is:
            // the trigger is armed if that is 56 or below, so a pedal resting
            // anywhere from 57 up can't fire it by flickering. A toggle
            // follows the knob from its first message.
            case
            { kind == \trigger } {
                if(state.isNil) { ^[nil, val <= 56] };
                if(state and: { high }) { ^[[\fire], false] };
                ^[nil, state or: { val <= 56 }]
            }
            { kind == \toggle } {
                // Sent a place since (*sentBack): a message near it is from a
                // knob that took it, so on the place's side; one further off
                // is from where it was, on its old side.
                if(state.isKindOf(Event)) {
                    state = case
                        { state[\sent].isNil or: { (val - state[\sent]).abs > this.sentNear } } { state[\side] }
                        { state[\sent] >= 64 } { true }
                        { state[\sent] <= 56 } { false }
                        { state[\side] };
                };
                if(high and: { state != true }) { ^[[\set, true], true] };
                if((val <= 56) and: { state != false }) { ^[[\set, false], false] };
                ^[nil, state]
            };
            ^this.prKnob(binding, val, 127, state, knob, true)
        };
        ^[nil, state]
    }

    // A knob or a pedal on a level, a count or a choice: its hysteresis (a
    // CC's), its input range, its takeover. Its state is an Event: the last
    // value that moved (\last) and which way (\dir), the takeover's, and the
    // place it was sent, if it was (\sent, *sentBack).
    //
    // The first message after a send within *sentNear steps of the place sent
    // is the knob's first move from there: it took what it was sent. As if it
    // had been at the control all along, it moves it (the hysteresis passes
    // it), pick-up holds it, and scale goes on from the place sent. A message
    // further off is from a knob that didn't take it (a fader with no motor, a
    // pedal, a group not shown): the usual rules, so pick-up still holds it
    // off and a pedal's flicker is still left out.
    *prKnob { |binding, val, top, state, knob, cc|
        var s = if(state.isKindOf(Event)) { state.copy } { () };
        var steps = if(cc) { binding[\hysteresis] ?? { knob !? { |k| k[\hysteresis] } } ? 0 } { 0 };
        var range = ((binding[\inHi] ? top) - (binding[\inLo] ? 0)).abs.max(1);
        // Pick-up's step: one of the input range's, never finer than a CC's,
        // as a pitch bend sender may move in 128s.
        var step = (1 / range).max(1 / 127);
        var mode = binding[\takeover] ?? { knob !? { |k| k[\takeover] } } ? \none;
        var sent = s[\sent], sentFor = s[\sentFor], move, c, out;
        s.removeAt(\sent);
        s.removeAt(\sentFor);
        c = this.position(val, binding[\inLo], binding[\inHi], top);
        if(sent.notNil and: { (val - sent).abs <= ((this.sentNear * step) * range) }) {
            s[\last] = val;
            s[\dir] = (val - sent).sign;
            s[\mode] = mode;
            s[\k] = this.position(sent, binding[\inLo], binding[\inHi], top);
            // At the control if the control is where it was when the place
            // was sent; moved since (a drag going on, a preset), pick-up has
            // to catch it from the place sent.
            s[\caught] = knob.isNil or: { knob[\value] == sentFor };
            s[\pos] = nil;
            knob !? { |k| s[\readBack] = k[\value] };
        } {
            if(steps > 0) {
                move = this.hysteresis(s[\last], s[\dir] ? 0, val, steps);
                if(move.isNil) { ^[nil, s] };
                s[\last] = move[0];
                s[\dir] = move[1];
            };
        };
        out = this.takeover(mode, c, s, knob !? { |k| k[\current] }, knob !? { |k| k[\value] }, knob !? { |k| k[\same] }, step);
        ^[out !? { |p| [\position, p] }, s]
    }

    // How far, in steps, a knob's first message after a send may be from the
    // place sent and still be its first move from there (*prKnob).
    *sentNear { ^4 }

    // A press: a trigger fires, a toggle flips (or goes on, held), a
    // continuous or step control jumps between its ends, a choice moves on.
    *prPress { |kind, mode|
        ^case
            { kind == \trigger } { [\fire] }
            { kind == \toggle } { if(mode == \hold) { [\set, true] } { [\flip] } }
            { kind == \choice } { [\next] }
            { (kind == \continuous) or: { kind == \step } } { [\flip] }
            { nil }
    }

    // ---- sending back ------------------------------------------------------------
    // What a binding sends back to its controller (docs/dev/midi-map.md 5.7), by
    // its control's kind (\trigger, \toggle, \continuous, \step or \choice):
    //   \knob   a knob or a pedal on a level, a count or a choice, or a CC
    //           knob on a toggle: it is sent where it would put the control,
    //           once something else (the mouse, a preset) has moved the
    //           control, so its next turn goes on from there;
    //   \light  a toggle on a note or a CC switch: its light, on or off, sent
    //           until the controller shows it;
    //   nil     nothing to show: a trigger, a program change, pitch bend on a
    //           switch, a level or a choice on a switch.
    *backKind { |binding, kind|
        var msg = binding[\msg];
        var knob = (msg == \bend) or: { (msg == \cc) and: { (binding[\switch] ? \knob) == \knob } };
        ^case
            { kind == \toggle } {
                case
                { (msg == \cc) and: { knob } } { \knob }
                { (msg == \note) or: { msg == \cc } } { \light }
                { nil }
            }
            { [\continuous, \step, \choice].includes(kind) } { if(knob) { \knob } }
            { nil }
    }

    // The value a binding sends back for its control's `value` (*backKind): a
    // toggle's 127 on and 0 off; a knob's where it would set the control to
    // that value, in its input range (*knobAt, for a choice its item's
    // middle, as the router spreads the travel over the items without min or
    // max). nil when there is nothing to send: no value, or nothing to show.
    *backValue { |binding, kind, value, toPos|
        var c, top, lo, hi;
        if(value.isNil or: { this.backKind(binding, kind).isNil }) { ^nil };
        if(kind == \toggle) { ^case { value == true } { 127 } { value == false } { 0 } { nil } };
        if(value.isNumber.not) { ^nil };
        c = if(kind == \choice) { toPos.value(value) } { this.knobAt(value, toPos, binding[\min], binding[\max]) };
        if(c.isNumber.not or: { c.isNaN }) { ^nil };
        top = this.top(binding[\msg]);
        lo = binding[\inLo] ? 0;
        hi = binding[\inHi] ? top;
        ^(lo + (c.clip(0, 1) * (hi - lo))).round.asInteger.clip(0, top)
    }

    // What the router keeps of a knob it has just sent `wire` (*backValue),
    // from the input and channel sent to, its control at `value`: the place
    // sent, and the control's value it was sent for, noted (\sent,
    // \sentFor). Whether the knob took it, its next message says (*prKnob,
    // and for a CC knob on a toggle *decide); until then all it kept stays as
    // it was. Answers the state.
    *sentBack { |state, binding, kind, wire, value|
        var s;
        if(kind == \toggle) { ^(side: if(state.isKindOf(Event)) { state[\side] } { state }, sent: wire) };
        s = if(state.isKindOf(Event)) { state.copy } { () };
        s[\sent] = wire;
        s[\sentFor] = value;
        ^s
    }
}
