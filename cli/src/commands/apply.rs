use crate::config;
use crate::extra::{Extra, ExtraKind, ThemeSpec};
use anyhow::{Context, Result, bail};
use std::collections::BTreeSet;
use std::ffi::OsString;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const GHOSTTY_TARGET: &str = "ghostty";
const VSCODE_TARGET: &str = "vscode";
const VSCODIUM_TARGET: &str = "vscodium";
const CURSOR_TARGET: &str = "cursor";

#[derive(Debug, Clone)]
pub struct ApplyRequest {
    pub extra_name: String,
    pub theme_id: Option<String>,
    pub targets: Option<Vec<String>>,
    pub global: bool,
    pub dry_run: bool,
    pub yes: bool,
}

#[derive(Debug, Clone)]
struct ApplyEnvironment {
    home_dir: PathBuf,
    config_dir: PathBuf,
    temp_dir: PathBuf,
    path_entries: Vec<PathBuf>,
    timestamp: String,
}

#[derive(Debug, Clone)]
struct ApplyPlan {
    extra_name: String,
    theme_id: String,
    theme_display: String,
    global: bool,
    targets: Vec<TargetPlan>,
    warnings: Vec<String>,
}

#[derive(Debug, Clone)]
struct TargetPlan {
    name: String,
    cli_name: String,
    cli_path: Option<PathBuf>,
    config_dir: PathBuf,
    config_file: PathBuf,
    backup_file: PathBuf,
    copies: Vec<FileCopyPlan>,
    managed_block: Option<String>,
    json_change: Option<JsonChangePlan>,
    vsix_path: Option<PathBuf>,
    commands: Vec<Vec<String>>,
}

#[derive(Debug, Clone)]
struct FileCopyPlan {
    source: PathBuf,
    destination: PathBuf,
}

#[derive(Debug, Clone)]
struct JsonChangePlan {
    key: String,
    value: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TargetKind {
    Ghostty,
    Vscode,
    Vscodium,
    Cursor,
}

#[derive(Debug, Clone)]
struct ResolvedTarget {
    name: String,
    kind: TargetKind,
    cli_name: String,
    cli_path: PathBuf,
}

impl ApplyEnvironment {
    fn current() -> Self {
        let path_entries = std::env::var_os("PATH")
            .map(split_paths)
            .unwrap_or_default();
        Self {
            home_dir: config::user_home_dir(),
            config_dir: config::user_config_dir(),
            temp_dir: std::env::temp_dir(),
            path_entries,
            timestamp: timestamp_now(),
        }
    }

    fn find_cli(&self, cli_name: &str) -> Option<PathBuf> {
        self.path_entries
            .iter()
            .map(|dir| dir.join(cli_name))
            .find(|candidate| candidate.is_file())
    }

    fn display_path(&self, path: &Path) -> String {
        if let Ok(rel) = path.strip_prefix(&self.home_dir) {
            if rel.as_os_str().is_empty() {
                "~".into()
            } else {
                format!("~/{}", rel.display())
            }
        } else {
            path.display().to_string()
        }
    }
}

impl TargetKind {
    fn from_target_name(name: &str) -> Option<Self> {
        match name {
            GHOSTTY_TARGET => Some(Self::Ghostty),
            VSCODE_TARGET => Some(Self::Vscode),
            VSCODIUM_TARGET => Some(Self::Vscodium),
            CURSOR_TARGET => Some(Self::Cursor),
            _ => None,
        }
    }

    fn cli_name(self) -> &'static str {
        match self {
            Self::Ghostty => "ghostty",
            Self::Vscode => "code",
            Self::Vscodium => "codium",
            Self::Cursor => "cursor",
        }
    }

    fn is_vscode_family(self) -> bool {
        matches!(self, Self::Vscode | Self::Vscodium | Self::Cursor)
    }
}

pub fn run(
    extra_name: String,
    theme_id: Option<String>,
    target_list: Option<String>,
    global: bool,
    dry_run: bool,
    yes: bool,
) -> Result<()> {
    let request = ApplyRequest {
        extra_name,
        theme_id,
        targets: parse_target_list(target_list.as_deref())?,
        global,
        dry_run,
        yes,
    };
    let env = ApplyEnvironment::current();
    let source_root = resolve_apply_source_root()?;
    let plan = build_plan_for_source(&source_root, &request, &env)?;

    for warning in &plan.warnings {
        eprintln!("warning: {warning}");
    }

    let rendered = render_plan(&plan, &env, request.dry_run);
    print!("{rendered}");

    if request.dry_run {
        return Ok(());
    }

    if !request.yes && !prompt_confirm()? {
        bail!("apply cancelled");
    }

    bail!("theme-pack apply is not implemented in this release; use --dry-run")
}

