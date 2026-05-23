use crate::config;
use crate::extra::{Extra, ExtraKind, ThemeSpec};
use crate::ghostty_apply::{self, GhosttyPathContext, GhosttyPlatform};
use crate::vscode_apply::VscodeEditor;
use anyhow::{Context, Result, bail};
use std::collections::BTreeSet;
use std::ffi::OsString;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

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
    xdg_config_home: Option<PathBuf>,
    temp_dir: PathBuf,
    path_entries: Vec<PathBuf>,
    platform: GhosttyPlatform,
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
    kind: TargetKind,
    cli_name: String,
    cli_path: Option<PathBuf>,
    config_dir: PathBuf,
    config_file: PathBuf,
    backup_file: PathBuf,
    copies: Vec<FileCopyPlan>,
    managed_block: Option<String>,
    json_change: Option<JsonChangePlan>,
    vsix_path: Option<PathBuf>,
    vscode: Option<VscodeThemePlan>,
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

#[derive(Debug, Clone)]
struct VscodeThemePlan {
    extension_root: PathBuf,
    package_json: PathBuf,
    theme_name: String,
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
    cli_path: Option<PathBuf>,
}

impl ApplyEnvironment {
    fn current() -> Self {
        let path_entries = std::env::var_os("PATH")
            .map(split_paths)
            .unwrap_or_default();
        Self {
            home_dir: config::user_home_dir(),
            config_dir: config::user_config_dir(),
            xdg_config_home: std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from),
            temp_dir: std::env::temp_dir(),
            path_entries,
            platform: GhosttyPlatform::current(),
            timestamp: ghostty_apply::utc_timestamp_now(),
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

fn vscode_editor(kind: TargetKind) -> Option<VscodeEditor> {
    match kind {
        TargetKind::Vscode => Some(VscodeEditor::Vscode),
        TargetKind::Vscodium => Some(VscodeEditor::Vscodium),
        TargetKind::Cursor => Some(VscodeEditor::Cursor),
        TargetKind::Ghostty => None,
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

    apply_plan(&plan)?;
    Ok(())
}

fn apply_plan(plan: &ApplyPlan) -> Result<()> {
    for target in &plan.targets {
        match target.kind {
            TargetKind::Ghostty => {
                apply_ghostty_target(&plan.extra_name, target)?;
                println!("Ghostty config updated. Reload Ghostty to apply the new theme.");
            }
            TargetKind::Vscode | TargetKind::Vscodium | TargetKind::Cursor => {
                apply_vscode_family_target(target)?;
            }
        }
    }
    Ok(())
}

fn apply_ghostty_target(extra_name: &str, target: &TargetPlan) -> Result<()> {
    let managed_block = target
        .managed_block
        .as_ref()
        .context("Ghostty target plan is missing a managed block")?;

    let original = ghostty_apply::write_backup(&target.config_file, &target.backup_file)?;

    for copy in &target.copies {
        if let Some(parent) = copy.destination.parent() {
            fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
        }
        fs::copy(&copy.source, &copy.destination).with_context(|| {
            format!(
                "copying {} to {}",
                copy.source.display(),
                copy.destination.display()
            )
        })?;
    }

    let original_config = String::from_utf8(original).with_context(|| {
        format!(
            "Ghostty config {} is not valid UTF-8",
            target.config_file.display()
        )
    })?;
    let updated_config =
        ghostty_apply::insert_or_replace_managed_block(&original_config, extra_name, managed_block);
    ghostty_apply::validate_managed_block_syntax(&updated_config, extra_name)?;

    if let Some(parent) = target.config_file.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    fs::write(&target.config_file, updated_config)
        .with_context(|| format!("writing {}", target.config_file.display()))?;

    if let Some(cli_path) = &target.cli_path {
        validate_ghostty_config(cli_path, &target.config_file, &target.backup_file)?;
    } else {
        eprintln!("warning: ghostty CLI not found on PATH; skipped `ghostty +validate-config`");
    }

    Ok(())
}

fn validate_ghostty_config(cli_path: &Path, config_file: &Path, backup_file: &Path) -> Result<()> {
    let output = Command::new(cli_path)
        .arg("+validate-config")
        .arg(format!("--config-file={}", config_file.display()))
        .output()
        .with_context(|| format!("running {} +validate-config", cli_path.display()))?;

    if output.status.success() {
        return Ok(());
    }

    let _ = ghostty_apply::restore_backup(backup_file, config_file);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    bail!(
        "Ghostty config validation failed; restored {} from {}\nstdout:\n{}\nstderr:\n{}",
        config_file.display(),
        backup_file.display(),
        stdout.trim_end(),
        stderr.trim_end()
    )
}

fn apply_vscode_family_target(target: &TargetPlan) -> Result<()> {
    let cli_path = target
        .cli_path
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("target `{}` has no CLI path", target.name))?;
    let vscode = target.vscode.as_ref().ok_or_else(|| {
        anyhow::anyhow!(
            "target `{}` has no VS Code-family package plan",
            target.name
        )
    })?;
    let vsix_path = target
        .vsix_path
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("target `{}` has no VSIX path", target.name))?;

    let cleanup = TempDirCleanup::from_child_path(vsix_path);
    let vsix = crate::vsix::write_vsix(&vscode.extension_root, &vscode.package_json, vsix_path)
        .with_context(|| format!("building VSIX for target `{}`", target.name))?;

    run_checked_command(
        cli_path,
        &[
            "--install-extension".to_string(),
            vsix_path.display().to_string(),
            "--force".to_string(),
        ],
    )
    .with_context(|| format!("installing VSIX for target `{}`", target.name))?;

    let settings_existed = target.config_file.exists();
    let original_settings = if settings_existed {
        fs::read_to_string(&target.config_file)
            .with_context(|| format!("reading {}", target.config_file.display()))?
    } else {
        "{}\n".to_string()
    };
    let patched_settings =
        crate::vscode_apply::patch_settings_text(&original_settings, &vscode.theme_name)
            .with_context(|| format!("patching {}", target.config_file.display()))?;

    if !settings_existed || patched_settings != original_settings {
        backup_settings_file(&target.config_file, &target.backup_file, settings_existed)?;
        if let Some(parent) = target.config_file.parent() {
            fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
        }
        fs::write(&target.config_file, patched_settings)
            .with_context(|| format!("writing {}", target.config_file.display()))?;
    }

    let listed = run_checked_command(cli_path, &["--list-extensions".to_string()])
        .with_context(|| format!("listing extensions for target `{}`", target.name))?;
    let stdout = String::from_utf8_lossy(&listed.stdout);
    if !extension_list_contains(&stdout, &vsix.extension_id) {
        bail!(
            "target `{}` did not list installed extension `{}` after VSIX install",
            target.name,
            vsix.extension_id
        );
    }

    drop(cleanup);
    Ok(())
}

fn backup_settings_file(settings_file: &Path, backup_file: &Path, existed: bool) -> Result<()> {
    if let Some(parent) = settings_file.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    if existed {
        fs::copy(settings_file, backup_file).with_context(|| {
            format!(
                "backing up {} to {}",
                settings_file.display(),
                backup_file.display()
            )
        })?;
    } else {
        fs::write(backup_file, b"").with_context(|| {
            format!(
                "creating empty backup for missing settings file {} at {}",
                settings_file.display(),
                backup_file.display()
            )
        })?;
    }
    Ok(())
}

fn run_checked_command(program: &Path, args: &[String]) -> Result<Output> {
    let output = Command::new(program)
        .args(args)
        .output()
        .with_context(|| format!("running {}", render_command_for_program(program, args)))?;
    if !output.status.success() {
        bail!(
            "command failed ({}):\nstdout:\n{}\nstderr:\n{}",
            render_command_for_program(program, args),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(output)
}

fn render_command_for_program(program: &Path, args: &[String]) -> String {
    let mut command = Vec::with_capacity(args.len() + 1);
    command.push(program.display().to_string());
    command.extend(args.iter().cloned());
    render_command(&command)
}

fn extension_list_contains(list_output: &str, extension_id: &str) -> bool {
    list_output
        .lines()
        .any(|line| line.trim().eq_ignore_ascii_case(extension_id))
}

struct TempDirCleanup {
    path: Option<PathBuf>,
}

impl TempDirCleanup {
    fn from_child_path(path: &Path) -> Self {
        Self {
            path: path.parent().map(Path::to_path_buf),
        }
    }
}

impl Drop for TempDirCleanup {
    fn drop(&mut self) {
        if let Some(path) = self.path.take() {
            let _ = fs::remove_dir_all(path);
        }
    }
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
                cli_path: Some(cli_path),
            }),
            None if kind == TargetKind::Ghostty => {
                warnings.push(format!(
                    "target `{target_name}`: CLI `{cli_name}` not found on PATH; external validation will be skipped"
                ));
                resolved.push(ResolvedTarget {
                    name: target_name,
                    kind,
                    cli_name,
                    cli_path: None,
                });
            }
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
    let config_file = ghostty_apply::resolve_config_file(&config_dir);
    let backup_file = ghostty_apply::backup_path(&config_file, &env.timestamp);
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

    let shader_file_names = shader_destinations
        .iter()
        .filter_map(|path| path.file_name().and_then(|name| name.to_str()))
        .map(str::to_string)
        .collect::<Vec<_>>();
    let managed_block = ghostty_apply::managed_block(extra.name(), &theme.id, &shader_file_names);
    let commands = target
        .cli_path
        .as_ref()
        .map(|cli_path| {
            vec![
                cli_path.display().to_string(),
                "+validate-config".to_string(),
                format!("--config-file={}", config_file.display()),
            ]
        })
        .into_iter()
        .collect();

    Ok(TargetPlan {
        name: target.name.clone(),
        kind: target.kind,
        cli_name: target.cli_name.clone(),
        cli_path: target.cli_path.clone(),
        config_dir,
        config_file,
        backup_file,
        copies,
        managed_block: Some(managed_block),
        json_change: None,
        vsix_path: None,
        vscode: None,
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

    let editor = vscode_editor(target.kind).ok_or_else(|| {
        anyhow::anyhow!("target `{}` is not a VS Code-family target", target.name)
    })?;
    let user_dir =
        crate::vscode_apply::user_dir_for_current_os(editor, &env.home_dir, &env.config_dir);
    let settings_file = user_dir.join("settings.json");
    let backup_file = ghostty_apply::backup_path(&settings_file, &env.timestamp);
    let vsix_dir = env.temp_dir.join(format!(
        "vstack-{}-{}-{}-{}",
        extra.name(),
        theme.id,
        target.name,
        env.timestamp
    ));
    let vsix_path = vsix_dir.join(format!("{}-{}.vsix", extra.name(), theme.id));
    let extension_root = extra.source_dir.join("vscode");
    let package_json = extension_root.join("package.json");
    let cli_path = target
        .cli_path
        .as_ref()
        .context("VS Code-family target plan is missing a CLI path")?;
    let commands = vec![
        vec![
            cli_path.display().to_string(),
            "--install-extension".to_string(),
            vsix_path.display().to_string(),
            "--force".to_string(),
        ],
        vec![
            cli_path.display().to_string(),
            "--list-extensions".to_string(),
        ],
    ];

    Ok(TargetPlan {
        name: target.name.clone(),
        kind: target.kind,
        cli_name: target.cli_name.clone(),
        cli_path: Some(cli_path.clone()),
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
        vscode: Some(VscodeThemePlan {
            extension_root,
            package_json,
            theme_name: vscode.theme_name.clone(),
        }),
        commands,
    })
}

fn ghostty_config_dir(env: &ApplyEnvironment) -> PathBuf {
    ghostty_apply::resolve_config_dir(&GhosttyPathContext {
        home_dir: env.home_dir.clone(),
        xdg_config_home: env.xdg_config_home.clone(),
        platform: env.platform,
    })
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

    fn write_ghostty_only_extra_without_shaders(root: &Path) -> PathBuf {
        let extra_dir = root.join("extras").join("vanillagreen-themes");
        fs::create_dir_all(extra_dir.join("ghostty/themes")).unwrap();
        fs::write(
            extra_dir.join("extra.toml"),
            r##"name = "vanillagreen-themes"
kind = "theme-pack"
description = "Matched themes."
default-theme = "forest"
targets = ["ghostty"]

[[themes]]
id = "forest"
display = "Forest"

[themes.ghostty]
theme-file = "ghostty/themes/forest.conf"
"##,
        )
        .unwrap();
        fs::write(
            extra_dir.join("ghostty/themes/forest.conf"),
            "background = #000000\nforeground = #ffffff\n",
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
            config_dir: config_dir.clone(),
            xdg_config_home: Some(config_dir),
            temp_dir,
            path_entries: vec![bin_dir],
            platform: GhosttyPlatform::Linux,
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

    fn write_cli_script(bin_dir: &Path, name: &str, script: &str) {
        let path = bin_dir.join(name);
        fs::write(&path, script).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = fs::metadata(&path).unwrap().permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&path, perms).unwrap();
        }
    }

    fn path_entries_from_current_path() -> Vec<PathBuf> {
        std::env::var_os("PATH")
            .map(split_paths)
            .unwrap_or_default()
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
    fn explicit_missing_vscode_target_cli_fails() {
        let root = sandbox("explicit_missing");
        write_sample_extra(&root);
        let env = env_for(&root, &[]);
        let mut req = request("vanillagreen-themes");
        req.targets = Some(vec!["vscode".to_string()]);

        let err = build_plan_for_source(&root, &req, &env).unwrap_err();
        let msg = format!("{err:#}");

        assert!(
            msg.contains("target `vscode` was requested explicitly"),
            "{msg}"
        );
        assert!(msg.contains("CLI `code` was not found on PATH"), "{msg}");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn explicit_missing_ghostty_cli_is_allowed_with_validation_warning() {
        let root = sandbox("explicit_missing_ghostty");
        write_sample_extra(&root);
        let env = env_for(&root, &[]);
        let mut req = request("vanillagreen-themes");
        req.targets = Some(vec!["ghostty".to_string()]);

        let plan = build_plan_for_source(&root, &req, &env).unwrap();

        assert_eq!(plan.targets.len(), 1);
        assert_eq!(plan.targets[0].name, "ghostty");
        assert!(plan.targets[0].cli_path.is_none());
        assert!(
            plan.warnings
                .iter()
                .any(|warning| warning.contains("external validation will be skipped")),
            "{:?}",
            plan.warnings
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn implicit_unavailable_vscode_family_targets_are_skipped_when_ghostty_remains() {
        let root = sandbox("implicit_skip");
        write_sample_extra(&root);
        let env = env_for(&root, &["ghostty"]);

        let plan = build_plan_for_source(&root, &request("vanillagreen-themes"), &env).unwrap();

        assert_eq!(plan.targets.len(), 1);
        assert_eq!(plan.targets[0].name, "ghostty");
        assert!(
            plan.warnings
                .iter()
                .any(|warning| warning.contains("target `vscode` skipped")),
            "{:?}",
            plan.warnings
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn implicit_missing_ghostty_cli_still_plans_ghostty_apply() {
        let root = sandbox("implicit_missing_ghostty");
        write_sample_extra(&root);
        let env = env_for(&root, &[]);

        let plan = build_plan_for_source(&root, &request("vanillagreen-themes"), &env).unwrap();

        assert_eq!(plan.targets.len(), 1);
        assert_eq!(plan.targets[0].name, "ghostty");
        assert!(plan.targets[0].cli_path.is_none());
        assert!(
            plan.warnings
                .iter()
                .any(|warning| warning.contains("external validation will be skipped")),
            "{:?}",
            plan.warnings
        );
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
    fn apply_ghostty_target_into_temp_xdg_config_home() {
        let root = sandbox("apply_ghostty_temp_xdg");
        write_ghostty_only_extra_without_shaders(&root);
        let home_dir = root.join("home");
        let config_dir = root.join("xdg");
        let temp_dir = root.join("tmp");
        fs::create_dir_all(&home_dir).unwrap();
        fs::create_dir_all(&config_dir).unwrap();
        fs::create_dir_all(&temp_dir).unwrap();
        let ghostty_config_dir = config_dir.join("ghostty");
        fs::create_dir_all(&ghostty_config_dir).unwrap();
        let config_file = ghostty_config_dir.join("config");
        fs::write(&config_file, "font-size = 14\n").unwrap();
        let env = ApplyEnvironment {
            home_dir,
            config_dir: config_dir.clone(),
            xdg_config_home: Some(config_dir.clone()),
            temp_dir,
            path_entries: path_entries_from_current_path(),
            platform: GhosttyPlatform::Linux,
            timestamp: "20260522T120000Z".to_string(),
        };
        let mut req = request("vanillagreen-themes");
        req.targets = Some(vec!["ghostty".to_string()]);

        let plan = build_plan_for_source(&root, &req, &env).unwrap();
        apply_ghostty_target(&plan.extra_name, &plan.targets[0]).unwrap();

        let updated = fs::read_to_string(&config_file).unwrap();
        ghostty_apply::validate_managed_block_syntax(&updated, "vanillagreen-themes").unwrap();
        assert!(
            updated.contains("config-file = themes/vstack/forest"),
            "{updated}"
        );
        assert_eq!(
            fs::read(ghostty_config_dir.join("config.vstack-backup.20260522T120000Z")).unwrap(),
            b"font-size = 14\n"
        );
        assert_eq!(
            fs::read_to_string(ghostty_config_dir.join("themes/vstack/forest")).unwrap(),
            "background = #000000\nforeground = #ffffff\n"
        );
        if plan.targets[0].cli_path.is_none() {
            eprintln!("ghostty not on PATH; skipped external `ghostty +validate-config` assertion");
        }
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn failed_ghostty_validation_restores_backup() {
        let root = sandbox("apply_ghostty_restore");
        write_ghostty_only_extra_without_shaders(&root);
        let env = env_for(&root, &[]);
        let bin_dir = root.join("bin");
        write_cli_script(
            &bin_dir,
            "ghostty",
            "#!/bin/sh\necho validate failed >&2\nexit 7\n",
        );
        let config_file = env.config_dir.join("ghostty/config");
        fs::create_dir_all(config_file.parent().unwrap()).unwrap();
        fs::write(&config_file, "font-size = 13\n").unwrap();
        let mut req = request("vanillagreen-themes");
        req.targets = Some(vec!["ghostty".to_string()]);

        let plan = build_plan_for_source(&root, &req, &env).unwrap();
        let err = apply_ghostty_target(&plan.extra_name, &plan.targets[0]).unwrap_err();
        let msg = format!("{err:#}");

        assert!(msg.contains("Ghostty config validation failed"), "{msg}");
        assert_eq!(
            fs::read_to_string(&config_file).unwrap(),
            "font-size = 13\n"
        );
        assert_eq!(
            fs::read(
                env.config_dir
                    .join("ghostty/config.vstack-backup.20260522T120000Z")
            )
            .unwrap(),
            b"font-size = 13\n"
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
