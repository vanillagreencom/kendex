use anyhow::{Context, Result, bail};
use serde_json::Value;
use std::collections::BTreeSet;
use std::fs::File;
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use walkdir::WalkDir;
use zip::CompressionMethod;
use zip::write::FileOptions;

/// Top-level directories or filenames inside `extension_root` that the bundler skips.
/// Build artifacts and VCS metadata are never shipped in the VSIX even when present.
const EXTENSION_BUNDLE_DENYLIST: &[&str] = &[
    ".git",
    ".gitignore",
    ".gitattributes",
    ".vscode",
    ".vscode-test",
    ".vscodeignore",
    "node_modules",
    "target",
    ".DS_Store",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VsixInfo {
    pub extension_id: String,
    pub package_name: String,
    pub publisher: String,
    pub version: String,
    pub included_theme_files: Vec<PathBuf>,
}

#[derive(Debug, Clone)]
struct PackageInfo {
    name: String,
    publisher: String,
    version: String,
    display_name: String,
    description: String,
    categories: Vec<String>,
    vscode_engine: Option<String>,
    theme_paths: Vec<PathBuf>,
}

impl PackageInfo {
    fn extension_id(&self) -> String {
        format!("{}.{}", self.publisher, self.name)
    }
}

pub fn write_vsix(
    extension_root: &Path,
    package_json_path: &Path,
    output_path: &Path,
) -> Result<VsixInfo> {
    let package_json = std::fs::read_to_string(package_json_path).with_context(|| {
        format!(
            "reading VS Code package manifest {}",
            package_json_path.display()
        )
    })?;
    let package = parse_package_info(&package_json).with_context(|| {
        format!(
            "parsing VS Code package manifest {}",
            package_json_path.display()
        )
    })?;

    if let Some(parent) = output_path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating VSIX output directory {}", parent.display()))?;
    }

    let file = File::create(output_path)
        .with_context(|| format!("creating VSIX {}", output_path.display()))?;
    let mut zip = zip::ZipWriter::new(file);
    let options = FileOptions::default()
        .compression_method(CompressionMethod::Stored)
        .unix_permissions(0o644);

    write_zip_entry(
        &mut zip,
        "[Content_Types].xml",
        content_types_xml().as_bytes(),
        options,
    )?;
    write_zip_entry(
        &mut zip,
        "extension.vsixmanifest",
        vsix_manifest_xml(&package).as_bytes(),
        options,
    )?;
    write_zip_entry(
        &mut zip,
        "extension/package.json",
        package_json.as_bytes(),
        options,
    )?;

    // Track every file added to the VSIX (relative to extension/) so the
    // post-theme directory walk doesn't double-bundle anything.
    let mut already_bundled: BTreeSet<String> = BTreeSet::new();
    already_bundled.insert("package.json".to_string());

    let mut seen_theme_basenames = BTreeSet::new();
    let mut included_theme_files = Vec::new();
    for theme_path in &package.theme_paths {
        let source = extension_root.join(theme_path);
        let basename = theme_path.file_name().ok_or_else(|| {
            anyhow::anyhow!(
                "theme path `{}` in {} has no file name",
                theme_path.display(),
                package_json_path.display()
            )
        })?;
        let basename_string = basename.to_string_lossy().to_string();
        if !seen_theme_basenames.insert(basename_string.clone()) {
            bail!(
                "multiple VS Code themes in {} resolve to basename `{basename_string}`; VSIX writer keeps themes under extension/themes/",
                package_json_path.display()
            );
        }

        let mut contents = Vec::new();
        File::open(&source)
            .with_context(|| format!("opening VS Code theme file {}", source.display()))?
            .read_to_end(&mut contents)
            .with_context(|| format!("reading VS Code theme file {}", source.display()))?;
        let entry = format!("extension/themes/{basename_string}");
        write_zip_entry(&mut zip, &entry, &contents, options)?;
        included_theme_files.push(source);
        already_bundled.insert(format!("themes/{basename_string}"));
    }

    // Bundle every other file under `extension_root` so iconThemes, README,
    // LICENSE, ext icon, and arbitrary asset directories ship with the VSIX.
    // Skip the manifest + theme files we already wrote, plus a small denylist
    // of VCS / build artifacts.
    for entry in WalkDir::new(extension_root).follow_links(false) {
        let entry = entry
            .with_context(|| format!("walking extension root {}", extension_root.display()))?;
        if !entry.file_type().is_file() {
            continue;
        }
        let path = entry.path();
        let rel = path
            .strip_prefix(extension_root)
            .with_context(|| format!("path outside extension root: {}", path.display()))?;
        if rel.components().any(|c| matches!(c, Component::Normal(p) if EXTENSION_BUNDLE_DENYLIST.iter().any(|d| p == std::ffi::OsStr::new(*d)))) {
            continue;
        }
        let rel_str = rel.to_string_lossy().replace('\\', "/");
        if rel_str.is_empty() || rel_str == "package.json" || already_bundled.contains(&rel_str) {
            continue;
        }
        let contents = std::fs::read(path)
            .with_context(|| format!("reading bundled file {}", path.display()))?;
        let zip_entry = format!("extension/{rel_str}");
        write_zip_entry(&mut zip, &zip_entry, &contents, options)?;
        already_bundled.insert(rel_str);
    }

    zip.finish()
        .with_context(|| format!("finalizing VSIX {}", output_path.display()))?;

    Ok(VsixInfo {
        extension_id: package.extension_id(),
        package_name: package.name,
        publisher: package.publisher,
        version: package.version,
        included_theme_files,
    })
}