fn parse_target_list(raw: Option<&str>) -> Result<Option<Vec<String>>> {
    let Some(raw) = raw else {
        return Ok(None);
    };
    let targets: Vec<String> = raw
        .split(',')
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .map(str::to_string)
        .collect();
    if targets.is_empty() {
        bail!("--target requires at least one target name");
    }
    Ok(Some(targets))
}

fn resolve_apply_source_root() -> Result<PathBuf> {
    if let Some(dir) = find_source_root_with_extras_from_cwd()? {
        return Ok(dir);
    }

    let project_root = config::project_root();
    let registry =
        config::SourceRegistry::load(&config::source_registry_path()).unwrap_or_default();

    let mut candidates = Vec::new();
    if let Some(current) = registry.current_for_project(&project_root) {
        candidates.push(current.to_string());
    }
    if let Some(current) = source_from_project_lock(&project_root) {
        candidates.push(current);
    }
    if let Some(current) = registry.current.as_ref() {
        candidates.push(current.clone());
    }
    candidates.extend(registry.entries.iter().cloned());
    candidates.push(crate::REPO.to_string());

    for source in candidates {
        if let Some(path) = config::resolve_source_path(&source)
            && path.join("extras").is_dir()
        {
            return Ok(path);
        }
    }

    bail!(
        "could not find a vstack source with extras; run from a source checkout or run `vstack add {}` first",
        crate::REPO
    )
}

fn find_source_root_with_extras_from_cwd() -> Result<Option<PathBuf>> {
    let mut dir = std::env::current_dir()?;
    loop {
        if dir.join("extras").is_dir() {
            return Ok(Some(dir));
        }
        if !dir.pop() {
            return Ok(None);
        }
    }
}

fn source_from_project_lock(project_root: &Path) -> Option<String> {
    let lock = config::LockFile::load(&project_root.join(".vstack-lock.json")).ok()?;
    let mut counts = std::collections::BTreeMap::<String, usize>::new();
    for entry in lock.entries.values() {
        *counts.entry(entry.source.clone()).or_default() += 1;
    }
    counts
        .into_iter()
        .max_by(|(a_source, a_count), (b_source, b_count)| {
            a_count.cmp(b_count).then_with(|| b_source.cmp(a_source))
        })
        .map(|(source, _)| source)
}

fn build_plan_for_source(
    source_root: &Path,
    request: &ApplyRequest,
    env: &ApplyEnvironment,
) -> Result<ApplyPlan> {
    let extras = crate::extra::discover_extras(source_root)?;
    let extra = extras
        .iter()
        .find(|extra| extra.name() == request.extra_name)
        .ok_or_else(|| unknown_extra_error(&request.extra_name, &extras))?;

    if extra.kind != ExtraKind::ThemePack {
        bail!("extra `{}` is not a theme-pack", extra.name());
    }

    let theme_id = request
        .theme_id
        .as_deref()
        .unwrap_or(&extra.theme_pack.default_theme);
    let theme = extra
        .theme_pack
        .themes
        .iter()
        .find(|theme| theme.id == theme_id)
        .ok_or_else(|| unknown_theme_error(extra, theme_id))?;

    let (targets, warnings) = resolve_targets(extra, request.targets.as_deref(), env)?;
    let mut target_plans = Vec::new();
    for target in targets {
        target_plans.push(build_target_plan(extra, theme, &target, env)?);
    }

    Ok(ApplyPlan {
        extra_name: extra.name().to_string(),
        theme_id: theme.id.clone(),
        theme_display: theme.display.clone(),
        global: request.global,
        targets: target_plans,
        warnings,
    })
}

fn unknown_extra_error(extra_name: &str, extras: &[Extra]) -> anyhow::Error {
    let available = list_or_none(extras.iter().map(|extra| extra.name().to_string()));
    anyhow::anyhow!("unknown extra `{extra_name}`; available extras: {available}")
}

