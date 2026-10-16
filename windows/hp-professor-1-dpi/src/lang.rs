use std::sync::atomic::{AtomicU8, Ordering};

static LANG: AtomicU8 = AtomicU8::new(0);

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Lang {
    ZhTw = 0,
    ZhCn = 1,
    En = 2,
}

pub fn init() {
    if let Some(saved) = read_saved() {
        set(saved);
        return;
    }
    set(system_lang());
}

pub fn current() -> Lang {
    match LANG.load(Ordering::Acquire) {
        1 => Lang::ZhCn,
        2 => Lang::En,
        _ => Lang::ZhTw,
    }
}

pub fn set(lang: Lang) {
    LANG.store(lang as u8, Ordering::Release);
    if let Some(path) = lang_path() {
        let _ = std::fs::create_dir_all(path.parent().unwrap_or(std::path::Path::new(".")));
        let text = match lang {
            Lang::ZhTw => "zh-TW",
            Lang::ZhCn => "zh-CN",
            Lang::En => "en",
        };
        let _ = std::fs::write(path, text);
    }
}

pub fn font_name() -> &'static str {
    match current() {
        Lang::ZhCn => "Microsoft YaHei",
        Lang::En => "Segoe UI",
        Lang::ZhTw => "Microsoft JhengHei",
    }
}

pub fn stage(index: usize, total: usize) -> String {
    match current() {
        Lang::ZhTw => format!("第 {index} / {total} 段"),
        Lang::ZhCn => format!("第 {index} / {total} 档"),
        Lang::En => format!("Level {index} / {total}"),
    }
}

pub fn offline() -> &'static str {
    match current() {
        Lang::ZhTw => "未連線",
        Lang::ZhCn => "未连接",
        Lang::En => "Offline",
    }
}

pub fn link(mode: crate::vendor::LinkMode) -> &'static str {
    use crate::vendor::LinkMode;
    match (current(), mode) {
        (_, LinkMode::Dongle) => "2.4G",
        (Lang::ZhTw, LinkMode::Bluetooth) => "藍牙",
        (Lang::ZhCn, LinkMode::Bluetooth) => "蓝牙",
        (Lang::En, LinkMode::Bluetooth) => "Bluetooth",
        (Lang::ZhTw, LinkMode::Asleep) => "2.4G 睡著",
        (Lang::ZhCn, LinkMode::Asleep) => "2.4G 休眠",
        (Lang::En, LinkMode::Asleep) => "2.4G asleep",
        (Lang::ZhTw, LinkMode::Offline) => "未連線",
        (Lang::ZhCn, LinkMode::Offline) => "未连接",
        (Lang::En, LinkMode::Offline) => "Offline",
    }
}

pub fn tip(mode: crate::vendor::LinkMode, dpi: u32, index: usize, total: usize) -> String {
    match current() {
        Lang::ZhTw => format!("{} · {dpi} DPI · 第 {index}/{total} 段", link(mode)),
        Lang::ZhCn => format!("{} · {dpi} DPI · 第 {index}/{total} 档", link(mode)),
        Lang::En => format!("{} · {dpi} DPI · {index}/{total}", link(mode)),
    }
}

pub fn panel_note(mode: crate::vendor::LinkMode, index: Option<usize>) -> String {
    use crate::vendor::LinkMode;
    match (current(), mode) {
        (Lang::ZhTw, LinkMode::Dongle) => index
            .map(|n| format!("2.4G · 第 {n} 段。點下面直接切。"))
            .unwrap_or_else(|| "2.4G".into()),
        (Lang::ZhCn, LinkMode::Dongle) => index
            .map(|n| format!("2.4G · 第 {n} 档。点下面直接切。"))
            .unwrap_or_else(|| "2.4G".into()),
        (Lang::En, LinkMode::Dongle) => index
            .map(|n| format!("2.4G · Level {n}. Click a value below."))
            .unwrap_or_else(|| "2.4G".into()),
        (Lang::ZhTw, LinkMode::Bluetooth) => "藍牙 · 按實體 DPI 鍵。軟體不能直切。".into(),
        (Lang::ZhCn, LinkMode::Bluetooth) => "蓝牙 · 按实体 DPI 键。软件不能直切。".into(),
        (Lang::En, LinkMode::Bluetooth) => "Bluetooth · Use the DPI button. Software can't switch.".into(),
        (Lang::ZhTw, LinkMode::Asleep) => "2.4G 睡著了。動一下滑鼠。".into(),
        (Lang::ZhCn, LinkMode::Asleep) => "2.4G 休眠了。动一下鼠标。".into(),
        (Lang::En, LinkMode::Asleep) => "2.4G asleep. Move the mouse.".into(),
        (Lang::ZhTw, LinkMode::Offline) => "未連線".into(),
        (Lang::ZhCn, LinkMode::Offline) => "未连接".into(),
        (Lang::En, LinkMode::Offline) => "Offline".into(),
    }
}

pub fn startup_item() -> &'static str {
    match current() {
        Lang::ZhTw => "開機時啟動",
        Lang::ZhCn => "开机时启动",
        Lang::En => "Start with Windows",
    }
}

pub fn quit_item() -> &'static str {
    match current() {
        Lang::ZhTw => "結束",
        Lang::ZhCn => "退出",
        Lang::En => "Quit",
    }
}

fn system_lang() -> Lang {
    let id = unsafe { crate::ffi::GetUserDefaultUILanguage() };
    let primary = id & 0x3ff;
    let sub = id >> 10;
    if primary == 0x04 {
        if sub == 0x02 || sub == 0x04 { Lang::ZhCn } else { Lang::ZhTw }
    } else {
        Lang::En
    }
}

fn read_saved() -> Option<Lang> {
    let text = std::fs::read_to_string(lang_path()?).ok()?;
    match text.trim() {
        "zh-CN" => Some(Lang::ZhCn),
        "en" => Some(Lang::En),
        "zh-TW" => Some(Lang::ZhTw),
        _ => None,
    }
}

fn lang_path() -> Option<std::path::PathBuf> {
    let base = std::env::var_os("LOCALAPPDATA")?;
    Some(std::path::PathBuf::from(base).join("HP Professor 1 DPI").join("lang.txt"))
}