fn write_zip_entry<W: Write + std::io::Seek>(
    zip: &mut zip::ZipWriter<W>,
    name: &str,
    contents: &[u8],
    options: FileOptions,
) -> Result<()> {
    zip.start_file(name, options)
        .with_context(|| format!("starting VSIX entry {name}"))?;
    zip.write_all(contents)
        .with_context(|| format!("writing VSIX entry {name}"))?;
    Ok(())
}

fn parse_package_info(package_json: &str) -> Result<PackageInfo> {
    let value: Value =
        serde_json::from_str(package_json).context("package.json is not valid JSON")?;
    let name = required_string(&value, "name")?.to_string();
    let publisher = required_string(&value, "publisher")?.to_string();
    let version = required_string(&value, "version")?.to_string();
    let display_name = optional_string(&value, "displayName")
        .unwrap_or(&name)
        .to_string();
    let description = optional_string(&value, "description")
        .unwrap_or("")
        .to_string();
    let vscode_engine = value
        .get("engines")
        .and_then(|engines| engines.get("vscode"))
        .and_then(Value::as_str)
        .map(str::to_string);
    let categories = value
        .get("categories")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    let themes = value
        .get("contributes")
        .and_then(|contributes| contributes.get("themes"))
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow::anyhow!("package.json must contain contributes.themes[]"))?;
    if themes.is_empty() {
        bail!("package.json contributes.themes[] must contain at least one theme");
    }

    let mut theme_paths = Vec::new();
    for theme in themes {
        let raw = theme.get("path").and_then(Value::as_str).ok_or_else(|| {
            anyhow::anyhow!("each contributes.themes[] item must contain a string path")
        })?;
        theme_paths.push(validate_relative_manifest_path(
            raw,
            "contributes.themes[].path",
        )?);
    }

    Ok(PackageInfo {
        name,
        publisher,
        version,
        display_name,
        description,
        categories,
        vscode_engine,
        theme_paths,
    })
}

fn required_string<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow::anyhow!("package.json must contain a non-empty string `{key}`"))
}

fn optional_string<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
}

fn validate_relative_manifest_path(raw: &str, field: &str) -> Result<PathBuf> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        bail!("{field} must not be empty");
    }
    let without_dot = trimmed.strip_prefix("./").unwrap_or(trimmed);
    let path = Path::new(without_dot);
    if path.is_absolute() {
        bail!("{field} `{raw}` must be relative");
    }
    for component in path.components() {
        match component {
            Component::ParentDir => bail!("{field} `{raw}` must not contain `..`"),
            Component::Prefix(_) | Component::RootDir => bail!("{field} `{raw}` must be relative"),
            Component::CurDir | Component::Normal(_) => {}
        }
    }
    Ok(path.to_path_buf())
}

fn content_types_xml() -> &'static str {
    r#"<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="json" ContentType="application/json" />
  <Default Extension="vsixmanifest" ContentType="text/xml" />
</Types>
"#
}

