// A flat tile: the stage window's button (scripts/gui-theme.scd and the panes).
// Square and filled, with an optional border (dashed for a part that is off), a
// second line under the label (`sub`), a footswitch label in its top corner
// (`sw`), a ring (the tile selected, or masked in MIDI Map mode) and the Break
// hatch. Qt's Button holds a label and two colours per state and is drawn by
// the macOS style, which won't flatten it (handoff/qt-mapping.md, "Action
// tile").
//
// It speaks Button's language where the window uses it: states (an Array of
// [label, text colour, fill], as Button's; a colour left out is the theme's),
// value (the state shown), value_ (no action), valueAction_, action (called
// with the tile and the modifiers on a click, after the value has moved on to
// the next state, as Button's is), font_ and string_ (the label of every
// state). `cycles` false keeps the value where the model put it: a click only
// calls the action, and the model's notification paints the tile, so a refused
// toggle stays dark. A mouseDownAction or mouseUpAction set from outside runs
// first, and answering true takes the event from it.
//
// Qt can't ask a UserView how wide it wants to be, so a tile keeps its
// minimum width at what its words need, until it is given a width
// (fixedWidth_, fixedSize_ or minWidth_). A label that would run into the
// footswitch words is drawn smaller rather than over them.
LooperTile : UserView {
    classvar <>defaultInk, <>defaultFill, <>defaultBorder, <>defaultFont, <>defaultSubFont,
        <>defaultSwFont, <>hatchDark, <>hatchLight;
    var <states, <value = 0, <>cycles = true;
    var <sub, <sw, <border, <borderWidth = 1, <dashed = false, <hatch = false, <ring, <ringWidth = 2;
    var <align = \center, <labelFont, <subFont, <swFont, <subAlpha = 0.8, <pad = 10;
    var <mark, <underline;
    var pressed = false, fit = true;

    *new { |parent, bounds|
        ^super.new(parent, bounds).initLooperTile
    }

    initLooperTile {
        states = [[""]];
        labelFont = defaultFont ?? { Font(Font.defaultSansFace, 14, true) };
        subFont = defaultSubFont ?? { Font(Font.defaultMonoFace, 11) };
        swFont = defaultSwFont ?? { Font(Font.defaultMonoFace, 11) };
        border = defaultBorder;
        this.canFocus_(false);
        this.minHeight_(26);
        this.setEventHandler(QObject.mouseDownEvent, \mouseDownEvent, true);
        this.setEventHandler(QObject.mouseDblClickEvent, \mouseDownEvent, true);
        this.setEventHandler(QObject.mouseUpEvent, \mouseUpEvent, true);
        this.drawFunc_({ this.prDraw });
    }

    // ---- Button's language ----------------------------------------------------
    // Painting what is already there is a no-op, so a painter may run often.
    states_ { |s|
        var ns = if(s.isNil or: { s.isEmpty }) { [[""]] } { s };
        if(ns != states) {
            states = ns;
            value = value.clip(0, states.size - 1);
            this.prFit;
            this.prRefresh;
        };
    }
    value_ { |v|
        var nv = (v ? 0).asInteger.clip(0, states.size - 1);
        if(nv != value) { value = nv; this.prRefresh };
    }
    valueAction_ { |v| this.value_(v); action.value(this) }
    string { ^(states[value] ? [""])[0] }
    string_ { |str|
        states = states.collect { |st| [str] ++ st.copyToEnd(1) };
        this.prFit;
        this.prRefresh;
    }
    font { ^labelFont }
    font_ { |f| labelFont = f; this.prFit; this.prRefresh }
    enabled_ { |flag| if(flag != this.enabled) { super.enabled_(flag); this.prRefresh } }
    // A width given from outside ends the fitting.
    fixedWidth_ { |w| fit = false; super.fixedWidth_(w) }
    fixedSize_ { |size| fit = false; super.fixedSize_(size) }
    minWidth_ { |w| fit = false; super.minWidth_(w) }

    // ---- The look -----------------------------------------------------------------
    sub_ { |str| if(str != sub) { sub = str; this.prFit; this.prRefresh } }
    sw_ { |str| if(str != sw) { sw = str; this.prFit; this.prRefresh } }
    border_ { |c| if(c != border) { border = c; this.prRefresh } }
    borderWidth_ { |px| borderWidth = px ? 1; this.prRefresh }
    dashed_ { |flag| if((flag == true) != dashed) { dashed = flag == true; this.prRefresh } }
    hatch_ { |flag| if((flag == true) != hatch) { hatch = flag == true; this.prRefresh } }
    ring_ { |c| ring = c; this.prRefresh }
    ringWidth_ { |px| ringWidth = px ? 2; this.prRefresh }
    align_ { |sym| align = sym ? \center; this.prRefresh }
    subFont_ { |f| subFont = f; this.prFit; this.prRefresh }
    swFont_ { |f| swFont = f; this.prFit; this.prRefresh }
    subAlpha_ { |a| subAlpha = a ? 0.8; this.prRefresh }
    pad_ { |px| pad = px ? 10; this.prFit; this.prRefresh }
    // A 10 px square before a centred label, in its own colour (MIDI MAP's).
    mark_ { |c| mark = c; this.prRefresh }
    // A 3 px bar along the bottom edge, in its colour (a tile that is on).
    underline_ { |c| underline = c; this.prRefresh }

    // ---- The mouse --------------------------------------------------------------
    mouseDown { |x, y, modifiers, buttonNumber, clickCount|
        var r = mouseDownAction.value(this, x, y, modifiers, buttonNumber, clickCount);
        if(r == true) { ^true };
        if(buttonNumber == 0) { pressed = true; this.prRefresh };
        ^true
    }

    mouseUp { |x, y, modifiers, buttonNumber|
        var r = mouseUpAction.value(this, x, y, modifiers, buttonNumber);
        var b = this.bounds;
        if(pressed) {
            pressed = false;
            this.prRefresh;
            if((r != true) and: { x >= 0 } and: { y >= 0 } and: { x < b.width } and: { y < b.height }) {
                this.prClick(modifiers);
            };
        };
        ^true
    }

    // ---- private ------------------------------------------------------------------
    prClick { |modifiers|
        if(cycles and: { states.size > 1 }) { value = (value + 1) % states.size; this.prRefresh };
        action.value(this, modifiers);
    }

    prRefresh { if(this.isClosed.not) { this.refresh } }

    // What its words need: the widest label (and the footswitch words beside
    // it), or the line under it, with the padding.
    prFit {
        var w = 0, labels, swW;
        if(fit and: { this.isClosed.not }) {
            labels = states.collect { |st| (st[0] ? "").asString.bounds(labelFont).width };
            swW = sw !? { |x| x.asString.bounds(swFont).width + 12 } ? 0;
            w = (labels.maxItem ? 0) + swW + (if(mark.notNil) { 18 } { 0 });
            sub !? { |x| w = w.max(x.asString.bounds(subFont).width) };
            super.minWidth_((w + (2 * pad) + 2).ceil.asInteger);
        };
    }

    // The label's font, smaller where the label and the footswitch words would
    // meet in `room` px.
    prLabelFont { |label, room|
        var f = labelFont, size = labelFont.size ? 14;
        while { (label.bounds(f).width > room) and: { size > 11 } } {
            size = size - 1;
            f = Font(labelFont.name, size, labelFont.bold ? false);
        };
        ^f
    }

    prFade { |c, a| ^Color(c.red, c.green, c.blue, c.alpha * a) }

    prDraw {
        var b = this.bounds, w = b.width, h = b.height;
        var st = states[value] ? [""];
        var label = (st[0] ? "").asString;
        var ink = st[1] ?? { defaultInk ?? { Color.white } };
        var fill = st[2] ?? { defaultFill };
        var a = if(this.enabled) { 1 } { 0.4 };
        var half, top, lh;
        if(hatch) {
            Pen.fillColor = hatchDark ?? { Color.new255(11, 11, 12) };
            Pen.addRect(Rect(0, 0, w, h));
            Pen.fill;
            Pen.strokeColor = hatchLight ?? { Color.new255(44, 44, 44) };
            Pen.width = 10;
            ((w + h) / 28).ceil.asInteger.do { |i|
                var x0 = (i * 28) - h;
                Pen.line(Point(x0, h), Point(x0 + h, 0));
            };
            Pen.stroke;
        } {
            fill !? { |f|
                Pen.fillColor = this.prFade(f, a);
                Pen.addRect(Rect(0, 0, w, h));
                Pen.fill;
            };
        };
        if(pressed) {
            Pen.fillColor = Color(ink.red, ink.green, ink.blue, 0.14);
            Pen.addRect(Rect(0, 0, w, h));
            Pen.fill;
        };
        border !? { |c|
            Pen.push;
            Pen.strokeColor = this.prFade(c, a);
            Pen.width = borderWidth;
            if(dashed) { Pen.lineDash_(FloatArray[4, 3]) };
            Pen.addRect(Rect(borderWidth / 2, borderWidth / 2, w - borderWidth, h - borderWidth));
            Pen.stroke;
            Pen.pop;
        };
        ring !? { |c|
            Pen.strokeColor = c;
            Pen.width = ringWidth;
            Pen.addRect(Rect(ringWidth / 2, ringWidth / 2, w - ringWidth, h - ringWidth));
            Pen.stroke;
        };
        underline !? { |c|
            Pen.fillColor = c;
            Pen.addRect(Rect(0, h - 3, w, 3));
            Pen.fill;
        };
        ink = this.prFade(ink, a);
        if(sub.isNil and: { sw.isNil }) {
            if(mark.notNil) {
                lh = label.bounds(labelFont).width + 18;
                top = ((w - lh) / 2).max(pad);
                Pen.fillColor = this.prFade(mark, a);
                Pen.addRect(Rect(top, (h / 2) - 5, 10, 10));
                Pen.fill;
                Pen.stringInRect(label, Rect(top + 18, 0, w - top - 18, h), labelFont, ink, QAlignment(\left));
            } {
                Pen.stringInRect(label, Rect(pad, 0, w - (2 * pad), h), labelFont, ink, QAlignment(align));
            };
        } {
            lh = (labelFont.size ? 14) + 6;
            top = if(sub.isNil) { (h - lh) / 2 } { 5 };
            Pen.stringInRect(label, Rect(pad, top, w - (2 * pad), lh),
                this.prLabelFont(label, w - (2 * pad) - (sw !? { |s| s.asString.bounds(swFont).width + 10 } ? 0)),
                ink, QAlignment(\left));
            sw !? { |s|
                Pen.stringInRect(s.asString, Rect(pad, top, w - (2 * pad), lh), swFont,
                    this.prFade(ink, 0.7), QAlignment(\right));
            };
            sub !? { |s|
                half = (subFont.size ? 11) + 6;
                Pen.stringInRect(s.asString, Rect(pad, h - half - 4, w - (2 * pad), half), subFont,
                    this.prFade(ink, subAlpha), QAlignment(\left));
            };
        };
    }
}
