// megalooper as a tool for an AI app (docs/ai.md): the switch that lets one
// in, and Revert, the AI's newest change taken back from the window.
//
// An AI app that speaks MCP (Claude Desktop, for one) starts
// tools/megalooper-mcp.py, which asks MegaRemote, inside megalooper, over
// this Mac's own network. MegaRemote runs only while the Setup view's AI
// APPS switch is on. It is off until you switch it on, and the choice is
// kept in settings.json beside the theme.
//
//   ~remoteApply.()     MegaRemote started or stopped as settings.json says
//                       (boot.scd, after the window)
//   ~remoteSet.(true)   the switch on, kept; false off
//   ~remoteRevert.()    the AI's newest change taken back (the footer's
//                       Revert); what went wrong is said in the status line
//
// What MegaRemote reads and changes it gets from ~remoteSource: the running
// Looper and SA, the preset folders, and the status line it speaks in.

~remotePrefKey = "aiApps";

~remoteOn = { (~guiPrefSaved !? { |f| f.value(~remotePrefKey) }) == "on" };

~remoteSource = {
    (looper: ~looper, sa: ~megaSA, profile: ~routingProfile, drumsPresetDir: ~saDrumsPresetDir,
        synthPresetDir: ~saSynthPresetDir, soundDir: ~saFxPresetDir,
        say: { |msg| ~guiSay !? { |f| f.value(msg) } }.inEnvir)
};

// Stops whatever runs, then starts a MegaRemote afresh if the switch is on:
// a boot run again, or the switch turned on, begins with no changes to
// revert. The window's Revert and the switch follow.
~remoteApply = {
    ~remoteWatcher !? { |w| w.remove };
    ~remoteWatcher = nil;
    ~megaRemote !? { |r| r.stop };
    ~megaRemote = nil;
    if(~remoteOn.()) {
        ~megaRemote = MegaRemote(~remoteSource.inEnvir).start;
        ~remoteWatcher = SimpleController(~megaRemote)
            .put(\aiChanges, { { ~guiAiPaint !? { |f| f.value } }.defer });
    };
    ~guiAiPaint !? { |f| f.value };
};

~remoteSet = { |on|
    on = on == true;
    if(on != ~remoteOn.()) {
        ~guiPrefSave !? { |f| f.value(~remotePrefKey, if(on) { "on" } { "off" }, "the AI apps switch") };
        ~remoteApply.();
        ~guiSay !? { |f| f.value(if(on) { "AI apps may connect" } { "AI apps are shut out" }) };
    };
};

~remoteRevert = {
    var answer = ~megaRemote !? { |r| r.revert(nil) };
    if(answer.notNil and: { answer.at("ok") != true }) {
        ~guiSay !? { |f| f.value(answer.at("error"), \bad) };
    };
};
