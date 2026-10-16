use crate::ffi::*;
use crate::paint::{self, Fonts, Frame};
use crate::vendor::{Channel, Reading};
use std::sync::atomic::{AtomicBool, AtomicIsize, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

pub const WM_TRAY: u32 = WM_APP + 1;
pub const WM_READING: u32 = WM_APP + 2;
pub const WM_SHOW: u32 = WM_APP + 3;
const CLASS_MSG: &str = "HPProfessor1DPI.Message";
const CLASS_HUD: &str = "HPProfessor1DPI.Hud";
const CLASS_PANEL: &str = "HPProfessor1DPI.Panel";

static MSG_HWND: AtomicIsize = AtomicIsize::new(0);
static QUIT: AtomicBool = AtomicBool::new(false);
static LATEST: OnceLock<Mutex<Option<Reading>>> = OnceLock::new();
static ASLEEP: AtomicBool = AtomicBool::new(false);
static LINK: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);
static FORCE_HUD: AtomicBool = AtomicBool::new(false);
static COMMAND: OnceLock<Mutex<Option<usize>>> = OnceLock::new();
static UI: OnceLock<Mutex<Ui>> = OnceLock::new();

struct Ui {
    msg: Hwnd,
    hud: Hwnd,
    panel: Hwnd,
    icon: Handle,
    stage_icons: [Handle; 7],
    fonts: Fonts,
    scale: f32,
    panel_visible: bool,
    hud_visible: bool,
    hud_until: u64,
    panel_x: i32,
    panel_y: i32,
    hud_x: i32,
    hud_y: i32,
    chips: Vec<paint::Chip>,
    dragging: bool,
    drag_dx: i32,
    drag_dy: i32,
    moved: bool,
    last_active: Option<usize>,
}

pub fn log(line: &str) {
    let path = log_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        use std::io::Write;
        let _ = writeln!(file, "{line}");
    }
}

fn log_path() -> std::path::PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.join("hp-professor-1-dpi.log")))
        .unwrap_or_else(|| std::path::PathBuf::from("hp-professor-1-dpi.log"))
}

fn latest() -> &'static Mutex<Option<Reading>> {
    LATEST.get_or_init(|| Mutex::new(None))
}

fn command() -> &'static Mutex<Option<usize>> {
    COMMAND.get_or_init(|| Mutex::new(None))
}

