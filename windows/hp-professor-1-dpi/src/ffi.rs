#![allow(non_snake_case, dead_code)]

use std::ffi::c_void;

pub type Handle = isize;
pub type Hwnd = isize;

pub const INVALID_HANDLE: Handle = -1;
pub const DIGCF_PRESENT: u32 = 0x02;
pub const DIGCF_DEVICEINTERFACE: u32 = 0x10;
pub const FILE_SHARE_READ: u32 = 0x1;
pub const FILE_SHARE_WRITE: u32 = 0x2;
pub const OPEN_EXISTING: u32 = 3;
pub const ERROR_ALREADY_EXISTS: u32 = 183;

pub const WS_POPUP: u32 = 0x8000_0000;
pub const WS_EX_TOPMOST: u32 = 0x0000_0008;
pub const WS_EX_TRANSPARENT: u32 = 0x0000_0020;
pub const WS_EX_TOOLWINDOW: u32 = 0x0000_0080;
pub const WS_EX_LAYERED: u32 = 0x0008_0000;
pub const WS_EX_NOACTIVATE: u32 = 0x0800_0000;

pub const SW_HIDE: i32 = 0;
pub const SW_SHOWNOACTIVATE: i32 = 4;
pub const SM_CXSCREEN: i32 = 0;
pub const SM_CYSCREEN: i32 = 1;
pub const SPI_GETWORKAREA: u32 = 0x0030;

pub const WM_DESTROY: u32 = 0x0002;
pub const WM_CLOSE: u32 = 0x0010;
pub const WM_QUIT: u32 = 0x0012;
pub const WM_KEYDOWN: u32 = 0x0100;
pub const WM_MOUSEMOVE: u32 = 0x0200;
pub const WM_LBUTTONDOWN: u32 = 0x0201;
pub const WM_LBUTTONUP: u32 = 0x0202;
pub const WM_RBUTTONUP: u32 = 0x0205;
pub const WM_TIMER: u32 = 0x0113;
pub const WM_NULL: u32 = 0x0000;
pub const WM_APP: u32 = 0x8000;
pub const VK_ESCAPE: usize = 0x1B;

pub const ULW_ALPHA: u32 = 0x00000002;
pub const AC_SRC_OVER: u8 = 0;
pub const AC_SRC_ALPHA: u8 = 1;
pub const BI_RGB: u32 = 0;
pub const DIB_RGB_COLORS: u32 = 0;

pub const NIM_ADD: u32 = 0;
pub const NIM_MODIFY: u32 = 1;
pub const NIM_DELETE: u32 = 2;
pub const NIF_MESSAGE: u32 = 0x01;
pub const NIF_ICON: u32 = 0x02;
pub const NIF_TIP: u32 = 0x04;
pub const MF_STRING: u32 = 0;
pub const MF_SEPARATOR: u32 = 0x00000800;
pub const MF_CHECKED: u32 = 0x0008;
pub const WM_INPUT: u32 = 0x00FF;
pub const RID_INPUT: u32 = 0x10000003;
pub const RIDEV_INPUTSINK: u32 = 0x00000100;

#[repr(C)]
pub struct RawHidHeader {
    pub kind: u32,
    pub size: u32,
    pub device: isize,
    pub wparam: usize,
}

#[repr(C)]
pub struct RawInputDevice {
    pub usage_page: u16,
    pub usage: u16,
    pub flags: u32,
    pub hwnd: Hwnd,
}
pub const TPM_RIGHTALIGN: u32 = 0x0008;
pub const TPM_RETURNCMD: u32 = 0x0100;
pub const TPM_NONOTIFY: u32 = 0x0080;

pub const SWP_NOSIZE: u32 = 0x0001;
pub const SWP_NOZORDER: u32 = 0x0004;
pub const SWP_NOACTIVATE: u32 = 0x0010;
pub const HWND_TOPMOST: isize = -1;
pub const HWND_MESSAGE: isize = -3;

pub const IDC_ARROW: *const u16 = 32512 as *const u16;
pub const IMAGE_ICON: u32 = 1;
pub const LR_DEFAULTSIZE: u32 = 0x40;
pub const DI_NORMAL: u32 = 0x0003;