fn unknown_theme_error(extra: &Extra, theme_id: &str) -> anyhow::Error {
    let available = list_or_none(extra.theme_pack.themes.iter().map(|theme| theme.id.clone()));
    anyhow::anyhow!(
        "unknown theme `{theme_id}` for extra `{}`; available themes: {available}",
        extra.name()
    )
}

fn resolve_targets(
    extra: &Extra,
    explicit_targets: Option<&[String]>,
    env: &ApplyEnvironment,
) -> Result<(Vec<ResolvedTarget>, Vec<String>)> {
    let declared: BTreeSet<&str> = extra
        .theme_pack
        .targets
        .iter()
        .map(String::as_str)
        .collect();
    if declared.is_empty() {
        bail!("extra `{}` declares no targets", extra.name());
    }

    let target_names: Vec<String> = match explicit_targets {
        Some(targets) => {
            for target in targets {
                if !declared.contains(target.as_str()) {
                    let declared_list = list_or_none(extra.theme_pack.targets.iter().cloned());
                    bail!(
                        "unknown target `{target}` for extra `{}`; declared targets: {declared_list}",
                        extra.name()
                    );
                }
            }
            dedupe_preserving_order(targets.iter().cloned())
        }
        None => extra.theme_pack.targets.clone(),
    };

    let mut resolved = Vec::new();
    let mut warnings = Vec::new();
    for target_name in target_names {
        let Some(kind) = TargetKind::from_target_name(&target_name) else {
            bail!(
                "target `{target_name}` is declared by extra `{}` but is not supported by `vstack apply` yet",
                extra.name()
            );
        };
        let cli_name = kind.cli_name().to_string();
        match env.find_cli(&cli_name) {
            Some(cli_path) => resolved.push(ResolvedTarget {
                name: target_name,
                kind,
                cli_name,
                cli_path,
            }),
            None if explicit_targets.is_some() => bail!(
                "target `{target_name}` was requested explicitly but CLI `{cli_name}` was not found on PATH"
            ),
            None => warnings.push(format!(
                "target `{target_name}` skipped: CLI `{cli_name}` not found on PATH"
            )),
        }
    }

    if resolved.is_empty() {
        bail!(
            "no declared targets for extra `{}` are available on this system; install one of: {}",
            extra.name(),
            extra
                .theme_pack
                .targets
                .iter()
                .filter_map(|target| TargetKind::from_target_name(target).map(TargetKind::cli_name))
                .collect::<BTreeSet<_>>()
                .into_iter()
                .collect::<Vec<_>>()
                .join(", ")
        );
    }

    Ok((resolved, warnings))
}

fn build_target_plan(
    extra: &Extra,
    theme: &ThemeSpec,
    target: &ResolvedTarget,
    env: &ApplyEnvironment,
) -> Result<TargetPlan> {
    match target.kind {
        TargetKind::Ghostty => build_ghostty_plan(extra, theme, target, env),
        TargetKind::Vscode | TargetKind::Vscodium | TargetKind::Cursor => {
            build_vscode_family_plan(extra, theme, target, env)
        }
    }
}

fn build_ghostty_plan(
    extra: &Extra,
    theme: &ThemeSpec,
    target: &ResolvedTarget,
    env: &ApplyEnvironment,
) -> Result<TargetPlan> {
    let ghostty = theme.ghostty.as_ref().with_context(|| {
        format!(
            "theme `{}` does not define Ghostty settings required for target `{}`",
            theme.id, target.name
        )
    })?;

    let config_dir = ghostty_config_dir(env);
    let config_file = ghostty_config_file(&config_dir);
    let backup_file = backup_path(&config_file, &env.timestamp);
    let theme_destination = config_dir.join("themes").join("vstack").join(&theme.id);
    let mut copies = vec![FileCopyPlan {
        source: extra.source_dir.join(&ghostty.theme_file),
        destination: theme_destination,
    }];

    let mut shader_destinations = Vec::new();
    for shader in &ghostty.shaders {
        let destination = shader_destination(&config_dir, shader)?;
        shader_destinations.push(destination.clone());
        copies.push(FileCopyPlan {
            source: extra.source_dir.join(shader),
            destination,
        });
    }
    if let Some(pulse_shader) = &ghostty.pulse_shader {
        copies.push(FileCopyPlan {
            source: extra.source_dir.join(pulse_shader),
            destination: shader_destination(&config_dir, pulse_shader)?,
        });
    }

    let managed_block = ghostty_managed_block(extra.name(), theme, &shader_destinations);
    let commands = vec![vec![
        target.cli_path.display().to_string(),
        "+validate-config".to_string(),
        "--config-file".to_string(),
        config_file.display().to_string(),
    ]];

    Ok(TargetPlan {
        name: target.name.clone(),
        cli_name: target.cli_name.clone(),
        cli_path: Some(target.cli_path.clone()),
        config_dir,
        config_file,
        backup_file,
        copies,
        managed_block: Some(managed_block),
        json_change: None,
        vsix_path: None,
        commands,
    })
}

