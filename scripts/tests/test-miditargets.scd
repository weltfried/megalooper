// The controls a MIDI binding can drive (setup-miditargets.scd): every one
// docs/dev/midi-map.md's table 4.2 names and none of those 4.3 leaves out, each
// with what its kind needs, on its widget's law, reading as its widget reads,
// and driving its model through the model's own methods, so that the model's
// notification, which the window follows, fires as for a mouse move. On a
// Live rig (no Megalooper SA) and on SA: a MegaSA with no server, its drums
// holding two small kits written here. No server, no window, no MIDIClient,
// no MIDI.
//
// The router and its rules are test-midimap.scd's; that it does what the old
// responders did, test-midi-equivalence.scd's.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-miditargets");

{
var dir = thisProcess.nowExecutingPath.dirname;
var scripts = dir.dirname;
var tmp = ~tTempPath.("miditargets-test");
var saved, targets, kinds, tabs, idShape, families, familyOf, looperIds, phase1, forbidden, words;
var stub, sa, d, l, rec, reader, writeWav, writeKit, heard, act, near, offenders, count, there, source;
var t, p, v, got, ids, map, route, sources, warned, live, keptTargets, before, id2, tid;

// What this needs, loaded only where it is not: beside a running megalooper
// every part is, and loading a GUI file again would unhook its live widgets.
// The file under test is always read afresh.
if(~routingProfiles.isNil) { (scripts +/+ "setup-routing.scd").load };
if(~setupMidiIO.isNil) { (scripts +/+ "setup-midi.scd").load };
if(~saGuitarBank.isNil) { (scripts +/+ "setup-sa.scd").load };
(scripts +/+ "setup-miditargets.scd").load;
if(~midiApply.isNil) { (scripts +/+ "setup-midimap.scd").load };
if(~onsetThresholdSpec.isNil) { (scripts +/+ "gui-const.scd").load };
if(~definePresetFamily.isNil) { (scripts +/+ "gui-presets.scd").load };
if(~granularParams.isNil) { (scripts +/+ "gui-granular.scd").load };
if(~midiNoteName.isNil) { (scripts +/+ "gui-analysis.scd").load };
if(~saLevelSpec.isNil) { (scripts +/+ "gui-sa.scd").load };
if(~effectsMap.isNil) { (scripts +/+ "gui-effects.scd").load };
if(~drumsTrimSpec.isNil) { (scripts +/+ "gui-drums.scd").load };

// Equal, numbers to within 1e-9.
near = { |a, b| if(a.isNumber and: { b.isNumber }) { (a - b).abs < 1e-9 } { a == b } };
// What a model said while `fn` ran: [what, args...] per notification.
heard = { |model, fn|
    var said = List.new;
    var f = { |obj, what ... args| said.add([what] ++ args) };
    model.addDependant(f);
    protect { fn.value } { model.removeDependant(f) };
    said.asArray
};
// An action of the router's (LooperMidiMap.decide) carried out on a control,
// as the router carries it out (~midiApply).
act = { |id, action| ~midiApply.(targets[id], action, (msg: \cc)) };
// The ids, or the labels, of the controls `test` holds for, for a failure's
// detail.
offenders = { |test| targets.keys.asArray.select { |id| test.(targets[id]).not }.sort };
count = { |test| targets.values.count(test) };
there = { |x| x[\available].value != false };

kinds = #[\trigger, \toggle, \continuous, \step, \choice, \light];
tabs = ["Perform", "Grains", "Cutter", "Analysis", "Effects", "Drums", "Synth", "Rig", "Live", "Window"];
// Dotted lower camel: words that start lower case, or a number (a pad's note).
idShape = "^[a-z][a-zA-Z0-9]*(\\.([a-z][a-zA-Z0-9]*|[0-9]+))+$";
// Table 4.2's families, as patterns of ids, with how many each has with no SA
// (the trims follow the kits, so they come with SA only).
families = [
    [\looper, "^looper\\.[a-z][a-zA-Z0-9]*$", 46],
    [\live, "^live\\.record$", 1],
    [\fxOn, "^sa\\.fxOn\\.(" ++ MegaSAFx.typeKeys.join("|") ++ ")$", 16],
    [\fx, "^sa\\.fx\\.(" ++ MegaSAFx.params.collect { |x| x[\name] }.join("|") ++ ")$", 128],
    [\fxReset, "^sa\\.fxReset\\.(" ++ MegaSAFx.typeKeys.join("|") ++ ")$", 16],
    [\fxRandom, "^sa\\.fxRandom\\.(" ++ MegaSAFx.typeKeys.join("|") ++ ")$", 16],
    [\level, "^sa\\.level\\.(guitar|bass|loop|drums|onsetKit|synth|master)$", 7],
    [\mute, "^sa\\.mute\\.(guitar|bass|loop|drums|onsetKit|synth)$", 6],
    [\drums, "^sa\\.drums\\.(on|breakPattern|repeats|reverbMix|livePattern\\.(main|break))$", 6],
    [\timing, "^sa\\.drums\\.(main|break)\\.(" ++ MegaSASteps.paramSpecs.collect { |x| x[\name] }.join("|") ++ ")$", 28],
    [\lane, "^sa\\.drums\\.(main|break)\\.lane[1-4]\\.(note|altNote|delay|mute|lock)$", 40],
    [\length, "^sa\\.drums\\.(main|break)\\.lane[1-4]\\.length\\.(chance|alt|velo|roll)$", 32],
    [\trim, "^sa\\.drums\\.trim\\.(steps|onset)\\.[0-9]+$", 0],
    [\groupTrim, "^sa\\.drums\\.groupTrim\\.(steps|onset)\\.[a-zA-Z0-9]+$", 0],
    [\synth, "^sa\\.synth\\.(on|random|reset|division|root|scale|swing|" ++ MegaSAWave.params.collect { |x| x[\name] }.join("|") ++ ")$",
        7 + MegaSAWave.params.size],
    [\window, "^gui\\.view\\.(perform|sound|fx|drums|synth|setup|calibrate)$", 7],
    [\count, "^count\\.(beatLight|countInLight|oddBarLight)$", 3]
];
familyOf = { |id| families.select { |f| f[1].matchRegexp(id.asString) }.collect { |f| f[0] } };
// The Looper's, as table 4.2 lists them: the transport, the switches, the
// three added after review, the levels, the granular block and its window,
// the counts and the cutter's mode.
looperIds = ['looper.trigger', 'looper.stop', 'looper.multiply', 'looper.undo', 'looper.clear', 'looper.halfTime',
    'looper.recordNextLoop', 'looper.break', 'looper.nextReading', 'looper.revertReading',
    'looper.reverse', 'looper.dissolve', 'looper.sessionRecording', 'looper.granular', 'looper.bbcut',
    'looper.onsetNotes', 'looper.analysisMonitor', 'looper.analyzeOverdubs',
    'looper.detectMeterFromOverdub', 'looper.rerollOnsetNotes', 'looper.granularResetTweaks',
    'looper.masterAmp', 'looper.feedback', 'looper.intensity', 'looper.onsetThreshold', 'looper.onsetNoteChance',
    'looper.granularMorph', 'looper.granularAmp', 'looper.granularPitch', 'looper.granularDetune',
    'looper.granularSize', 'looper.granularDensity', 'looper.granularSizeRand', 'looper.granularPosition',
    'looper.granularScan', 'looper.granularSpray', 'looper.granularEnv', 'looper.granularFollowChords',
    'looper.dissolveBars', 'looper.breakLoops', 'looper.onsetNote', 'looper.onsetNoteVelLo',
    'looper.onsetNoteVelHi', 'looper.onsetNoteDynRange', 'looper.onsetNoteGateMs', 'looper.bbcutMode'];
// The 36 the old responders drove (phase 1).
phase1 = ['looper.trigger', 'looper.stop', 'looper.multiply', 'looper.undo', 'looper.clear',
    'looper.recordNextLoop', 'looper.break', 'looper.nextReading', 'looper.reverse', 'looper.dissolve',
    'looper.sessionRecording', 'looper.granular', 'looper.bbcut', 'looper.onsetNotes', 'live.record',
    'looper.feedback', 'looper.intensity', 'looper.granularMorph', 'looper.onsetThreshold',
    'looper.granularAmp', 'looper.granularPitch', 'looper.granularDetune', 'looper.granularSize',
    'looper.granularDensity', 'looper.granularSizeRand', 'looper.granularPosition', 'looper.granularScan',
    'looper.granularSpray', 'sa.fxOn.shifter', 'sa.fxOn.delay', 'sa.fxOn.filter', 'sa.fxOn.pitchLoop',
    'sa.fxOn.echo', 'sa.fxOn.saturator', 'sa.fxOn.redux', 'sa.drums.on'];
// Section 4.3, by the model's names: the rig's settings, the kit menus, the
// fields and buttons left out, and what waits for phase 5.
forbidden = [\latencyMs, \abletonSyncMs, \declickMs, \transportMode, \inChannel, \inChannelCount,
    \analysisChannel, \onsetNoteChannel, \onsetNoteOffsetMs, \chainRecOffsetMs, \offsetMs, \kit, \setKit,
    \hzLo, \hzHi, \minSamples, \chordMinPerWindow, \fallbackNum, \fallbackDenom, \fallbackBars,
    \guitarEditor, \addVoice, \removeVoice, \voice, \step, \setStep, \analysisResetStats];
words = ["preset", "keep", "calibrat", "export", "variation", "bank", "editor", "voice", "rescan", "resetStats"];

// ---- the small kits ----
// Two kits for the slots and a third to load over the steps kit: their audio
// beside them, read through a reader standing in for Buffer.read, so a kit
// loads at once and nothing reaches a server.
writeWav = { |path|
    var sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(1).sampleRate_(48000);
    sf.openWrite(path);
    sf.writeData(Signal.fill(480, { 0.1 }));
    sf.close;
};
writeKit = { |key, text| File.use(tmp +/+ key ++ ".json", "w", { |f| f.write(text) }) };
reader = { |srv, path, done| done.((bufnum: 100, path: path, numChannels: 1, sampleRate: 48000, numFrames: 480)) };
File.mkdir(tmp);
File.mkdir(tmp +/+ "mt");
writeWav.(tmp +/+ "mt" +/+ "a.wav");
writeWav.(tmp +/+ "mt" +/+ "b.wav");
writeKit.("mt-steps", "{ \"version\": 1, \"key\": \"mt-steps\", \"name\": \"MT Steps\", "
    "\"groups\": { \"body\": \"Body\", \"layer\": \"The layer\" }, \"pads\": { "
    "\"36\": { \"name\": \"Kick\", \"layers\": [ { \"group\": \"body\", \"file\": \"mt/a.wav\" } ] }, "
    "\"38\": { \"name\": \"Snare\", \"layers\": [ { \"group\": \"body\", \"file\": \"mt/a.wav\" }, "
    "{ \"group\": \"layer\", \"file\": \"mt/b.wav\" } ] }, "
    "\"42\": { \"name\": \"Hat\", \"beatRepeat\": true, \"layers\": [ { \"group\": \"body\", \"file\": \"mt/b.wav\" } ] } } }");
writeKit.("mt-onset", "{ \"version\": 1, \"key\": \"mt-onset\", \"name\": \"MT Onset\", "
    "\"groups\": { \"one\": \"One\" }, \"pads\": { "
    "\"36\": { \"name\": \"Clap\", \"layers\": [ { \"group\": \"one\", \"file\": \"mt/a.wav\" } ] }, "
    "\"37\": { \"name\": \"Rim\", \"layers\": [ { \"group\": \"one\", \"file\": \"mt/b.wav\" } ] } } }");
writeKit.("mt-other", "{ \"version\": 1, \"key\": \"mt-other\", \"name\": \"MT Other\", "
    "\"groups\": { \"body\": \"Body\" }, \"pads\": { "
    "\"36\": { \"name\": \"Kick 2\", \"layers\": [ { \"group\": \"body\", \"file\": \"mt/a.wav\" } ] } } }");

// ---- a real MegaSA on the recording stub (~tMegaSA), as test-megasa.scd and
// check-gui-effects.scd make one, its drums (MegaSADrums) holding the two
// kits ----
stub = ~tStubServer.();
// With a bass input, as on the duo's rig, so the bass's strip is there.
sa = ~tMegaSA.(stub, nil, nil, nil, nil, nil, 1);
d = sa.drums;
d.kitDir = tmp;
d.kitReader = reader;
d.setKit(\steps, 'mt-steps');
d.setKit(\onset, 'mt-onset');
~tAssert.("the small kits load into the two slots",
    (d.kitState(\steps) == \ready) and: { d.kitState(\onset) == \ready }
        and: { d.kitFor(\steps).notes == [36, 38, 42] } and: { d.kitFor(\onset).notes == [36, 37] },
    [d.kitState(\steps), d.kitState(\onset)].asString);

// These swap globals a running megalooper uses (~looper, ~megaSA, Live's
// record switch), so they are put back however it ends.
saved = [~looper, ~megaSA, ~liveRecordToggle, ~liveRecordSet, ~rp];
protect {
    // ------------------------------------------------------------ on a Live rig --
    l = ~tLooper.();
    ~looper = l;
    ~megaSA = nil;
    ~rp = nil;   // no rig said: one beside Live, as every rig without `live: false`
    ~liveRecordToggle = { true };   // never Live's: that one sends OSC
    ~liveRecordSet = { |on| on };
    targets = ~tCheck.("the controls are made on a Live rig", { ~midiTargetsBuild.() }) ? IdentityDictionary.new;

    ~tEq.("every control knows its own id, and its kind is one of the six",
        offenders.({ |x| (x[\id].notNil) and: { targets[x[\id]] === x } and: { kinds.includes(x[\kind]) } }), []);
    ~tEq.("...with words for a label, a tab the window has, and a group in words where there is one",
        offenders.({ |x| x[\label].isString and: { x[\label].notEmpty } and: { tabs.includesEqual(x[\path]) }
            and: { x[\group].isNil or: { x[\group].isString } } }), []);
    // A toggle with no set of its own (Reverse, Dissolve...) is flipped by the
    // router to go where it is told, through the model's toggle.
    ~tEq.("a trigger has its action; a toggle its flip and get, and set where it has one; every control says whether it is there",
        offenders.({ |x|
            var fn = { |k| x[k].isKindOf(Function) };
            fn.(\available) and: {
                case
                { x[\kind] == \trigger } { fn.(\fire) }
                { x[\kind] == \toggle } { fn.(\flip) and: { fn.(\get) } and: { x[\set].isNil or: { fn.(\set) } } }
                { true }
            }
        }), []);
    ~tEq.("...and every toggle the table adds has a set of its own",
        offenders.({ |x| (x[\kind] != \toggle) or: { phase1.includes(x[\id]) } or: { x[\set].isKindOf(Function) } }), []);
    ~tEq.("a level and a count have get, set, a law both ways and a readout",
        offenders.({ |x| [\continuous, \step].includes(x[\kind]).not
            or: { [\get, \set, \fromPos, \toPos, \format].every { |k| x[k].isKindOf(Function) } } }), []);
    ~tEq.("a choice has get, set, a law, a readout and items, as Strings",
        offenders.({ |x| var items = x[\items].value;
            (x[\kind] != \choice) or: {
                [\get, \set, \fromPos, \toPos, \format].every { |k| x[k].isKindOf(Function) }
                    and: { items.isKindOf(Array) } and: { items.notEmpty } and: { items.every(_.isString) } } }), []);
    ~tEq.("every level, count and choice has its section in its pane as its group",
        offenders.({ |x| [\continuous, \step, \choice].includes(x[\kind]).not
            or: { x[\group].notNil } }), []);
    ~tEq.("the ids are dotted lower camel", targets.keys.asArray.reject { |id| idShape.matchRegexp(id.asString) }, []);
    ~tEq.("...and no two differ only in case",
        targets.keys.asArray.collect { |id| id.asString.toLower }.asSet.size, targets.size);
    ~tEq.("every id is of exactly one of table 4.2's families",
        targets.keys.asArray.select { |id| familyOf.(id).size != 1 }.sort, []);
    ~tEq.("each family has as many as the table gives",
        families.collect { |f| [f[0], targets.keys.count { |id| f[1].matchRegexp(id.asString) }] },
        families.collect { |f| [f[0], f[2]] });
    ~tEq.("the Looper's are the table's, no more and no fewer",
        [looperIds.reject { |id| targets.includesKey(id) },
            targets.keys.asArray.select { |id| familyOf.(id) == [\looper] }.reject { |id| looperIds.includes(id) }],
        [[], []]);
    ~tEq.("the 36 controls today's numbers drive are all still there",
        phase1.reject { |id| targets.includesKey(id) }, []);
    // A view of the window is shown, not set: the wizard's view is no
    // calibration setting.
    ~tEq.("none of 4.3's is there: the rig's settings, kit menus, fields, presets, Keep, voices, steps",
        targets.keys.asArray.reject { |id| id.asString.beginsWith("gui.view.") }.select { |id|
            var parts = id.asString.split($.).collect(_.asSymbol);
            parts.any { |w| forbidden.includes(w) }
                or: { words.any { |w| id.asString.toLower.contains(w.toLower) } }
        }.sort, []);
    ~tEq.("in the picker, no two controls of one tab and group share a label",
        targets.values.collect { |x| x[\path] ++ " / " ++ (x[\group] ? "") ++ " / " ++ x[\label] }.asSet.size,
        targets.size);
    // The effects' controls as the maps and the picker know them, pinned to a
    // snapshot (fixtures/effect-targets.tsv: id, label, group, tab, kind), so
    // rebuilding how the effects are made of synths and devices cannot move an
    // id or a label the TSMega's map, a map of yours or the picker relies on.
    {
        var want = File.readAllString(dir +/+ "fixtures" +/+ "effect-targets.tsv") ? "";
        var have = targets.keys.asArray.select { |id|
            var s = id.asString;
            s.beginsWith("sa.fxOn.") or: { s.beginsWith("sa.fx.") } or: { s.beginsWith("sa.fxReset.") }
        }.collect { |id|
            var x = targets[id];
            [id, x[\label], x[\group], x[\path], x[\kind]].collect(_.asString).join("\t")
        }.sort;
        var wantLines = want.split($\n).reject(_.isEmpty);
        ~tEq.("the effects' controls are exactly the snapshot's: ids, labels, groups, tabs, kinds",
            [have.reject { |l| wantLines.includesEqual(l) }, wantLines.reject { |l| have.includesEqual(l) }], [[], []]);
        ~tEq.("...all 160 of them", have.size, 160);
    }.value;

    live = [targets.size, count.(there)];
    ("  on a Live rig: " ++ live[0] ++ " controls, " ++ live[1] ++ " there").postln;
    ~tEq.("on a Live rig the Looper's 46, Live's record and the count's 3 lights are there, and nothing of SA's",
        [live[1], targets.keys.asArray.select { |id| there.(targets[id]) and: { id.asString.beginsWith("sa.") } }],
        [50, []]);

    // ------------------------------------------------------------------- laws --
    ~tEq.("every level's law goes back to where it came from, at 0, 1/4, 1/2, 3/4 and 1 ("
        ++ count.({ |x| x[\kind] == \continuous }) ++ " of them)",
        offenders.({ |x| (x[\kind] != \continuous) or: {
            [0, 0.25, 0.5, 0.75, 1].every { |c| (x[\toPos].value(x[\fromPos].value(c)) - c).abs < 1e-6 } } }), []);
    ~tEq.("a count's law runs end to end in whole numbers",
        offenders.({ |x| (x[\kind] != \step) or: {
            [0, 0.25, 0.5, 0.75, 1].every { |c| v = x[\fromPos].value(c); v.round == v }
                and: { x[\toPos].value(x[\fromPos].value(0)) == 0 } and: { x[\toPos].value(x[\fromPos].value(1)) == 1 } } }),
        []);
    ~tEq.("a choice's law gives every item back, the first at 0 and the last at 1",
        offenders.({ |x| var n = (x[\items].value ? []).size;
            (x[\kind] != \choice) or: {
                (0..(n - 1)).every { |i| x[\fromPos].value(x[\toPos].value(i)) == i }
                    and: { x[\fromPos].value(0) == 0 } and: { x[\fromPos].value(1) == (n - 1) } } }), []);
    ~tEq.("the header's levels and Chance move straight 0..1, as their sliders",
        ['looper.masterAmp', 'looper.feedback', 'looper.intensity', 'looper.onsetNoteChance'].collect { |id|
            [0.3, 0.77].collect { |c| targets[id][\fromPos].value(c) } }, [[0.3, 0.77], [0.3, 0.77], [0.3, 0.77], [0.3, 0.77]]);
    ~tEq.("every granular row is on ~granularMapValue, as its slider",
        offenders.({ |x| var row = ~granularParams.detect { |r| ("looper." ++ r[\key]).asSymbol == x[\id] };
            row.isNil or: { [0.1, 0.5, 0.9].every { |c| near.(x[\fromPos].value(c), ~granularMapValue.(row, c)) } } }),
        []);
    ~tEq.("every effect knob is on ~effectsMap and ~effectsUnmap, and reads as ~effectsFormat",
        MegaSAFx.params.reject { |q| q[\choices].notNil }.reject { |q|
            t = targets[("sa.fx." ++ q[\name]).asSymbol];
            [0.1, 0.5, 0.9].every { |c| near.(t[\fromPos].value(c), ~effectsMap.(q, c)) }
                and: { near.(t[\toPos].value(q[\spec].default), ~effectsUnmap.(q, q[\spec].default)) }
                and: { t[\format].value(q[\spec].default) == ~effectsFormat.(q, q[\spec].default) }
        }.collect { |q| q[\name] }, []);
    ~tEq.("...the four set in whole steps (Coarse, Pitch L and R, Bit Depth) are counts, the rest levels",
        MegaSAFx.params.select { |q| targets[("sa.fx." ++ q[\name]).asSymbol][\kind] == \step }.collect { |q| q[\name] },
        [\shifterCoarse, \pitchLoopPitchL, \pitchLoopPitchR, \reduxBits]);
    ~tEq.("a strip's level is in dB on ~saLevelSpec and reads as ~saLevelText",
        [\guitar, \bass, \loop, \drums, \onsetKit, \synth, \master].reject { |k|
            t = targets[("sa.level." ++ k).asSymbol];
            [0, 0.3, 1].every { |c| t[\fromPos].value(c) == ~saLevelSpec.map(c) }
                and: { t[\format].value(-10.5) == ~saLevelText.((-10.5).dbamp) }
        }, []);
    ~tEq.("the drums' timing knobs are on their ControlSpecs and read as ~drumsFormat",
        MegaSASteps.paramSpecs.reject { |q| q[\choices].notNil or: { q[\bool] == true } }.reject { |q|
            t = targets[("sa.drums.break." ++ q[\name]).asSymbol];
            [0.1, 0.5, 0.9].every { |c| near.(t[\fromPos].value(c), q[\spec].map(c)) }
                and: { t[\format].value(q[\spec].default) == ~drumsFormat.(q, q[\spec].default) }
        }.collect { |q| q[\name] }, []);
    t = targets['sa.drums.main.lane1.delay'];
    ~tEq.("a lane's D moves 0..50 ms in half milliseconds, as its box, and reads as ~drumsFormat",
        [[0, 0.25, 0.5, 1].collect { |c| t[\fromPos].value(c) }, t[\fromPos].value(0.123) * 2 % 1,
            t[\format].value(12.5)],
        [[0, 12.5, 25, 50], 0, ~drumsFormat.(MegaSASteps.laneParamSpec(\delay), 12.5)]);
    t = targets['sa.drums.main.lane1.length.alt'];
    ~tEq.("a lane's L runs 2..16, as its box", [t[\fromPos].value(0), t[\fromPos].value(1)], [2, 16]);
    ~tEq.("the reverb is on ~drumsReverbSpec and reads as its slider's readout",
        [targets['sa.drums.reverbMix'][\fromPos].value(0.4), targets['sa.drums.reverbMix'][\format].value(0.1508)],
        [~drumsReverbSpec.map(0.4), (0.1508 * 100).round(0.1).asString ++ " %"]);
    ~tEq.("the Looper's readouts are their widgets': two decimals, a percentage, a note with its name, units",
        [targets['looper.masterAmp'][\format].value(0.456), targets['looper.onsetNoteChance'][\format].value(0.456),
            targets['looper.onsetNote'][\format].value(42), targets['looper.onsetNoteDynRange'][\format].value(30),
            targets['looper.onsetNoteGateMs'][\format].value(20), targets['looper.dissolveBars'][\format].value(8),
            targets['looper.granularPitch'][\format].value(-12)],
        ["0.46", "46%", "42 · " ++ ~midiNoteName.(42), "30 dB", "20 ms", "8",
            ~granularFormat.(~granularParams.detect { |r| r[\key] == \granularPitch }, -12)]);
    ~tEq.("a choice reads as its item", [targets['looper.granularEnv'][\format].value(2),
        targets['sa.fx.filterType'][\format].value(1)], [Looper.granularEnvNames[2], "High-pass"]);
    ~tEq.("the counts run over their boxes' ranges",
        ['looper.dissolveBars', 'looper.breakLoops', 'looper.onsetNote', 'looper.onsetNoteVelLo',
            'looper.onsetNoteVelHi', 'looper.onsetNoteDynRange', 'looper.onsetNoteGateMs'].collect { |id|
            [targets[id][\fromPos].value(0), targets[id][\fromPos].value(1)] },
        [[1, 32], [1, 8], [0, 127], [1, 127], [1, 127], [1, 90], [1, 1000]]);

    // ------------------------------------------------------- choices' items --
    source = { |file| File.readAllString(scripts +/+ file) ? "" };
    ~tAssert.("the grain window's items are the Grains pane's tiles (Looper.granularEnvNames)",
        (targets['looper.granularEnv'][\items] == Looper.granularEnvNames)
            and: { source.("gui-granular.scd").contains("~guiSeg.(Looper.granularEnvNames,") });
    ~tAssert.("the cutter's mode items are Perform's tiles, in their order",
        (targets['looper.bbcutMode'][\items] == ["Mix", "Insert", "Gate"])
            and: { source.("gui-perform.scd").contains("~guiSeg.([\"Mix\", \"Insert\", \"Gate\"],") }
            and: { source.("gui-perform.scd").contains("lp.bbcutMode = [\\mix, \\insert, \\gate][i]") });
    ~tEq.("an effect's menu items are its choices' labels, as the Effects tab lists them",
        MegaSAFx.params.select { |q| q[\choices].notNil }.reject { |q|
            targets[("sa.fx." ++ q[\name]).asSymbol][\items] == q[\choices].collect { |c| c[1] } }.collect { |q| q[\name] }
            ++ (if(source.("gui-effects.scd").contains(".items_(p[\\choices].collect { |pair| pair[1] })")) { [] } { [\source] }),
        []);
    ~tEq.("a timing menu's items are its choices' labels, as the Drums tab lists them",
        MegaSASteps.paramSpecs.select { |q| q[\choices].notNil and: { q[\bool] != true } }.reject { |q|
            [\main, \break].every { |w|
                targets[("sa.drums." ++ w ++ "." ++ q[\name]).asSymbol][\items] == q[\choices].collect { |c| c[1] } }
        }.collect { |q| q[\name] }
            ++ (if(source.("gui-drums.scd").contains(".items_(p[\\choices].collect { |pair| pair[1] })")) { [] } { [\source] }),
        []);

    // --------------------------------------------- the Looper's, driven --
    ~tEq.("Master: the knob sets the model, which says so", heard.(l, { act.('looper.masterAmp', [\position, 0.42]) }),
        [[\masterAmp, 0.42]]);
    ~tEq.("...and reads back through the model", [l.masterAmp, targets['looper.masterAmp'][\get].value], [0.42, 0.42]);
    ~tEq.("Chance likewise", [heard.(l, { act.('looper.onsetNoteChance', [\position, 0.3]) }), l.onsetNoteChance],
        [[[\onsetNoteChance, 0.3]], 0.3]);
    ~tEq.("a count is set in whole numbers: Dissolve loops halfway is 17 (its id from when it counted bars)",
        [heard.(l, { act.('looper.dissolveBars', [\position, 0.5]) }), l.dissolveLoops,
            targets['looper.dissolveBars'][\get].value], [[[\dissolveLoops, 17]], 17, 17]);
    ~tEq.("...the break's loops at the top, the gate at the bottom",
        [heard.(l, { act.('looper.breakLoops', [\position, 1]) }), heard.(l, { act.('looper.onsetNoteGateMs', [\position, 0]) })],
        [[[\breakLoops, 8]], [[\onsetNoteGateMs, 1]]]);
    ~tEq.("the onset note too, and its velocities and dynamics",
        [\onsetNote, \onsetNoteVelLo, \onsetNoteVelHi, \onsetNoteDynRange].collect { |k|
            heard.(l, { act.(("looper." ++ k).asSymbol, [\position, 1]) }) },
        [[[\onsetNote, 127]], [[\onsetNoteVelLo, 127]], [[\onsetNoteVelHi, 127]], [[\onsetNoteDynRange, 90]]]);
    ~tEq.("the grain window: a knob picks an item, a press moves on and round",
        [heard.(l, { act.('looper.granularEnv', [\position, 0.6]) }), l.granularEnv,
            { act.('looper.granularEnv', [\next]); l.granularEnv }.value,
            { act.('looper.granularEnv', [\next]); l.granularEnv }.value],
        [[[\granularEnv, 2]], 2, 3, 0]);
    ~tEq.("the cutter's mode: Mix at the bottom, then on to Insert, read back as its index",
        [heard.(l, { act.('looper.bbcutMode', [\position, 0]) }), { act.('looper.bbcutMode', [\next]); l.bbcutMode }.value,
            targets['looper.bbcutMode'][\get].value], [[[\bbcutMode, \mix]], \insert, 1]);
    ~tEq.("Overdub detect flips through the model's setter, and goes where it is told",
        [heard.(l, { act.('looper.analyzeOverdubs', [\flip]) }), l.analyzeOverdubs,
            heard.(l, { act.('looper.analyzeOverdubs', [\set, false]) }), l.analyzeOverdubs],
        [[[\analyzeOverdubs, true]], true, [[\analyzeOverdubs, false]], false]);
    ~tEq.("Re-roll throws the dice again, and the Chance readout hears of it",
        heard.(l, { act.('looper.rerollOnsetNotes', [\fire]) }), [[\onsetNoteChance, 0.3]]);
    l.granularPitch = 7;
    l.granularEnv = 2;
    l.granularFollowChords = true;
    got = heard.(l, { act.('looper.granularResetTweaks', [\fire]) });
    ~tAssert.("Reset tweaks puts the bends back through the model, the window and the chords last, morph left alone",
        (l.granularPitch == 0) and: { l.granularEnv == 0 } and: { got.last == [\granularFollowChords, false] }
            and: { got.includesEqual([\granularEnv, 0]) }
            and: { got.any { |x| x == [\granularPitch, 0] } } and: { got.every { |x| x[0] != \granularMorph } },
        got.asString);
    ~tCheck.("Revert with no reading to leave is the model's no-op", { act.('looper.revertReading', [\fire]) });
    // A Looper stand-in that writes down what it is asked: the monitor and the
    // two triggers that need a server or a recorded loop to do anything.
    rec = List.new;
    ~looper = (analysisMonitorOn: false,
        startAnalysisMonitor: { |self| rec.add(\start); self[\analysisMonitorOn] = true; self },
        stopAnalysisMonitor: { |self| rec.add(\stop); self[\analysisMonitorOn] = false; self },
        detectMeterFromOverdub: { |self, force| rec.add([\detect, force]); self },
        revertReading: { |self| rec.add(\revert); self });
    act.('looper.analysisMonitor', [\flip]);
    v = targets['looper.analysisMonitor'][\get].value;
    act.('looper.analysisMonitor', [\flip]);
    act.('looper.analysisMonitor', [\set, true]);
    act.('looper.detectMeterFromOverdub', [\fire]);
    act.('looper.revertReading', [\fire]);
    ~tEq.("the monitor starts and stops as its button does; Detect now forces; Revert reverts",
        [rec.asArray, v], [[\start, \stop, \start, [\detect, true], \revert], true]);
    ~looper = l;

    // -------------------------------------------------------------- on SA --
    ~megaSA = sa;
    targets = ~tCheck.("the controls are made on SA", { ~midiTargetsBuild.() }) ? IdentityDictionary.new;
    ~rp = (sa: true, live: false);
    ~tEq.("Live's arrangement record is offered only on a rig beside Live",
        [targets.includesKey('live.record'), ~midiTargetsBuild.().includesKey('live.record')], [true, false]);
    ~rp = nil;
    ~tEq.("the trims are the two kits' pads, and the steps kit's layer group (not its main one)",
        targets.keys.asArray.select { |id| id.asString.contains("rim.") }.sort,
        ['sa.drums.groupTrim.steps.layer', 'sa.drums.trim.onset.36', 'sa.drums.trim.onset.37',
            'sa.drums.trim.steps.36', 'sa.drums.trim.steps.38', 'sa.drums.trim.steps.42']);
    ~tEq.("...named by their pads and the layer's name, under their kit",
        ['sa.drums.trim.steps.38', 'sa.drums.trim.onset.37', 'sa.drums.groupTrim.steps.layer'].collect { |id|
            [targets[id][\label], targets[id][\group]] },
        [["38 Snare", "Steps kit trims"], ["37 Rim", "Onset kit trims"], ["Layer: The layer", "Steps kit trims"]]);
    ~tEq.("every id is still of exactly one family", targets.keys.asArray.select { |id| familyOf.(id).size != 1 }, []);
    ~tEq.("...and every level's law still goes back and forth, the trims' among them",
        offenders.({ |x| (x[\kind] != \continuous) or: {
            [0, 0.25, 0.5, 0.75, 1].every { |c| (x[\toPos].value(x[\fromPos].value(c)) - c).abs < 1e-6 } } }), []);
    ~tEq.("the trims are on ~drumsTrimSpec and read as ~drumsDbText",
        [[0, 0.5, 1].collect { |c| targets['sa.drums.trim.steps.38'][\fromPos].value(c) },
            targets['sa.drums.groupTrim.steps.layer'][\format].value(-3.5)],
        [[0, 0.5, 1].collect { |c| ~drumsTrimSpec.map(c) }, ~drumsDbText.(-3.5)]);
    ~tEq.("a lane's Note menu is the Drums tab's, named by the steps kit",
        [targets['sa.drums.break.lane3.altNote'][\items].value, targets['sa.drums.main.lane1.note'][\items].value.size],
        [~drumsNoteItems.(d), 16]);
    ~tAssert.("...the menu the tab builds from the same function",
        source.("gui-drums.scd").contains(".items_(~drumsNoteItems.(~drumsModel.()))")
            and: { ~drumsNoteItems.(d)[6] == ("42 Hat · " ++ ~midiNoteName.(42)) });
    v = [targets.size, count.(there)];
    ("  on SA: " ++ v[0] ++ " controls, " ++ v[1] ++ " there").postln;
    // The utility, texture and space effects' 82 come with their devices,
    // which no chain holds to begin with.
    ~tEq.("on SA every control is there: SA's and its kits' 6 trims beside the Looper's and Live's "
        "(the views' 7 need the window, the effects in no chain their devices)", v, [live[0] + 6, ((live[0] + 6) - 7) - 82]);

    // ---------------------------------------------------- SA's, driven --
    p = MegaSAFx.param(\filterFreq);
    got = heard.(sa, { act.('sa.fx.filterFreq', [\position, 0.5]) });
    ~tAssert.("an effect knob sets its setting on the knob's law, MegaSA says so, and the chain hears it",
        near.(sa.fxParam(\filterFreq), p[\spec].map(0.5)) and: { got == [[\fxParam, \filterFreq, sa.fxParam(\filterFreq)]] }
            and: { stub[\msgs].last == [15, sa.fxNode(\filter).nodeID, \filterFreq, sa.fxParam(\filterFreq)] },
        [sa.fxParam(\filterFreq), got, stub[\msgs].last].asString);
    ~tEq.("...and it reads back through the model", targets['sa.fx.filterFreq'][\get].value, sa.fxParam(\filterFreq));
    ~tEq.("Bit Depth, a count: a quarter of the way is 5 bits", [heard.(sa, { act.('sa.fx.reduxBits', [\position, 0.25]) }),
        sa.fxParam(\reduxBits)], [[[\fxParam, \reduxBits, 5.0]], 5.0]);
    ~tEq.("an effect's menu: a knob picks High-pass, a press moves on to Band-pass",
        [heard.(sa, { act.('sa.fx.filterType', [\position, 0.3]) }), targets['sa.fx.filterType'][\get].value,
            { act.('sa.fx.filterType', [\next]); sa.fxParam(\filterType) }.value],
        [[[\fxParam, \filterType, 1.0]], 1, 2.0]);
    ~tEq.("...the echo's note values are its divisions", { act.('sa.fx.echoBeatsL', [\position, 0]); sa.fxParam(\echoBeatsL) }.value,
        0.0625);
    got = heard.(sa, { act.('sa.fxReset.filter', [\fire]) });
    ~tAssert.("Live values puts every setting of the effect back, each through setFxParam",
        MegaSAFx.paramsOf(\filter).every { |q| sa.fxParam(q[\name]) == q[\spec].default }
            and: { got.size == MegaSAFx.paramsOf(\filter).size } and: { got.every { |x| x[0] == \fxParam } },
        got.asString);
    got = heard.(sa, { act.('sa.level.drums', [\position, 0.5]) });
    ~tAssert.("a strip's level: halfway is -27 dB, set as an amplitude, as its slider sets it",
        near.(sa.level(\drums), (-27).dbamp) and: { got == [[\level, \drums, sa.level(\drums)]] }
            and: { (targets['sa.level.drums'][\get].value - -27).abs < 1e-9 },
        [sa.level(\drums), got].asString);
    ~tEq.("...the master's top is +6 dB", { act.('sa.level.master', [\end, \max]); sa.level(\master).ampdb.round(1e-9) }.value, 6);
    ~tEq.("a strip's mute flips through setMute, and says so", [heard.(sa, { act.('sa.mute.loop', [\flip]) }), sa.mute(\loop)],
        [[[\mute, \loop, true]], true]);
    // A strip held for a reason of SA's own (a plugin whose sound did not
    // load) shows muted, and a flip unmutes it, as its button does.
    sa.hold(\guitar, \state);
    ~tEq.("a held strip's mute reads as muted", targets['sa.mute.guitar'][\get].value, true);
    act.('sa.mute.guitar', [\flip]);
    ~tEq.("...and a flip lets it go and unmutes it", [sa.held(\guitar), sa.muted(\guitar), sa.mute(\guitar)], [[], false, false]);
    ~tEq.("which pattern plays: the switch puts the break in, and the drums say so",
        [heard.(d, { act.('sa.drums.breakPattern', [\flip]) }), d.breakActive], [[[\breakActive, true]], true]);
    ~tEq.("Beat Repeat, there with this steps kit, flips through setRepeats",
        [there.(targets['sa.drums.repeats']), heard.(d, { act.('sa.drums.repeats', [\flip]) }), d.repeats],
        [true, [[\repeats, true]], true]);
    ~tEq.("the reverb sets on its slider's law, and says so",
        [heard.(d, { act.('sa.drums.reverbMix', [\position, 0.4]) }), d.reverbMix], [[[\mix, \reverbMix, 0.4]], 0.4]);
    d.setLaneParam(\main, 0, \note, 50);
    got = heard.(d, { act.('sa.drums.livePattern.main', [\fire]) });
    ~tAssert.("Live pattern puts the main pattern back as the Live set has it, and says so",
        (d.laneParam(\main, 0, \note) == MegaSASteps.livePattern(\main)[\note][0]) and: { got.includesEqual([\pattern, \main]) },
        got.asString);
    ~tEq.("a timing menu: a knob picks the Clock item, read back as its index",
        [heard.(d, { act.('sa.drums.break.clockSpeed', [\position, 0.75]) }), d.param(\break, \clockSpeed),
            targets['sa.drums.break.clockSpeed'][\get].value], [[[\param, \break, \clockSpeed, 4]], 4, 4]);
    ~tEq.("Shuffle Len in whole steps, Global on its knob, Retrig switched",
        [heard.(d, { act.('sa.drums.main.shuffleLength', [\position, 1]) }),
            heard.(d, { act.('sa.drums.main.globalShuffle', [\position, 0.5]) }),
            { act.('sa.drums.main.autoRetrigger', [\flip]); d.param(\main, \autoRetrigger) }.value],
        [[[\param, \main, \shuffleLength, 8]], [[\param, \main, \globalShuffle, 50.0]],
            MegaSASteps.livePattern(\main)[\autoRetrigger].not]);
    ~tEq.("a lane's Note: a knob picks pad 42, read back as its item",
        [heard.(d, { act.('sa.drums.main.lane2.note', [\position, 0.4]) }), d.laneParam(\main, 1, \note),
            targets['sa.drums.main.lane2.note'][\get].value], [[[\lane, \main, 1, \note, 42]], 42, 6]);
    ~tEq.("its D in half milliseconds, its M switched",
        [heard.(d, { act.('sa.drums.main.lane1.delay', [\position, 0.25]) }),
            heard.(d, { act.('sa.drums.break.lane3.mute', [\flip]) })],
        [[[\lane, \main, 0, \delay, 12.5]], [[\lane, \break, 2, \mute, true]]]);
    ~tEq.("an L sets its page's length while the lane is not locked",
        [heard.(d, { act.('sa.drums.main.lane4.length.velo', [\position, 0]) }), d.length(\main, \velo, 3),
            targets['sa.drums.main.lane4.length.velo'][\get].value], [[[\length, \main, \velo, 3, 2]], 2, 2]);
    act.('sa.drums.main.lane4.lock', [\set, true]);
    ~tEq.("...and the lane's Global Len while it is, the page's own kept, as the L box does",
        [heard.(d, { act.('sa.drums.main.lane4.length.velo', [\position, 0.5]) }), d.laneParam(\main, 3, \globalLength),
            d.length(\main, \velo, 3), targets['sa.drums.main.lane4.length.velo'][\get].value],
        [[[\lane, \main, 3, \globalLength, 9]], 9, 2, 9]);
    ~tEq.("a pad's trim sets the kit's pad, and says so",
        [heard.(d, { act.('sa.drums.trim.steps.38', [\position, 0.5]) }), d.padTrim(\steps, 38)],
        [[[\padTrim, \steps, 38, -6.0]], -6.0]);
    ~tEq.("a layer's trim likewise", [heard.(d, { act.('sa.drums.groupTrim.steps.layer', [\position, 0.75]) }),
        d.groupTrim(\steps, \layer)], [[[\groupTrim, \steps, \layer, 3.0]], 3.0]);
    d.setKit(\steps, 'mt-other');
    ~tEq.("another kit in the slot: a trim it has a pad for is there, one it has not and its lost layer are not",
        ['sa.drums.trim.steps.36', 'sa.drums.trim.steps.38', 'sa.drums.groupTrim.steps.layer',
            'sa.drums.repeats'].collect { |id| there.(targets[id]) },
        [true, false, false, false]);
    ~tEq.("...and the trim it has drives that kit's pad", { act.('sa.drums.trim.steps.36', [\position, 1]);
        d.padTrim(\steps, 36) }.value, 12.0);
    d.setKit(\steps, 'mt-steps');

    // ---------------------------------------------- SA's, after chain edits --
    // A removed device's controls are not there and drive nothing; undo
    // brings them back; a moved one keeps them; a second Delay is no control
    // yet (its own come with phase 4), and the ids' high-water mark keeps the
    // Delay's footswitch off any device but the first Delay.
    {
        var delayIds = targets.keys.asArray.select { |id|
            (id == 'sa.fxOn.delay') or: { id == 'sa.fxReset.delay' } or: { id == 'sa.fxRandom.delay' } or: { MegaSAFx.param(id.asString.drop(6).asSymbol)
                !? { |q| id.asString.beginsWith("sa.fx.") and: { q[\fx] == \delay } } ? false } };
        var before = count.(there), n, d2;
        ~tEq.("(the Delay's own controls: its switch, its 8 settings, its Live values, its Random)", delayIds.size, 11);
        sa.removeDevice(\delay);
        ~tEq.("a removed device's controls are not there: the Delay's 11, and no other",
            [delayIds.select { |id| there.(targets[id]) }, before - count.(there)], [[], 11]);
        n = stub[\msgs].size + stub[\bundles].size;
        got = heard.(sa, {
            act.('sa.fxOn.delay', [\flip]);
            act.('sa.fxOn.delay', [\set, true]);
            act.('sa.fx.delayMix', [\position, 0.5]);
            act.('sa.fx.delayTimeR', [\position, 0.5]);
            act.('sa.fxReset.delay', [\fire]);
        });
        ~tEq.("...and driven anyway they do nothing: nothing said, nothing sent",
            [got, (stub[\msgs].size + stub[\bundles].size) - n], [[], 0]);
        ~tEq.("...their reading is no reading", [targets['sa.fxOn.delay'][\get].value, targets['sa.fx.delayMix'][\get].value],
            [nil, nil]);
        ~tAssert.("...while its synth is gone, and undo can bring it back", sa.canUndo and: { sa.limboDevices.isEmpty });
        sa.undo;
        ~tEq.("undo brings them back", [delayIds.every { |id| there.(targets[id]) }, count.(there)], [true, before]);
        got = heard.(sa, { act.('sa.fxOn.delay', [\flip]) });
        ~tEq.("...and the footswitch drives the Delay again, in its own synth",
            [got, ~tLastSet.(sa, sa.fxNode(\delay), \delayOn)], [[[\fx, \delay, true]], 1]);
        act.('sa.fxOn.delay', [\flip]);
        sa.moveDevice(\delay, \guitar, 0);
        got = heard.(sa, { act.('sa.fx.delayMix', [\position, 0.25]) });
        // (Stamped after the move, which is still on its way: ~tLastSet reads
        // the bundles too.)
        ~tEq.("a moved device keeps its controls: they reach it where it is now",
            [got.collect(_.first), ~tLastSet.(sa, sa.fxNode(\delay), \delayMix)], [[\fxParam], sa.fxParam(\delayMix)]);
        d2 = sa.insertDevice(\guitar, nil, \delay);
        ~tEq.("a second Delay has its own controls, built again after the insert: the effects' 176 and its eleven",
            { var now = ~midiTargetsBuild.();
              [now.keys.asArray.count { |id| id.asString.beginsWith("sa.fx") }, now.includesKey('sa.fxOn.delay2')] }.value,
            [187, true]);
        act.('sa.fx.delayTimeR', [\position, 0.75]);
        ~tAssert.("...and the Delay's settings still drive the first Delay, never the second",
            (d2.param(\delayTimeR) == MegaSAFx.param(\delayTimeR)[\spec].default)
                and: { sa.fxParam(\delayTimeR) != d2.param(\delayTimeR) });
        sa.removeDevice(\delay);
        d2 = sa.insertDevice(\guitar, nil, \delay);
        ~tEq.("with the first Delay removed, a new one is never the first's id: the Delay's footswitch finds no device",
            [d2.id, there.(targets['sa.fxOn.delay'])], [\delay3, false]);
        4.do { sa.undo };
        ~tEq.("(undone back to the chains as they were)", [sa.guitarChain.ids.keep(4), there.(targets['sa.fxOn.delay'])],
            [MegaSAFx.guitarKeys, true]);
    }.value;

    // ---- the effects' controls are made from the chains (docs/dev/device-chains.md, phase 4) ----
    ~megaSA = sa;
    // (The guitar chain: this MegaSA has no Looper, so its loop chain is not built.)
    v = sa.insertDevice(\guitar, nil, \delay);
    id2 = v !? { |x| x.id };
    tid = { |a, b| (a ++ id2 ++ (b ? "")).asSymbol };
    before = v !? { |x| x.name };
    t = ~midiTargetsBuild.();
    ~tEq.("a second Delay has its own switch, settings and Reset, under its own id",
        [v.notNil, t[tid.("sa.fxOn.")].notNil, t[tid.("sa.fx.", ".delayMix")].notNil, t[tid.("sa.fxReset.")].notNil,
            t.keys.count { |id| id.asString.beginsWith(("sa.fx." ++ id2 ++ ".")) }],
        [true, true, true, true, MegaSAFx.paramsOf(\delay).size]);
    ~tEq.("...each named by its device, so no two rows read alike",
        [t[tid.("sa.fx.", ".delayMix")][\group], t['sa.fx.delayMix'][\group], t[tid.("sa.fxOn.")][\label], before == sa.device(\delay).name],
        [before, sa.device(\delay).name, before, false]);
    ~tEq.("in the picker, still no two controls of one tab and group share a label",
        t.values.collect { |x| x[\path] ++ " / " ++ (x[\group] ? "") ++ " / " ++ x[\label] }.asSet.size, t.size);
    got = [sa.device(\delay).param(\delayMix), sa.fx(\delay)];
    t[tid.("sa.fx.", ".delayMix")][\set].(0.37);
    t[tid.("sa.fxOn.")][\set].(sa.fx(\delay).not);
    ~tEq.("its controls drive it, and not the first Delay",
        [(t[tid.("sa.fx.", ".delayMix")][\get].value - 0.37).abs < 1e-6, sa.fx(id2), sa.device(\delay).param(\delayMix), sa.fx(\delay)],
        [true, got[1].not] ++ got);
    t[tid.("sa.fxOn.")][\flip].value;
    ~tEq.("...its switch flips it", sa.fx(id2), got[1]);
    t[tid.("sa.fxReset.")][\fire].value;
    ~tEq.("...and its Reset puts its settings back", [sa.fxEdited(id2), t[tid.("sa.fxReset.")][\label]], [false, "Reset"]);
    // One family alone, as a chain edit asks for it.
    got = ~midiTargetsBuild.(\effects);
    ~tEq.("the effects' family alone is every control of the effects and no other",
        [got.keys.asArray.sort, got.keys.count { |id| id.asString.beginsWith("sa.fx").not }],
        [t.keys.asArray.select { |id| id.asString.beginsWith("sa.fx") }.sort, 0]);
    // Timed one by one, judged by the median: a chain edit makes them once, and
    // a collection pause in the language lands on one build of twenty, which
    // a mean takes for the cost of all. (With sixteen effects they took 8 to
    // 16 ms, until each name stopped being found by a caught throw: under 1.)
    v = 20.collect {
        var t0 = Main.elapsedTime;
        ~midiTargetsBuild.(\effects);
        Main.elapsedTime - t0
    }.sort;
    ("  the effects' controls are made in " ++ (v[10] * 1000).round(0.01) ++ " ms (median; mean "
        ++ (v.mean * 1000).round(0.01) ++ ", slowest " ++ (v.last * 1000).round(0.01) ++ ")").postln;
    ~tAssert.("...made in under 10 ms", v[10] < 0.01);
    // After a chain edit: only they are made again, and a removed device's stay.
    keptTargets = ~midiTargets;
    ~midiTargets = t;
    sa.removeDevice(id2);
    ~midiTargetsRefresh.(\effects);
    ~tEq.("after a chain edit only the effects' controls are made again",
        [~midiTargets['looper.trigger'] === t['looper.trigger'], ~midiTargets['sa.fx.delayMix'] === t['sa.fx.delayMix']], [true, false]);
    ~tEq.("a removed device's controls stay, not there, and say why; one that is there says nothing",
        [~midiTargets[tid.("sa.fxOn.")].notNil, ~midiTargets[tid.("sa.fxOn.")][\available].value, ~midiTargetWhy.(tid.("sa.fxOn.")),
            ~midiTargetWhy.(tid.("sa.fx.", ".delayMix")), ~midiTargetWhy.('sa.fx.delayMix')],
        [true, false, before ++ " is not in the chains now", before ++ " is not in the chains now", nil]);
    got = sa.device(\delay).param(\delayMix);
    ~tEq.("...and drive nothing, without throwing",
        [~tCheck.("a removed device's controls can be driven", { ~midiTargets[tid.("sa.fx.", ".delayMix")][\set].(0.9);
            ~midiTargets[tid.("sa.fxOn.")][\flip].value; ~midiTargets[tid.("sa.fxReset.")][\fire].value; true }),
            sa.device(id2), sa.device(\delay).param(\delayMix)], [true, nil, got]);
    sa.undo;
    ~midiTargetsRefresh.(\effects);
    ~tEq.("Undo brings them back", [~midiTargets[tid.("sa.fxOn.")][\available].value, ~midiTargetWhy.(tid.("sa.fxOn."))], [true, nil]);
    ~tEq.("a control of an effect no chain ever held says that; one this megalooper never had, that",
        [~midiTargetWhy.('sa.fxOn.redux7'), ~midiTargetWhy.('looper.nothing')],
        ["its effect is not in the chains now", "not in this megalooper"]);
    ~tEq.("a setting's words carry its device; a switch's and another tab's are as they were",
        [~midiTargetLabel.(tid.("sa.fx.", ".delayMix")), ~midiTargetLabel.(tid.("sa.fxOn.")), ~midiTargetLabel.('looper.trigger')],
        [before ++ " › " ++ t['sa.fx.delayMix'][\label], before, t['looper.trigger'][\label]]);
    ~megaSA = nil;
    ~tEq.("with no Megalooper SA the reason is that", ~midiTargetWhy.('sa.fxOn.delay'), "This rig has no effect chains");
    ~tEq.("...and the family is every type's first device's, from the table", ~midiTargetsBuild.(\effects).size, 176);
    ~megaSA = sa;
    sa.undo;
    ~midiTargets = keptTargets;
    sa.renameDevice(\delay, "Slap");
    got = ~midiTargetsBuild.(\effects);
    ~tEq.("a default device renamed names its controls too", [got['sa.fx.delayMix'][\group], got['sa.fxOn.delay'][\label],
        got['sa.fxReset.delay'][\group]], ["Slap", "Slap", "Slap"]);
    sa.renameDevice(\delay, MegaSAFx.title(\delay));

    // A plugin's sends (MegaSA.pluginSend): megalooper hears the controllers,
    // a hosted plugin does not, so a footswitch on a send passes the plugin
    // a controller for its own MIDI learn.
    ~tEq.("with no plugin in the chains there are no sends in the map",
        ~midiTargetsBuild.().keys.count { |id| id.asString.beginsWith("sa.fxSend.") }, 0);
    if(\VSTPlugin.asClass.isNil) { ~tSkip.("a plugin's sends in the map", "VSTPlugin is not installed here") } {
        var fake = ~tFakePlugin.(\open, "Amp"), sap = ~tMegaSA.(nil, fake), was = ~megaSA, tt, one;
        var called = sap.device(\plugin1).name.asString;
        ~megaSA = sap;
        tt = ~midiTargetsBuild.();
        one = tt['sa.fxSend.plugin1.3'] ? ();
        ~tEq.("a plugin in the chains has eight sends in the map, under its device's id",
            tt.keys.asArray.select { |id| id.asString.beginsWith("sa.fxSend.") }.sort,
            (1..8).collect { |n| ("sa.fxSend.plugin1." ++ n).asSymbol });
        ~tEq.("...each a trigger named by its number and the controller it sends, under the plugin's name, on the Effects tab",
            [one[\label], one[\group], one[\path], one[\kind], called.notEmpty], ["Send 3 (CC 22)", called, "Effects", \trigger, true]);
        ~tEq.("...there while the plugin is in the chains", there.(one), true);
        one[\fire].value;
        ~tEq.("firing one sends the plugin that controller, value 127 on channel 1", fake[\controls], [[0, 22, 127]]);
        ~tEq.("the effects' own refresh makes them again: their ids start as the effects' do",
            (1..8).every { |n| ~midiTargetsBuild.(\effects).includesKey(("sa.fxSend.plugin1." ++ n).asSymbol) }, true);
        ~tEq.("in the picker no two of them read alike",
            (1..8).collect { |n| tt[("sa.fxSend.plugin1." ++ n).asSymbol][\label] }.asSet.size, 8);
        sap.removeDevice(\plugin1);
        one[\fire].value;
        ~tEq.("a removed plugin's send does nothing, is not there, and says why",
            [fake[\controls].size, there.(one), one[\why].value], [1, false, called ++ " is not in the chains now"]);
        ~megaSA = was;
        sap.free;
    };

    // A kit given but still loading is read from its file for the trims, and
    // they are not there until it is in force.
    v = MegaSADrums(sa);
    v.kitDir = tmp;
    v.instVarPut(\kitRequested, (steps: 'mt-steps', onset: nil));
    ~megaSA = (drums: v);
    targets = ~tCheck.("the controls are made with a kit still loading", { ~midiTargetsBuild.() }) ? IdentityDictionary.new;
    ~tEq.("...its trims from its file, not there until it is in force",
        targets.keys.asArray.select { |id| id.asString.contains("rim.") }.sort.collect { |id| [id, there.(targets[id])] },
        [['sa.drums.groupTrim.steps.layer', false], ['sa.drums.trim.steps.36', false], ['sa.drums.trim.steps.38', false],
            ['sa.drums.trim.steps.42', false]]);
    v.free;

    // ---------------------------------------------- the router drives them --
    ~megaSA = sa;
    targets = ~midiTargetsBuild.();
    map = LooperMidiMap([(msg: \cc, num: 20, target: 'sa.fx.echoMix'), (msg: \program, num: 30, target: 'sa.mute.guitar'),
        (msg: \note, num: 70, target: 'looper.bbcutMode'), (msg: \cc, num: 21, target: 'sa.drums.main.lane1.note'),
        (msg: \cc, num: 22, target: 'sa.level.guitar', min: -12, max: 0)], "test");
    warned = IdentitySet.new;
    route = { |msg, num, val| ~midiRouteWith.(map, targets, msg, 0, num, val, 1001, nil, warned) };
    route.(\cc, 20, 127);
    route.(\program, 30, nil);
    route.(\noteOn, 70, 100);
    route.(\cc, 21, 127);
    route.(\cc, 22, 0);
    ~tEq.("through the router: a CC sets an effect's Dry/Wet, a PC mutes the guitar, a note moves the mode on, "
        "a CC picks a lane's pad, a strip's knob covers its own range",
        [sa.fxParam(\echoMix), sa.mute(\guitar), l.bbcutMode, d.laneParam(\main, 0, \note), sa.level(\guitar).ampdb.round(1e-9),
            warned.size], [1.0, true, \gate, 51, -12, 0]);

    // ---------------------------------------------------- no model at all --
    ~looper = nil;
    ~megaSA = nil;
    ~liveRecordToggle = nil;
    targets = ~tCheck.("the controls are made with no Looper and no SA", { ~midiTargetsBuild.() }) ? IdentityDictionary.new;
    ~tEq.("with no model nothing is there", targets.keys.asArray.select { |id| there.(targets[id]) }, []);
    ~tEq.("...and nothing throws: not whether it is there, not its value, not its readout",
        targets.keys.asArray.select { |id|
            var x = targets[id];
            (try { x[\available].value; x[\get].value; x[\format] !? { |f| f.value(x[\get].value) }; false } { true })
        }, []);
    ~tEq.("...a value it has none of reads as a dash",
        targets.values.select { |x| x[\format].notNil }.collect { |x| x[\format].value(nil) }.asSet.asArray, ["—"]);
    // A MegaSA with no drums, then an Event standing in for one, as the
    // equivalence test makes it: the drums' are not there, and nothing throws.
    ~megaSA = MegaSA.newCopyArgs(stub, 0, 0);
    targets = ~tCheck.("the controls are made beside a MegaSA with no drums", { ~midiTargetsBuild.() }) ? IdentityDictionary.new;
    ~tEq.("...where the drums' are not there, and nothing throws",
        targets.keys.asArray.select { |id|
            var x = targets[id];
            id.asString.beginsWith("sa.drums.") and: {
                (try { there.(x) or: { x[\format] !? { |f| f.value(x[\get].value) }; false } } { true }) }
        }, []);
    ~megaSA = (drums: (on: true), fx: { |self, key| false });
    targets = ~tCheck.("...and beside an Event standing in for one", { ~midiTargetsBuild.() }) ? IdentityDictionary.new;
    ~tEq.("...with no trims made from it, and nothing throwing",
        [targets.keys.count { |id| id.asString.contains("rim.") },
            targets.keys.asArray.select { |id|
                var x = targets[id];
                (try { x[\available].value; x[\get].value; x[\format] !? { |f| f.value(x[\get].value) }; false } { true })
            }], [0, []]);
} {
    ~looper = saved[0]; ~megaSA = saved[1]; ~liveRecordToggle = saved[2]; ~liveRecordSet = saved[3]; ~rp = saved[4];
    d !? { |x| x.free };
    sa !? { |x| x.free };
    ~tRemoveTree.(tmp);
};
}.value;
