// megalooper — the Rig column of the Setup view: what this machine is plugged
// into, the three numbers trimmed per rig, Megalooper SA's levels and the MIDI
// map.
//
// Loaded by boot.scd; defines only, runs nothing. Entry point:
//   ~buildRigPane — builds a fresh Rig pane against the EXISTING ~looper and
//                   swaps it into the shell's holder. Safe to re-run; it never
//                   touches the model. Follow with ~wireLooperController.().
//
// Everything here is set once for a rig and then left alone, which is exactly
// why it does not belong beside the transport. The one reason to come back
// mid-session is that something sounds wrong — so the rows that say WHAT is
// actually connected sit at the top, and the MIDI monitor beside this column
// says whether the controller is even being heard.
//
// Reads ~routingProfile / ~rp / ~analysisChannel, which ~applyRoutingProfile
// sets, so it cannot be built before the routing profile is resolved.
(
~rigLabelWidth = 130;
// A row: what it is in \mute, its value or control on the right, a rule under.
// What the Looper's transport drives on this rig: (label:, items:, tip:), or
// nil for a rig where it drives nothing.
~rigTransportWords = { |rp|
    case
    { rp.isNil or: { rp[\live] != false } } {
        (label: "Live transport", items: ~transportModeLabels, tip: "Whether the looper drives Live's transport at all.") }
    { rp[\sa] == true } {
        (label: "Drums follow the loop", items: ["Start + Stop", "Start only", "Off"],
            tip: "Whether the drums start and stop with the loop. Start only: they play on after a stop.\n"
                "Off: they do not start.") }
    { nil }
};
~rigTransportRow = {
    var words = ~rigTransportWords.(~rp);
    if(words.isNil) { ~transportModeSeg = nil; View().fixedHeight_(0) } {
        // The switch under its label: beside it, "Drums follow the loop" and
        // three options made the Rig column too wide for a 1440 window.
        View().layout_(VLayout(
            ~guiLabel.(words[\label], 14).toolTip_(words[\tip]),
            HLayout((~transportModeSeg = ~guiSeg.(words[\items], (height: 28, font: ~guiSans.(13),
                action: { |i| ~looper !? { |lp| lp.transportMode = ~transportModes[i] } })))[\view].fixedWidth_(300)
                .toolTip_(words[\tip]), nil).margins_(0),
            ~guiRule.()
        ).margins_(0).spacing_(8))
    }
};

~rigRow = { |label, value|
    View().layout_(VLayout(
        HLayout(~guiLabel.(label, 14), nil, value).margins_(0).spacing_(10),
        ~guiRule.()
    ).margins_(0).spacing_(8))
};
// A timing bar: label and value over a bar in \ink, with its neutral mark.
~rigTiming = { |label, bar, value, tip|
    bar.toolTip_(tip);
    VLayout(
        HLayout(~guiLabel.(label, 14).toolTip_(tip), nil, value).margins_(0),
        bar
    ).spacing_(5).margins_(0)
};

// AI apps let in or not (setup-remote.scd): the switch, kept in
// settings.json, and what it does. Off until switched on.
~rigAiSection = {
    var tip = "An AI app that speaks MCP (Claude Desktop, for one) can read what megalooper is doing and change the\n"
        "drums, the synth and the effects while this is on. Only apps on this Mac; plugins stay\n"
        "yours. Every change it makes can be taken back with Revert, at the bottom of the window.\n"
        "How to connect one: the buttons below, or docs/ai.md.";
    var small = { |label, what, tipText|
        LooperTile().border_(~gt[\line]).font_(~guiSans.(13)).fixedHeight_(26).pad_(8)
            .states_([[label]]).toolTip_(tipText).action_({ what.value })
    };
    ~remoteSeg = ~guiSeg.(["Off", "On"], (height: 28, font: ~guiSans.(13),
        action: { |i| ~remoteSet !? { |f| f.value(i == 1) } }));
    ~guiSegSet.(~remoteSeg, ((~remoteOn !? { |f| f.value }) == true).binaryValue);
    ~remoteInstallTile = small.("Install in Claude Desktop", { ~remoteInstallExtension.() },
        "Makes megalooper's extension and hands it to Claude Desktop, which asks to install it.\n"
            "Nothing else to install: Claude Desktop runs it itself. Once is enough.");
    ~remoteCopyTile = small.("Copy config", { ~remoteCopyConfig.() },
        "For any other app that speaks MCP: its config for megalooper, with this Mac's paths,\n"
            "on the clipboard. It runs tools/megalooper-mcp.py, which needs Python 3.");
    View().layout_(VLayout(
        ~guiCaption.("AI APPS", 11),
        ~rigRow.("Let AI apps in", ~remoteSeg[\view].fixedWidth_(170).toolTip_(tip)),
        ~rigRow.("Connect an app", View().layout_(HLayout(
            if(MegaFiles.isMac) { ~remoteInstallTile } { ~remoteInstallTile.visible_(false) }, ~remoteCopyTile
        ).margins_(0).spacing_(8))),
        ~guiHint.("Claude Desktop and other MCP apps: they change, you hear it, Revert takes it back. docs/ai.md says how.")
            .toolTip_(tip)
    ).margins_(0).spacing_(8))
};

// Log every action (setup-actions.scd): every change into Record set's log,
// for AI apps and replays. The switch, kept in settings.json, and what it
// costs; off, nothing listens. Under AI APPS on Setup's MIDI & AI page.
~actionsPaint = {
    ~actionsSeg !? { |s| ~guiSegSet.(s, ((~actionsOn !? { |f| f.value }) == true).binaryValue) };
};
// The cost, measured headless on an M1 (2026-10-30): three controls turned at
// MIDI's 60 a second took 1.6 % of the language's time, the clock's 99th
// percentile unmoved; nothing turning, nothing.
~actionsHint = "Every change, yours and an AI app's, in the set's log: for AI apps and replays. "
    "While knobs turn it takes under 2 % of the language's time; off, nothing.";
~actionsSection = {
    var tip = "Every change you make, and every one an AI app makes, goes into Record set's log, with how\n"
        "everything is set when the set starts and once a part has settled after a change. AI apps can\n"
        "then say what you did in a set, bring a moment of it back, and see what you just did.\n"
        "docs/manual.md, Every action.";
    var view;
    ~actionsSeg = ~guiSeg.(["Off", "On"], (height: 28, font: ~guiSans.(13),
        action: { |i| ~actionsSet !? { |f| f.value(i == 1) } }));
    view = View().layout_(VLayout(
        ~guiCaption.("RECORD SET", 11),
        ~rigRow.("Log every action", ~actionsSeg[\view].fixedWidth_(170).toolTip_(tip)),
        ~guiHint.(~actionsHint).toolTip_(tip)
    ).margins_(0).spacing_(8));
    ~actionsPaint.();
    view
};

// AUDIO: on saSystem the devices and inputs it plays on, chosen here as in
// the launcher (setup-routing.scd's audio settings), and Apply and restart:
// the device is fixed when the server starts, so a change starts megalooper
// again on it (~audioApply), after a second click. On a rig of yours
// (profiles.scd) its name and device, which the profile says.
~rigAudioMenu = { |width|
    PopUpMenu().canFocus_(false).font_(~guiSans.(14)).background_(~gt[\panel]).stringColor_(~gt[\ink])
        .fixedWidth_(width)
};
~rigAudioSection = {
    var rp = ~rp, chosen, devs, entriesIn, entriesOut, now, fillInputs, paint, armed = false, armGen = 0;
    var restartWords = "Changing the audio starts megalooper again on it: the loop goes, and the effects, "
        "drums and synth come back as kept (Keep on their views).";
    var notes = (rp !? { |r| r[\audioNotes] } ? []);
    var noteText = ~guiText.(notes.join("\n"), 13, ~gt[\rec]).visible_(notes.notEmpty);
    if(rp.isNil or: { rp[\audioSettings] != true } or: { MegaFiles.isMac.not }) {
        View().layout_(VLayout(
            ~guiCaption.("AUDIO", 11),
            ~rigRow.("Profile", ~statusProfileLabel = ~guiText.((~routingProfile ? "—").asString, 15, nil, true)),
            ~rigRow.("Device", ~statusDeviceLabel = ~guiText.(~audioDeviceLabel.(rp), 15, nil, true)),
            ~guiHint.(if(MegaFiles.isMac) { "A rig of yours: its device and inputs are written in profiles.scd (docs/routing.md)." }
                { "JACK or PipeWire connects megalooper's inputs and outputs (docs/linux.md)." })
        ).margins_(0).spacing_(8))
    } {
    ~statusProfileLabel = nil;
    ~statusDeviceLabel = nil;
    chosen = (rp[\audio] ? ()).copy;
    devs = ~audioDevicesNow.();
    // What the menus say, as the audio settings.
    now = {
        (inDevice: entriesIn[~rigInDevMenu.value] !? { |e| e[\name] },
            outDevice: entriesOut[~rigOutDevMenu.value] !? { |e| e[\name] },
            inChannel: ~rigInstMenu.value ? 0,
            bassChannel: if((~rigBassMenu.value ? 0) > 0) { ~rigBassMenu.value - 1 },
            hardwareBufferSize: ~audioBuffers[~rigBufferMenu.value ? 0])
    };
    fillInputs = { |want|
        var count = ~audioInputCount.(devs, entriesIn[~rigInDevMenu.value] !? { |e| e[\name] });
        ~rigInstMenu.items = ~audioInputLabels.(count);
        ~rigInstMenu.value = (want[\inChannel] ? 0).clip(0, count - 1);
        ~rigBassMenu.items = ["None"] ++ ~audioInputLabels.(count);
        ~rigBassMenu.value = (want[\bassChannel] !? { |b| if(b < count) { b + 1 } }) ? 0;
    };
    // Apply only when the menus say something other than what plays.
    paint = {
        var changed = ~audioSettingsKeys.any { |k| now.()[k] != chosen[k] };
        if(changed.not) { armed = false };
        ~rigAudioApply.enabled_(changed)
            .states_([[if(armed) { "Click again to restart" } { "Apply and restart" }]])
            .border_(if(armed) { ~gt[\rec] } { ~gt[\line] });
    };
    ~rigInDevMenu = ~rigAudioMenu.(300).toolTip_("The device your instrument comes in on. System default follows the Mac's Sound settings.");
    ~rigOutDevMenu = ~rigAudioMenu.(300).toolTip_("The device the mix plays on, on its outputs 1 and 2.");
    ~rigInstMenu = ~rigAudioMenu.(120).toolTip_("The input your instrument is plugged into. The looper records it through the\n"
        "Instrument chain, and listens to it dry for the meter.");
    ~rigBassMenu = ~rigAudioMenu.(120).toolTip_("A bass on an input of its own, with a chain and a strip of its own.");
    ~rigBufferMenu = ~rigAudioMenu.(170).items_(~audioBuffers.collect { |n| ~audioBufferLabel.(n) })
        .toolTip_("The audio buffer. Bigger stops dropouts on a slower computer, and adds delay: run\n"
            "the Calibrate view's latency step after a change.");
    entriesIn = ~audioMenuEntries.(devs[\inputs], chosen[\inDevice], devs[\defaultIn], \in);
    entriesOut = ~audioMenuEntries.(devs[\outputs], chosen[\outDevice], devs[\defaultOut], \out);
    ~rigInDevMenu.items_(entriesIn.collect { |e| e[\label] }).value_(~audioMenuIndex.(entriesIn, chosen[\inDevice]));
    ~rigOutDevMenu.items_(entriesOut.collect { |e| e[\label] }).value_(~audioMenuIndex.(entriesOut, chosen[\outDevice]));
    ~rigBufferMenu.value = ~audioBuffers.indexOf(chosen[\hardwareBufferSize]) ? 0;
    fillInputs.(chosen);
    ~rigAudioApply = LooperTile().border_(~gt[\line]).font_(~guiSans.(13)).fixedHeight_(28).pad_(10)
        .states_([["Apply and restart"]]).toolTip_(restartWords)
        .action_({
            var why, gen;
            if(armed) {
                armed = false;
                why = ~audioApply.(now.());
                if(why.notNil) { ~guiSay !? { |f| f.value(why, \bad) }; paint.() } {
                    ~guiSay !? { |f| f.value("Starting again on " ++ ~audioDeviceLabel.(~audioProfile.(~routingProfiles[~routingProfile],
                        now.(), devs)) ++ "…") };
                    ~rigAudioApply.enabled_(false).states_([["Starting again…"]]);
                };
            } {
                armed = true;
                armGen = armGen + 1;
                gen = armGen;
                paint.();
                // A second click within four seconds, or it is as it was.
                AppClock.sched(4, { if(armed and: { gen == armGen }) { armed = false; paint.() }; nil });
            };
        });
    ~rigInDevMenu.action_({ fillInputs.(now.()); paint.() });
    [~rigOutDevMenu, ~rigInstMenu, ~rigBassMenu, ~rigBufferMenu].do { |m| m.action_({ paint.() }) };
    paint.();
    View().layout_(VLayout(
        ~guiCaption.("AUDIO", 11),
        ~rigRow.("Input device", ~rigInDevMenu),
        ~rigRow.("Output device", ~rigOutDevMenu),
        ~rigRow.("Instrument on", View().layout_(HLayout(~rigInstMenu, ~guiLabel.("Bass on", 14), ~rigBassMenu)
            .margins_(0).spacing_(10))),
        ~rigRow.("Buffer", ~rigBufferMenu),
        noteText,
        View().layout_(HLayout([~guiText.(restartWords, 13, ~gt[\mute]), stretch: 1], ~rigAudioApply).margins_(0).spacing_(12))
    ).margins_(0).spacing_(8))
    }
};

~buildRigPane = {
    var pane = View().background_(~gt[\bg]);
    var l = ~looper;
    var ms = { |v| v.round(0.1).asString ++ " ms" };
    // "Analysis in" said what the menu below says: the menu stays.
    ~statusAnalysisLabel = nil;
    pane.layout_(VLayout(
        ~guiTitle.("Rig", 24),
        // ---- What is actually connected -----------------------------------
        ~rigAudioSection.(),
        // Which input the onset/pitch detection listens to. The loop is
        // always RECORDED from the processed guitar on inChannel; this only
        // moves the ANALYSIS onto the guitar's dry hardware input, whose sharp
        // attacks fit a pulse grid far better than a distorted or reverbed
        // signal does. "Same as input" is the old single-stream behaviour, and
        // the thing to switch back to if the tap is silent (0 onsets on every
        // take).
        ~rigRow.("Listen for onsets on", ~analysisSourceMenu = PopUpMenu()
            .canFocus_(false).font_(~guiSans.(14)).background_(~gt[\panel]).stringColor_(~gt[\ink])
            .fixedWidth_(230)
            .toolTip_("Where onset + pitch detection listens. The recording itself is unaffected either way.\n"
                "Same as input: analyse the processed instrument being recorded.\n"
                "Clean tap: analyse the instrument's dry hardware input direct from the interface — crisper\n"
                "attacks, better meter detection, and none of the effects are in the path.")
            .items_([
                "Same as input (processed)",
                if(~analysisChannel.notNil) {
                    "Clean tap (dry, ch " ++ (~analysisChannel + 1) ++ ")"
                } {
                    "Clean tap (not in profile)"
                }])
            // No pair declared by this rig means there is nothing to switch
            // to; leave the menu inert rather than offering a choice that
            // would silently do nothing.
            .enabled_(~analysisChannel.notNil)
            .value_(if(l.notNil and: { l.analysisChannel.notNil and: { l.analysisChannel != l.inChannel } }) { 1 } { 0 })
            .action_({ |menu|
                ~looper !? { |lp| lp.analysisChannel = if(menu.value == 1) { ~analysisChannel } { nil } };
            })),
        ~rigRow.("Input", (~inChannelSeg = ~guiSeg.(~inChannelLabels, (height: 28, font: ~guiSans.(13),
            action: { |i| ~looper !? { |lp| lp.inChannelCount = ~inChannelCounts[i] } })))[\view].fixedWidth_(170)
            .toolTip_("How many channels the recorder reads from inChannel.")),
        // The Looper's transport is Live's on a Live rig and the drums' on SA
        // (MegaSATransport); standalone has neither, and no row.
        ~rigTransportRow.(),

        // ---- Timing, per rig ---------------------------------------------------
        // Three numbers trimmed by ear, per rig. Write them back into the
        // routing profile once they are right (the Calibrate wizard measures
        // them); check.scd fails if a profile holds a value these bars cannot
        // reach.
        ~guiCaption.("TIMING · PER RIG", 11),
        ~rigTiming.("Overdub latency",
            ~latencySlider = ~guiBar.(\ink, 16).neutral_(0)
                .value_((l !? { |lp| lp.latencyMs } ? 0) / ~latencyMax)
                .action_({ |sl|
                    var v = sl.value * ~latencyMax;
                    ~looper !? { |lp| lp.latencyMs = v };
                    ~latencyLabel.string_(ms.(v));
                }),
            ~latencyLabel = ~guiMonoText.(ms.(l !? { |lp| lp.latencyMs } ? 0), 14, ~gt[\ink]),
            "Round-trip audio latency. Shifts the overdub write head back by this much, so a note\n"
                "played in time with what you hear lands at the matching loop position. Too low and\n"
                "overdubs drag; too high and they rush."),
        // Bipolar — centre = 0 ms, left pulls Live earlier (negative), full
        // scale ±~syncMax. Applied to the Start on the next play, and slewed
        // into the running clock live, so sweep it by ear against Live's
        // metronome.
        View().layout_(~rigTiming.("Live sync · negative pulls Live earlier",
            ~syncSlider = ~guiBar.(\ink, 16).origin_(0.5).neutral_(0.5)
                .value_(((l !? { |lp| lp.abletonSyncMs } ? 0) / (2 * ~syncMax)) + 0.5)
                .action_({ |sl|
                    var v = (sl.value * 2 - 1) * ~syncMax;
                    ~looper !? { |lp| lp.abletonSyncMs = v };
                    ~syncLabel.string_((if(v > 0) { "+" } { "" }) ++ ms.(v));
                }),
            ~syncLabel = ~guiMonoText.(ms.(l !? { |lp| lp.abletonSyncMs } ? 0), 14, ~gt[\ink]),
            "Shifts WHEN the MIDI clock/Start is sent relative to the loop, to cancel the lag Live\n"
                "adds as a clock follower. Centre = 0 ms · full scale ±" ++ ~syncMax ++ " ms."))
            // Without Live there is nothing to pull: on SA the drums' Start
            // lands on the boundary whatever this says (MegaSATransport).
            .visible_((~rp !? { |r| r[\live] }) != false),
        ~rigTiming.("Declick at the loop seam",
            ~declickSlider = ~guiBar.(\ink, 16).neutral_(3 / ~declickMax)
                .value_((l !? { |lp| lp.declickMs } ? 0) / ~declickMax)
                .action_({ |sl|
                    var v = sl.value * ~declickMax;
                    ~looper !? { |lp| lp.declickMs = v };
                    ~declickLabel.string_(ms.(v));
                }),
            ~declickLabel = ~guiMonoText.(ms.(l !? { |lp| lp.declickMs } ? 0), 14, ~gt[\ink]),
            "Fade length at the loop seam. Higher = clicks reliably gone but a softer seam · lower =\n"
                "more of the original attack · about 3 ms (the mark) is a good default."),

        // Megalooper SA's levels; hidden on every other rig.
        ~buildSARigSection !? { |f| f.value } ?? { View().visible_(false) },
        nil
    ).margins_([22, 20, 22, 20]).spacing_(14));

    ~guiSegSet.(~inChannelSeg, ~inChannelCounts.indexOf(l !? { |lp| lp.inChannelCount }) ? 0);
    ~guiSegSet.(~transportModeSeg, ~transportModes.indexOf(l !? { |lp| lp.transportMode }) ? 0);
    // The menus the old pane had, for the code and checks that ask for them.
    ~inChannelMenu = ~inChannelSeg[\view];
    ~transportModeMenu = ~transportModeSeg !? { |s| s[\view] };
    ~rigPane = pane;
    ~guiSwapPane.(\rig, pane);
    pane
};

// Setup's MIDI & AI page, its left column: the MIDI map, its inputs,
// bindings and learning (gui-midimap.scd). The page's right column, AI APPS
// over the MIDI monitor, is the window's (gui-shell.scd).
~buildMidiPane = {
    var pane = View().background_(~gt[\bg]);
    pane.layout_(VLayout(
        ~buildMidiMapSection !? { |f| f.value } ?? { View().visible_(false) },
        nil
    ).margins_([22, 20, 22, 20]).spacing_(14));
    ~guiSwapPane.(\midi, pane);
    pane
};
)
