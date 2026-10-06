# A human architecture page

The page `content/how-a-plugin-reaches-your-desktop.mdx` on the product's help site. The root `AGENTS.md` names `content/` as product content and routes no agent through it.

````markdown
# How does a plugin reach my desktop?

You pick a plugin in the Plugins window and turn it on. The shell writes that choice to your configuration file, builds the plugin from its manifest, and gives it a slot: a place on the bar, a window or a background service. The plugin runs on its own, so a plugin that fails leaves your bar, your launcher and every other plugin running.

![Turn it on, the shell reads the manifest, the shell gives it a slot, it runs on its own](../images/plugin-flow.svg)

1. **You turn it on.** The switch writes one line to your configuration file.
2. **The shell reads the manifest.** The manifest says what the plugin is, a bar widget, a window or a service, and which parts of the shell it may use.
3. **The shell gives it a slot.** A bar widget gets space on the bar, a window gets a window, a service runs in the background.
4. **It runs on its own.** The plugin cannot reach another plugin. If it fails, its page shows you the error and everything else keeps running.

Turn it off the same way. The shell takes it out of its slot and keeps your settings for next time.
````

The title is the reader's question, the first paragraph answers it in plain words, the diagram shows the four steps, and no sentence is written for an agent.

---

## Not this

```markdown
# How does a plugin reach my desktop?

Read before touching `PluginManager.enable`.

- Do write enablement through `Config.set("plugins", id)`; never edit `shell.json` by hand.
- Never import a core module from a plugin; `scripts/check-plugin-boundary.py` refuses it (D003).
```

With, in the root `AGENTS.md`: "Before enabling a plugin: `content/how-a-plugin-reaches-your-desktop.mdx`."

The person who asked the question is handed do and never lines, a script name and a decision ID, and the agent routed there finds a story with no rule it could break; the rules are `docs/architecture/plugins.md`, and the page keeps its reader.
