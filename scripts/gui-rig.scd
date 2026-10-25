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
    var tip = "An AI app that speaks MCP (Claude Desktop, for one) can read the set and change the\n"
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

~buildRigPane = {
    var pane = View().background_(~gt[\bg]);
    var l = ~looper;
    var ms = { |v| v.round(0.1).asString ++ " ms" };
    // "Analysis in" said what the menu below says: the menu stays.
    ~statusAnalysisLabel = nil;
    pane.layout_(VLayout(
        ~guiTitle.("Rig", 24),
        // ---- What is actually connected -----------------------------------
        ~rigRow.("Profile", ~statusProfileLabel = ~guiText.((~routingProfile ? "—").asString, 15, nil, true)),
        ~rigRow.("Device", ~statusDeviceLabel = ~guiText.(((~rp !? { |r| r[\device] }) ? "—").asString, 15, nil, true)),
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
                "attacks, better meter detection, and Live is not in the path at all.")
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