pub fn run() -> Result<(), String> {
    crate::lang::init();
    unsafe {
        SetProcessDpiAwarenessContext(-4);
        if paint::startup() == 0 {
            return Err("GDI+ 啟動失敗".into());
        }
        let instance = GetModuleHandleW(std::ptr::null());
        let class_msg = wide(CLASS_MSG);
        register(instance, &class_msg, wnd_proc);
        register(instance, &wide(CLASS_HUD), wnd_proc);
        register(instance, &wide(CLASS_PANEL), wnd_proc);
        let msg = CreateWindowExW(
            0,
            class_msg.as_ptr(),
            wide("HP Professor 1 DPI").as_ptr(),
            WS_POPUP,
            0,
            0,
            0,
            0,
            0,
            0,
            instance,
            std::ptr::null_mut(),
        );
        if msg == 0 {
            return Err(format!("訊息視窗建立失敗 ({})", GetLastError()));
        }
        let scale = paint::scale();
        let hud = create_layered(instance, CLASS_HUD, true, true);
        let panel = create_layered(instance, CLASS_PANEL, false, false);
        let fonts = Fonts::load(scale);
        let icon = icon_from_bgra(&crate::logo_icons::APP_MARK);
        let stage_icons = [
            icon_from_bgra(crate::logo_icons::STAGES[0]),
            icon_from_bgra(crate::logo_icons::STAGES[1]),
            icon_from_bgra(crate::logo_icons::STAGES[2]),
            icon_from_bgra(crate::logo_icons::STAGES[3]),
            icon_from_bgra(crate::logo_icons::STAGES[4]),
            icon_from_bgra(crate::logo_icons::STAGES[5]),
            icon_from_bgra(crate::logo_icons::STAGES[6]),
        ];
        unsafe {
            SendMessageW(msg, 0x0080, 1, icon);
            SendMessageW(msg, 0x0080, 0, icon);
        }
        let ui = Ui {
            msg,
            hud,
            panel,
            icon,
            stage_icons,
            fonts,
            scale,
            panel_visible: false,
            hud_visible: false,
            hud_until: 0,
            panel_x: 0,
            panel_y: 0,
            hud_x: 0,
            hud_y: 0,
            chips: Vec::new(),
            dragging: false,
            drag_dx: 0,
            drag_dy: 0,
            moved: false,
            last_active: None,
        };
        MSG_HWND.store(msg, Ordering::Release);
        UI.get_or_init(|| Mutex::new(ui));
        ShowWindow(msg, SW_HIDE);
        register_ble_input(msg);
        SetTimer(msg, 1, 100, std::ptr::null_mut());
        SetTimer(msg, 2, 200, std::ptr::null_mut());
        if let Some(saved) = load_reading() {
            if let Ok(mut slot) = latest().lock() {
                *slot = Some(saved);
            }
        }
        std::thread::spawn(worker);
        let mut message = std::mem::zeroed::<Msg>();
        while GetMessageW(&mut message, 0, 0, 0) > 0 {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        QUIT.store(true, Ordering::Release);
        remove_tray(msg);
        Ok(())
    }
}

fn register(instance: Handle, name: &[u16], proc: unsafe extern "system" fn(Hwnd, u32, usize, isize) -> isize) {
    let class = WndClassW {
        style: 0,
        lpfn_wnd_proc: Some(proc),
        cb_cls_extra: 0,
        cb_wnd_extra: 0,
        h_instance: instance,
        h_icon: 0,
        h_cursor: unsafe { LoadCursorW(0, IDC_ARROW) },
        h_br_background: 0,
        lpsz_menu_name: std::ptr::null(),
        lpsz_class_name: name.as_ptr(),
    };
    unsafe { RegisterClassW(&class) };
}

fn create_layered(instance: Handle, class: &str, click_through: bool, no_activate: bool) -> Hwnd {
    let mut ex = WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW;
    if no_activate {
        ex |= WS_EX_NOACTIVATE;
    }
    if click_through {
        ex |= WS_EX_TRANSPARENT;
    }
    unsafe {
        CreateWindowExW(
            ex,
            wide(class).as_ptr(),
            wide(class).as_ptr(),
            WS_POPUP,
            0,
            0,
            0,
            0,
            0,
            0,
            instance,
            std::ptr::null_mut(),
        )
    }
}

unsafe extern "system" fn wnd_proc(hwnd: Hwnd, msg: u32, wparam: usize, lparam: isize) -> isize {
    match msg {
        WM_READING => {
            on_reading();
            0
        }
        WM_INPUT => {
            if let Some(step) = ble_step_from_input(lparam) {
                apply_ble_step(step);
            }
            0
        }
        WM_SHOW => {
            show_panel();
            0
        }
        WM_TIMER => {
            if wparam == 2 {
                unsafe { KillTimer(hwnd, 2) };
                with_ui(|ui| add_tray(ui.msg, ui.icon, "HP Professor 1 DPI"));
            }
            hide_hud_if_due();
            0
        }
        WM_TRAY => {
            let event = lparam as u32;
            if event == WM_LBUTTONUP || event == 0x0203 {
                toggle_panel();
            } else if event == WM_RBUTTONUP {
                show_tray_menu(hwnd);
            }
            0
        }
        WM_LBUTTONUP => {
            end_drag(lparam);
            0
        }
        WM_KEYDOWN if wparam == VK_ESCAPE => {
            hide_panel();
            0
        }
        0x0006 if (wparam & 0xFFFF) == 0 => {
            with_ui(|ui| {
                if ui.panel == hwnd && ui.panel_visible {
                    ui.panel_visible = false;
                    unsafe { ShowWindow(ui.panel, SW_HIDE) };
                }
            });
            0
        }
        WM_DESTROY | WM_CLOSE if hwnd == MSG_HWND.load(Ordering::Acquire) => {
            PostQuitMessage(0);
            0
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn with_ui<T>(f: impl FnOnce(&mut Ui) -> T) -> Option<T> {
    UI.get().and_then(|ui| ui.lock().ok().map(|mut ui| f(&mut ui)))
}

fn link_mode() -> crate::vendor::LinkMode {
    match LINK.load(Ordering::Acquire) {
        1 => crate::vendor::LinkMode::Asleep,
        2 => crate::vendor::LinkMode::Dongle,
        3 => crate::vendor::LinkMode::Bluetooth,
        _ => crate::vendor::LinkMode::Offline,
    }
}

fn set_link(mode: crate::vendor::LinkMode) {
    LINK.store(mode as u8, Ordering::Release);
    ASLEEP.store(mode == crate::vendor::LinkMode::Asleep, Ordering::Release);
}

fn panel_note(reading: Option<&crate::vendor::Reading>) -> String {
    crate::lang::panel_note(link_mode(), reading.map(|r| r.active + 1))
}

fn register_ble_input(hwnd: Hwnd) {
    let device = RawInputDevice {
        usage_page: 0xFF55,
        usage: 0x0202,
        flags: RIDEV_INPUTSINK,
        hwnd,
    };
    let ok = unsafe { RegisterRawInputDevices(&device, 1, std::mem::size_of::<RawInputDevice>() as u32) };
    if ok == 0 {
        log(&format!("藍牙通知註冊失敗 ({})", unsafe { GetLastError() }));
    } else {
        log("藍牙通知已註冊");
    }
}

fn ble_step_from_input(raw: isize) -> Option<usize> {
    unsafe {
        let mut size = 0u32;
        let header = std::mem::size_of::<crate::ffi::RawHidHeader>() as u32;
        if GetRawInputData(raw, RID_INPUT, std::ptr::null_mut(), &mut size, header) == u32::MAX || size < header + 8 {
            return None;
        }
        let mut buf = vec![0u8; size as usize];
        if GetRawInputData(raw, RID_INPUT, buf.as_mut_ptr().cast(), &mut size, header) == u32::MAX {
            return None;
        }
        let hid = &buf[header as usize..];
        if hid.len() < 8 {
            return None;
        }
        let report_bytes = u32::from_le_bytes(hid[0..4].try_into().ok()?) as usize;
        let data = &hid[8..];
        let payload = if data.first() == Some(&0x06) { &data[1..] } else { data };
        let window = payload.len().min(report_bytes.max(3));
        step_from_bytes(&payload[..window.min(payload.len())])
    }
}

fn step_from_bytes(bytes: &[u8]) -> Option<usize> {
    let start = if bytes.first() == Some(&0x06) { 1 } else { 0 };
    let b = bytes.get(start..)?;
    if b.len() >= 3 && b[0] == 0x66 && b[1] == 0x0C && b[2] < 7 {
        Some(b[2] as usize)
    } else {
        None
    }
}

fn apply_ble_step(step: usize) {
    let table = latest().lock().ok().and_then(|g| g.as_ref().map(|r| r.values.clone())).unwrap_or_default();
    let battery = latest().lock().ok().and_then(|g| g.as_ref().map(|r| r.battery)).unwrap_or(-1);
    let Some(reading) = crate::vendor::reading_for_step(step, &table, battery) else { return };
    log(&format!("藍牙 {} DPI  第 {}/7", reading.dpi, step + 1));
    set_link(crate::vendor::LinkMode::Bluetooth);
    FORCE_HUD.store(true, Ordering::Release);
    if let Ok(mut slot) = latest().lock() {
        *slot = Some(reading);
    }
    post_reading();
}

fn on_reading() {
    let reading = latest().lock().ok().and_then(|g| g.clone());
    with_ui(|ui| {
        let mode = link_mode();
        let changed = mode != crate::vendor::LinkMode::Asleep && reading.as_ref().map(|r| r.active) != ui.last_active;
        if let Some(reading) = reading.as_ref() {
            if mode != crate::vendor::LinkMode::Asleep {
                ui.last_active = Some(reading.active);
            }
            let tip = crate::lang::tip(link_mode(), reading.dpi, reading.active + 1, reading.levels);
            add_tray(ui.msg, stage_icon(ui, reading.active), &tip);
        } else {
            add_tray(ui.msg, ui.icon, link_mode().label());
        }
        if changed || FORCE_HUD.swap(false, Ordering::AcqRel) {
            show_hud(ui, reading.as_ref());
        }
        if ui.panel_visible {
            paint_panel(ui, reading.as_ref(), false);
        }
    });
}

fn show_hud(ui: &mut Ui, reading: Option<&Reading>) {
    let frame = paint::render_hud(&ui.fonts, reading, ui.scale);
    let area = paint::work_area();
    ui.hud_x = area.left + (area.right - area.left - frame.width) / 2;
    ui.hud_y = area.top + (36.0 * ui.scale) as i32;
    paint::present(ui.hud, &frame, ui.hud_x, ui.hud_y);
    unsafe { ShowWindow(ui.hud, SW_SHOWNOACTIVATE) };
    ui.hud_visible = true;
    ui.hud_until = unsafe { GetTickCount64() } + 1800;
}

fn paint_panel(ui: &mut Ui, reading: Option<&Reading>, anchor_to_cursor: bool) {
    let frame = paint::render_panel(
        &ui.fonts,
        reading,
        ui.scale,
        &panel_note(reading),
        link_mode() == crate::vendor::LinkMode::Asleep,
    );
    if anchor_to_cursor || ui.panel_x == 0 && ui.panel_y == 0 {
        place_above_tray(ui, frame.width, frame.height);
    }
    ui.chips = frame.chips.clone();
    paint::present(ui.panel, &frame, ui.panel_x, ui.panel_y);
    let _ = Frame { width: frame.width, height: frame.height, pixels: Vec::new(), chips: Vec::new() };
}

fn place_above_tray(ui: &mut Ui, width: i32, height: i32) {
    // Fixed: right side, sitting fully above the taskbar. A small gap so the
    // rounded bottom is not clipped by the taskbar.
    let area = paint::work_area();
    let margin = (16.0 * ui.scale) as i32;
    let gap = (20.0 * ui.scale) as i32;
    let mut x = area.right - width - margin;
    let mut y = area.bottom - height - gap;
    if x < area.left {
        x = area.left;
    }
    if y < area.top {
        y = area.top;
    }
    ui.panel_x = x;
    ui.panel_y = y;
}

fn show_panel() {
    let reading = latest().lock().ok().and_then(|g| g.clone());
    with_ui(|ui| {
        ui.panel_visible = true;
        paint_panel(ui, reading.as_ref(), true);
        unsafe {
            ShowWindow(ui.panel, 5);
            SetForegroundWindow(ui.panel);
        }
    });
}

fn hide_panel() {
    with_ui(|ui| {
        ui.panel_visible = false;
        unsafe { ShowWindow(ui.panel, SW_HIDE) };
    });
}

fn toggle_panel() {
    let visible = with_ui(|ui| ui.panel_visible).unwrap_or(false);
    if visible { hide_panel() } else { show_panel() }
}

fn hide_hud_if_due() {
    with_ui(|ui| {
        if ui.hud_visible && unsafe { GetTickCount64() } >= ui.hud_until {
            ui.hud_visible = false;
            unsafe { ShowWindow(ui.hud, SW_HIDE) };
        }
    });
}

fn end_drag(lparam: isize) {
    let index = with_ui(|ui| {
        let (x, y) = point(lparam);
        hit_chip(ui, x, y)
    }).flatten();
    if let Some(index) = index {
        if let Ok(mut cmd) = command().lock() {
            *cmd = Some(index);
        }
    }
}

fn hit_chip(ui: &Ui, x: i32, y: i32) -> Option<usize> {
    ui.chips.iter().find(|chip| x >= chip.x && y >= chip.y && x < chip.x + chip.w && y < chip.y + chip.h).map(|chip| chip.index)
}

fn point(lparam: isize) -> (i32, i32) {
    let x = (lparam as i16) as i32;
    let y = ((lparam >> 16) as i16) as i32;
    (x, y)
}

fn show_tray_menu(hwnd: Hwnd) {
    unsafe {
        let menu = CreatePopupMenu();
        let startup = wide(crate::lang::startup_item());
        let quit = wide(crate::lang::quit_item());
        let zh_tw = wide("繁體中文");
        let zh_cn = wide("简体中文");
        let en = wide("English");
        let startup_flags = if crate::install::autostart_enabled() {
            MF_STRING | MF_CHECKED
        } else {
            MF_STRING
        };
        let lang = crate::lang::current();
        let tw_flags = if lang == crate::lang::Lang::ZhTw { MF_STRING | MF_CHECKED } else { MF_STRING };
        let cn_flags = if lang == crate::lang::Lang::ZhCn { MF_STRING | MF_CHECKED } else { MF_STRING };
        let en_flags = if lang == crate::lang::Lang::En { MF_STRING | MF_CHECKED } else { MF_STRING };
        AppendMenuW(menu, startup_flags, 2, startup.as_ptr());
        AppendMenuW(menu, MF_SEPARATOR, 0, std::ptr::null());
        AppendMenuW(menu, tw_flags, 10, zh_tw.as_ptr());
        AppendMenuW(menu, cn_flags, 11, zh_cn.as_ptr());
        AppendMenuW(menu, en_flags, 12, en.as_ptr());
        AppendMenuW(menu, MF_SEPARATOR, 0, std::ptr::null());
        AppendMenuW(menu, MF_STRING, 1, quit.as_ptr());
        let mut pt = Point::default();
        GetCursorPos(&mut pt);
        SetForegroundWindow(hwnd);
        let cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTALIGN | TPM_NONOTIFY, pt.x, pt.y, 0, hwnd, std::ptr::null());
        PostMessageW(hwnd, WM_NULL, 0, 0);
        DestroyMenu(menu);
        if cmd == 2 {
            crate::install::toggle_autostart();
        } else if cmd == 10 || cmd == 11 || cmd == 12 {
            let next = match cmd {
                11 => crate::lang::Lang::ZhCn,
                12 => crate::lang::Lang::En,
                _ => crate::lang::Lang::ZhTw,
            };
            crate::lang::set(next);
            with_ui(|ui| ui.fonts = paint::Fonts::load(ui.scale));
            post_reading();
        } else if cmd == 1 {
            PostQuitMessage(0);
        }
    }
}

fn add_tray(hwnd: Hwnd, icon: Handle, tip: &str) {
    let mut data = NotifyIconDataW {
        cb_size: std::mem::size_of::<NotifyIconDataW>() as u32,
        hwnd,
        uid: 1,
        flags: NIF_MESSAGE | NIF_ICON | NIF_TIP,
        callback: WM_TRAY,
        icon,
        tip: [0; 128],
    };
    for (i, unit) in tip.encode_utf16().take(127).enumerate() {
        data.tip[i] = unit;
    }
    unsafe {
        SetLastError(0);
        let modified = Shell_NotifyIconW(NIM_MODIFY, &data);
        let modify_err = GetLastError();
        SetLastError(0);
        let added = Shell_NotifyIconW(NIM_ADD, &data);
        let add_err = GetLastError();
        if modified == 0 && added == 0 {
            log(&format!(
                "工作列圖示加入失敗 modify={modify_err} add={add_err} hwnd={hwnd} icon={icon} cb={}",
                data.cb_size
            ));
        } else {
            log("工作列圖示已加入");
        }
    }
}

fn remove_tray(hwnd: Hwnd) {
    let data = NotifyIconDataW {
        cb_size: std::mem::size_of::<NotifyIconDataW>() as u32,
        hwnd,
        uid: 1,
        flags: 0,
        callback: 0,
        icon: 0,
        tip: [0; 128],
    };
    unsafe { Shell_NotifyIconW(NIM_DELETE, &data) };
}

fn stage_icon(ui: &Ui, active: usize) -> Handle {
    ui.stage_icons.get(active).copied().filter(|h| *h != 0).unwrap_or(ui.icon)
}

fn icon_from_bgra(pixels: &[u8]) -> Handle {
    if pixels.len() < 32 * 32 * 4 {
        return 0;
    }
    unsafe {
        let screen = GetDC(0);
        let mem = CreateCompatibleDC(screen);
        let bmi = BitmapInfo {
            header: BitmapInfoHeader {
                size: std::mem::size_of::<BitmapInfoHeader>() as u32,
                width: 32,
                height: -32,
                planes: 1,
                bit_count: 32,
                compression: BI_RGB,
                size_image: 0,
                x_pels: 0,
                y_pels: 0,
                clr_used: 0,
                clr_important: 0,
            },
        };
        let mut bits = std::ptr::null_mut();
        let color = CreateDIBSection(mem, &bmi, DIB_RGB_COLORS, &mut bits, 0, 0);
        if !bits.is_null() {
            std::ptr::copy_nonoverlapping(pixels.as_ptr(), bits.cast(), 32 * 32 * 4);
        }
        let mask_bits = [0u8; 128];
        let mask = CreateBitmap(32, 32, 1, 1, mask_bits.as_ptr());
        let info = IconInfo {
            f_icon: 1,
            x_hotspot: 0,
            y_hotspot: 0,
            hbm_mask: mask,
            hbm_color: color,
        };
        let icon = CreateIconIndirect(&info);
        DeleteObject(color);
        DeleteObject(mask);
        DeleteDC(mem);
        ReleaseDC(0, screen);
        icon
    }
}

fn make_icon() -> Handle {
    unsafe {
        let screen = GetDC(0);
        let mem = CreateCompatibleDC(screen);
        let bmi = BitmapInfo {
            header: BitmapInfoHeader {
                size: std::mem::size_of::<BitmapInfoHeader>() as u32,
                width: 32,
                height: -32,
                planes: 1,
                bit_count: 32,
                compression: BI_RGB,
                size_image: 0,
                x_pels: 0,
                y_pels: 0,
                clr_used: 0,
                clr_important: 0,
            },
        };
        let mut bits = std::ptr::null_mut();
        let color = CreateDIBSection(mem, &bmi, DIB_RGB_COLORS, &mut bits, 0, 0);
        if !bits.is_null() {
            let px = std::slice::from_raw_parts_mut(bits.cast::<u8>(), 32 * 32 * 4);
            for y in 0..32 {
                for x in 0..32 {
                    let i = (y * 32 + x) * 4;
                    let inside = x >= 2 && x <= 29 && y >= 2 && y <= 29
                        && !(x < 6 && y < 6 && (x as i32 - 6).pow(2) + (y as i32 - 6).pow(2) > 16)
                        && !(x > 25 && y < 6 && (x as i32 - 25).pow(2) + (y as i32 - 6).pow(2) > 16)
                        && !(x < 6 && y > 25 && (x as i32 - 6).pow(2) + (y as i32 - 25).pow(2) > 16)
                        && !(x > 25 && y > 25 && (x as i32 - 25).pow(2) + (y as i32 - 25).pow(2) > 16);
                    let bar = ((6..10).contains(&x) && (18..25).contains(&y))
                        || ((14..18).contains(&x) && (14..25).contains(&y))
                        || ((22..26).contains(&x) && (8..25).contains(&y));
                    if bar {
                        px[i] = 255;
                        px[i + 1] = 255;
                        px[i + 2] = 255;
                        px[i + 3] = 255;
                    } else if inside {
                        px[i] = 32;
                        px[i + 1] = 28;
                        px[i + 2] = 28;
                        px[i + 3] = 255;
                    }
                }
            }
        }
        let mask_bits = [0u8; 128];
        let mask = CreateBitmap(32, 32, 1, 1, mask_bits.as_ptr());
        let info = IconInfo {
            f_icon: 1,
            x_hotspot: 0,
            y_hotspot: 0,
            hbm_mask: mask,
            hbm_color: color,
        };
        let icon = CreateIconIndirect(&info);
        DeleteObject(color);
        DeleteObject(mask);
        DeleteDC(mem);
        ReleaseDC(0, screen);
        icon
    }
}

fn save_frame_bmp(frame: &paint::Frame) -> std::io::Result<()> {
    let path = std::env::current_exe()?.parent().unwrap().join("panel-rendered.bmp");
    let w = frame.width as u32;
    let h = frame.height as u32;
    let row = (w * 4) as usize;
    let mut file = Vec::new();
    let pixel_size = row * h as usize;
    let offset = 14 + 40;
    file.extend_from_slice(b"BM");
    file.extend_from_slice(&((offset + pixel_size) as u32).to_le_bytes());
    file.extend_from_slice(&0u32.to_le_bytes());
    file.extend_from_slice(&(offset as u32).to_le_bytes());
    file.extend_from_slice(&40u32.to_le_bytes());
    file.extend_from_slice(&(w as i32).to_le_bytes());
    file.extend_from_slice(&(-(h as i32)).to_le_bytes());
    file.extend_from_slice(&1u16.to_le_bytes());
    file.extend_from_slice(&32u16.to_le_bytes());
    file.extend_from_slice(&0u32.to_le_bytes());
    file.extend_from_slice(&(pixel_size as u32).to_le_bytes());
    file.extend_from_slice(&0u32.to_le_bytes());
    file.extend_from_slice(&0u32.to_le_bytes());
    file.extend_from_slice(&0u32.to_le_bytes());
    file.extend_from_slice(&0u32.to_le_bytes());
    file.extend_from_slice(&frame.pixels);
    std::fs::write(path, file)
}

fn last_path() -> std::path::PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.join("dpi-last.txt")))
        .unwrap_or_else(|| std::path::PathBuf::from("dpi-last.txt"))
}