fn build_vscode_family_plan(
    extra: &Extra,
    theme: &ThemeSpec,
    target: &ResolvedTarget,
    env: &ApplyEnvironment,
) -> Result<TargetPlan> {
    debug_assert!(target.kind.is_vscode_family());
    let vscode = theme.vscode.as_ref().with_context(|| {
        format!(
            "theme `{}` does not define VS Code-family settings required for target `{}`",
            theme.id, target.name
        )
    })?;

    let user_dir = vscode_user_dir(target.kind, env);
    let settings_file = user_dir.join("settings.json");
    let backup_file = backup_path(&settings_file, &env.timestamp);
    let vsix_path = env
        .temp_dir
        .join(format!("vstack-{}-{}.vsix", extra.name(), theme.id));
    let commands = vec![
        vec![
            target.cli_path.display().to_string(),
            "--install-extension".to_string(),
            vsix_path.display().to_string(),
            "--force".to_string(),
        ],
        vec![
            target.cli_path.display().to_string(),
            "--list-extensions".to_string(),
        ],
    ];

    Ok(TargetPlan {
        name: target.name.clone(),
        cli_name: target.cli_name.clone(),
        cli_path: Some(target.cli_path.clone()),
        config_dir: user_dir,
        config_file: settings_file,
        backup_file,
        copies: Vec::new(),
        managed_block: None,
        json_change: Some(JsonChangePlan {
            key: "workbench.colorTheme".to_string(),
            value: vscode.theme_name.clone(),
        }),
        vsix_path: Some(vsix_path),
        commands,
    })
}

fn ghostty_config_dir(env: &ApplyEnvironment) -> PathBuf {
    if cfg!(target_os = "macos") {
        let xdg = env.config_dir.join("ghostty");
        if xdg.join("config").exists() || xdg.join("config.ghostty").exists() {
            return xdg;
        }
        env.home_dir
            .join("Library")
            .join("Application Support")
            .join("com.mitchellh.ghostty")
    } else {
        env.config_dir.join("ghostty")
    }
}

fn ghostty_config_file(config_dir: &Path) -> PathBuf {
    let config = config_dir.join("config");
    if config.exists() {
        return config;
    }
    let config_ghostty = config_dir.join("config.ghostty");
    if config_ghostty.exists() {
        return config_ghostty;
    }
    config
}

fn vscode_user_dir(kind: TargetKind, env: &ApplyEnvironment) -> PathBuf {
    let app_dir = match kind {
        TargetKind::Vscode => "Code",
        TargetKind::Vscodium => "VSCodium",
        TargetKind::Cursor => "Cursor",
        TargetKind::Ghostty => unreachable!("Ghostty is not a VS Code-family target"),
    };

    if cfg!(target_os = "macos") {
        env.home_dir
            .join("Library")
            .join("Application Support")
            .join(app_dir)
            .join("User")
    } else {
        env.config_dir.join(app_dir).join("User")
    }
}

fn shader_destination(config_dir: &Path, shader: &str) -> Result<PathBuf> {
    let file_name = Path::new(shader)
        .file_name()
        .ok_or_else(|| anyhow::anyhow!("shader path `{shader}` has no file name"))?;
    Ok(config_dir.join("shaders").join("vstack").join(file_name))
}

fn ghostty_managed_block(
    extra_name: &str,
    theme: &ThemeSpec,
    shader_destinations: &[PathBuf],
) -> String {
    let mut lines = vec![
        format!("# vstack:begin {extra_name}"),
        "# Managed by vstack. Edit source extras or remove this block to opt out.".to_string(),
        format!("theme = vstack/{}", theme.id),
    ];
    for destination in shader_destinations {
        if let Some(file_name) = destination.file_name().and_then(|name| name.to_str()) {
            lines.push(format!("custom-shader = shaders/vstack/{file_name}"));
        }
    }
    if !shader_destinations.is_empty() {
        lines.push("custom-shader-animation = always".to_string());
    }
    lines.push(format!("# vstack:end {extra_name}"));
    lines.join("\n")
}

