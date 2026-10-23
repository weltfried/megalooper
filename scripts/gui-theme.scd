// megalooper — the stage theme: two palettes, the type, and the few shapes the
// whole window is built from (docs/dev/stage-ui.md; the design is "Megalooper
// Stage" in Claude Design, handed off as handoff/gui-theme.scd and
// handoff/qt-mapping.md).
//
// Loaded by boot.scd right after gui-const.scd; defines only. Nothing here
// constructs a view at load time (check.scd and the headless tests load the
// gui files without a window): the builders below are called by the panes.
//
// The rules the palette encodes:
//   * LAYER colours (loop cut grain fx drum) say which part a control belongs
//     to: a section's header bar, a slider's fill, a tab's dot, an ON tile.
//     They never mean recording or playing.
//   * STATE colours (rec play dub armed) fill the state block, the beat cell
//     under the playhead, an action tile that is live and SET REC. Nowhere
//     else.
//   * BREAK is not a colour: it is the hatch, the one pattern that can't be
//     mistaken for an idle grey ("a deliberate silence and broken audio look
//     identical", docs/manual.md).
//   * OFF is no fill, a dashed or \line border and \mute text; a layer that is
//     off shows its colour faded.
//   * Text on an accent fill is \onacc (near-black on dark, white on light).
//   * \map is MIDI Map mode's alone: the one blue fill on screen.
// Both palettes have the same keys, so every painter reads ~gt[\key], and a
// switch of theme is ~guiThemeSet plus a rebuild of the window
// (~guiThemeToggle), which never touches the model.
(
~guiThemes = (
    dark: (
        bg:      Color.new255(13, 14, 16),
        panel:   Color.new255(19, 21, 24),
        panel2:  Color.new255(30, 33, 37),
        line:    Color.new255(44, 47, 52),
        ink:     Color.new255(243, 243, 241),
        mute:    Color.new255(144, 149, 160),
        onacc:   Color.new255(11, 11, 12),
        loop:    Color.new255(43, 155, 227),
        cut:     Color.new255(180, 141, 244),
        grain:   Color.new255(68, 214, 214),
        fx:      Color.new255(240, 114, 179),
        drum:    Color.new255(216, 218, 75),
        synth:   Color.new255(226, 160, 110),
        rec:     Color.new255(241, 57, 54),
        play:    Color.new255(60, 201, 106),
        dub:     Color.new255(255, 162, 52),
        armed:   Color.new255(249, 213, 68),
        map:     Color.new255(59, 123, 255)
    ),
    // Darker accents (L about 0.52), so white text on a fill passes 4.5:1
    // (test-theme-contrast.scd holds every one of them to it), and a darker
    // \mute and \line for stage light.
    light: (
        bg:      Color.new255(246, 246, 243),
        panel:   Color.new255(253, 253, 253),
        panel2:  Color.new255(226, 226, 221),
        line:    Color.new255(189, 189, 183),
        ink:     Color.new255(0, 0, 0),
        mute:    Color.new255(69, 73, 79),
        onacc:   Color.new255(255, 255, 255),
        loop:    Color.new255(0, 116, 189),
        cut:     Color.new255(122, 74, 186),
        grain:   Color.new255(0, 121, 132),
        fx:      Color.new255(184, 39, 113),
        drum:    Color.new255(122, 118, 0),
        synth:   Color.new255(150, 82, 30),
        rec:     Color.new255(201, 15, 26),
        play:    Color.new255(0, 127, 53),
        dub:     Color.new255(186, 90, 0),
        armed:   Color.new255(150, 109, 0),
        map:     Color.new255(31, 85, 214)
    )
);
// The Break hatch's two greys, the same on both themes: a break looks the same
// in daylight as on a dark stage.
~guiHatchDark = Color.new255(11, 11, 12);
~guiHatchLight = Color.new255(44, 44, 44);

// ---- Type -----------------------------------------------------------------------
// Nitti Grotesk (sans) and Nitti (mono) when they are installed system-wide
// (Font Book: the four .otf files of the design); Qt only sees installed fonts.
// Without them, the system's sans and mono, so a machine without them still
// boots and reads the same sizes. Looked up once, on first use, and never at
// load time.
~guiFaces = nil;
~guiFace = { |mono = false|
    var fonts;
    if(~guiFaces.isNil) {
        fonts = try { Font.availableFonts } { [] };
        ~guiFaces = (
            sans: if(fonts.includesEqual("Nitti Grotesk")) { "Nitti Grotesk" } { Font.defaultSansFace },
            mono: if(fonts.includesEqual("Nitti")) { "Nitti" } { Font.defaultMonoFace }
        );
    };
    ~guiFaces[if(mono) { \mono } { \sans }]
};
~guiSans = { |size = 15, medium = false| Font(~guiFace.(false), size, medium) };
~guiMono = { |size = 13, medium = true| Font(~guiFace.(true), size, medium) };
// The ladder, in px. Nothing below 11.
~guiType = (state: 58, take: 84, number: 40, pos: 22, section: 22, body: 15, label: 14, micro: 12);

// ---- Switching ----------------------------------------------------------------------
// The palette in use, and the older names the panes read, pointed at it.
~guiThemeSet = { |name|
    ~guiThemeName = if(~guiThemes.includesKey(name ? \dark)) { name ? \dark } { \dark };
    ~gt = ~guiThemes[~guiThemeName];
    ~guiOn        = ~gt[\play];
    ~guiOff       = ~gt[\panel2];
    ~guiArmed     = ~gt[\armed];
    ~guiDanger    = ~gt[\rec];
    ~guiBusy      = ~gt[\dub];
    ~guiStopping  = ~gt[\cut];
    ~guiCut       = ~gt[\cut];
    ~guiIdleBtn   = ~gt[\panel2];
    ~guiInk       = ~gt[\ink];
    ~guiHintColor = ~gt[\mute];
    ~guiHintFont  = ~guiSans.(12);
    // The two widget classes' defaults, so a bare LooperTile() or
    // LooperBar() is already the theme's.
    LooperTile.defaultInk = ~gt[\ink];
    LooperTile.defaultFill = nil;
    LooperTile.defaultBorder = nil;
    LooperTile.defaultFont = ~guiSans.(15, true);
    LooperTile.defaultSubFont = ~guiMono.(12);
    LooperTile.defaultSwFont = ~guiMono.(11);
    LooperTile.hatchDark = ~guiHatchDark;
    LooperTile.hatchLight = ~guiHatchLight;
    LooperBar.defaultColor = ~gt[\ink];
    LooperBar.defaultGroove = ~gt[\panel2];
    LooperBar.defaultTick = ~gt[\ink];
    LooperBar.defaultNeutral = ~gt[\mute];
    LooperSeg.defaultInk = ~gt[\ink];
    LooperSeg.defaultLine = ~gt[\line];
    LooperSeg.defaultFont = ~guiSans.(14);
    ~gt
};

// The other theme, kept in settings.json (gui.theme) for the next boot, and
// the window rebuilt in it, where it stood, on the view it showed. T, or the ◐
// in the top bar. The rebuild never touches the model, but it holds the
// language for 65-80 ms, and with it the MIDI clock (one tick that late: Live
// reads 31 BPM for it) and the cutter's routines: so it is refused while a loop moves or the clock goes out to Live
// (T sits beside R, and a stray press mid-song must not stall Live's tempo).
// The effects' bar calls its presets sounds.
~presetPlaceholder = { |key| "Name a new " ++ (if(key == \saFx) { "sound" } { "preset" }) ++ ", then Save new" };
~guiThemeToggle = {
    var view = ~guiView, lp = ~looper;
    var busy = lp.notNil and: {
        [\recording, \playing, \overdubbing].includes(lp.state) or: { lp.midiClockRunning == true } };
    if(busy) {
        ~guiSay.("Refused: the theme changes with the loop and clock stopped", \bad)
    } {
        ~guiThemeSet.(if(~guiThemeName == \light) { \dark } { \light });
        ~guiWindow !? { |w|
            if(w.isClosed.not) {
                ~buildGuiWindow.();
                ~wireLooperController.();
                view !? { |v| ~guiSelectView.(v) };
            };
        };
        // Kept last: whatever happens to the file, the window is whole.
        ~guiThemeSave.(~guiThemeName);
    };
};

// settings.json keeps it beside the MIDI choices (setup-midimap.scd writes back
// every field it doesn't know as it was read). Without the MIDI settings
// loaded (the headless tests), nothing is kept.
~guiThemeSaved = {
    var raw = ~midiSettingsNow !? { |f| f.value[\raw] };
    var gui = raw !? { |r| r["gui"] };
    var name = if(gui.isKindOf(Dictionary)) { gui["theme"] };
    name !? { |n| n.asString.asSymbol }
};
// A Dictionary from parseJSON is built with no free slot, so a key put into
// it that it doesn't have fails (_BasicPut, "Index out of range"): the raw
// settings and their "gui" are copied into fresh ones before the theme goes
// in. A missing settings.json starts fresh ones anyway, which is how the
// checks missed it until there was a file.
~guiDictCopy = { |d|
    var c = Dictionary.new;
    if(d.isKindOf(Dictionary)) { d.keysValuesDo { |k, v| c.put(k, v) } };
    c
};
~guiThemeSave = { |name| ~guiPrefSave.("theme", name.asString, "the theme") };
// One of the window's choices kept under "gui" in settings.json (the theme,
// the help lines), and read back.
~guiPrefSave = { |key, value, what|
    var s = ~midiSettingsNow !? { |f| f.value };
    var raw, gui;
    if(s.notNil and: { ~midiSettingsSave.notNil }) {
        raw = ~guiDictCopy.(s[\raw]);
        gui = ~guiDictCopy.(raw["gui"]);
        gui.put(key, value);
        raw.put("gui", gui);
        s[\raw] = raw;
        ~midiSettingsSave.({ |ok, why|
            if(ok != true) { ("megalooper: " ++ (what ? key) ++ " was not kept: " ++ (why ? "")).warn };
        });
    };
};
~guiPrefSaved = { |key|
    var raw = ~midiSettingsNow !? { |f| f.value[\raw] };
    var gui = raw !? { |r| r["gui"] };
    if(gui.isKindOf(Dictionary)) { gui[key] }
};

// ---- Help lines -----------------------------------------------------------------------
// The sentences that explain how a page works, not what is going on: the "?"
// switch in the top bar, or H, hides them all at once for the stage and shows
// them again. Kept in settings.json beside the theme. A view becomes one by
// passing through ~guiHelp (every ~guiHint does).
~guiHelpShown = ~guiHelpShown ? true;
~guiHelpViews = List.new;
~guiHelp = { |view|
    ~guiHelpViews.add(view);
    if(~guiHelpShown == false) { view.visible_(false) };
    view
};
~guiHelpApply = {
    ~guiHelpViews = List.newFrom(~guiHelpViews.reject { |v| v.isClosed });
    ~guiHelpViews.do { |v| v.visible_(~guiHelpShown != false) };
    ~guiHelpPaint !? { |f| f.value };
};
~guiHelpToggle = {
    ~guiHelpShown = ~guiHelpShown == false;
    ~guiHelpApply.();
    ~guiPrefSave.("help", if(~guiHelpShown) { "shown" } { "hidden" }, "the help lines' switch");
};

~guiThemeSet.(~guiThemeName ? \dark);

// ---- The window's palette ---------------------------------------------------------
// What every stock widget left as Qt draws it (a menu, a field, a number box,
// a scroll bar, a tooltip) takes from: set once on the window's view, and
// inherited by everything in it.
~guiPalette = {
    var p = QPalette.auto(~gt[\panel2], ~gt[\bg]);
    p.window = ~gt[\bg];
    p.windowText = ~gt[\ink];
    p.base = ~gt[\panel];
    p.baseText = ~gt[\ink];
    p.button = ~gt[\panel2];
    p.buttonText = ~gt[\ink];
    p.highlight = ~gt[\loop];
    p.highlightText = ~gt[\onacc];
    p.setColor(~gt[\panel2], \alternateBase);
    p.setColor(~gt[\panel], \toolTipBase);
    p.setColor(~gt[\ink], \toolTipText);
    p
};

// ---- Text ----------------------------------------------------------------------------
~guiText = { |str, size = 15, color, medium = false|
    StaticText().string_(str ? "").font_(~guiSans.(size, medium)).stringColor_(color ? ~gt[\ink])
};
// A label that stays on one line: in a row with a spring beside it, a
// wrapping StaticText is squeezed to its narrowest and breaks.
~guiLabel = { |str, size = 14, color, medium = false|
    var t = ~guiText.(str, size, color ? ~gt[\mute], medium);
    t.setProperty(\wordWrap, false);
    t
};
~guiMonoText = { |str, size = 12, color, medium = true|
    StaticText().string_(str ? "").font_(~guiMono.(size, medium)).stringColor_(color ? ~gt[\ink])
};
// A caption: "LOOPER STATE", "ACTIONS · FOOTSWITCH".
~guiCaption = { |str, size = 12| ~guiMonoText.(str, size, ~gt[\mute]) };
~guiTitle = { |str, size = 24| ~guiText.(str, size, nil, true) };
// A one-line note in \mute. Replaces the 10 px hint lines: what doesn't fit
// one line goes to a tooltip.
~guiHint = { |str| ~guiHelp.(~guiText.(str, 13, ~gt[\mute])) };

// ---- Structure ----------------------------------------------------------------------
// A 1 px rule in \line, across or (vertical) down.
~guiRule = { |vertical = false|
    var v = View().background_(~gt[\line]);
    if(vertical) { v.fixedWidth_(1) } { v.fixedHeight_(1) }
};
// The 8 px bar at the top of a layer's column or section, in its colour.
~guiBand = { |key, height = 8| View().background_(~gt[key] ? ~gt[\line]).fixedHeight_(height) };
// A view filled with `color` (the panel's by default) holding `layout`.
~guiPanel = { |layout, color| View().background_(color ? ~gt[\panel]).layout_(layout) };
// A scrolling holder whose canvas is pinned to its width (see gui-shell.scd on
// why wrapping text needs that).
~guiScroll = { |canvas|
    ScrollView().hasBorder_(false).hasHorizontalScroller_(false)
        .background_(~gt[\bg]).canvas_(canvas)
};

// ---- Controls -------------------------------------------------------------------------
// A flat bar slider in a layer's colour (LooperBar).
~guiBar = { |key, height = 14|
    LooperBar().color_(~gt[key ? \ink] ? ~gt[\ink]).groove_(~gt[\panel2]).fixedHeight_(height)
};

// A flat tile with one state (LooperTile).
~guiTile = { |label, sub, sw, height = 56|
    LooperTile().states_([[label, ~gt[\ink], ~gt[\panel]]]).border_(~gt[\line]).borderWidth_(2)
        .align_(\left).sub_(sub).sw_(sw).fixedHeight_(height).font_(~guiSans.(17, true))
};

// A layer's ON/OFF tile: filled in the layer's colour when on; no fill, a
// dashed \line border and \mute text when off. `cycles` false: the model
// paints it, so a refused toggle stays dark.
~guiLayerStates = { |key, onLabel = "ON", offLabel = "OFF"|
    [[offLabel, ~gt[\mute], nil], [onLabel, ~gt[\onacc], ~gt[key]]]
};
~guiLayerTile = { |key, onLabel = "ON", offLabel = "OFF", height = 46|
    LooperTile().states_(~guiLayerStates.(key, onLabel, offLabel)).cycles_(false)
        .font_(~guiMono.(16, true)).fixedHeight_(height)
        .border_(~gt[\line]).dashed_(true)
};
// Paint a layer tile on or off.
~guiLayerPaint = { |tile, on, key|
    tile !? { |t|
        if(t.isClosed.not) {
            t.value_(if(on == true) { 1 } { 0 });
            t.border_(if(on == true) { ~gt[key] } { ~gt[\line] }).dashed_(on != true);
        };
    };
};

// A segmented row (LooperSeg): every option one click, all of them visible.
// Replaces a PopUpMenu of seven options or fewer (Mix/Insert/Gate, the cut
// synth, the ratio, the grain window, the transport mode). Answers an Event
// (view:); paint it with ~guiSegSet. `opts`:
//   fill, ink   the chosen option's fill and text (default \ink on \bg)
//   base        the others' fill, as the ground under the row (default \bg)
//   gap         space between options; 0 draws them as one bordered strip
//   font        the options' font
//   height      a row's height
//   columns     wrap into a grid this many wide
//   action      called with the index clicked; the model paints the row back
~guiSeg = { |labels, opts|
    var o = opts ? ();
    var view = LooperSeg().cycles_(false)
        .fill_(~gt[o[\fill] ? \ink]).fillInk_(~gt[o[\ink] ? \bg]).base_(~gt[o[\base] ? \bg])
        .ink_(~gt[\ink]).line_(~gt[\line])
        .font_(o[\font] ? ~guiSans.(14)).gap_(o[\gap] ? 0).columns_(o[\columns]).rowHeight_(o[\height] ? 32)
        .items_(labels)
        .action_({ |sg| o[\action] !? { |f| f.value(sg.value) } });
    (view: view, labels: labels)
};
~guiSegSet = { |seg, index|
    seg !? { |s| s[\view] !? { |v| if(v.isClosed.not) { v.value_(index ? -1) } } };
};

// A preset bar in the stage look, in two parts a pane places where it likes:
// `menu`, the menu as an underlined field with its rescan (a section's header
// has room for it), and `edit`, the name field, Save, Revert, Delete and the
// status line under them. The behaviour is gui-presets.scd's, line for line
// (~presetBarRows): only the widgets differ. Answers (menu:, edit:).
~guiPresetParts = { |key, tips|
    var fam = ~presetFamilies[key];
    var t = tips ? ();
    var small = { |label, width, action, tip|
        LooperTile().states_([[label, ~gt[\ink], ~gt[\panel]]]).border_(~gt[\line])
            .font_(~guiSans.(13, false)).fixedHeight_(28).fixedWidth_(width).pad_(6)
            .toolTip_(tip ? "").action_(action)
    };
    var menu = ~presetWidget.(key, \menu, PopUpMenu().canFocus_(false)
        .font_(~guiSans.(15, true)).background_(~gt[\bg]).stringColor_(~gt[\ink])
        .toolTip_(t[\menu] ? "")
        .items_([(~presetNoneText !? { |f| f.(key) }) ? "— no presets yet —"])
        .action_({ |m|
            var slug = fam[\items][m.value];
            if(slug.isNil) {
                fam[\loaded] = nil;
                ~presetDisarm.(key);
            } {
                // Never let the menu claim a preset we failed to load.
                if(~presetLoad.(key, slug).not) {
                    m.value = fam[\items].indexOfEqual(fam[\loaded]) ? 0;
                };
            };
        }));
    var field = ~presetWidget.(key, \nameField, TextField()
        .font_(~guiSans.(14)).background_(~gt[\panel]).stringColor_(~gt[\ink])
        .toolTip_(t[\name] ? "")
        .string_("")
        .action_({ ~guiWindow !? { |w| w.view.focus(true) } })
        .focusGainedAction_({ |v|
            fam[\nameFocused] = true;
            v.background_(~gt[\armed]).stringColor_(~gt[\onacc]);
            ~presetSetStatus.(key, "Typing… Enter or Esc to release the keyboard");
            ~guiSetTyping !? { |f| f.(true) };
        })
        .focusLostAction_({ |v|
            fam[\nameFocused] = false;
            v.background_(~gt[\panel]).stringColor_(~gt[\ink]);
            ~presetDisarm.(key);   // a retyped target un-arms Save
            ~guiSetTyping !? { |f| f.(false) };
        })
        .keyDownAction_({ |v, char, mods, uni|
            if(uni == 27) {
                ~guiWindow !? { |w| w.view.focus(true) }; true
            } {
                // Deferred so it reads the string after Qt applied the
                // character: keeps the Save/Overwrite label honest.
                { ~presetRefreshButtons.(key) }.defer(0);
                nil
            };
        }));
    var status = ~presetWidget.(key, \statusText, StaticText()
        .string_(fam[\statusIdle]).font_(~guiSans.(13)).stringColor_(~gt[\mute]));
    status.setProperty(\wordWrap, false);
    // Empty, a dark bar did not read as a place to type: Qt's own grey hint
    // says what goes there, and goes when typing starts.
    field.setProperty(\placeholderText, ~presetPlaceholder.(key));
    (
        menu: View().layout_(HLayout(
            // What the bar's files are called: presets, or a family's own word.
            ~guiMonoText.(fam[\caption] ? "preset", 13, ~gt[\mute]),
            [menu, stretch: 1],
            small.("↻", 30, {
                ~presetRefreshList.(key);
                ~presetSetStatus.(key, "Preset list rescanned.");
            }, t[\rescan] ? "Rescan the folder for presets added or removed outside megalooper.")
        ).spacing_(8).margins_(0)),
        edit: View().layout_(VLayout(
            HLayout(
                [field, stretch: 1],
                ~presetWidget.(key, \saveButton, small.("Save new", 92, { ~presetSave.(key) }, t[\save])),
                ~presetWidget.(key, \revertButton, small.("Revert", 64, { ~presetRevert.(key) },
                    t[\revert] ? "Re-read the selected preset from disk, discarding every edit made since it was loaded.")),
                ~presetWidget.(key, \deleteButton, small.("Delete", 92, { ~presetDelete.(key) },
                    t[\delete] ? "Delete the selected preset. Click once to arm, again to confirm. What is playing is not touched."))
            ).spacing_(6).margins_(0),
            status
        ).spacing_(6).margins_(0))
    )
};
// Both parts, one over the other.
~guiPresetBar = { |key, tips|
    var parts = ~guiPresetParts.(key, tips);
    View().layout_(VLayout(parts[\menu], parts[\edit]).spacing_(6).margins_(0))
};
)
