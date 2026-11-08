// megalooper — the app's own model: the state the setup scripts hold that no
// class does, said by name as a class's model says its changes. The window
// listens to it as it listens to the Looper (gui-shell.scd, ~appWatch),
// instead of the setup scripts painting the window themselves
// (docs/dev/architecture.md, 5, step 4).
//
// Loaded by boot.scd through parts.scd; defines only, runs nothing.
//   ~app   — the model. It says:
//              \say, words, kind   something for the player: the window's
//                                  status line (kind \bad for trouble)
//              \aiApps, on         AI apps let in or not (setup-remote.scd)
//              \aiChanges          the AI's changes, which Revert takes back
//              \actionsLog, on     Log every action on or off (setup-actions.scd)
//            The same object for as long as the app runs: a part loaded again
//            keeps it, and whoever listens with it.
//   ~say   — says \say; with nobody listening (no window: a check, the IDE
//            before the window), the words go to the post window.
(
~app = ~app ?? { Object.new };
~say = { |words, kind|
    if(~app.dependants.isEmpty) { ("megalooper: " ++ words).postln } { ~app.changed(\say, words, kind) };
};
)