fn backup_path(path: &Path, timestamp: &str) -> PathBuf {
    PathBuf::from(format!("{}.vstack-backup.{timestamp}", path.display()))
}

fn render_plan(plan: &ApplyPlan, env: &ApplyEnvironment, dry_run: bool) -> String {
    let mut out = String::new();
    if dry_run {
        out.push_str("vstack apply dry-run\n");
        out.push_str("No files will be written.\n");
    } else {
        out.push_str("vstack apply plan\n");
        out.push_str("No files have been written yet.\n");
    }
    out.push_str(&format!("Extra: {}\n", plan.extra_name));
    out.push_str(&format!(
        "Theme: {} ({})\n",
        plan.theme_display, plan.theme_id
    ));
    out.push_str(&format!(
        "Scope: {}\n",
        if plan.global {
            "global/user (--global supplied)"
        } else {
            "global/user (default)"
        }
    ));

    for target in &plan.targets {
        out.push('\n');
        out.push_str(&format!("Target: {}\n", target.name));
        out.push_str(&format!(
            "  CLI: {}\n",
            target
                .cli_path
                .as_ref()
                .map(|path| env.display_path(path))
                .unwrap_or_else(|| format!("not detected ({})", target.cli_name))
        ));
        out.push_str(&format!(
            "  Config dir: {}\n",
            env.display_path(&target.config_dir)
        ));
        out.push_str(&format!(
            "  Config file: {}\n",
            env.display_path(&target.config_file)
        ));
        out.push_str(&format!(
            "  Backup: {}\n",
            env.display_path(&target.backup_file)
        ));

        if let Some(vsix_path) = &target.vsix_path {
            out.push_str(&format!("  VSIX: {}\n", env.display_path(vsix_path)));
        }

        if !target.copies.is_empty() {
            out.push_str("  Files:\n");
            for copy in &target.copies {
                out.push_str(&format!(
                    "    copy {} -> {}\n",
                    env.display_path(&copy.source),
                    env.display_path(&copy.destination)
                ));
            }
        }

        if let Some(block) = &target.managed_block {
            out.push_str("  Managed block:\n");
            for line in block.lines() {
                out.push_str(&format!("    {line}\n"));
            }
        }

        if let Some(json_change) = &target.json_change {
            out.push_str("  JSON settings change:\n");
            out.push_str(&format!(
                "    {} = {}\n",
                json_change.key,
                serde_json::Value::String(json_change.value.clone())
            ));
        }

        if !target.commands.is_empty() {
            out.push_str("  Commands:\n");
            for command in &target.commands {
                out.push_str(&format!("    {}\n", render_command(command)));
            }
        }
    }

    out
}

fn render_command(command: &[String]) -> String {
    command
        .iter()
        .map(|part| shell_token(part))
        .collect::<Vec<_>>()
        .join(" ")
}

fn shell_token(part: &str) -> String {
    if part.chars().all(|ch| {
        ch.is_ascii_alphanumeric() || matches!(ch, '/' | '.' | '_' | '-' | ':' | '+' | '=')
    }) {
        part.to_string()
    } else {
        format!("'{}'", part.replace('\'', "'\\''"))
    }
}

fn prompt_confirm() -> Result<bool> {
    eprint!("Apply theme changes? [y/N] ");
    std::io::stderr().flush()?;
    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;
    Ok(matches!(
        input.trim().to_ascii_lowercase().as_str(),
        "y" | "yes"
    ))
}

fn split_paths(paths: OsString) -> Vec<PathBuf> {
    std::env::split_paths(&paths).collect()
}

fn timestamp_now() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    seconds.to_string()
}

fn dedupe_preserving_order(values: impl IntoIterator<Item = String>) -> Vec<String> {
    let mut seen = BTreeSet::new();
    let mut out = Vec::new();
    for value in values {
        if seen.insert(value.clone()) {
            out.push(value);
        }
    }
    out
}

