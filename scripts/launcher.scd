// megalooper — standalone launcher.
//
// The entry point when megalooper is started from the Desktop icon rather than
// from the SuperCollider IDE. Shows one window: pick a rig, press Start, the
// looper boots. Build the icon with tools/make-app.sh.
//
// Why a launcher at all: ~routingProfile is the one line that has to change per
// rig, and picking the wrong one aborts the boot with a banner nobody sees when
// there is no post window. So this asks first, and checks up front whether the
// profile's audio device is actually plugged in.
//
// It sets ~launcherProfile, which boot.scd prefers over its own default, and
// ~launcherBufferSize, the audio buffer in frames (nil: as the rig sets it),
// which setup-routing.scd prefers over the profile's. Running boot.scd from
// the IDE is unaffected: both are nil there.
//
// Under the Desktop icon there is no post window — stdout goes to
// ~/Library/Logs/megalooper.log (see tools/make-app.sh). The status line at the
// bottom of this window is therefore the only feedback the player gets, so
// every failure path has to write to it.
(
var scriptDir = thisProcess.nowExecutingPath !? { |p| p.dirname }
    ?? { Looper.repoRoot +/+ "scripts" };
var prefsPath = Platform.userAppSupportDir +/+ "megalooper-launcher.txt";
var profileKeys, deviceOf, presentDevices, isPresent, labelFor;
var lastUsed, startIdx, saved, lastBuffer;
var win, menu, bufferMenu, statusText, startButton, setStatus, refresh;
// The audio buffer, in frames: nil keeps what the rig sets (64 on the duo's
// TSMEGA, the device's own on the system's default). More frames give a slow
// computer more time for each block, so it drops out less, and add as much
// delay: 256 at 48 kHz are 5.3 ms each way.
var buffers = [nil, 64, 128, 256, 512, 1024];
var booted = false;
// An Apple Silicon Mac running this interpreter as Intel. megalooper.app
// starts sclang natively since tools/make-app.sh learnt to (macOS may run the
// script bundle under Rosetta on its own, with no checkbox to undo it), so this
// means an app built before that, or an Intel-only SuperCollider. Everything
// started from here, scsynth and every plugin, then runs translated too: about
// twice the CPU, and a slow first start after each SuperCollider update.
var translated = (Platform.architecture == \x86_64)
    and: { "sysctl -n hw.optional.arm64 2>/dev/null".unixCmdGetStdOut.stripWhiteSpace == "1" };
var rosettaNote = if(translated) {
    "\nUnder Rosetta: rebuild the app with tools/make-app.sh /Applications."
} { "" };

// The profile table is the single source of truth for both the launcher and
// boot.scd — load it rather than restating the rigs here, or the two lists
// drift apart the first time a rig is added.
(scriptDir +/+ "setup-routing.scd").load;
profileKeys = ~routingProfiles.keys.asArray.sort { |a, b| a.asString < b.asString };
if(translated) { ("megalooper: running under Rosetta." ++ rosettaNote).warn };

// \systemDefault is a sentinel, not a device name — there is nothing to look up
// and nothing that can be missing, so it reads as a description instead.
deviceOf = { |key|
    var dev = ~routingProfiles[key][\device];
    if(dev == \systemDefault) {
        if(MegaFiles.isLinux) { "system default (JACK or PipeWire)" } { "system default (built-in audio)" }
    } { dev.asString }
};

// Same lenient match the boot guard uses: SC truncates long / non-ASCII device
// names, so require only that either string contains the other.
presentDevices = { ~audioDeviceNames.() };
isPresent = { |key|
    var want = deviceOf.(key);
    // The system default is always there by definition.
    (~routingProfiles[key][\device] == \systemDefault) or: {
        presentDevices.value.any { |listed|
            (listed == want) or: { listed.contains(want) } or: { want.contains(listed) }
        }
    };
};

// The menu doubles as a rig inventory: a tick means that profile's device is
// plugged in right now, so the player can see at a glance which rig they are on.
labelFor = { |key|
    (if(isPresent.(key)) { "✓  " } { "✗  " }) ++ key.asString ++ "   — " ++ deviceOf.(key)
};

// Remember the last rig and buffer across launches. A plain file, the rig on
// its first line and the buffer on its second (a file from before has only
// the rig): this runs before any Looper exists, so there is nothing heavier
// to hang it on.
saved = if(File.exists(prefsPath)) { File.readAllString(prefsPath).split($\n) } { [] };
lastUsed = saved[0] !? { |x| x.stripWhiteSpace.asSymbol };
lastBuffer = saved[1] !? { |x| x.stripWhiteSpace.asInteger };
// Preference order: the rig used last, then the editor default from
// setup-routing.scd, then whatever is actually plugged in, then slot 0.
startIdx = profileKeys.indexOf(lastUsed)
    ?? { profileKeys.indexOf(~defaultRoutingProfile) }
    ?? { profileKeys.detectIndex { |k| isPresent.(k) } } ? 0;

win = Window("megalooper", Rect(240, 320, 460, 240)).userCanClose_(true);

setStatus = { |str, isError = false|
    statusText.string_(str).stringColor_(
        if(isError) { Color.new(0.7, 0.15, 0.15) } { Color.gray(0.35) });
};

// Rescan CoreAudio. Devices come and go while this window is open — plugging
// the interface in after launching is the normal case, not the exception.
refresh = {
    var keep = menu.value;
    menu.items = profileKeys.collect { |k| labelFor.(k) };
    menu.value = keep.clip(0, profileKeys.size - 1);
    if(booted.not) {
        if(isPresent.(profileKeys[menu.value])) {
            setStatus.("Ready — " ++ deviceOf.(profileKeys[menu.value]) ++ " is connected.\n"
                ++ ~routingProfileSays.(profileKeys[menu.value]) ++ rosettaNote);
        } {
            setStatus.("\"" ++ deviceOf.(profileKeys[menu.value])
                ++ "\" is not connected. Plug it in and press Rescan." ++ rosettaNote, true);
        };
    };
};

win.layout_(VLayout(
    StaticText()
        .string_("megalooper")
        .font_(Font(Font.defaultSansFace, 22, true))
        .align_(\left),
    StaticText()
        .string_("Pick the rig you are playing on, then start.")
        .stringColor_(Color.gray(0.4))
        .align_(\left),
    HLayout(
        StaticText().string_("Rig:").align_(\right).fixedWidth_(50),
        menu = PopUpMenu()
            .canFocus_(false)
            .toolTip_("Routing profile: which audio device megalooper plays on, and where your\n"
                "instrument comes in. ✓ = that device is connected right now. Rigs of your own\n"
                "go in profiles.scd (docs/routing.md).")
            .action_({ refresh.() }),
        Button()
            .canFocus_(false)
            .fixedWidth_(80)
            .toolTip_("Re-scan CoreAudio for devices plugged in since this window opened.")
            .states_([["Rescan"]])
            .action_({ refresh.() })
    ),
    HLayout(
        StaticText().string_("Buffer:").align_(\right).fixedWidth_(50),
        bufferMenu = PopUpMenu()
            .canFocus_(false)
            .items_(buffers.collect { |n| if(n.isNil) { "as the rig sets it" } { n.asString ++ " frames" } })
            .toolTip_("The audio buffer. On a slower computer a bigger one stops dropouts\n"
                "(clicks, gaps) and adds delay: 256 frames at 48 kHz are 5 ms each way.\n"
                "After a change, run the latency step on the Calibrate view,\n"
                "so that overdubs land in time.")
    ),
    HLayout(
        startButton = Button()
            .canFocus_(false)
            .toolTip_("Boot the server with the selected rig and open the looper windows.")
            .states_([["Start megalooper", Color.white, Color.new(0.2, 0.55, 0.3)]])
            .action_({
                var key = profileKeys[menu.value];
                if(booted) {
                    setStatus.("Already running — quit and relaunch to change rig.", true);
                } {
                    if(isPresent.(key).not) {
                        setStatus.("Cannot start: \"" ++ deviceOf.(key)
                            ++ "\" is not connected.", true);
                    } {
                        booted = true;
                        // boot.scd reads these in preference to its own defaults.
                        ~launcherProfile = key;
                        ~launcherBufferSize = buffers[bufferMenu.value];
                        protect { File.use(prefsPath, "w", { |f|
                            f.write(key.asString ++ "\n" ++ (~launcherBufferSize ? "").asString) }) } { };
                        startButton.states_([["Running…", Color.gray(0.35), Color.gray(0.85)]]);
                        startButton.enabled = false;
                        menu.enabled = false;
                        bufferMenu.enabled = false;
                        setStatus.("Booting on " ++ key ++ " — windows will open shortly.");
                        // Deferred so this click returns and the label/status
                        // above actually repaint before boot.scd blocks the
                        // language during its synchronous setup.
                        {
                            protect {
                                (scriptDir +/+ "boot.scd").load;
                            } { |err|
                                if(err.notNil) {
                                    booted = false;
                                    menu.enabled = true;
                                    bufferMenu.enabled = true;
                                    startButton.enabled = true;
                                    startButton.states_([["Start megalooper",
                                        Color.white, Color.new(0.2, 0.55, 0.3)]]);
                                    // The banner and stack trace go to the log;
                                    // the window gets the one-line version.
                                    setStatus.("Boot failed: " ++ err.errorString
                                        ++ " — see ~/Library/Logs/megalooper.log", true);
                                };
                            };
                        }.defer(0.1);
                    };
                };
            }),
        Button()
            .canFocus_(false)
            .fixedWidth_(80)
            .toolTip_("Stop the server and quit megalooper.")
            .states_([["Quit"]])
            .action_({ win.close })
    ),
    statusText = StaticText()
        .string_("")
        .font_(Font(Font.defaultSansFace, 11))
        .align_(\left)
));

// This window owns the process: closing it quits the app. Without this, closing
// every window under the Desktop icon would leave sclang running invisibly with
// the server still on the audio device.
win.onClose = {
    ~looper !? { |l| protect { l.free } { } };
    Server.default.quit;
    // Give the server's /quit a moment to land before the process goes away.
    AppClock.sched(0.4, { 0.exit; nil });
};

menu.items = profileKeys.collect { |k| labelFor.(k) };
menu.value = startIdx;
bufferMenu.value = buffers.indexOf(lastBuffer) ? 0;
refresh.();
win.front;
)
