# PlantUML

Nothing is bundled to draw a `plantuml` block: without a setting, it stays a code block. Choose a local command or a server:

```bash
# A local PlantUML (brew install plantuml): the diagram stays on this Mac.
# Run as `<command> -pipe -tpng`; Homebrew's folders are on its PATH.
defaults write dev.folio.Folio PlantUMLCommand plantuml          # or: "java -jar /path/plantuml.jar"

# A server, which is sent the diagram's text.
defaults write dev.folio.Folio PlantUMLServer https://plantuml.example.com/plantuml
```

- You can also pass `-PlantUMLCommand …` or `-PlantUMLServer …` on the command line.
- The command wins when both are set.
- `defaults delete dev.folio.Folio <key>` turns one off.

Fenced `mermaid` blocks need no setting: the app draws them with its hidden diagram page ([preview](../architecture/preview.md)).
