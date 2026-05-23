use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::path::{Component, Path, PathBuf};

/// Extra package discovered under `extras/<name>/extra.toml`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Extra {
    pub kind: ExtraKind,
    pub theme_pack: ThemePack,
    /// Directory containing the extra's `extra.toml`.
    #[serde(skip)]
    pub source_dir: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ExtraKind {
    ThemePack,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ThemePack {
    pub name: String,
    pub description: String,
    #[serde(rename = "default-theme")]
    pub default_theme: String,
    #[serde(default)]
    pub targets: Vec<String>,
    #[serde(default)]
    pub themes: Vec<ThemeSpec>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ThemeSpec {
    pub id: String,
    pub display: String,
    #[serde(default)]
    pub ghostty: Option<GhosttyThemeSpec>,
    #[serde(default)]
    pub vscode: Option<VscodeThemeSpec>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GhosttyThemeSpec {
    #[serde(rename = "theme-file")]
    pub theme_file: String,
    #[serde(default)]
    pub shaders: Vec<String>,
    #[serde(default, rename = "pulse-shader")]
    pub pulse_shader: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VscodeThemeSpec {
    #[serde(rename = "theme-name")]
    pub theme_name: String,
    #[serde(rename = "theme-file")]
    pub theme_file: String,
}

#[derive(Debug, Deserialize)]
struct RawExtraManifest {
    name: String,
    kind: ExtraKind,
    description: String,
    #[serde(rename = "default-theme")]
    default_theme: String,
    #[serde(default)]
    targets: Vec<String>,
    #[serde(default)]
    themes: Vec<ThemeSpec>,
}

impl Extra {
    /// Parse an extra manifest from `extras/<name>/extra.toml`.
    pub fn from_dir(dir: &Path) -> Result<Self> {
        let manifest_path = dir.join("extra.toml");
        Self::from_manifest(&manifest_path)
    }

    /// Parse an extra manifest at an explicit path.
    pub fn from_manifest(manifest_path: &Path) -> Result<Self> {
        let raw = std::fs::read_to_string(manifest_path)
            .with_context(|| format!("reading {}", manifest_path.display()))?;
        let parsed: RawExtraManifest =
            toml::from_str(&raw).with_context(|| format!("parsing {}", manifest_path.display()))?;
        let source_dir = manifest_path
            .parent()
            .unwrap_or(Path::new("."))
            .to_path_buf();
        let theme_pack = ThemePack {
            name: parsed.name,
            description: parsed.description,
            default_theme: parsed.default_theme,
            targets: parsed.targets,
            themes: parsed.themes,
        };
        validate_theme_pack_paths(&theme_pack, &source_dir, manifest_path)?;
        Ok(Self {
            kind: parsed.kind,
            theme_pack,
            source_dir,
        })
    }

    pub fn name(&self) -> &str {
        &self.theme_pack.name
    }

    pub fn description(&self) -> &str {
        &self.theme_pack.description
    }
}

/// Discover all extras in a source repo by scanning `<source>/extras/*/extra.toml`.
pub fn discover_extras(source_root: &Path) -> Result<Vec<Extra>> {
    let extras_dir = source_root.join("extras");
    let mut extras = Vec::new();
    if !extras_dir.exists() {
        return Ok(extras);
    }

    for entry in std::fs::read_dir(&extras_dir)
        .with_context(|| format!("reading {}", extras_dir.display()))?
    {
        let entry = entry?;
        let path = entry.path();
        if !path.is_dir() || !path.join("extra.toml").exists() {
            continue;
        }
        extras.push(Extra::from_dir(&path)?);
    }

    extras.sort_by(|a, b| a.name().cmp(b.name()));
    Ok(extras)
}

fn validate_theme_pack_paths(
    theme_pack: &ThemePack,
    source_dir: &Path,
    manifest_path: &Path,
) -> Result<()> {
    for theme in &theme_pack.themes {
        if let Some(ghostty) = &theme.ghostty {
            validate_manifest_path(&ghostty.theme_file, source_dir, manifest_path)?;
            for shader in &ghostty.shaders {
                validate_manifest_path(shader, source_dir, manifest_path)?;
            }
            if let Some(pulse_shader) = &ghostty.pulse_shader {
                validate_manifest_path(pulse_shader, source_dir, manifest_path)?;
            }
        }
        if let Some(vscode) = &theme.vscode {
            validate_manifest_path(&vscode.theme_file, source_dir, manifest_path)?;
        }
    }
    Ok(())
}

fn validate_manifest_path(path_value: &str, source_dir: &Path, manifest_path: &Path) -> Result<()> {
    let rel = Path::new(path_value);
    if path_value.trim().is_empty() {
        bail!(
            "manifest path `{path_value}` in {} must not be empty",
            manifest_path.display()
        );
    }
    if rel.is_absolute() {
        bail!(
            "manifest path `{path_value}` in {} must be relative and stay inside the extra directory",
            manifest_path.display()
        );
    }

    for component in rel.components() {
        match component {
            Component::ParentDir => bail!(
                "manifest path `{path_value}` in {} must not contain `..`",
                manifest_path.display()
            ),
            Component::Prefix(_) | Component::RootDir => bail!(
                "manifest path `{path_value}` in {} must be relative and stay inside the extra directory",
                manifest_path.display()
            ),
            Component::CurDir | Component::Normal(_) => {}
        }
    }

    let resolved = source_dir.join(rel);
    if resolved == source_dir || !resolved.starts_with(source_dir) {
        bail!(
            "manifest path `{path_value}` in {} must resolve inside the extra directory {}",
            manifest_path.display(),
            source_dir.display()
        );
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn sandbox(label: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "vstack_extra_{label}_{}_{}",
            std::process::id(),
            unique
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn valid_manifest(name: &str) -> String {
        format!(
            r#"name = "{name}"
kind = "theme-pack"
description = "Matched themes."
default-theme = "forest"
targets = ["ghostty", "vscode"]

[[themes]]
id = "forest"
display = "Forest"

[themes.ghostty]
theme-file = "ghostty/themes/forest.conf"
shaders = ["ghostty/shaders/forest.glsl"]
pulse-shader = "ghostty/shaders/forest-pulse.glsl"

[themes.vscode]
theme-name = "Forest"
theme-file = "vscode/themes/forest-color-theme.json"
"#
        )
    }

    fn write_extra(root: &Path, dir_name: &str, manifest: &str) -> PathBuf {
        let extra_dir = root.join("extras").join(dir_name);
        fs::create_dir_all(&extra_dir).unwrap();
        fs::write(extra_dir.join("extra.toml"), manifest).unwrap();
        extra_dir
    }

    #[test]
    fn parses_valid_theme_pack_manifest() {
        let root = sandbox("valid");
        let extra_dir = write_extra(&root, "themes", &valid_manifest("themes"));

        let extra = Extra::from_dir(&extra_dir).unwrap();

        assert_eq!(extra.kind, ExtraKind::ThemePack);
        assert_eq!(extra.name(), "themes");
        assert_eq!(extra.description(), "Matched themes.");
        assert_eq!(extra.theme_pack.default_theme, "forest");
        assert_eq!(extra.theme_pack.targets, vec!["ghostty", "vscode"]);
        assert_eq!(extra.theme_pack.themes.len(), 1);
        let theme = &extra.theme_pack.themes[0];
        assert_eq!(theme.id, "forest");
        assert_eq!(theme.display, "Forest");
        assert_eq!(
            theme.ghostty.as_ref().unwrap().theme_file,
            "ghostty/themes/forest.conf"
        );
        assert_eq!(
            theme.vscode.as_ref().unwrap().theme_file,
            "vscode/themes/forest-color-theme.json"
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn malformed_manifest_error_includes_file_path() {
        let root = sandbox("malformed");
        let extra_dir = write_extra(&root, "broken", "kind = \"theme-pack\"\n");
        let manifest = extra_dir.join("extra.toml");

        let err = Extra::from_dir(&extra_dir).unwrap_err();
        let msg = format!("{err:#}");

        assert!(msg.contains(&manifest.display().to_string()), "{msg}");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn rejects_manifest_path_that_escapes_extra_dir() {
        let root = sandbox("escape");
        let manifest = valid_manifest("escape")
            .replace("ghostty/themes/forest.conf", "../outside/forest.conf");
        let extra_dir = write_extra(&root, "escape", &manifest);
        let manifest_path = extra_dir.join("extra.toml");

        let err = Extra::from_dir(&extra_dir).unwrap_err();
        let msg = format!("{err:#}");

        assert!(msg.contains("../outside/forest.conf"), "{msg}");
        assert!(msg.contains(&manifest_path.display().to_string()), "{msg}");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn rejects_absolute_manifest_path() {
        let root = sandbox("absolute");
        let absolute = std::env::temp_dir()
            .join("forest.conf")
            .to_string_lossy()
            .replace('\\', "\\\\");
        let manifest = valid_manifest("absolute").replace("ghostty/themes/forest.conf", &absolute);
        let extra_dir = write_extra(&root, "absolute", &manifest);
        let manifest_path = extra_dir.join("extra.toml");

        let err = Extra::from_dir(&extra_dir).unwrap_err();
        let msg = format!("{err:#}");

        assert!(msg.contains(&absolute), "{msg}");
        assert!(msg.contains(&manifest_path.display().to_string()), "{msg}");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn discover_extras_returns_empty_when_extras_dir_absent() {
        let root = sandbox("absent");

        let extras = discover_extras(&root).unwrap();

        assert!(extras.is_empty());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn discover_extras_discovers_multiple_extras() {
        let root = sandbox("multiple");
        write_extra(&root, "zeta", &valid_manifest("zeta"));
        write_extra(&root, "alpha", &valid_manifest("alpha"));
        fs::create_dir_all(root.join("extras").join("ignored")).unwrap();

        let extras = discover_extras(&root).unwrap();
        let names: Vec<&str> = extras.iter().map(|e| e.name()).collect();

        assert_eq!(names, vec!["alpha", "zeta"]);
        let _ = fs::remove_dir_all(root);
    }
}
