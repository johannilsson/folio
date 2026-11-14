# Where Swift code goes

How a piece of Swift is placed in the app, and so how it is tested. Most of the app already works this way. Apply these rules to the code you touch rather than refactoring ahead of a change.

1. **Three layers, each calling only the one below.**
   - The *engine* (Rust, through `Rust.swift`) decides about text and annotations: anchoring, accept, edits, sets.
   - The *logic* is plain Swift in FolioKit, values in and values out, no views: `PreviewBuilder`, `PreviewText`, `AnnotationModel`, `MarkdownHighlighter`, layout math.
   - The *UI* (AppKit views and controllers) turns events into calls on the logic, and its results into frames and attributes. It applies decisions; it does not make them.
2. **A rule you can say in a sentence is a function.** "A card sits at its anchor's top minus 4 and is pushed down 6 when it would overlap" belongs in something like `layoutCards(anchors, heights) -> [frame]`, not inside a view's layout code. The view sets the frames it is given.
3. **One owner per piece of state; views redraw from it.** The file belongs to `Document`, its annotations to `AnnotationStore`, and the mode, the comments pane and the shown file to the window controller. A view does not keep its own copy that can drift. (A sidebar refresh that bounced to the first file was such a copy.)
4. **The disk is the truth.** Changes are read, modified and written through libfolio so an agent's concurrent writes survive. Nothing in Swift assumes its copy in memory is current.
5. **A protocol only for two real implementations.** `AnnotationSurface` has two (the preview and the source). Do not add protocols, coordinators or containers to make something mockable; take the logic out into a function (rule 2) instead.
6. **Dependencies are passed in; globals stay at the edges.** The existing statics (`AppConfig`, `RecentFiles`, `AppServer`) are the process boundary. New code takes what it needs as parameters and adds no singletons or `NotificationCenter` broadcasts.
7. **UI code is on the main actor.** Move work off it only when it is measured to be slow (diagrams, very large files).
8. **Test a rule in the layer where it lives.** These are faster and fail closer to the cause than the self-test:
   - a logic rule gets a unit test;
   - a rule about where things land on screen gets an off-screen layout or picture test;
   - a rule about wiring (focus, windows, files changing underneath, the CLI and MCP against the live app) gets a self-test check. The self-test is for this kind only.

   See [development](../development.md#tests).

Anchoring and accept run in Rust through `Rust.swift` → `ffi.rs`. Do not reimplement them in Swift.
