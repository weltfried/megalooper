// A segmented row for the stage window (scripts/gui-theme.scd): every option
// of a short choice drawn side by side, the chosen one filled, each one click.
// It replaces a PopUpMenu of seven options or fewer (Mix/Insert/Gate, the cut
// synth, the ratio, the grain window, the transport mode), so every choice is
// in sight (handoff/qt-mapping.md, "Segmented").
//
// One view drawn in one paint, not a row of tiles in a layout: MIDI Map mode
// lays its mask over a view as a child (gui-mapmode.scd), and a view with a
// layout would take that mask into its layout as one more option.
//
// It speaks PopUpMenu's language where the window uses it: items, value (the
// index chosen; -1 for none), value_ (no action), valueAction_ and action
// (called with the row once a click has moved the value: the option already
// chosen does nothing, as a PopUpMenu does on reselection). `cycles` false keeps
// the value where the model put it: a click calls the action with the row's
// value set to the option clicked, and puts it back, so the model's
// notification paints the row (at once, or later). With `columns` the options
// wrap into a grid.
LooperSeg : UserView {
    classvar <>defaultInk, <>defaultLine, <>defaultFont;
    var <items, <value = -1, <>cycles = true;
    var <fill, <fillInk, <base, <ink, <line, <font, <gap = 0, <columns, <rowHeight = 30, <pad = 8;
    var pressed, fit = true, painted = false;

    *new { |parent, bounds|
        ^super.new(parent, bounds).initLooperSeg
    }

    initLooperSeg {
        items = [];
        ink = defaultInk ?? { Color.white };
        line = defaultLine ?? { Color.gray(0.3) };
        fill = ink;
        fillInk = Color.black;
        font = defaultFont ?? { Font(Font.defaultSansFace, 14) };
        this.canFocus_(false);
        this.drawFunc_({ this.prDraw });
    }

    // ---- PopUpMenu's language ----------------------------------------------------
    items_ { |list| items = list ? []; this.prFit; this.prRefresh }
    value_ { |i|
        var nv = (i ? -1).asInteger;
        painted = true;
        if(nv != value) { value = nv; this.prRefresh };
    }
    valueAction_ { |i| this.value_(i); action.value(this) }
    item { ^items[value] }

    // ---- The look -----------------------------------------------------------------
    // fill/fillInk: the chosen option; base/ink: the others; line: the
    // borders. A gap of 0 draws one bordered strip; more, each option boxed.
    fill_ { |c| fill = c; this.prRefresh }
    fillInk_ { |c| fillInk = c; this.prRefresh }
    base_ { |c| base = c; this.prRefresh }
    ink_ { |c| ink = c; this.prRefresh }
    line_ { |c| line = c; this.prRefresh }
    font_ { |f| font = f; this.prFit; this.prRefresh }
    gap_ { |px| gap = px ? 0; this.prFit; this.prRefresh }
    columns_ { |n| columns = n; this.prFit; this.prRefresh }
    rowHeight_ { |px| rowHeight = px ? 30; this.prFit; this.prRefresh }
    pad_ { |px| pad = px ? 8; this.prFit; this.prRefresh }
    enabled_ { |flag| if(flag != this.enabled) { super.enabled_(flag); this.prRefresh } }
    // A width given from outside ends the fitting.
    fixedWidth_ { |w| fit = false; super.fixedWidth_(w) }
    fixedSize_ { |size| fit = false; super.fixedSize_(size) }
    minWidth_ { |w| fit = false; super.minWidth_(w) }

    // The option under a point, or nil.
    indexAt { |x, y|
        var cols = this.prCols, rows = this.prRows, b = this.bounds;
        var cw = (b.width - ((cols - 1) * gap)) / cols;
        var c = (x / (cw + gap)).floor.asInteger, r = (y / (rowHeight + gap)).floor.asInteger;
        var i = (r * cols) + c;
        ^if((c >= 0) and: { c < cols } and: { r >= 0 } and: { r < rows } and: { i < items.size }) { i }
    }

    // ---- The mouse ------------------------------------------------------------------
    mouseDown { |x, y, modifiers, buttonNumber, clickCount|
        var r = mouseDownAction.value(this, x, y, modifiers, buttonNumber, clickCount);
        if(r == true) { ^true };
        if(buttonNumber == 0) { pressed = this.indexAt(x, y); this.prRefresh };
        ^true
    }

    mouseUp { |x, y, modifiers, buttonNumber|
        var r = mouseUpAction.value(this, x, y, modifiers, buttonNumber);
        var i = this.indexAt(x, y), was;
        if(pressed.notNil) {
            if((r != true) and: { i == pressed } and: { i != value } and: { this.enabled }) {
                was = value;
                value = i;
                painted = false;
                action.value(this);
                // `cycles` false: the value goes back, for the model's
                // notification to paint, unless that has painted it already.
                // A repaint deferred from the GUI's own thread runs at once,
                // inside the action, and putting the old value back after it
                // left every row showing the option before the click.
                if(cycles.not and: { painted.not }) { value = was };
            };
            pressed = nil;
            this.prRefresh;
        };
        ^true
    }

    // ---- private ------------------------------------------------------------------
    prCols { ^(columns ? items.size).max(1) }
    prRows { ^(items.size / this.prCols).ceil.asInteger.max(1) }

    prFit {
        var cols, widest;
        if(this.isClosed.not) {
            this.fixedHeight_((this.prRows * rowHeight) + ((this.prRows - 1) * gap));
            if(fit) {
                cols = this.prCols;
                widest = items.collect { |it| it.asString.bounds(font).width }.maxItem ? 0;
                super.minWidth_(((widest + (2 * pad)) * cols + ((cols - 1) * gap)).ceil.asInteger);
            };
        };
    }

    prRefresh { if(this.isClosed.not) { this.refresh } }

    prDraw {
        var b = this.bounds, cols = this.prCols;
        var cw = (b.width - ((cols - 1) * gap)) / cols;
        var a = if(this.enabled) { 1 } { 0.4 };
        var fade = { |c, k| Color(c.red, c.green, c.blue, c.alpha * k) };
        items.do { |it, i|
            var c = i % cols, r = i div: cols;
            var rect = Rect(c * (cw + gap), r * (rowHeight + gap), cw, rowHeight);
            var on = i == value;
            var f = if(on) { fill } { base };
            f !? { Pen.fillColor = fade.(f, a); Pen.addRect(rect); Pen.fill };
            if(pressed == i) {
                Pen.fillColor = fade.(ink, 0.14);
                Pen.addRect(rect);
                Pen.fill;
            };
            if(gap > 0) {
                Pen.strokeColor = fade.(line, a);
                Pen.width = 1;
                Pen.addRect(rect.insetBy(0.5, 0.5));
                Pen.stroke;
            };
            Pen.stringCenteredIn(it.asString, rect, font, fade.(if(on) { fillInk } { ink }, a));
        };
        if(gap == 0) {
            Pen.strokeColor = fade.(line, a);
            Pen.width = 1;
            Pen.addRect(Rect(0.5, 0.5, b.width - 1, b.height - 1));
            Pen.stroke;
        };
    }
}