fn vsix_manifest_xml(package: &PackageInfo) -> String {
    let categories = if package.categories.is_empty() {
        "Themes".to_string()
    } else {
        package.categories.join(",")
    };
    let engine = package.vscode_engine.as_deref().unwrap_or("*");
    format!(
        r#"<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="{}" Version="{}" Publisher="{}" />
    <DisplayName>{}</DisplayName>
    <Description xml:space="preserve">{}</Description>
    <Categories>{}</Categories>
    <Tags>theme,color-theme</Tags>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="{}" />
    </Properties>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code" />
  </Installation>
  <Dependencies />
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" />
  </Assets>
</PackageManifest>
"#,
        xml_escape(&package.name),
        xml_escape(&package.version),
        xml_escape(&package.publisher),
        xml_escape(&package.display_name),
        xml_escape(&package.description),
        xml_escape(&categories),
        xml_escape(engine),
    )
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

#[cfg(test)]
mod tests {
    #[test]
    fn bundles_icon_theme_and_assets_alongside_themes() {
        // Synthesize a small extension tree that mirrors a real theme pack:
        // package.json (with 1 color theme + 1 icon theme + pkg.icon), themes/<theme>.json,
        // icon-theme/<icon-theme>.json, icon-theme/icons/files/foo.svg, icon.png, README.md, LICENSE.txt.
        let root = sandbox("bundle");
        let _cleanup = scopeguard_remove(root.clone());
        let root = root.as_path();
        let pkg = r#"{
            "name": "sample-pack",
            "displayName": "Sample",
            "publisher": "test",
            "version": "1.0.0",
            "description": "d",
            "icon": "icon.png",
            "engines": {"vscode": "^1.60.0"},
            "categories": ["Themes"],
            "contributes": {
                "themes": [{"label": "Sample", "uiTheme": "vs-dark", "path": "./themes/sample-color-theme.json"}],
                "iconThemes": [{"id": "sample-icons", "label": "Sample Icons", "path": "./icon-theme/sample-icons.json"}]
            }
        }"#;
        std::fs::write(root.join("package.json"), pkg).unwrap();
        std::fs::create_dir_all(root.join("themes")).unwrap();
        std::fs::write(root.join("themes/sample-color-theme.json"), r#"{"name":"Sample"}"#).unwrap();
        std::fs::create_dir_all(root.join("icon-theme/icons/files")).unwrap();
        std::fs::write(root.join("icon-theme/sample-icons.json"), r#"{"iconDefinitions":{}}"#).unwrap();
        std::fs::write(root.join("icon-theme/icons/files/foo.svg"), "<svg/>").unwrap();
        std::fs::write(root.join("icon.png"), b"\x89PNG\r\n\x1a\n").unwrap();
        std::fs::write(root.join("README.md"), "# Sample").unwrap();
        std::fs::write(root.join("LICENSE.txt"), "MIT").unwrap();
        // Denylisted entries that must NOT end up in the VSIX
        std::fs::create_dir_all(root.join(".git")).unwrap();
        std::fs::write(root.join(".git/HEAD"), "ref: refs/heads/main").unwrap();
        std::fs::create_dir_all(root.join("node_modules/dep")).unwrap();
        std::fs::write(root.join("node_modules/dep/index.js"), "// dep").unwrap();

        let vsix_path = root.join("out.vsix");
        let _info = super::write_vsix(root, &root.join("package.json"), &vsix_path).expect("vsix");

        // Read the VSIX and list entries
        let f = std::fs::File::open(&vsix_path).unwrap();
        let mut archive = zip::ZipArchive::new(f).unwrap();
        let mut names: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
        for i in 0..archive.len() {
            let entry = archive.by_index(i).unwrap();
            names.insert(entry.name().to_string());
        }

        let expected = [
            "extension/package.json",
            "extension/themes/sample-color-theme.json",
            "extension/icon-theme/sample-icons.json",
            "extension/icon-theme/icons/files/foo.svg",
            "extension/icon.png",
            "extension/README.md",
            "extension/LICENSE.txt",
        ];
        for e in expected {
            assert!(names.contains(e), "VSIX missing {e}; got: {names:?}");
        }
        // Denylist must be excluded
        for d in ["extension/.git/HEAD", "extension/node_modules/dep/index.js"] {
            assert!(!names.contains(d), "VSIX should not contain {d}");
        }
    }

    fn scopeguard_remove(root: std::path::PathBuf) -> ScopeRemove {
        ScopeRemove { root }
    }
    struct ScopeRemove { root: std::path::PathBuf }
    impl Drop for ScopeRemove {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    use super::*;
    use std::fs;
    use std::io::Read;
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn sandbox(label: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "vstack_vsix_{label}_{}_{}",
            std::process::id(),
            unique
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write_fixture(root: &Path) -> (PathBuf, PathBuf) {
        let extension_root = root.join("vscode");
        fs::create_dir_all(extension_root.join("themes")).unwrap();
        let package_json = extension_root.join("package.json");
        fs::write(
            &package_json,
            r#"{
  "name": "vanillagreen-themes",
  "displayName": "Vanillagreen Themes",
  "description": "Matched themes & colors.",
  "version": "0.1.0",
  "publisher": "vanillagreen",
  "engines": { "vscode": "^1.85.0" },
  "categories": ["Themes"],
  "contributes": {
    "themes": [
      { "label": "Forest", "uiTheme": "vs", "path": "./themes/forest-color-theme.json" }
    ]
  }
}
"#,
        )
        .unwrap();
        fs::write(
            extension_root.join("themes/forest-color-theme.json"),
            r#"{"name":"Forest","type":"light","colors":{}}"#,
        )
        .unwrap();
        (extension_root, package_json)
    }

    fn find_cli(name: &str) -> Option<PathBuf> {
        std::env::split_paths(&std::env::var_os("PATH")?)
            .map(|dir| dir.join(name))
            .find(|candidate| candidate.is_file())
    }

    #[test]
    fn vsix_writer_produces_required_entries_and_manifest() {
        let root = sandbox("entries");
        let (extension_root, package_json) = write_fixture(&root);
        let vsix_path = root.join("out/theme.vsix");

        let info = write_vsix(&extension_root, &package_json, &vsix_path).unwrap();

        assert_eq!(info.extension_id, "vanillagreen.vanillagreen-themes");
        assert_eq!(info.included_theme_files.len(), 1);

        let file = File::open(&vsix_path).unwrap();
        let mut archive = zip::ZipArchive::new(file).unwrap();
        let mut names = Vec::new();
        for index in 0..archive.len() {
            names.push(archive.by_index(index).unwrap().name().to_string());
        }
        names.sort();
        assert_eq!(
            names,
            vec![
                "[Content_Types].xml",
                "extension.vsixmanifest",
                "extension/package.json",
                "extension/themes/forest-color-theme.json",
            ]
        );

        let mut manifest = String::new();
        archive
            .by_name("extension.vsixmanifest")
            .unwrap()
            .read_to_string(&mut manifest)
            .unwrap();
        assert!(manifest.contains("<PackageManifest"), "{manifest}");
        assert!(
            manifest.contains("Id=\"vanillagreen-themes\""),
            "{manifest}"
        );
        assert!(
            manifest.contains("Publisher=\"vanillagreen\""),
            "{manifest}"
        );
        assert!(
            manifest.contains("Microsoft.VisualStudio.Code.Manifest"),
            "{manifest}"
        );
        assert!(manifest.ends_with("</PackageManifest>\n"), "{manifest}");

        let mut package = String::new();
        archive
            .by_name("extension/package.json")
            .unwrap()
            .read_to_string(&mut package)
            .unwrap();
        let parsed: Value = serde_json::from_str(&package).unwrap();
        assert_eq!(parsed["name"], "vanillagreen-themes");

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn vsix_writer_rejects_escaping_theme_path() {
        let root = sandbox("escape");
        let extension_root = root.join("vscode");
        fs::create_dir_all(&extension_root).unwrap();
        let package_json = extension_root.join("package.json");
        fs::write(
            &package_json,
            r#"{
  "name": "bad",
  "version": "0.1.0",
  "publisher": "example",
  "contributes": { "themes": [{ "path": "../bad.json" }] }
}
"#,
        )
        .unwrap();

        let err = write_vsix(&extension_root, &package_json, &root.join("bad.vsix")).unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("must not contain `..`"), "{msg}");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn detected_editor_clis_install_vsix_in_sandbox() {
        let editors = ["code", "codium", "cursor"];
        let available: Vec<(&str, PathBuf)> = editors
            .iter()
            .filter_map(|name| find_cli(name).map(|path| (*name, path)))
            .collect();
        if available.is_empty() {
            eprintln!("skipping VS Code-family VSIX install integration test: no editor CLI found");
            return;
        }

        for (name, cli) in available {
            let root = sandbox(&format!("install_{name}"));
            let (extension_root, package_json) = write_fixture(&root);
            let vsix_path = root.join("theme.vsix");
            let info = write_vsix(&extension_root, &package_json, &vsix_path).unwrap();
            let user_data = root.join("user-data");
            let extensions_dir = root.join("extensions");

            let install = Command::new(&cli)
                .arg("--user-data-dir")
                .arg(&user_data)
                .arg("--extensions-dir")
                .arg(&extensions_dir)
                .arg("--install-extension")
                .arg(&vsix_path)
                .arg("--force")
                .output()
                .unwrap_or_else(|err| panic!("failed to run {name}: {err}"));
            assert!(
                install.status.success(),
                "{name} install failed\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&install.stdout),
                String::from_utf8_lossy(&install.stderr)
            );

            let listed = Command::new(&cli)
                .arg("--user-data-dir")
                .arg(&user_data)
                .arg("--extensions-dir")
                .arg(&extensions_dir)
                .arg("--list-extensions")
                .output()
                .unwrap_or_else(|err| panic!("failed to list {name} extensions: {err}"));
            assert!(
                listed.status.success(),
                "{name} list failed\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&listed.stdout),
                String::from_utf8_lossy(&listed.stderr)
            );
            let stdout = String::from_utf8_lossy(&listed.stdout);
            assert!(
                stdout
                    .lines()
                    .any(|line| line.trim().eq_ignore_ascii_case(&info.extension_id)),
                "{name} did not list {} in:\n{stdout}",
                info.extension_id
            );

            let _ = fs::remove_dir_all(root);
        }
    }
}
