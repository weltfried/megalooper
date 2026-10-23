// megalooper as a tool for an AI app (docs/dev/ai-tool.md): a request names
// an id, its body is a JSON file in <userRoot>/remote/, and the answer is
// another one there, written whole. tools/megalooper-mcp.py asks; it is the
// bridge between an AI app speaking MCP and this.
//
// Who may ask: a message from 127.0.0.1 carrying the token of this boot, as
// the handshake file (<userRoot>/remote.json, mode 600) holds it beside the
// port sclang got. sclang's port listens on every interface, so a message
// from anywhere else is dropped unanswered, as is one with a wrong token.
//
// Phase 0 reads only: \ping, \context (what is playing and how it is set)
// and \describe (what every setting means). Nothing here changes a pattern,
// a device or a setting.
//
// Everything a request reads comes from `source`, a function answering an
// Event (looper:, sa:, profile:), so a test hands it stubs; boot.scd hands it
// the running ~looper and ~megaSA.
MegaRemote {
    var <source, <token, <port, responder, onShutDown, <started = false;

    *new { |source| ^super.newCopyArgs(source) }

    *formatName { ^"megalooper remote" }
    *version { ^1 }
    *oscPath { ^'/megalooper/remote' }
    *dir { ^MegaFiles.userRoot +/+ "remote" }
    *handshakePath { ^MegaFiles.userRoot +/+ "remote.json" }
    *requestPath { |id| ^this.dir +/+ id ++ ".request.json" }
    *replyPath { |id| ^this.dir +/+ id ++ ".reply.json" }

    // ---- starting and stopping ---------------------------------------------

    // Listens on `langPort` (sclang's own unless a test names another), with a
    // new token, and says so in the handshake file. Requests and replies left
    // from an earlier run are cleared: nobody waits for them any more.
    start { |langPort|
        var why;
        this.stop;
        port = langPort ? NetAddr.langPort;
        token = this.class.newToken;
        File.mkdir(this.class.dir);
        (this.class.dir +/+ "*.json").pathMatch.do { |p| File.delete(p) };
        responder = OSCdef(\megalooperRemote, { |msg, time, addr| this.receive(msg, addr) },
            this.class.oscPath).permanent_(true);
        why = MegaFiles.writeNow(this.class.handshakePath, this.handshakeText);
        if(why.notNil) {
            ("MegaRemote: the handshake was not written to " ++ this.class.handshakePath
                ++ " (" ++ why ++ "); no AI app can reach megalooper.").warn;
        } {
            ("chmod 600 " ++ this.class.handshakePath.shellQuote).systemCmd;
        };
        onShutDown = { this.stop };
        ShutDown.add(onShutDown);
        started = true;
    }

    // Stops listening and removes the handshake, if it is still this run's.
    stop {
        var text;
        responder !? { |r| r.free };
        responder = nil;
        onShutDown !? { |f| ShutDown.remove(f) };
        onShutDown = nil;
        if(started) {
            text = MegaFiles.readText(this.class.handshakePath);
            if(text.notNil and: { token.notNil } and: { text.contains(token) }) {
                File.delete(this.class.handshakePath)
            };
        };
        started = false;
    }

    free { this.stop }

    handshakeText {
        ^MegaFiles.json(this.class.obj([\format, this.class.formatName, \version, this.class.version,
            \port, port, \token, token, \pid, thisProcess.pid, \oscPath, this.class.oscPath.asString,
            \dir, this.class.dir])) ++ "\n"
    }

    // 32 hex digits from the system's random source, or from sclang's
    // generator where there is none.
    *newToken {
        var bytes = try {
            File.use("/dev/urandom", "rb", { |f| var a = Int8Array.newClear(16); f.read(a); a.asArray })
        };
        ^if(bytes.isKindOf(Array) and: { bytes.size == 16 }) {
            bytes.collect { |b| b.bitAnd(255).asHexString(2) }.join.toLower
        } { Array.fill(32, { 16.rand.asHexString(1) }).join.toLower }
    }

    // ---- receiving -----------------------------------------------------------

    *isLocal { |addr| ^addr.notNil and: { addr.ip == "127.0.0.1" } }

    // An id names two files, so it may hold nothing a path could misread.
    *idOk { |id|
        id = id.asString;
        ^(id.size >= 1) and: { id.size <= 64 } and: { id.every { |c| c.isAlphaNum or: { c == $- } } }
    }

    // [path, token, id] from `addr`: answered, or dropped without a word.
    receive { |msg, addr|
        var id = msg[2];
        if(this.class.isLocal(addr).not) { ^this };
        if(token.isNil or: { msg[1].asString != token }) { ^this };
        if(this.class.idOk(id).not) { ^this };
        this.answer(id.asString);
    }

    // The request file's answer, in the reply file (asynchronously: the move
    // into place is a shell's, so the clocks keep time). The request goes.
    answer { |id|
        var reqPath = this.class.requestPath(id);
        var text = MegaFiles.readText(reqPath);
        var reply;
        if(File.exists(reqPath)) { File.delete(reqPath) };
        reply = this.handle(text);
        MegaFiles.write(this.class.replyPath(id), MegaFiles.json(reply), nil, nil, { |ok, why|
            if(ok.not) { ("MegaRemote: a reply was not written (" ++ why ++ ").").warn } });
    }

    // A request's text answered: (ok: true, result:) or (ok: false, error:).
    handle { |text|
        var request = MegaFiles.parseObject(text), command, args;
        if(request.isString) { ^this.class.failure("the request " ++ request) };
        command = request.at("command");
        args = request.at("args");
        if(args.notNil and: { args.isKindOf(MegaJsonObject).not }) {
            ^this.class.failure("args must be an object")
        };
        ^try {
            case
            { command == "ping" } {
                this.class.success(this.class.obj([\format, this.class.formatName,
                    \version, this.class.version, \pid, thisProcess.pid]))
            }
            { command == "context" } { this.class.success(this.class.context(source.value)) }
            { command == "describe" } {
                this.class.describe(args !? { |a| a.at("topic") }) !? { |d| this.class.success(d) }
                    ?? { this.class.failure("no such topic; there are " ++ this.class.topics.join(", ")) }
            }
            { this.class.failure("no command " ++ command.asString.quote ++ "; there are ping, context, describe") }
        } { |err| this.class.failure("megalooper failed to answer: " ++ err.errorString) }
    }

    *success { |result| ^this.obj([\ok, true, \result, result]) }
    *failure { |why| ^this.obj([\ok, false, \error, why]) }

    // An object with its members in this order: [key, value, key, value ...].
    // A nil value stays, as null.
    *obj { |pairs|
        var o = MegaJsonObject.new;
        pairs.pairsDo { |k, v| o.add(k, v) };
        ^o
    }

    // ---- the context -----------------------------------------------------------

    // What is playing and how it is set, from `src` (looper:, sa:, profile:).
    *context { |src|
        var looper = src !? { |s| s[\looper] }, sa = src !? { |s| s[\sa] };
        var drums = sa !? { |m| m.drums };
        ^this.obj([
            \format, "megalooper context", \version, this.version,
            \profile, src !? { |s| s[\profile] !? { |p| p.asString } },
            \standalone, sa.notNil,
            \loop, this.loopOf(looper),
            \tempo, sa !? { |m| m.tempo },
            \drums, drums !? { |d| this.drumsOf(d) },
            \synth, sa !? { |m| this.synthOf(m) },
            \chains, sa !? { |m| m.sessionInfo[\chains] }
        ])
    }

    // The loop's state and the reading in force: its signature as the window
    // shows it ("7/8", "7+7+7+8/8"), its bars (each in units of 1 /
    // denominator), its tempo in quarter notes a minute and its length.
    *loopOf { |looper|
        var r;
        if(looper.isNil) { ^nil };
        r = looper.lastResult;
        ^this.obj([
            \state, looper.state !? { |s| s.asString },
            \reading, if(r.isNil or: { r[\denominator].isNil }) { nil } {
                this.obj([
                    \signature, MeterAnalyzer.sigString(r),
                    \numerator, r[\numerator], \denominator, r[\denominator],
                    \bars, (r[\bars] ?? { Array.fill(r[\k] ? 1, r[\numerator]) }).asArray,
                    \barCount, r[\k],
                    \bpm, r[\bpm], \loopSeconds, r[\loopDur],
                    \byHand, r[\from] == \hand
                ])
            }
        ])
    }

    // Both step patterns, which is in force, the kits and their pads.
    *drumsOf { |d|
        var pads = { |slot|
            var o = MegaJsonObject.new;
            d.pads(slot).asArray.sort.do { |n| o.add(n.asString, d.padName(slot, n)) };
            o
        };
        ^this.obj([
            \on, d.on, \playing, d.playing, \breakActive, d.breakActive,
            \stepsKit, d.kit(\steps) !? { |k| k.asString },
            \onsetKit, d.kit(\onset) !? { |k| k.asString },
            \kits, d.kitKeys.collect(_.asString),
            \pads, this.obj([\steps, pads.(\steps), \onset, pads.(\onset)]),
            \repeats, d.repeats, \reverbMix, d.reverbMix, \offsetMs, d.offsetMs,
            \patterns, this.obj([\main, d.patterns[\main], \break, d.patterns[\break]])
        ])
    }

    // The note sequencer's pattern and what plays it.
    *synthOf { |sa|
        var d = sa.drums, w = sa.wave;
        ^this.obj([
            \notesOn, d !? { |x| x.notesOn },
            \notes, d !? { |x| x.notes },
            \instrument, sa.instrumentKey !? { |k| k.asString } ? "wave",
            \wave, w !? { |x| x.settings },
            \waveTable, w !? { |x| x.tableName }
        ])
    }

    // ---- describe --------------------------------------------------------------

    *topics { ^#["drums", "synth", "effects"] }

    // What every setting of `topic` means, or nil for a topic there is not.
    // With no topic: the list of them.
    *describe { |topic|
        ^case
        { topic.isNil } { this.obj([\topics, this.topics]) }
        { topic == "drums" } { this.describeDrums }
        { topic == "synth" } { this.describeSynth }
        { topic == "effects" } { this.describeEffects }
        { nil }
    }

    // A settings row as JSON has it: its range from the ControlSpec, choices
    // as [value, label], `displayScale` when the window shows it multiplied
    // (a 0..0.25 shown as 0..25 %). A switch (true or false) has no range.
    *rowOf { |row|
        var spec = if(row[\bool] == true) { nil } { row[\spec] };
        ^this.obj([
            \name, row[\name], \label, row[\label],
            \min, spec !? { |s| s.minval }, \max, spec !? { |s| s.maxval },
            \step, spec !? { |s| s.step }, \default, spec !? { |s| s.default },
            \warp, spec !? { |s| s.warp.asSpecifier.asString },
            \units, row[\units] !? { |u| u.stripWhiteSpace },
            \displayScale, row[\scale],
            \choices, row[\choices],
            \switch, row[\bool] == true,
            \bipolar, row[\centered] == true,
            \tip, row[\tip] !? { |t| t.replace("\n", " ") }
        ])
    }

    *describeDrums {
        ^this.obj([
            \about, "The drums are a step sequencer of four lanes, each playing one drum pad (note) "
                "or its alternative pad (altNote). There are two patterns: main, and break (in force "
                "while a break is open). A step is a 16th at clockSpeed 3. A pattern holds, per lane, "
                "five pages of 16 step values each 0..6: chance (the step plays with probability "
                "value/6: 0 never, 6 always), velo (an index into velocities), alt (the probability, "
                "/6, that the step plays altNote instead of note), roll (that many extra hits within "
                "the step at rollRate), slide (stored, not heard). Each page of each lane has its own "
                "length (lengths[page][lane], 2..16): it wraps on its own, so lanes of different "
                "lengths drift against each other; lock[lane] plays globalLength[lane] on every page "
                "instead. The lanes restart at every bar line of the loop's reading (uneven bars "
                "too), so a lane of 7 steps fits a bar of 7/16 and a lane of 14 a bar of 7/8. "
                "mute[lane] silences a lane, delay[lane] moves it later in ms. Shuffle: shuffle[0..7] "
                "per step of a shuffleLength cycle, scaled by globalShuffle. Lane 0 is the hats in "
                "the shipped pattern. The pads a kit has are in the context's drums.pads.steps.",
            \velocities, MegaSASteps.velocities,
            \pages, MegaSASteps.subs,
            \stepValues, this.obj([\min, 0, \max, 6]),
            \stepsPerPage, 16,
            \clockSpeeds, MegaSASteps.clockSpeedLabels.collect { |l, i| [i, l] },
            \rollRates, MegaSASteps.rollRateLabels.collect { |l, i| [i, l] },
            \settings, MegaSASteps.paramSpecs.collect { |r| this.rowOf(r) },
            \laneSettings, MegaSASteps.laneParamSpecs.collect { |r| this.rowOf(r) }
        ])
    }

    *describeSynth {
        var specs = MegaSANoteSeq.laneSpecs;
        ^this.obj([
            \about, "The note sequencer plays one note per step (stepCount 8 or 16, steps[i] on or "
                "off) on the synth: the built-in Wave synth, or an instrument plugin. Seven lanes "
                "hold a value per step: pitch (semitones), octave, velocity, length (% of the step), "
                "shift (late, ms), ratchet (the step plays ratchet + 1 times), condition (0 or 1 "
                "always; +k once every k passes of the lane; -k all but that one; -1 never). A lane "
                "follows the sequence unless own is true: then it steps on its own between first "
                "and last in its own direction, so lanes drift. Pitch is pitch + octave * 12, "
                "snapped to scale and root when scaleOn, around the base note. division indexes "
                "divisions (1/1 .. 1/64), with triplet or dotted; swing 0..100 % delays every "
                "second step. restart: bar (from every bar line), loop or off.",
            \lanes, MegaSANoteSeq.laneNames.collect { |n|
                this.obj([\name, n, \min, specs[n][0], \max, specs[n][1], \default, specs[n][2]]) },
            \settings, MegaSANoteSeq.settingNames,
            \laneSettings, MegaSANoteSeq.laneSettingNames,
            \directions, MegaSANoteSeq.directions,
            \divisions, MegaSANoteSeq.divisionNames.collect { |l, i| [i, l] },
            \restarts, MegaSANoteSeq.restarts,
            \roots, MegaSANoteSeq.rootNames.collect { |l, i| [i, l] },
            \scales, MegaSANoteSeq.scales.collect { |s, i| [i, s[0], s[1]] },
            \wave, MegaSAWave.params.collect { |r| this.rowOf(r) }
        ])
    }

    // Every built-in effect: its key, the chain it is made for, what it does,
    // and its settings.
    *describeEffects {
        ^this.obj([
            \about, "Effects sit in chains (guitar, loop, drums, bass, synth) as devices: a device "
                "has an id, a type (one of these keys), a name, an on switch and settings by name. "
                "Plugins (VST) are devices too; their own settings are not listed here.",
            \effects, MegaSAFx.types.collect { |t|
                this.obj([\key, t[\key], \track, t[\track], \about, t[\blurb],
                    \settings, MegaSAFx.paramsOf(t[\key]).collect { |r| this.rowOf(r) }])
            }
        ])
    }
}
