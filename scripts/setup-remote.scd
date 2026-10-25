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
// Looper and SA, the preset folders, the Grains view's rows (their tips are
// what the AI is told), and the status line it speaks in.

~remotePrefKey = "aiApps";

~remoteOn = { (~guiPrefSaved !? { |f| f.value(~remotePrefKey) }) == "on" };

~remoteSource = {
    (looper: ~looper, sa: ~megaSA, profile: ~routingProfile, drumsPresetDir: ~saDrumsPresetDir,
        synthPresetDir: ~saSynthPresetDir, soundDir: ~saFxPresetDir, grainsPresetDir: ~granularPresetDir,
        cutterPresetDir: ~bbcutPresetDir, grainParams: ~granularParams,
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

// ---- Connecting an app ---------------------------------------------------------------
// The Setup view's two ways (docs/ai.md):
//
//   ~remoteInstallExtension.()  Claude Desktop's extension (megalooper.mcpb)
//                               made by tools/make-mcpb.sh in megalooper's
//                               folder and opened: Claude Desktop asks to
//                               install it. macOS; nothing to install first.
//   ~remoteCopyConfig.()        the config an app adds, with this Mac's
//                               python3 and the bridge's path, on the
//                               clipboard
//
// ~remoteOpen and ~remoteClipboard, the commands they end with, are the
// checks' to replace.

~remoteRepo = { ~megalooperRoot ?? { Looper.repoRoot } };
~remoteOpen = "/usr/bin/open";
~remoteClipboard = nil;

// The python3 an app should run the bridge with: Homebrew's if it is there,
// else the system's (which asks to install Apple's command line tools the
// first time, if they are not in).
~remotePython = {
    MegaFiles.commandPath(["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3", "python3"])
        ? "python3"
};

~remoteConfigText = {
    "{\n  \"mcpServers\": {\n    \"megalooper\": {\n      \"command\": " ++ MegaFiles.jsonString(~remotePython.())
        ++ ",\n      \"args\": [" ++ MegaFiles.jsonString(~remoteRepo.() +/+ "tools" +/+ "megalooper-mcp.py")
        ++ "]\n    }\n  }\n}\n"
};

~remoteCopyConfig = {
    var cmd = ~remoteClipboard ?? { MegaFiles.clipboardCommand };
    var say = { |msg, kind| { ~guiSay !? { |f| f.value(msg, kind) } }.defer };
    if(cmd.isNil) { say.("No clipboard here: the config is in docs/ai.md", \bad) } {
        ("printf '%s' " ++ ~remoteConfigText.().shellQuote ++ " | " ++ cmd).unixCmd({ |code|
            if(code == 0) { say.("Copied: paste it into the app's config (Claude Desktop: Settings > Developer > Edit Config)") }
                { say.("The config was not copied (" ++ code ++ ")", \bad) };
        }, false);
    };
};

~remoteInstallExtension = {
    var out = MegaFiles.userRoot +/+ "megalooper.mcpb";
    var say = { |msg, kind| { ~guiSay !? { |f| f.value(msg, kind) } }.defer };
    say.("Making the extension…");
    ((~remoteRepo.() +/+ "tools" +/+ "make-mcpb.sh").shellQuote ++ " " ++ out.shellQuote).unixCmd({ |code|
        if(code != 0) { say.("The extension was not made (" ++ code ++ "; the post window says why)", \bad) } {
            (~remoteOpen ++ " " ++ out.shellQuote).unixCmd({ |opened|
                if(opened == 0) { say.("Claude Desktop asks to install megalooper: say Install") }
                    { say.("Claude Desktop did not open it: is it installed? The extension is " ++ out, \bad) };
            }, false);
        };
    }, false);
};
