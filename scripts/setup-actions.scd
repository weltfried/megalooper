// Every action (MegaActionLog, docs/manual.md "Every action"): each change
// the players make, and each an AI app makes, written into the set's log while
// Record set runs, with how every part is set when the set starts and again
// whenever a part has settled after a change; and the last minute of them in
// the AI's context. The switch is under RECORD SET on Setup's MIDI & AI page
// (gui-rig.scd), kept in settings.json beside the theme. Off, nothing listens.
//
//   ~actionsApply.()     the log started or stopped as settings.json says
//                        (boot.scd, after the window)
//   ~actionsSet.(true)   the switch on, kept; false off
//   ~actionsNote.(part, what, ...args)   a change that is no part's own
//                        (the window's views, its preset bars)
//   ~actionsHeader.()    what a set's header says of it (~saSessionExtras):
//                        that every action is in the log, and the view shown;
//                        nil while off
//
// What it listens to is ~actionsParts: the Looper (its layers, the arc, the
// transport), MegaSA (the effects' settings, Random, the mixer, sounds), its
// drums (the patterns, the kits, the note sequence) and the Wave synth. Each
// part already says its changes by name to the window; MegaActionLog hears
// the same, so a key, a click, MIDI and an AI app are all heard alike.

~actionsPrefKey = "logActions";
// Unless settings.json says otherwise.
~actionsDefault = "off";

~actionsOn = { ((~guiPrefSaved !? { |f| f.value(~actionsPrefKey) }) ? ~actionsDefault) == "on" };

// The Looper's own switches, for its state.
~actionsLooperState = { |l|
    (reverse: l.reverseFlag, halfTime: l.halfTime, intensity: l.intensity, feedback: l.feedback,
        masterAmp: l.masterAmp, breakLoops: l.breakLoops, dissolveLoops: l.dissolveLoops,
        onsetNotes: l.onsetNotes, onsetNoteChance: l.onsetNoteChance, onsetThreshold: l.onsetThreshold)
};

// The mixer's strips that are there: level in dB and the mute.
~actionsMixer = { |m|
    var mix = ();
    [\guitar, \bass, \loop, \drums, \onsetKit, \synth, \master].do { |k|
        m.level(k) !? { |a| mix.put(k, (level: a.ampdb.round(0.1), mute: m.mute(k) == true)) };
    };
    mix
};

// The parts, as MegaActionLog takes them. What is skipped is not an action
// (the onset lamp, a dissolve's position, the onset notes rebuilt after a
// take, the drums' own transport), says one
// already heard (\speed beside \halfTime), or is the log's own business; what
// is `logged` the set's log already has from its own writer (Looper's
// halfTime, the drums' drumsOn, SA's fx and fxChain: setup-sa.scd). A state is
// built on SystemClock's thread, hence inEnvir where it asks this environment.
~actionsParts = {
    var l = ~looper, m = ~megaSA, parts = ();
    l !? {
        parts.put(\looper, (model: l,
            skip: #[\liveOnset, \dissolvePos, \analysisMonitor, \sessionRecording, \sessionChannel, \reading,
                \readingIndex, \speed, \breakEndsAt, \overdubDetected, \bbcutState, \onsetNotePattern],
            logged: #[\halfTime],
            bare: #[\bbcutVoices],
            state: { (grains: MegaRemote.grainsOf(l), cutter: MegaRemote.cutterOf(l),
                looper: ~actionsLooperState.(l)) }.inEnvir));
    };
    m !? {
        parts.put(\sa, (model: m,
            skip: #[\fxParam, \latency, \tempo, \hold],
            logged: #[\fx, \chain],
            state: { (chains: m.sessionInfo[\chains], mixer: ~actionsMixer.(m)) }.inEnvir));
        m.drums !? { |d|
            parts.put(\drums, (model: d,
                skip: #[\playing, \breakActive, \kitState, \reverb],
                logged: #[\on],
                state: { (drums: MegaRemote.drumsOf(d), synth: MegaRemote.synthOf(m)) }));
        };
        m.wave !? { |w| parts.put(\wave, (model: w, state: { (synth: MegaRemote.synthOf(m)) })) };
    };
    // The window: its views and the preset bars' recalls, told by ~actionsNote.
    parts.put(\window, ());
    parts
};

// Stops a log that runs, then starts one afresh if the switch is on: a boot
// run again or the switch turned on listens to the parts as they are now. A
// set that starts gets every part's state in its first lines.
~actionsApply = {
    ~actionLog !? { |a| a.stop };
    ~actionLog = nil;
    ~actionsSetWatch !? { |w| w.remove };
    ~actionsSetWatch = nil;
    if(~actionsOn.()) {
        ~actionLog = MegaActionLog(~actionsParts.(),
            { ~looper !? { |l| l.sessionRec } }.inEnvir,
            { if(MegaRemote.applying.notNil) { "ai" } }).start;
        // The drums' state is slow only the first time it is asked for
        // (about 40 ms, then a twentieth of a millisecond): asked now, not
        // when a set starts or while one plays.
        ~actionLog.stateOf(\drums);
        ~looper !? { |l|
            ~actionsSetWatch = SimpleController(l).put(\sessionRecording, { |obj, what, on|
                if(on == true) { ~actionLog !? { |a| a.writeStates } } }.inEnvir);
        };
    };
    ~actionsPaint !? { |f| f.value };
};

~actionsSet = { |on|
    on = on == true;
    if(on != ~actionsOn.()) {
        ~guiPrefSave !? { |f| f.value(~actionsPrefKey, if(on) { "on" } { "off" }, "the Log every action switch") };
        ~actionsApply.();
        ~guiSay !? { |f| f.value(if(on) { "Every action is logged from now on" } { "Actions are not logged" }) };
    };
};

~actionsNote = { |part, what ... args| ~actionLog !? { |a| a.note(part, what, *args) } };

~actionsHeader = { ~actionLog !? { (actions: true, view: ~guiView) } };
