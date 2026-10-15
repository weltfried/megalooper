// A flat bar slider for the stage window (scripts/gui-theme.scd and the panes):
// a filled bar from an origin to the value, square, with an optional tick (what
// the arc pedal leaves of a value) and an optional neutral mark (where a bend
// does nothing), all drawn in one paint. Qt's Slider draws a groove and a
// raised handle, which the macOS style won't flatten, and it can draw neither
// the tick nor the mark (handoff/qt-mapping.md, "Slider (all)").
//
// It speaks Slider's language where the window uses it: value (the position,
// 0..1), value_ (no action), valueAction_, action, step (a quantum of the
// position, 0 for none), background (the groove, as Slider's is) and
// orientation_ (taken, and ignored: only horizontal is drawn). A press puts the
// value under the mouse and a drag follows it; with Shift held at the press it
// moves ten times finer, from where it was. A mouseDownAction, mouseMoveAction
// or mouseUpAction set from outside runs first, and answering true takes the
// event from it (a double-click that puts a default back). The wheel is left
// alone, so the pane under the mouse scrolls. `held` is true from the press to
// the release, for a painter that must not move the bar under the hand.
LooperBar : UserView {
    classvar <>defaultColor, <>defaultGroove, <>defaultTick, <>defaultNeutral;
    var <value = 0, <>step = 0, <held = false;
    var <color, <groove, <origin = 0, <tick, <neutral, <tickColor, <neutralColor;
    var <inset = 0, <dim = 1;
    var fine = false, grabX = 0, grabValue = 0;

    *new { |parent, bounds|
        ^super.new(parent, bounds).initLooperBar
    }

    initLooperBar {
        color = defaultColor ?? { Color.gray(0.85) };
        groove = defaultGroove ?? { Color.gray(0.2) };
        tickColor = defaultTick ?? { Color.white };
        neutralColor = defaultNeutral ?? { Color.gray(0.55) };
        this.canFocus_(false);
        this.minHeight_(12);
        // The press, the drag and the release reach the methods below whether
        // or not anything outside sets an action of its own.
        this.setEventHandler(QObject.mouseDownEvent, \mouseDownEvent, true);
        this.setEventHandler(QObject.mouseDblClickEvent, \mouseDownEvent, true);
        this.setEventHandler(QObject.mouseMoveEvent, \mouseMoveEvent, true);
        this.setEventHandler(QObject.mouseUpEvent, \mouseUpEvent, true);
        this.drawFunc_({ this.prDraw });
    }

    // ---- Slider's language --------------------------------------------------
    value_ { |v|
        var nv = this.prQuantise((v ? 0).clip(0, 1));
        if(nv != value) { value = nv; this.prRefresh };
    }
    valueAction_ { |v| this.value_(v); action.value(this) }
    background { ^groove }
    background_ { |c| this.groove_(c) }
    orientation_ { }
    thumbSize_ { }
    knobColor_ { }

    // ---- The look -------------------------------------------------------------
    color_ { |c| color = c; this.prRefresh }
    groove_ { |c| groove = c; this.prRefresh }
    // Where the fill starts: 0 is the left end; 0.5 makes a bipolar bar that
    // fills from the middle towards the value.
    origin_ { |pos| origin = pos ? 0; this.prRefresh }
    tick_ { |pos| if(pos != tick) { tick = pos; this.prRefresh } }
    neutral_ { |pos| if(pos != neutral) { neutral = pos; this.prRefresh } }
    tickColor_ { |c| tickColor = c; this.prRefresh }
    neutralColor_ { |c| neutralColor = c; this.prRefresh }
    // Pixels kept clear above and below the groove, so the tick and the mark
    // can stand proud of it.
    inset_ { |px| inset = px ? 0; this.prRefresh }
    // The fill's opacity: a layer that is off shows its values faded.
    dim_ { |a| if((a ? 1) != dim) { dim = a ? 1; this.prRefresh } }
    enabled_ { |flag| if(flag != this.enabled) { super.enabled_(flag); this.prRefresh } }

    // ---- The mouse --------------------------------------------------------------
    mouseDown { |x, y, modifiers, buttonNumber, clickCount|
        var r = mouseDownAction.value(this, x, y, modifiers, buttonNumber, clickCount);
        if(r == true) { ^true };
        held = true;
        fine = modifiers.notNil and: { modifiers.isShift };
        grabX = x;
        grabValue = value;
        this.prSetFromX(x);
        ^true
    }

    mouseMove { |x, y, modifiers|
        var r = mouseMoveAction.value(this, x, y, modifiers);
        if(r == true) { ^true };
        if(held) { this.prSetFromX(x) };
        ^true
    }

    mouseUp { |x, y, modifiers, buttonNumber|
        held = false;
        mouseUpAction.value(this, x, y, modifiers, buttonNumber);
        ^true
    }

    // ---- private ------------------------------------------------------------------
    prQuantise { |pos|
        var q = if(step > 0) { (pos / step).round * step } { pos };
        ^q.clip(0, 1)
    }

    prSetFromX { |x|
        var w = this.bounds.width.max(1);
        var nv = if(fine) { grabValue + (((x - grabX) / w) * 0.1) } { x / w };
        nv = this.prQuantise(nv.clip(0, 1));
        if(nv != value) {
            value = nv;
            this.prRefresh;
            action.value(this);
        };
    }

    prRefresh { if(this.isClosed.not) { this.refresh } }

    prDraw {
        var b = this.bounds, w = b.width, h = b.height;
        var top = inset, bh = h - (2 * inset);
        var lo = min(origin, value), hi = max(origin, value);
        var alpha = if(this.enabled) { dim } { dim * 0.35 };
        Pen.fillColor = groove;
        Pen.addRect(Rect(0, top, w, bh));
        Pen.fill;
        if(hi > lo) {
            Pen.fillColor = Color(color.red, color.green, color.blue, color.alpha * alpha);
            Pen.addRect(Rect(lo * w, top, (hi - lo) * w, bh));
            Pen.fill;
        };
        neutral !? { |n|
            Pen.fillColor = neutralColor;
            Pen.addRect(Rect(((n * w).round).clip(0, w - 1), 0, 1, h));
            Pen.fill;
        };
        tick !? { |t|
            Pen.fillColor = tickColor;
            Pen.addRect(Rect(((t * w) - 1.5).clip(0, w - 3), 0, 3, h));
            Pen.fill;
        };
    }
}