pub const PIXEL_FORMAT_32BPP_PARGB: i32 = 0x000E_200B;
pub const SMOOTHING_MODE_ANTI_ALIAS: i32 = 4;
pub const TEXT_RENDERING_HINT_ANTI_ALIAS: i32 = 4;
pub const UNIT_PIXEL: i32 = 2;
pub const FONT_STYLE_REGULAR: i32 = 0;
pub const FONT_STYLE_BOLD: i32 = 1;
pub const FILL_MODE_ALTERNATE: i32 = 0;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Guid {
    pub data1: u32,
    pub data2: u16,
    pub data3: u16,
    pub data4: [u8; 8],
}

pub const HID_GUID: Guid = Guid {
    data1: 0x4d1e55b2,
    data2: 0xf16f,
    data3: 0x11cf,
    data4: [0x88, 0xcb, 0x00, 0x11, 0x11, 0x00, 0x00, 0x30],
};

#[repr(C)]
pub struct SpDeviceInterfaceData {
    pub cb_size: u32,
    pub interface_class_guid: Guid,
    pub flags: u32,
    pub reserved: usize,
}

#[repr(C)]
pub struct HiddAttributes {
    pub size: u32,
    pub vendor_id: u16,
    pub product_id: u16,
    pub version_number: u16,
}