fn save_reading(reading: &Reading) {
    let values = reading.values.iter().map(|v| v.to_string()).collect::<Vec<_>>().join(",");
    let line = format!("{} {} {} {} {values}\n", reading.dpi, reading.active, reading.levels, reading.battery);
    let _ = std::fs::write(last_path(), line);
}

fn load_reading() -> Option<Reading> {
    let text = std::fs::read_to_string(last_path()).ok()?;
    let mut parts = text.split_whitespace();
    let dpi: u32 = parts.next()?.parse().ok()?;
    let active: usize = parts.next()?.parse().ok()?;
    let levels: usize = parts.next()?.parse().ok()?;
    let battery: i32 = parts.next()?.parse().ok()?;
    let values = parts.next()?.split(',').map(|v| v.parse().ok()).collect::<Option<Vec<u32>>>()?;
    if values.len() != levels || active >= levels {
        return None;
    }
    Some(Reading {
        levels,
        active,
        values,
        dpi,
        battery,
        product: "HP Professor 1".into(),
        relay: true,
    })
}

fn worker() {
    let mut channel: Option<Channel> = None;
    let mut misses = 0u32;
    let mut was_asleep = false;
    while !QUIT.load(Ordering::Acquire) {
        if channel.is_none() {
            match Channel::connect() {
                Ok(ch) => {
                    log(&format!("已連上 {}", ch.product));
                    channel = Some(ch);
                    misses = 0;
                }
                Err(err) => {
                    if crate::vendor::bluetooth_present() {
                        if link_mode() != crate::vendor::LinkMode::Bluetooth {
                            set_link(crate::vendor::LinkMode::Bluetooth);
                            log("藍牙已連線。按實體 DPI 鍵會跳出提示。");
                            post_reading();
                        }
                    } else {
                        if link_mode() != crate::vendor::LinkMode::Offline {
                            set_link(crate::vendor::LinkMode::Offline);
                            log(&err);
                            post_reading();
                        }
                    }
                    std::thread::sleep(Duration::from_millis(1200));
                    continue;
                }
            }
        }
        if let Some(index) = command().lock().ok().and_then(|mut cmd| cmd.take()) {
            if let Some(ch) = channel.as_mut() {
                let values = latest().lock().ok().and_then(|g| g.as_ref().map(|r| r.values.clone())).unwrap_or_default();
                let ok = ch.set_active(index, &values);
                log(&format!("切到第 {} 段：{}", index + 1, if ok { "已送出" } else { "失敗" }));
            }
        }
        let reading = channel.as_mut().and_then(|ch| ch.read());
        if let Some(reading) = reading {
            misses = 0;
            let changed = was_asleep || latest().lock().ok().and_then(|g| g.as_ref().map(|r| r.active)) != Some(reading.active);
            was_asleep = false;
            set_link(crate::vendor::LinkMode::Dongle);
            if changed {
                log(&format!("{} DPI  第 {}/{}", reading.dpi, reading.active + 1, reading.levels));
            }
            save_reading(&reading);
            if let Ok(mut slot) = latest().lock() {
                *slot = Some(reading);
            }
            if changed {
                post_reading();
            }
        } else if crate::vendor::bluetooth_present() {
            misses = 0;
            let changed = link_mode() != crate::vendor::LinkMode::Bluetooth;
            set_link(crate::vendor::LinkMode::Bluetooth);
            was_asleep = false;
            if changed {
                log("藍牙已連線。按實體 DPI 鍵會跳出提示。");
                post_reading();
            }
        } else if channel.as_mut().is_some_and(|ch| ch.asleep()) {
            misses = 0;
            set_link(crate::vendor::LinkMode::Asleep);
            if !was_asleep {
                was_asleep = true;
                log("滑鼠睡著了，動一下就會更新");
                post_reading();
            }
        } else {
            misses += 1;
            if misses >= 3 {
                log("通道中斷，重新連線");
                channel = None;
                misses = 0;
                post_reading();
            }
        }
        std::thread::sleep(Duration::from_millis(450));
    }
}

fn post_reading() {
    let hwnd = MSG_HWND.load(Ordering::Acquire);
    if hwnd != 0 {
        unsafe { PostMessageW(hwnd, WM_READING, 0, 0) };
    }
}