fn list_or_none(values: impl IntoIterator<Item = String>) -> String {
    let values: Vec<String> = values.into_iter().collect();
    if values.is_empty() {
        "(none)".to_string()
    } else {
        values.join(", ")
    }
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
            "vstack_apply_{label}_{}_{}",
            std::process::id(),
            unique
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write_sample_extra(root: &Path) -> PathBuf {
        let extra_dir = root.join("extras").join("vanillagreen-themes");
        fs::create_dir_all(extra_dir.join("ghostty/themes")).unwrap();
        fs::create_dir_all(extra_dir.join("ghostty/shaders")).unwrap();
        fs::create_dir_all(extra_dir.join("vscode/themes")).unwrap();
        fs::write(
            extra_dir.join("extra.toml"),
            r#"name = "vanillagreen-themes"
kind = "theme-pack"
description = "Matched themes."
default-theme = "forest"
targets = ["ghostty", "vscode", "vscodium", "cursor"]

[[themes]]
id = "forest"
display = "Forest"

[themes.ghostty]
theme-file = "ghostty/themes/forest.conf"
shaders = ["ghostty/shaders/forest.glsl"]
pulse-shader = "ghostty/shaders/forest-pulse.glsl"

[themes.vscode]
theme-name = "Forest Theme"
theme-file = "vscode/themes/forest-color-theme.json"
"#,
        )
        .unwrap();
        fs::write(
            extra_dir.join("ghostty/themes/forest.conf"),
            "palette = 0=#000\n",
        )
        .unwrap();
        fs::write(extra_dir.join("ghostty/shaders/forest.glsl"), "// shader\n").unwrap();
        fs::write(
            extra_dir.join("ghostty/shaders/forest-pulse.glsl"),
            "// pulse\n",
        )
        .unwrap();
        fs::write(
            extra_dir.join("vscode/themes/forest-color-theme.json"),
            "{\"name\":\"Forest Theme\"}\n",
        )
        .unwrap();
        extra_dir
    }

    fn env_for(root: &Path, cli_names: &[&str]) -> ApplyEnvironment {
        let home_dir = root.join("home");
        let config_dir = root.join("config");
        let temp_dir = root.join("tmp");
        let bin_dir = root.join("bin");
        fs::create_dir_all(&home_dir).unwrap();
        fs::create_dir_all(&config_dir).unwrap();
        fs::create_dir_all(&temp_dir).unwrap();
        fs::create_dir_all(&bin_dir).unwrap();
        for cli in cli_names {
            write_cli(&bin_dir, cli);
        }
        ApplyEnvironment {
            home_dir,
            config_dir,
            temp_dir,
            path_entries: vec![bin_dir],
            timestamp: "20260522T120000Z".to_string(),
        }
    }

    fn write_cli(bin_dir: &Path, name: &str) {
        let path = bin_dir.join(name);
        fs::write(&path, "#!/bin/sh\nexit 0\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = fs::metadata(&path).unwrap().permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&path, perms).unwrap();
        }
    }

    fn request(extra_name: &str) -> ApplyRequest {
        ApplyRequest {
            extra_name: extra_name.to_string(),
            theme_id: None,
            targets: None,
            global: false,
            dry_run: true,
            yes: false,
        }
    }

    fn collect_paths(root: &Path) -> Vec<PathBuf> {
        let mut paths = Vec::new();
        if !root.exists() {
            return paths;
        }
        for entry in walkdir::WalkDir::new(root) {
            let entry = entry.unwrap();
            paths.push(entry.path().strip_prefix(root).unwrap().to_path_buf());
        }
        paths.sort();
        paths
    }

    #[test]
    fn unknown_extra_name_fails_clearly() {
        let root = sandbox("unknown_extra");
        write_sample_extra(&root);
        let env = env_for(&root, &["ghostty"]);

        let err = build_plan_for_source(&root, &request("missing"), &env).unwrap_err();
        let msg = format!("{err:#}");

        assert!(msg.contains("unknown extra `missing`"), "{msg}");
        assert!(msg.contains("vanillagreen-themes"), "{msg}");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn unknown_theme_id_fails_clearly() {
        let root = sandbox("unknown_theme");
        write_sample_extra(&root);
        let env = env_for(&root, &["ghostty"]);
        let mut req = request("vanillagreen-themes");
        req.theme_id = Some("missing-theme".to_string());

        let err = build_plan_for_source(&root, &req, &env).unwrap_err();
        let msg = format!("{err:#}");

        assert!(msg.contains("unknown theme `missing-theme`"), "{msg}");
        assert!(msg.contains("forest"), "{msg}");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn unknown_explicit_target_fails() {
        let root = sandbox("unknown_target");
        write_sample_extra(&root);
        let env = env_for(&root, &["ghostty"]);
        let mut req = request("vanillagreen-themes");
        req.targets = Some(vec!["kitty".to_string()]);

        let err = build_plan_for_source(&root, &req, &env).unwrap_err();
        let msg = format!("{err:#}");

        assert!(msg.contains("unknown target `kitty`"), "{msg}");
        assert!(msg.contains("ghostty, vscode, vscodium, cursor"), "{msg}");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn explicit_missing_target_cli_fails() {
        let root = sandbox("explicit_missing");
        write_sample_extra(&root);
        let env = env_for(&root, &[]);
        let mut req = request("vanillagreen-themes");
        req.targets = Some(vec!["ghostty".to_string()]);

        let err = build_plan_for_source(&root, &req, &env).unwrap_err();
        let msg = format!("{err:#}");

        assert!(
            msg.contains("target `ghostty` was requested explicitly"),
            "{msg}"
        );
        assert!(msg.contains("CLI `ghostty` was not found on PATH"), "{msg}");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn implicit_unavailable_target_is_skipped_when_other_targets_remain() {
        let root = sandbox("implicit_skip");
        write_sample_extra(&root);
        let env = env_for(&root, &["code"]);

        let plan = build_plan_for_source(&root, &request("vanillagreen-themes"), &env).unwrap();

        assert_eq!(plan.targets.len(), 1);
        assert_eq!(plan.targets[0].name, "vscode");
        assert!(
            plan.warnings
                .iter()
                .any(|warning| warning.contains("target `ghostty` skipped")),
            "{:?}",
            plan.warnings
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn implicit_all_targets_unavailable_fails() {
        let root = sandbox("implicit_none");
        write_sample_extra(&root);
        let env = env_for(&root, &[]);

        let err = build_plan_for_source(&root, &request("vanillagreen-themes"), &env).unwrap_err();
        let msg = format!("{err:#}");

        assert!(msg.contains("no declared targets"), "{msg}");
        assert!(msg.contains("available on this system"), "{msg}");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn dry_run_plan_does_not_write_under_config_dirs() {
        let root = sandbox("no_write");
        write_sample_extra(&root);
        let env = env_for(&root, &["ghostty", "code"]);
        let before = collect_paths(&env.config_dir);

        let plan = build_plan_for_source(&root, &request("vanillagreen-themes"), &env).unwrap();
        let _rendered = render_plan(&plan, &env, true);
        let after = collect_paths(&env.config_dir);

        assert_eq!(before, after);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn dry_run_output_includes_targets_theme_destinations_and_backups() {
        let root = sandbox("output");
        write_sample_extra(&root);
        let env = env_for(&root, &["ghostty", "code"]);
        let mut req = request("vanillagreen-themes");
        req.targets = Some(vec!["ghostty".to_string(), "vscode".to_string()]);

        let plan = build_plan_for_source(&root, &req, &env).unwrap();
        let output = render_plan(&plan, &env, true);

        assert!(output.contains("Target: ghostty"), "{output}");
        assert!(output.contains("Target: vscode"), "{output}");
        assert!(output.contains("Theme: Forest (forest)"), "{output}");
        assert!(
            output.contains("themes/vstack/forest"),
            "expected Ghostty theme destination in {output}"
        );
        assert!(
            output.contains("shaders/vstack/forest.glsl"),
            "expected Ghostty shader destination in {output}"
        );
        assert!(
            output.contains("workbench.colorTheme = \"Forest Theme\""),
            "expected VS Code JSON key change in {output}"
        );
        assert!(
            output.contains("settings.json.vstack-backup.20260522T120000Z"),
            "expected VS Code backup path in {output}"
        );
        assert!(
            output.contains("config.vstack-backup.20260522T120000Z"),
            "expected Ghostty backup path in {output}"
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn parse_target_list_trims_and_splits_commas() {
        let parsed = parse_target_list(Some("ghostty, vscode,,cursor ")).unwrap();
        assert_eq!(
            parsed,
            Some(vec![
                "ghostty".to_string(),
                "vscode".to_string(),
                "cursor".to_string()
            ])
        );
    }
}
