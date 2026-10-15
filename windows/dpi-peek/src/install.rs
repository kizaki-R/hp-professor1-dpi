//! Per-user install. No admin, no MSI.
//!
//! First launch from a download folder copies the exe to
//! `%LOCALAPPDATA%\DPIPeek\` and adds a Startup shortcut, then relaunches that copy.
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

const CREATE_NO_WINDOW: u32 = 0x08000000;

pub fn prepare() {
    match ensure_installed() {
        Ok(InstallAction::Relaunch(path)) => {
            let _ = Command::new(&path).spawn();
            std::process::exit(0);
        }
        Ok(InstallAction::Ready) => {}
        Err(err) => {
            let _ = std::fs::write(fallback_log(), format!("install: {err}\r\n"));
        }
    }
}

enum InstallAction {
    Ready,
    Relaunch(PathBuf),
}

fn ensure_installed() -> Result<InstallAction, String> {
    let current = std::env::current_exe().map_err(|e| e.to_string())?;
    let dest = install_exe()?;
    if !same_path(&current, &dest) {
        if let Some(parent) = dest.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        std::fs::copy(&current, &dest).map_err(|e| format!("複製到 {} 失敗: {e}", dest.display()))?;
        let _ = write_app_icon(dest.parent().unwrap_or(Path::new(".")));
        set_autostart(true)?;
        let _ = write_start_menu_shortcut();
        return Ok(InstallAction::Relaunch(dest));
    }
    if let Some(parent) = dest.parent() {
        let _ = write_app_icon(parent);
    }
    if !autostart_enabled() {
        set_autostart(true)?;
    }
    let _ = write_start_menu_shortcut();
    Ok(InstallAction::Ready)
}

pub fn install_exe() -> Result<PathBuf, String> {
    Ok(local_appdata()?.join("DPIPeek").join("DPIPeek.exe"))
}

pub fn autostart_enabled() -> bool {
    startup_shortcut().is_some_and(|path| path.is_file())
}

pub fn set_autostart(enabled: bool) -> Result<(), String> {
    let dir = startup_dir()?;
    let _ = std::fs::remove_file(dir.join("DPI Peek.lnk"));
    let lnk = dir.join("HP Professor 1 DPI.lnk");
    if !enabled {
        if lnk.is_file() {
            std::fs::remove_file(&lnk).map_err(|e| e.to_string())?;
        }
        return Ok(());
    }
    write_shortcut(&lnk)
}

pub fn write_start_menu_shortcut() -> Result<(), String> {
    let programs = appdata()?.join("Microsoft").join("Windows").join("Start Menu").join("Programs");
    std::fs::create_dir_all(&programs).map_err(|e| e.to_string())?;
    let lnk = programs.join("HP Professor 1 DPI.lnk");
    write_shortcut(&lnk)
}

fn write_shortcut(lnk: &Path) -> Result<(), String> {
    let target = install_exe()?;
    let work = target.parent().unwrap_or(Path::new(".")).to_string_lossy().replace('\'', "''");
    let target_ps = target.to_string_lossy().replace('\'', "''");
    let lnk_ps = lnk.to_string_lossy().replace('\'', "''");
    let icon = target.parent().unwrap_or(Path::new(".")).join("seven_app.ico");
    let icon_ps = icon.to_string_lossy().replace('\'', "''");
    let script = format!(
        "$s = New-Object -ComObject WScript.Shell; $sc = $s.CreateShortcut('{lnk_ps}'); $sc.TargetPath = '{target_ps}'; $sc.WorkingDirectory = '{work}'; $sc.IconLocation = '{icon_ps},0'; $sc.WindowStyle = 7; $sc.Description = 'HP Professor 1 DPI'; $sc.Save()"
    );
    let status = Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", &script])
        .creation_flags(CREATE_NO_WINDOW)
        .status()
        .map_err(|e| e.to_string())?;
    if !status.success() {
        return Err("無法建立捷徑".into());
    }
    Ok(())
}

pub fn toggle_autostart() {
    let next = !autostart_enabled();
    if let Err(err) = set_autostart(next) {
        let _ = std::fs::write(fallback_log(), format!("autostart: {err}\r\n"));
    }
}

fn startup_shortcut() -> Option<PathBuf> {
    let path = startup_dir().ok()?.join("HP Professor 1 DPI.lnk");
    Some(path)
}

fn startup_dir() -> Result<PathBuf, String> {
    Ok(appdata()?.join("Microsoft").join("Windows").join("Start Menu").join("Programs").join("Startup"))
}

fn local_appdata() -> Result<PathBuf, String> {
    std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .ok_or_else(|| "找不到 LOCALAPPDATA".into())
}

fn appdata() -> Result<PathBuf, String> {
    std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .ok_or_else(|| "找不到 APPDATA".into())
}

fn same_path(a: &Path, b: &Path) -> bool {
    let na = std::fs::canonicalize(a).unwrap_or_else(|_| a.to_path_buf());
    let nb = std::fs::canonicalize(b).unwrap_or_else(|_| b.to_path_buf());
    na.to_string_lossy().eq_ignore_ascii_case(&nb.to_string_lossy())
}

fn write_app_icon(dir: &Path) -> Result<PathBuf, String> {
    let path = dir.join("seven_app.ico");
    std::fs::write(&path, include_bytes!("../assets/seven_app.ico")).map_err(|e| e.to_string())?;
    Ok(path)
}

fn fallback_log() -> PathBuf {
    local_appdata()
        .unwrap_or_else(|_| PathBuf::from("."))
        .join("DPIPeek")
        .join("install.log")
}