#[repr(C)]
pub struct HidpCaps {
    pub usage: u16,
    pub usage_page: u16,
    pub input_report_byte_length: u16,
    pub output_report_byte_length: u16,
    pub feature_report_byte_length: u16,
    pub reserved: [u16; 17],
    pub number_link_collection_nodes: u16,
    pub number_input_button_caps: u16,
    pub number_input_value_caps: u16,
    pub number_input_data_indices: u16,
    pub number_output_button_caps: u16,
    pub number_output_value_caps: u16,
    pub number_output_data_indices: u16,
    pub number_feature_button_caps: u16,
    pub number_feature_value_caps: u16,
    pub number_feature_data_indices: u16,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Point {
    pub x: i32,
    pub y: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Size {
    pub cx: i32,
    pub cy: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Rect {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct RectF {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

#[repr(C)]
pub struct Msg {
    pub hwnd: Hwnd,
    pub message: u32,
    pub wparam: usize,
    pub lparam: isize,
    pub time: u32,
    pub pt: Point,
}

#[repr(C)]
pub struct WndClassW {
    pub style: u32,
    pub lpfn_wnd_proc: Option<unsafe extern "system" fn(Hwnd, u32, usize, isize) -> isize>,
    pub cb_cls_extra: i32,
    pub cb_wnd_extra: i32,
    pub h_instance: Handle,
    pub h_icon: Handle,
    pub h_cursor: Handle,
    pub h_br_background: Handle,
    pub lpsz_menu_name: *const u16,
    pub lpsz_class_name: *const u16,
}

#[repr(C)]
pub struct BitmapInfoHeader {
    pub size: u32,
    pub width: i32,
    pub height: i32,
    pub planes: u16,
    pub bit_count: u16,
    pub compression: u32,
    pub size_image: u32,
    pub x_pels: i32,
    pub y_pels: i32,
    pub clr_used: u32,
    pub clr_important: u32,
}

#[repr(C)]
pub struct BitmapInfo {
    pub header: BitmapInfoHeader,
}

#[repr(C)]
pub struct BlendFunction {
    pub blend_op: u8,
    pub blend_flags: u8,
    pub source_constant_alpha: u8,
    pub alpha_format: u8,
}

#[repr(C)]
pub struct NotifyIconDataW {
    pub cb_size: u32,
    pub hwnd: Hwnd,
    pub uid: u32,
    pub flags: u32,
    pub callback: u32,
    pub icon: Handle,
    pub tip: [u16; 128],
}

#[repr(C)]
pub struct IconInfo {
    pub f_icon: i32,
    pub x_hotspot: u32,
    pub y_hotspot: u32,
    pub hbm_mask: Handle,
    pub hbm_color: Handle,
}

#[repr(C)]
pub struct GdiplusStartupInput {
    pub gdiplus_version: u32,
    pub debug_event_callback: *mut c_void,
    pub suppress_background_thread: i32,
    pub suppress_external_codecs: i32,
}

#[link(name = "kernel32")]
extern "system" {
    pub fn GetModuleHandleW(name: *const u16) -> Handle;
    pub fn CreateFileW(
        name: *const u16,
        access: u32,
        share: u32,
        security: *mut c_void,
        disposition: u32,
        flags: u32,
        template: Handle,
    ) -> Handle;
    pub fn CloseHandle(handle: Handle) -> i32;
    pub fn GetLastError() -> u32;
    pub fn GetUserDefaultUILanguage() -> u16;
    pub fn SetLastError(code: u32);
    pub fn LoadLibraryW(name: *const u16) -> Handle;
    pub fn GetProcAddress(module: Handle, name: *const u8) -> *mut c_void;
    pub fn CreateMutexW(security: *mut c_void, initial_owner: i32, name: *const u16) -> Handle;
    pub fn GetTickCount64() -> u64;
    pub fn Sleep(ms: u32);
}

#[link(name = "setupapi")]
extern "system" {
    pub fn SetupDiGetClassDevsW(
        class_guid: *const Guid,
        enumerator: *const u16,
        hwnd: Hwnd,
        flags: u32,
    ) -> Handle;
    pub fn SetupDiEnumDeviceInterfaces(
        dev_info: Handle,
        device_info_data: *mut c_void,
        class_guid: *const Guid,
        member_index: u32,
        data: *mut SpDeviceInterfaceData,
    ) -> i32;
    pub fn SetupDiGetDeviceInterfaceDetailW(
        dev_info: Handle,
        data: *const SpDeviceInterfaceData,
        detail: *mut c_void,
        detail_size: u32,
        required_size: *mut u32,
        device_info_data: *mut c_void,
    ) -> i32;
    pub fn SetupDiDestroyDeviceInfoList(dev_info: Handle) -> i32;
}

fn proc<T>(dll: &str, name: &[u8]) -> T {
    unsafe {
        let module = LoadLibraryW(wide(dll).as_ptr());
        let addr = GetProcAddress(module, name.as_ptr());
        if addr.is_null() {
            panic!("missing {dll}!{}", String::from_utf8_lossy(name));
        }
        std::mem::transmute_copy(&addr)
    }
}

pub unsafe fn HidD_GetAttributes(handle: Handle, attrs: *mut HiddAttributes) -> i32 {
    type F = unsafe extern "system" fn(Handle, *mut HiddAttributes) -> i32;
    proc::<F>("hid.dll", b"HidD_GetAttributes\0")(handle, attrs)
}
pub unsafe fn HidD_GetPreparsedData(handle: Handle, preparsed: *mut *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(Handle, *mut *mut c_void) -> i32;
    proc::<F>("hid.dll", b"HidD_GetPreparsedData\0")(handle, preparsed)
}
pub unsafe fn HidD_FreePreparsedData(preparsed: *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void) -> i32;
    proc::<F>("hid.dll", b"HidD_FreePreparsedData\0")(preparsed)
}
pub unsafe fn HidP_GetCaps(preparsed: *mut c_void, caps: *mut HidpCaps) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void, *mut HidpCaps) -> i32;
    proc::<F>("hid.dll", b"HidP_GetCaps\0")(preparsed, caps)
}
pub unsafe fn HidD_GetProductString(handle: Handle, buffer: *mut u16, length: u32) -> i32 {
    type F = unsafe extern "system" fn(Handle, *mut u16, u32) -> i32;
    proc::<F>("hid.dll", b"HidD_GetProductString\0")(handle, buffer, length)
}
pub unsafe fn HidD_SetFeature(handle: Handle, buffer: *mut u8, length: u32) -> i32 {
    type F = unsafe extern "system" fn(Handle, *mut u8, u32) -> i32;
    proc::<F>("hid.dll", b"HidD_SetFeature\0")(handle, buffer, length)
}
pub unsafe fn HidD_GetFeature(handle: Handle, buffer: *mut u8, length: u32) -> i32 {
    type F = unsafe extern "system" fn(Handle, *mut u8, u32) -> i32;
    proc::<F>("hid.dll", b"HidD_GetFeature\0")(handle, buffer, length)
}

#[link(name = "user32")]
extern "system" {
    pub fn RegisterClassW(class: *const WndClassW) -> u16;
    pub fn CreateWindowExW(
        ex_style: u32,
        class: *const u16,
        window_name: *const u16,
        style: u32,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        parent: Hwnd,
        menu: Handle,
        instance: Handle,
        param: *mut c_void,
    ) -> Hwnd;
    pub fn DestroyWindow(hwnd: Hwnd) -> i32;
    pub fn ShowWindow(hwnd: Hwnd, cmd: i32) -> i32;
    pub fn UpdateLayeredWindow(
        hwnd: Hwnd,
        hdc_dst: Handle,
        ppt_dst: *const Point,
        psize: *const Size,
        hdc_src: Handle,
        ppt_src: *const Point,
        color_key: u32,
        blend: *const BlendFunction,
        flags: u32,
    ) -> i32;
    pub fn GetDC(hwnd: Hwnd) -> Handle;
    pub fn ReleaseDC(hwnd: Hwnd, hdc: Handle) -> i32;
    pub fn DefWindowProcW(hwnd: Hwnd, msg: u32, wparam: usize, lparam: isize) -> isize;
    pub fn GetMessageW(msg: *mut Msg, hwnd: Hwnd, min: u32, max: u32) -> i32;
    pub fn TranslateMessage(msg: *const Msg) -> i32;
    pub fn DispatchMessageW(msg: *const Msg) -> isize;
    pub fn PostQuitMessage(code: i32);
    pub fn PostMessageW(hwnd: Hwnd, msg: u32, wparam: usize, lparam: isize) -> i32;
    pub fn SendMessageW(hwnd: Hwnd, msg: u32, wparam: usize, lparam: isize) -> isize;
    pub fn SetTimer(hwnd: Hwnd, id: usize, elapse: u32, proc: *mut c_void) -> usize;
    pub fn KillTimer(hwnd: Hwnd, id: usize) -> i32;
    pub fn LoadCursorW(instance: Handle, name: *const u16) -> Handle;
    pub fn LoadIconW(instance: Handle, name: *const u16) -> Handle;
    pub fn RegisterRawInputDevices(devices: *const RawInputDevice, count: u32, size: u32) -> i32;
    pub fn GetRawInputData(raw: isize, command: u32, data: *mut c_void, size: *mut u32, header_size: u32) -> u32;
    pub fn SetCapture(hwnd: Hwnd) -> Hwnd;
    pub fn ReleaseCapture() -> i32;
    pub fn GetCursorPos(point: *mut Point) -> i32;
    pub fn SetWindowPos(
        hwnd: Hwnd,
        insert_after: Hwnd,
        x: i32,
        y: i32,
        cx: i32,
        cy: i32,
        flags: u32,
    ) -> i32;
    pub fn GetWindowRect(hwnd: Hwnd, rect: *mut Rect) -> i32;
    pub fn FindWindowW(class: *const u16, window: *const u16) -> Hwnd;
    pub fn SetForegroundWindow(hwnd: Hwnd) -> i32;
    pub fn CreatePopupMenu() -> Handle;
    pub fn AppendMenuW(menu: Handle, flags: u32, id: usize, text: *const u16) -> i32;
    pub fn TrackPopupMenu(
        menu: Handle,
        flags: u32,
        x: i32,
        y: i32,
        reserved: i32,
        hwnd: Hwnd,
        rect: *const Rect,
    ) -> i32;
    pub fn DestroyMenu(menu: Handle) -> i32;
    pub fn SystemParametersInfoW(action: u32, param: u32, pv: *mut c_void, win_ini: u32) -> i32;
    pub fn GetSystemMetrics(index: i32) -> i32;
    pub fn GetDpiForSystem() -> u32;
    pub fn SetProcessDpiAwarenessContext(value: isize) -> i32;
    pub fn MessageBoxW(hwnd: Hwnd, text: *const u16, caption: *const u16, kind: u32) -> i32;
}

#[link(name = "gdi32")]
extern "system" {
    pub fn CreateCompatibleDC(hdc: Handle) -> Handle;
    pub fn DeleteDC(hdc: Handle) -> i32;
    pub fn CreateDIBSection(
        hdc: Handle,
        bmi: *const BitmapInfo,
        usage: u32,
        bits: *mut *mut c_void,
        section: Handle,
        offset: u32,
    ) -> Handle;
    pub fn SelectObject(hdc: Handle, object: Handle) -> Handle;
    pub fn DeleteObject(object: Handle) -> i32;
    pub fn CreateBitmap(width: i32, height: i32, planes: u32, bits: u32, bits_ptr: *const u8) -> Handle;
    pub fn CreateCompatibleBitmap(hdc: Handle, width: i32, height: i32) -> Handle;
}

#[repr(C)]
pub struct NotifyIconIdentifier {
    pub cb_size: u32,
    pub hwnd: Hwnd,
    pub uid: u32,
    pub guid: [u8; 16],
}

#[link(name = "shell32")]
extern "system" {
    pub fn Shell_NotifyIconW(message: u32, data: *const NotifyIconDataW) -> i32;
    pub fn Shell_NotifyIconGetRect(id: *const NotifyIconIdentifier, rect: *mut Rect) -> i32;
}

#[link(name = "user32")]
extern "system" {
    pub fn CreateIconIndirect(info: *const IconInfo) -> Handle;
    pub fn DestroyIcon(icon: Handle) -> i32;
}

pub unsafe fn GdiplusStartup(token: *mut usize, input: *const GdiplusStartupInput, output: *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(*mut usize, *const GdiplusStartupInput, *mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdiplusStartup\0")(token, input, output)
}
pub unsafe fn GdipCreateBitmapFromScan0(width: i32, height: i32, stride: i32, format: i32, scan0: *mut u8, bitmap: *mut *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(i32, i32, i32, i32, *mut u8, *mut *mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipCreateBitmapFromScan0\0")(width, height, stride, format, scan0, bitmap)
}
pub unsafe fn GdipGetImageGraphicsContext(image: *mut c_void, graphics: *mut *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void, *mut *mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipGetImageGraphicsContext\0")(image, graphics)
}
pub unsafe fn GdipSetSmoothingMode(graphics: *mut c_void, mode: i32) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void, i32) -> i32;
    proc::<F>("gdiplus.dll", b"GdipSetSmoothingMode\0")(graphics, mode)
}
pub unsafe fn GdipSetTextRenderingHint(graphics: *mut c_void, hint: i32) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void, i32) -> i32;
    proc::<F>("gdiplus.dll", b"GdipSetTextRenderingHint\0")(graphics, hint)
}
pub unsafe fn GdipCreatePath(fill_mode: i32, path: *mut *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(i32, *mut *mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipCreatePath\0")(fill_mode, path)
}
pub unsafe fn GdipAddPathPolygon(path: *mut c_void, points: *const f32, count: i32) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void, *const f32, i32) -> i32;
    proc::<F>("gdiplus.dll", b"GdipAddPathPolygon\0")(path, points, count)
}
pub unsafe fn GdipAddPathArc(path: *mut c_void, x: f32, y: f32, width: f32, height: f32, start: f32, sweep: f32) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void, f32, f32, f32, f32, f32, f32) -> i32;
    proc::<F>("gdiplus.dll", b"GdipAddPathArc\0")(path, x, y, width, height, start, sweep)
}
pub unsafe fn GdipClosePathFigure(path: *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipClosePathFigure\0")(path)
}
pub unsafe fn GdipCreateSolidFill(color: u32, brush: *mut *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(u32, *mut *mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipCreateSolidFill\0")(color, brush)
}
pub unsafe fn GdipFillPath(graphics: *mut c_void, brush: *mut c_void, path: *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void, *mut c_void, *mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipFillPath\0")(graphics, brush, path)
}
pub unsafe fn GdipCreatePen1(color: u32, width: f32, unit: i32, pen: *mut *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(u32, f32, i32, *mut *mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipCreatePen1\0")(color, width, unit, pen)
}
pub unsafe fn GdipDrawPath(graphics: *mut c_void, pen: *mut c_void, path: *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void, *mut c_void, *mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipDrawPath\0")(graphics, pen, path)
}
pub unsafe fn GdipDeletePen(pen: *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipDeletePen\0")(pen)
}
pub unsafe fn GdipDeletePath(path: *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipDeletePath\0")(path)
}
pub unsafe fn GdipDeleteBrush(brush: *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipDeleteBrush\0")(brush)
}
pub unsafe fn GdipCreateFontFamilyFromName(name: *const u16, collection: *mut c_void, family: *mut *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(*const u16, *mut c_void, *mut *mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipCreateFontFamilyFromName\0")(name, collection, family)
}
pub unsafe fn GdipGetGenericFontFamilySansSerif(family: *mut *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(*mut *mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipGetGenericFontFamilySansSerif\0")(family)
}
pub unsafe fn GdipCreateFont(family: *mut c_void, size: f32, style: i32, unit: i32, font: *mut *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void, f32, i32, i32, *mut *mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipCreateFont\0")(family, size, style, unit, font)
}
pub unsafe fn GdipCreateStringFormat(flags: i32, language: i32, format: *mut *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(i32, i32, *mut *mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipCreateStringFormat\0")(flags, language, format)
}
pub unsafe fn GdipSetStringFormatAlign(format: *mut c_void, align: i32) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void, i32) -> i32;
    proc::<F>("gdiplus.dll", b"GdipSetStringFormatAlign\0")(format, align)
}
pub unsafe fn GdipDrawString(graphics: *mut c_void, text: *const u16, length: i32, font: *mut c_void, rect: *const RectF, format: *mut c_void, brush: *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void, *const u16, i32, *mut c_void, *const RectF, *mut c_void, *mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipDrawString\0")(graphics, text, length, font, rect, format, brush)
}
pub unsafe fn GdipMeasureString(graphics: *mut c_void, text: *const u16, length: i32, font: *mut c_void, layout: *const RectF, format: *mut c_void, bounding: *mut RectF, codepoints: *mut i32, lines: *mut i32) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void, *const u16, i32, *mut c_void, *const RectF, *mut c_void, *mut RectF, *mut i32, *mut i32) -> i32;
    proc::<F>("gdiplus.dll", b"GdipMeasureString\0")(graphics, text, length, font, layout, format, bounding, codepoints, lines)
}
pub unsafe fn GdipDeleteFont(font: *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipDeleteFont\0")(font)
}
pub unsafe fn GdipDeleteFontFamily(family: *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipDeleteFontFamily\0")(family)
}
pub unsafe fn GdipDeleteStringFormat(format: *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipDeleteStringFormat\0")(format)
}
pub unsafe fn GdipDeleteGraphics(graphics: *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipDeleteGraphics\0")(graphics)
}
pub unsafe fn GdipDisposeImage(image: *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipDisposeImage\0")(image)
}
pub unsafe fn GdipCreateBitmapFromScan0Alloc(width: i32, height: i32, format: i32, bitmap: *mut *mut c_void) -> i32 {
    type F = unsafe extern "system" fn(i32, i32, i32, i32, *mut u8, *mut *mut c_void) -> i32;
    proc::<F>("gdiplus.dll", b"GdipCreateBitmapFromScan0\0")(width, height, 0, format, std::ptr::null_mut(), bitmap)
}
pub unsafe fn GdipBitmapLockBits(bitmap: *mut c_void, rect: *const GpRect, flags: u32, format: i32, data: *mut BitmapData) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void, *const GpRect, u32, i32, *mut BitmapData) -> i32;
    proc::<F>("gdiplus.dll", b"GdipBitmapLockBits\0")(bitmap, rect, flags, format, data)
}
pub unsafe fn GdipBitmapUnlockBits(bitmap: *mut c_void, data: *mut BitmapData) -> i32 {
    type F = unsafe extern "system" fn(*mut c_void, *mut BitmapData) -> i32;
    proc::<F>("gdiplus.dll", b"GdipBitmapUnlockBits\0")(bitmap, data)
}

#[repr(C)]
pub struct GpRect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

#[repr(C)]
pub struct BitmapData {
    pub width: u32,
    pub height: u32,
    pub stride: i32,
    pub pixel_format: i32,
    pub scan0: *mut c_void,
    pub reserved: usize,
}

pub fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

pub fn from_wide(buf: &[u16]) -> String {
    let end = buf.iter().position(|c| *c == 0).unwrap_or(buf.len());
    String::from_utf16_lossy(&buf[..end])
}
