// megalooper — MIDI Map mode: click a control in the window, then move or
// press what is to drive it, as in Ableton Live (docs/dev/midi-map.md 6.1, 6.4-6.6
// and 7.1-7.2). Phase 3 of the MIDI Map.
//
// Loaded by boot.scd after gui-midimap.scd; defines only, runs nothing. The
// MIDI MAP button in the top bar (on every view, so it never depends on the
// view shown: docs/dev/stage-ui.md), or Cmd+M, turns it on and off; MIDI can't.
// While it is on:
//   - every view the window tagged (~mapTag, gui-const.scd) wears a mask: a
//     see-through \map view laid over it as its child, outlined in \map and
//     saying what drives its control ("PC 4") where the control shows its
//     value. The mask takes the mouse, so the control under it never moves,
//     and the wheel over it scrolls the pane as it would;
//   - a click on a mask arms its control: the router's learning
//     (setup-midimap.scd), as Learn on the Setup view. What it learns replaces
//     the control's bindings; with Shift held it is added to them. The armed
//     mask is \armed;
//   - MIDI goes on driving everything, except while a control is armed: then
//     every message goes to the learning, as from the Setup view's list;
//   - the map bar opens above the footer, filled \map (\armed while a control
//     learns): what is happening, the question when a message is another
//     control's, Undo, Keep and Done. The MIDI MAP button is filled, the only
//     \map fill on screen, so it can't be taken for the Loop layer;
//   - Esc disarms, and with nothing armed leaves; Delete or Backspace removes
//     the armed control's bindings; Cmd+Z undoes; Cmd+M leaves. A click on
//     the window's background, or on a label, disarms too.
// Leaving with changes not kept asks once: Keep, Discard (Undo brings them
// back), or Later (they stay, not kept, and the Rig tab says so; the next
// boot starts from what was kept). Cmd-period, closing the window and
// rebuilding it leave at once.
//
// Everything here runs on AppClock: the router tells the window through
// ~midiChanged, deferred, and never touches a view (5.5).
(
// Re-loaded while map mode is on (the IDE, or boot.scd run again): it is left
// first, with the old definitions, so no mask, hook or wrapper of it stays.
if(~mapMode == true) { ~mapModeOff !? { |f| f.value } };
~mapMode = false;
~mapLeaving = false;            // the question when leaving with changes not kept
~mapKeeping = false;            // its Keep, written in the background
~mapMasks = ~mapMasks ? List.new;   // one Event per mask: view, mask, label, hook, tag
// The map bar: built with the window, so a re-load keeps it.
~mapBar = ~mapBar ? IdentityDictionary.new;
// A mask's fill: \map (\armed while it learns) blended into the panel, opaque,
// so the control's own value is covered and its binding shows in its place.
// Read when painted, so a switch of theme repaints them right.
~mapTintFor = { |armed|
    if(armed == true) { ~gt[\panel].blend(~gt[\armed], 0.32) } { ~gt[\panel].blend(~gt[\map], 0.22) }
};
~mapFont = Font(Font.defaultMonoFace, 11, true);

// A view tagged while map mode is on (a pane rebuilt: the Effects editor on
// every tile, the drum trims on every kit) gets its mask once laid out.
~mapTagged = { |view, id|
    if(~mapMode == true) {
        AppClock.sched(0, {
            if((~mapMode == true) and: { view.isClosed.not }) {
                ~mapMaskMake.(view, id);
                ~mapRepaint.();
            };
            nil
        });
    };
};

// The tags of the views still open.
~mapLiveTags = {
    ~mapTags = List.newFrom((~mapTags ? List.new).reject { |e| e[0].isClosed });
    ~mapTags
};

// ---- Masks ---------------------------------------------------------------------
// A mask is a UserView made as its view's child: it doesn't touch the layout,
// moves with the view and hides with its view (docs/dev/midi-map.md 7.2). Qt paints
// its tint; its drawFunc adds only the 2 px outline, once per paint. Its label
// is a StaticText that lets the mouse through, so the mask's own tooltip
// shows, and stays on one line, the rest clipped: the tooltip says it all. A
// mouse action that answers true stops the view's own handling: the view
// never moves, and its double-click resets and holds are never reached. The
// view's size is followed through its onResize, chained to whatever it had.
// A tile tall enough keeps its name in the corner (the mask's drawFunc), and
// its binding goes under the name, not over it.
~mapNamed = { |view, mask| view.isKindOf(LooperTile) and: { mask.bounds.height >= 50 } };
~mapTileName = { |str| var s = str ? "", i = s.find(" · "); if(i.notNil) { s.keep(i) } { s } };
~mapLabelRect = { |view, mask|
    var b = mask.bounds.moveTo(0, 0);
    if(~mapNamed.(view, mask)) { Rect(0, 26, b.width, (b.height - 26).max(1)) } { b }
};
~mapMaskMake = { |view, tag|
    var mask, label, hook, entry;
    if(view.isClosed.not and: { ~mapMasks.any { |e| e[\view] === view }.not }) {
        mask = UserView(view, view.bounds.moveTo(0, 0)).canFocus_(false).background_(~mapTintFor.(false));
        label = StaticText(mask, ~mapLabelRect.(view, mask)).acceptsMouse_(false).align_(\center)
            .font_(~mapFont).stringColor_(~gt[\ink]);
        mask.drawFunc_({ |m|
            var b = m.bounds, armed = entry !? { |e| e[\tint] == \armed } ? false;
            Pen.strokeColor = if(armed) { ~gt[\armed] } { ~gt[\map] };
            Pen.width = 2;
            Pen.addRect(Rect(1, 1, b.width - 2, b.height - 2));
            Pen.stroke;
            // A tile tall enough keeps its name in the corner: an action
            // tile reads "Trigger" over its binding.
            // Its name only: a tile that says its binding (" · PC 20") would
            // say it twice.
            if(~mapNamed.(view, m)) {
                Pen.stringInRect(~mapTileName.(view.string), Rect(10, 4, b.width - 20, 22),
                    ~guiSans.(15, true), ~gt[\ink],
                    QAlignment(\left));
            };
        });
        label.setProperty(\wordWrap, false);
        mask.mouseDownAction_({ |m, x, y, mods, button, clicks|
            if((button == 0) and: { clicks == 1 }) { ~mapClick.(tag, mods.notNil and: { mods.isShift }) };
            true
        });
        mask.mouseUpAction_({ true }).mouseMoveAction_({ true });
        mask.mouseWheelAction_({ |m, x, y, mods, dx, dy| ~mapScroll.(view, dy); true });
        // UserView.new shows a child of a view that is showing; one on a tab
        // not shown is shown with its tab once told it may be.
        mask.visible_(true);
        label.visible_(true);
        entry = (view: view, mask: mask, label: label, tag: tag);
        hook = { |v|
            if(mask.isClosed.not) {
                mask.bounds = v.bounds.moveTo(0, 0);
                label.bounds = ~mapLabelRect.(v, mask);
                entry[\align] = ~mapLabelAlign.(label, mask);
            };
        };
        entry[\hook] = hook;
        view.onResize = view.onResize.addFunc(hook);
        ~mapMasks.add(entry);
        entry
    }
};

~mapMasksMake = { ~mapLiveTags.().do { |e| ~mapMaskMake.(e[0], e[1]) } };

// A label wider than its mask is aligned left, so what it starts with shows
// ("note 66" on a 28 px knob), not its middle. Answers the alignment.
~mapLabelAlign = { |label, mask|
    var align = if((label.string ? "").bounds(~mapFont).width > mask.bounds.width) { \left } { \center };
    label.align_(align);
    align
};

// Every mask gone, and every view's onResize as it was.
~mapMasksRemove = {
    ~mapMasks.do { |e|
        if(e[\view].isClosed.not) { e[\view].onResize = e[\view].onResize.removeFunc(e[\hook]) };
        if(e[\mask].isClosed.not) { e[\mask].remove };
    };
    ~mapMasks = List.new;
};

// What drives each control in the map now, by id: each binding in words, in
// full and without its channel, made once per map, so a repaint is one lookup
// a mask.
~mapWordsFor = {
    var short;
    if(~mapWordsMap !== ~midiMap) {
        ~mapWordsMap = ~midiMap;
        ~mapWords = IdentityDictionary.new;
        (~midiMap !? { |m| m.bindings } ? []).do { |b|
            short = b.copy;
            short.removeAt(\chan);
            ~mapWords.put(b[\target], (~mapWords[b[\target]] ? [])
                .add([LooperMidiMap.describe(b), LooperMidiMap.describe(short)]));
        };
    };
    ~mapWords
};

// Each mask's label, tooltip and tint, from the map and the learning now. A
// tag that is a function is asked again, so a Drums knob says what drives the
// pattern shown. The label is short, for a narrow control: the first binding
// without its channel, and how many more ("PC 8 +1"). Only what changed is set.
~mapRepaint = {
    var words, armed, id, w, text, tip, tint, t;
    if(~mapMode == true) {
        ~mapMasks = List.newFrom(~mapMasks.reject { |e| e[\view].isClosed or: { e[\mask].isClosed } });
        words = ~mapWordsFor.();
        armed = ~midiLearning !? { |l| l[\target] };
        ~mapMasks.do { |e|
            id = e[\tag].value;
            t = id !? { |i| (~midiTargets ? ())[i] };
            w = id !? { |i| words[i] };
            text = if(w.isNil) { "" } { w[0][1] ++ if(w.size > 1) { " +" ++ (w.size - 1) } { "" } };
            tip = if(t.isNil) { "Not a control megalooper can map here" } {
                t[\label] ++ (t[\group] !? { |g| " (" ++ g ++ ")" } ? "") ++ " — "
                    ++ (w !? { |x| x.collect(_.first).join(", ") } ? "no MIDI")
                    ++ "\nClick to map it; Shift-click to add another mapping."
            };
            tint = if(armed.notNil and: { armed == id }) { \armed } { \map };
            if(e[\text] != text) { e[\text] = text; e[\label].string_(text); e[\align] = ~mapLabelAlign.(e[\label], e[\mask]) };
            if(e[\tip] != tip) { e[\tip] = tip; e[\mask].toolTip_(tip) };
            if(e[\tint] != tint) {
                e[\tint] = tint;
                e[\mask].background_(~mapTintFor.(tint == \armed));
                e[\mask].refresh;
            };
        };
    };
};

// ---- The mouse -----------------------------------------------------------------
// A mask clicked: its control is armed, to replace its bindings, or with
// Shift to add one (6.4). Not once map mode is over.
~mapClick = { |tag, add = false|
    var id;
    if(~mapMode == true) {
        id = tag.value;
        ~mapLeaving = false;
        if(id.notNil and: { (~midiTargets ? ())[id].notNil }) {
            ~midiLearnArm.(id, add == true);
        } {
            ~midiLearnDisarm.("That control can't be mapped here");
        };
        ~midiChanged.(\learn);
    };
};

// The wheel over a mask: the pane scrolls, as it would over the control
// (knobs and sliders take the wheel for themselves). Qt gives a wheel's notch
// as 15 and a trackpad's pixels as a quarter of them.
~mapScroll = { |view, dy|
    var sv, o;
    if(view.isClosed.not and: { dy.notNil }) {
        sv = view.parents.detect { |p| p.isKindOf(ScrollView) };
        if(sv.notNil and: { sv.isClosed.not }) {
            o = sv.visibleOrigin;
            sv.visibleOrigin = Point(o.x, (o.y - (dy * 4)).max(0));
        };
    };
};

// A click no view took for itself: one on the window's background or on a
// label, which pass it on up. An armed control is disarmed (6.1). A view that
// takes the click (a menu, a field, the Rig tab's list) keeps the arm.
~mapBackgroundClick = {
    if((~mapMode == true) and: { ~midiLearning.notNil }) { ~midiLearnDisarm.("Nothing changed") };
    nil
};

// ---- On and off ----------------------------------------------------------------
~mapModeOn = {
    var gen, prev;
    if(~mapMode != true) {
        ~mapMode = true;
        ~mapLeaving = false;
        ~mapKeeping = false;
        ~midiLearnNote = nil;
        ~mapMasks = List.new;
        ~mapMasksMake.();
        // A click on the window's background disarms. The action the window
        // had is kept here and given back on leaving; this wrapper never wraps
        // itself.
        ~guiWindow !? { |w|
            prev = w.view.mouseDownAction;
            if(w.isClosed.not and: { prev.isNil or: { prev !== ~mapWindowWrapper } }) {
                ~mapWindowPrev = prev;
                ~mapWindowWrapper = { |v ... args| ~mapBackgroundClick.(); prev.value(v, *args) };
                w.view.mouseDownAction = ~mapWindowWrapper;
            };
        };
        // Cmd-period leaves map mode. It clears AppClock before it runs this,
        // so the deferred call survives.
        ~mapCmdPeriod !? { |f| CmdPeriod.remove(f) };
        ~mapCmdPeriod = { { ~mapModeOff.() }.defer };
        CmdPeriod.add(~mapCmdPeriod);
        // The map bar's countdown, four times a second while map mode is on.
        gen = (~mapGen ? 0) + 1;
        ~mapGen = gen;
        AppClock.sched(0.25, {
            if((gen == ~mapGen) and: { ~mapMode == true }) { ~mapBarRefresh.(); 0.25 } { nil }
        });
        ~midiChanged.(\mapMode);
    };
};

~mapModeOff = {
    if(~mapMode == true) {
        ~mapMode = false;
        ~mapLeaving = false;
        ~mapKeeping = false;
        ~mapGen = (~mapGen ? 0) + 1;
        if(~midiLearning.notNil) { ~midiLearnDisarm.("Nothing changed") };
        ~mapMasksRemove.();
        ~guiWindow !? { |w|
            if(w.isClosed.not and: { w.view.mouseDownAction === ~mapWindowWrapper }) {
                w.view.mouseDownAction = ~mapWindowPrev;
            };
        };
        ~mapWindowWrapper = nil;
        ~mapWindowPrev = nil;
        ~mapCmdPeriod !? { |f| CmdPeriod.remove(f) };
        ~mapCmdPeriod = nil;
        ~midiChanged.(\mapMode);
    };
};

// Are there changes not kept? A map with no name yet and bindings in it (a
// fresh clone's first mappings) has none kept.
~mapUnkept = {
    (~midiMapDirty !? { |f| f.value } ? false)
        or: { ~midiMap.notNil and: { ~midiMap.name.isNil } and: { ~midiMap.bindings.notEmpty } }
};

// Done, a second Esc, Cmd+M: leave, asking first if there are changes not
// kept. Asked once: leaving again while it asks is Later.
~mapModeLeave = {
    case
    { ~mapMode != true } { }
    { ~mapKeeping } { }
    { ~mapLeaving } { ~mapModeOff.() }
    { ~mapUnkept.() } {
        if(~midiLearning.notNil) { ~midiLearnDisarm.(nil) };
        ~mapLeaving = true;
        ~midiChanged.(\mapMode);
    }
    { ~mapModeOff.() };
};

// The answer to the question: \keep keeps the map as yours, and leaves once
// it is written: if it can't be, map mode stays and the bar says why. While
// the write is under way the question is answered: the bar says so, and
// nothing else answers it (a second Keep would race the first). \discard
// goes back to the map as kept (as an edit, so Undo brings the changes back);
// \later leaves them as they are.
~mapLeaveAnswer = { |answer|
    case
    { ~mapKeeping } { }
    { answer == \keep } {
        ~mapKeeping = true;
        ~midiChanged.(\mapMode);
        // The write's answer may come from the shell's thread: views only
        // from AppClock.
        ~midiGuiKeep.({ |ok|
            {
                ~mapKeeping = false;
                ~mapLeaving = false;
                if(ok == true) { ~mapModeOff.() } { ~midiChanged.(\mapMode) };
            }.defer
        });
    }
    { answer == \discard } {
        ~midiKept !? { |k| ~midiMapEdit.(k) };
        ~midiLearnNote = "Discarded: Undo (Setup › MIDI map) brings them back";
        ~mapModeOff.();
    }
    { ~mapModeOff.() };
};

~mapModeToggle = { if(~mapMode == true) { ~mapModeLeave.() } { ~mapModeOn.() } };

// ---- Keys ------------------------------------------------------------------------
// The window's keys go here first (~guiKeyDown, gui-shell.scd). Answers true
// for a key it took. Cmd+M anywhere; in map mode Esc, Delete or Backspace,
// and Cmd+Z. `key` is Qt's key code, which a letter has whatever is held.
~mapKeyEscape = 16r1000000;
~mapKeyBackspace = 16r1000003;
~mapKeyDelete = 16r1000007;
~mapKeyDown = { |char, modifiers, key|
    var cmd = modifiers.notNil and: { modifiers.isCmd or: { modifiers.isCtrl } };
    case
    { cmd and: { key == 77 } } { ~mapModeToggle.(); true }        // Cmd+M
    { ~mapMode != true } { false }
    { cmd and: { key == 90 } } { ~midiMapUndo.(); true }          // Cmd+Z
    { key == ~mapKeyEscape } { ~mapEscape.(); true }
    { (key == ~mapKeyBackspace) or: { key == ~mapKeyDelete } } { ~mapDelete.(); true }
    { false };
};

// Esc: the leaving question goes (map mode stays); else an armed control is
// disarmed; else map mode is left.
~mapEscape = {
    case
    { ~mapKeeping } { }
    { ~mapLeaving } { ~mapLeaving = false; ~midiChanged.(\mapMode) }
    { ~midiLearning.notNil } { ~midiLearnDisarm.("Nothing changed") }
    { ~mapModeLeave.() };
};

// Delete with a control armed: all its bindings go (6.6). Undo brings them
// back.
~mapDelete = {
    var id = ~midiLearning !? { |l| l[\target] };
    var gone;
    id !? {
        gone = ~midiMap !? { |m| m.bindingsFor(id) } ? [];
        if(gone.notEmpty) {
            ~midiMapEdit.(~midiMap.removing(gone));
            ~midiLearnDisarm.(~midiTargetLabel.(id) ++ ": no MIDI now (Undo brings it back)");
        } {
            ~midiLearnDisarm.(~midiTargetLabel.(id) ++ " had no MIDI");
        };
    };
};

// ---- The MIDI MAP button -----------------------------------------------------------
// In the top bar, between the rig's lamp and SET REC, on every view. Off: the
// bar's own 1 px line, \ink text and a \map square (a \map outline looked
// like keyboard focus, or a switch left on). On: filled \map, white text and a
// white underline. Cmd+M does the same.
~buildMapButton = {
    ~mapButton = LooperTile().cycles_(false).fixedHeight_(52).minWidth_(150)
        .font_(~guiMono.(15, true)).pad_(10)
        .toolTip_("MIDI Map mode: click a control, then move or press what is to drive it (Cmd+M).")
        .action_({ ~mapModeToggle.() });
    ~mapButtonPaint.();
    ~mapButton
};
~mapButtonPaint = {
    var on = ~mapMode == true;
    ~mapButton !? { |b|
        if(b.isClosed.not) {
            b.states_([["MIDI MAP  ⌘M", ~gt[\ink], nil], ["MIDI MAP  ⌘M", Color.white, ~gt[\map]]]);
            b.value_(on.binaryValue);
            b.mark_(if(on) { Color.white } { ~gt[\map] });
            b.border_(if(on) { nil } { ~gt[\line] }).borderWidth_(if(on) { 2 } { 1 });
            b.underline_(if(on) { Color.white } { nil });
        };
    };
};

// ---- The map bar -----------------------------------------------------------------
// It opens above the footer while map mode is on (~guiHintRowRefresh,
// gui-shell.scd): one line of what is happening and a line under it, and the
// buttons that fit it. The lines never wrap: what doesn't fit is in their
// tooltip. Filled \map, and \armed while a control learns or a message waits
// for an answer.
~buildMapBar = {
    var b = IdentityDictionary.new;
    var sep = { |key| var v = View().fixedWidth_(1); b[key] = v; v };
    var button = { |label, action, width|
        LooperTile().states_([[label, Color.white, nil]]).cycles_(false).font_(~guiSans.(14, false))
            .fixedHeight_(44).pad_(18).minWidth_(width ? 70).action_(action)
    };
    b[\label] = ~guiMonoText.("MIDI MAP", 13, Color.white).align_(\center);
    b[\labelView] = View().fixedWidth_(116).layout_(HLayout(b[\label]).margins_(0));
    // An explicit minimum, or a label that doesn't wrap asks for its whole
    // line and widens the window.
    b[\text] = ~guiText.("", 15, Color.white, true).minWidth_(10);
    b[\text].setProperty(\wordWrap, false);
    b[\sub] = ~guiMonoText.("", 13, Color.white).minWidth_(10);
    b[\sub].setProperty(\wordWrap, false);
    b[\move] = button.("Move it here", { ~midiLearnAnswer.(\move) }, 120);
    b[\both] = button.("Both", { ~midiLearnAnswer.(\both) });
    b[\cancel] = button.("Cancel", { ~midiLearnDisarm.("Nothing changed") });
    b[\delete] = button.("Delete · ⌫", { ~mapDelete.() }, 110)
        .toolTip_("Take every mapping of the armed control away (Delete or Backspace). Undo brings them back.");
    b[\keepLeave] = button.("Keep", { ~mapLeaveAnswer.(\keep) });
    b[\discard] = button.("Discard", { ~mapLeaveAnswer.(\discard) });
    b[\later] = button.("Later", { ~mapLeaveAnswer.(\later) });
    b[\undo] = button.("Undo · ⌘Z", { ~midiMapUndo.() }, 110).toolTip_("Take the last change back (Cmd+Z).");
    b[\keep] = button.("Keep", { ~midiGuiKeep.() })
        .toolTip_("Keep this map as yours: the next boot starts with it. Nothing is written before this.");
    b[\done] = LooperTile().states_([["Done", Color.new255(11, 11, 12), Color.white]]).cycles_(false)
        .font_(~guiSans.(14, true)).fixedHeight_(44).fixedWidth_(84)
        .action_({ ~mapModeLeave.() }).toolTip_("Leave MIDI Map mode (Esc, Cmd+M).");
    // Hidden or not, the bar must not set the window's width.
    b[\view] = View().background_(~gt[\map]).visible_(false).fixedHeight_(44).minWidth_(10).layout_(HLayout(
        b[\labelView],
        [View().layout_(HLayout(b[\text], [b[\sub], stretch: 1]).margins_([18, 0, 18, 0]).spacing_(14)), stretch: 1],
        sep.(\sep1), b[\move], b[\both], b[\cancel], b[\delete], b[\keepLeave], b[\discard], b[\later],
        sep.(\sep2), b[\undo], sep.(\sep3), b[\keep], b[\done]
    ).margins_(0).spacing_(0));
    b[\shown] = [\undo, \keep, \done];
    [\move, \both, \cancel, \delete, \keepLeave, \discard, \later].do { |k| b[k].visible_(false) };
    ~mapBar = b;
    b[\view]
};

// What the bar says, and which of its buttons it shows, now: in a question or
// a learning, only the buttons that answer it.
~mapBarState = {
    var l = ~midiLearning, q = l !? { |x| x[\question] }, now = ~midiNow.(), secs, label, others;
    case
    { ~mapKeeping } { ["Keeping the map…", []] }
    { ~mapLeaving } {
        ["Changes not kept: keep them for the next boot?", [\keepLeave, \discard, \later]]
    }
    { q.notNil } {
        secs = (q[\until] - now).ceil.max(0).asInteger;
        others = q[\others] ? [];
        [LooperMidiMap.describe(q[\binding]) ++ " is "
            ++ (others.first !? { |o| ~midiTargetLabel.(o[\target]) } ? "another control")
            ++ (if(others.size > 1) { " and " ++ (others.size - 1) ++ " more" } { "" })
            ++ "'s · " ++ secs ++ " s",
            [\move, \both, \cancel]]
    }
    { l.notNil } {
        label = ~midiTargetLabel.(l[\target]);
        if(l[\learner].counting) {
            ["Learning " ++ label ++ ": counting the presses…", [\cancel]]
        } {
            secs = (l[\learner].deadline - now).ceil.max(0).asInteger;
            ["Learning " ++ label ++ ": " ++ (~midiLearnNote ? "") ++ " · " ++ secs ++ " s", [\cancel, \delete]]
        }
    }
    {
        [~midiLearnNote ?? { "Click a control to map it · Shift-click adds one · Esc leaves" },
            [\undo, \keep, \done]]
    }
};

// The line under: how to get out of what is happening.
~mapBarSub = {
    case
    { ~mapKeeping or: { ~mapLeaving } } { "" }
    { (~midiLearning !? { |l| l[\question] }).notNil } { "a message that drives another control" }
    { ~midiLearning.notNil } { "Esc cancels · move a knob or press a switch" }
    { "MIDI keeps driving everything until you click" }
};

~mapBarRefresh = {
    var b = ~mapBar, state, armed, ink, unkept, now, secs, l;
    // A learning started from the Setup view's list answers the question to
    // leave: the player is mapping, not leaving.
    if(~mapLeaving and: { ~midiLearning.notNil }) { ~mapLeaving = false };
    if(b[\view].notNil and: { b[\view].isClosed.not }) {
        state = ~mapBarState.();
        armed = ~midiLearning.notNil;
        ink = if(armed) { Color.new255(11, 11, 12) } { Color.white };
        if(b[\armedNow] != armed) {
            b[\armedNow] = armed;
            b[\view].background_(if(armed) { ~gt[\armed] } { ~gt[\map] });
            b[\labelView].background_(Color(0, 0, 0, 0.18));
            [b[\label], b[\text], b[\sub]].do { |t| t.stringColor_(ink) };
            [\move, \both, \cancel, \delete, \keepLeave, \discard, \later, \undo, \keep].do { |k|
                b[k].states_([[b[k].string, ink, nil]]);
            };
            [\sep1, \sep2, \sep3].do { |k|
                b[k].background_(if(armed) { Color(0, 0, 0, 0.25) } { Color(1, 1, 1, 0.3) });
            };
        };
        if(b[\textNow] != state[0]) { b[\textNow] = state[0]; b[\text].string_(state[0]).toolTip_(state[0]) };
        b[\sub].string_(~mapBarSub.());
        if(b[\shown] != state[1]) {
            b[\shown] = state[1];
            [\move, \both, \cancel, \delete, \keepLeave, \discard, \later, \undo, \keep, \done].do { |k|
                b[k].visible_(state[1].includes(k));
            };
        };
        b[\undo].enabled_((~midiUndo ? []).notEmpty);
        b[\keep].enabled_(~midiMap.notNil and: { ~midiMap.name.notNil or: { ~midiMap.bindings.notEmpty } });
        // Keep says how many changes wait: "Keep  ● unkept".
        unkept = ~mapUnkept !? { |f| f.value } ? false;
        b[\keep].states_([[if(unkept) { "Keep  ●" } { "Keep" }, ink, nil]]);
        // The armed mask counts down where the control showed its binding.
        l = ~midiLearning;
        if(l.notNil and: { l[\learner].notNil } and: { l[\learner].counting.not }) {
            now = ~midiNow.();
            secs = (l[\learner].deadline - now).ceil.max(0).asInteger;
            ~mapMasks.do { |e|
                if(e[\tint] == \armed and: { e[\label].isClosed.not }) {
                    e[\label].string_(secs.asString ++ " s");
                    e[\text] = nil;
                };
            };
        };
    };
};

// ---- Lifetimes -------------------------------------------------------------------
~guiTeardowns = ~guiTeardowns ? ();
~guiTeardowns[\mapmode] = {
    // Closing or rebuilding the window leaves map mode (6.5).
    ~mapModeOff.();
    ~mapBar = IdentityDictionary.new;
    ~mapButton = nil;
};
)
