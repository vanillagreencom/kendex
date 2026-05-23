# vstack themes

![Showcase](https://github.com/vanillagreencom/vstack/raw/main/extras/assets/vanillagreen-themes.gif)

A single VS Code / VSCodium / Cursor extension contributing **25 color themes** + a matched **Rosé Pine icon theme**, curated by **vanillagreen** and distributed through [vstack](https://github.com/vanillagreencom/vstack/blob/main/extras/README.md).

Each theme has a matching Ghostty palette + ambient shader pair in the vstack extras pack, so the editor and terminal stay in sync. Install + switch the whole pack with one command:

```bash
vstack apply vanillagreen-themes --theme ghibli-serene-nature --target ghostty,vscodium,cursor
```

## Themes (25)

Light (`uiTheme: vs`):

- Anthropic
- Catppuccin Latte
- Ghibli Serene Nature
- Kawaii Pixel
- Rosé Pine Dawn

Dark (`uiTheme: vs-dark`):

- Anthropic Dark, Anthropic Slate
- Aura Dark
- Bearded Theme Monokai Black
- Catppuccin Frappé, Catppuccin Macchiato, Catppuccin Mocha
- Citrus
- Dracula
- Flowers
- Iceberg
- Method Dark
- Pixel Corsair
- Retro City Console
- Rosé Pine, Rosé Pine Black, Rosé Pine Extra Black, Rosé Pine Moon
- Tokyo Night
- Warp

## Icon theme

`Rosé Pine Icons` — 326-icon Rose Pine-tinted file/folder/language set. Activate via **File → Preferences → Theme → File Icon Theme**.

## Install standalone

The extension is published to:

- [Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=vanillagreen.vstack-themes)
- [Open VSX Registry](https://open-vsx.org/extension/vanillagreen/vstack-themes) *(for VSCodium / Cursor / OSS forks)*

Install in any editor via its marketplace, or run:

```bash
codium --install-extension vanillagreen.vstack-themes
```

The extension is also bundled by [vstack](https://github.com/vanillagreencom/vstack/blob/main/extras/README.md), which installs the matching Ghostty palette + shaders alongside it.

## Attribution

This pack redistributes content from several MIT-licensed upstream projects, combined and themed for vanillagreen:

- **Catppuccin** (`catppuccin.catppuccin-vsc`) — frappe, latte, macchiato, mocha
- **Dracula Theme** (`dracula-theme/visual-studio-code` v2.24.3) — dracula
- **Iceberg** (`cocopon/vscode-iceberg-theme`) — iceberg
- **Tokyo Night** (`avetis.tokyo-night`) — tokyo-night (Gogh variant)
- **BeardedBear** (`beardedbear.beardedtheme`) — bearded-theme-monokai-black
- **Rosé Pine** (`mvllow.rose-pine`) — rose-pine, rose-pine-moon (+ the four generic icon SVGs)
- **Rosé Pine Symbols** (`ravenothere.rose-pine-symbols`, itself a fork of `miguelsolorio.vscode-symbols`) — the 326 file/folder icons
- All other themes (anthropic*, aura-dark, citrus, flowers, ghibli-serene-nature, kawaii-pixel, method-dark, pixel-corsair, retro-city-console, rose-pine-black, rose-pine-dawn, rose-pine-extra-black, warp) — original vanillagreen palettes.

See `LICENSE.txt` for the full combined notice.

## License

MIT.
