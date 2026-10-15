use crate::ffi::*;
use crate::vendor::Reading;
use std::ffi::c_void;

#[derive(Clone)]
pub struct Chip {
    pub index: usize,
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

pub struct Frame {
    pub width: i32,
    pub height: i32,
    pub pixels: Vec<u8>,
    pub chips: Vec<Chip>,
}

pub struct Fonts {
    family: *mut c_void,
    format: *mut c_void,
    center: *mut c_void,
}

unsafe impl Send for Fonts {}

impl Fonts {
    pub fn load(scale: f32) -> Self {
        unsafe {
            let mut family = std::ptr::null_mut();
            let name = wide(crate::lang::font_name());
            if GdipCreateFontFamilyFromName(name.as_ptr(), std::ptr::null_mut(), &mut family) != 0 {
                GdipGetGenericFontFamilySansSerif(&mut family);
            }
            let mut format = std::ptr::null_mut();
            let mut center = std::ptr::null_mut();
            GdipCreateStringFormat(0x1000, 0, &mut format);
            GdipCreateStringFormat(0x1000, 0, &mut center);
            GdipSetStringFormatAlign(center, 1);
            let _ = scale;
            Self { family, format, center }
        }
    }
}

pub fn startup() -> usize {
    let input = GdiplusStartupInput {
        gdiplus_version: 1,
        debug_event_callback: std::ptr::null_mut(),
        suppress_background_thread: 0,
        suppress_external_codecs: 0,
    };
    let mut token = 0usize;
    let status = unsafe { GdiplusStartup(&mut token, &input, std::ptr::null_mut()) };
    if status != 0 {
        return 0;
    }
    token
}

pub fn scale() -> f32 {
    let dpi = unsafe { GetDpiForSystem() };
    if dpi == 0 { 1.0 } else { dpi as f32 / 96.0 }
}

pub fn render_hud(fonts: &Fonts, reading: Option<&Reading>, scale: f32) -> Frame {
    let scale = scale * 0.93;
    let width = (476.0 * scale * 0.93) as i32;
    let height = (148.0 * scale) as i32;
    let mut pixels = vec![0u8; (width * height * 4) as usize];
    let gfx = Canvas::new(&mut pixels, width, height);
    let radius = 32.0 * scale;
    gfx.round_rect(0.5, 0.5, width as f32 - 1.0, height as f32 - 1.0, radius, 0xE816_1618, 0x1CFF_FFFF);
    match reading {
        Some(reading) => {
            gfx.text(
                fonts,
                &crate::lang::stage(reading.active + 1, reading.levels),
                0.0,
                14.0 * scale,
                width as f32,
                26.0 * scale,
                16.0 * scale,
                false,
                0xFFBA_BABE,
                true,
            );
            let number = reading.dpi.to_string();
            gfx.text(fonts, &number, 28.0 * scale, 46.0 * scale, 220.0 * scale, 78.0 * scale, 58.0 * scale, true, 0xFFFF_FFFF, false);
            let number_w = gfx.measure(fonts, &number, 58.0 * scale, true);
            gfx.text(fonts, "DPI", 28.0 * scale + number_w + 12.0 * scale, 74.0 * scale, 56.0 * scale, 28.0 * scale, 20.0 * scale, false, 0xFFBA_BABE, false);
            draw_logo_bars(&gfx, width as f32 - 158.0 * scale, 36.0 * scale, 128.0 * scale, 92.0 * scale, reading.active);
        }
        None => {
            gfx.text(fonts, crate::lang::offline(), 36.0 * scale, 48.0 * scale, 400.0 * scale, 60.0 * scale, 36.0 * scale, true, 0xFFFF_FFFF, false);
        }
    }
    gfx.finish();
    Frame { width, height, pixels, chips: Vec::new() }
}

pub fn render_panel(fonts: &Fonts, reading: Option<&Reading>, scale: f32, note: &str, warn: bool) -> Frame {
    let width = (420.0 * scale) as i32;
    let height = (292.0 * scale) as i32;
    let mut pixels = vec![0u8; (width * height * 4) as usize];
    let gfx = Canvas::new(&mut pixels, width, height);
    gfx.round_rect(0.5, 0.5, width as f32 - 1.0, height as f32 - 1.0, 28.0 * scale, 0xE816_1618, 0x1CFF_FFFF);
    gfx.text(fonts, "HP Professor 1", 28.0 * scale, 20.0 * scale, 220.0 * scale, 24.0 * scale, 15.0 * scale, false, 0xFFA0_A0A6, false);
    let mut chips = Vec::new();
    match reading {
        Some(reading) => {
            if reading.battery >= 0 {
                let label = format!("{}%", reading.battery);
                gfx.text(fonts, &label, width as f32 - 88.0 * scale, 20.0 * scale, 60.0 * scale, 24.0 * scale, 15.0 * scale, false, 0xFFA0_A0A6, true);
            }
            let number = reading.dpi.to_string();
            gfx.text(fonts, &number, 28.0 * scale, 46.0 * scale, 240.0 * scale, 64.0 * scale, 54.0 * scale, true, 0xFFFF_FFFF, false);
            let number_w = gfx.measure(fonts, &number, 54.0 * scale, true);
            gfx.text(fonts, "DPI", 28.0 * scale + number_w + 14.0 * scale, 70.0 * scale, 70.0 * scale, 28.0 * scale, 18.0 * scale, false, 0xFFBA_BABE, false);
            gfx.text(
                fonts,
                note,
                28.0 * scale,
                116.0 * scale,
                360.0 * scale,
                28.0 * scale,
                15.0 * scale,
                false,
                if warn { 0xFFE0_B080 } else { 0xFF96_969C },
                false,
            );
            chips = layout_chips(reading.values.len(), width as f32, scale);
            for chip in &chips {
                let value = reading.values[chip.index];
                let selected = chip.index == reading.active;
                let fill = if selected { 0xFFFF_FFFF } else { 0x10FF_FFFF };
                let fg = if selected { 0xFF16_1618 } else { 0xFFE6_E6E8 };
                gfx.round_rect(chip.x as f32, chip.y as f32, chip.w as f32, chip.h as f32, 12.0 * scale, fill, 0);
                gfx.text(fonts, &value.to_string(), chip.x as f32, chip.y as f32 + 8.0 * scale, chip.w as f32, chip.h as f32 - 8.0, 16.0 * scale, true, fg, true);
            }
        }
        None => {
            let title = if note.is_empty() { crate::lang::offline() } else { note };
            gfx.text(fonts, title, 28.0 * scale, 70.0 * scale, 360.0 * scale, 56.0 * scale, 32.0 * scale, true, 0xFFFF_FFFF, false);
        }
    }
    gfx.finish();
    Frame { width, height, pixels, chips }
}

fn layout_chips(count: usize, panel_w: f32, scale: f32) -> Vec<Chip> {
    if count == 0 {
        return Vec::new();
    }
    let chip_w = (86.0 * scale) as i32;
    let chip_h = (42.0 * scale) as i32;
    let gap = (8.0 * scale) as i32;
    let first = count.min(4);
    let second = count.saturating_sub(4);
    let mut chips = Vec::new();
    let place = |chips: &mut Vec<Chip>, n: usize, y: i32, start_index: usize| {
        let total = n as i32 * chip_w + (n as i32 - 1) * gap;
        let mut x = ((panel_w as i32) - total) / 2;
        for i in 0..n {
            chips.push(Chip { index: start_index + i, x, y, w: chip_w, h: chip_h });
            x += chip_w + gap;
        }
    };
    place(&mut chips, first, (162.0 * scale) as i32, 0);
    if second > 0 {
        place(&mut chips, second, (214.0 * scale) as i32, first);
    }
    chips
}

/// Equal pitch, equal width, same slant. Heights still rise toward the middle.
const BAR_HEIGHTS: [f32; 7] = [0.42, 0.58, 0.78, 1.0, 0.78, 0.58, 0.42];

fn draw_logo_bars(gfx: &Canvas, x: f32, y: f32, w: f32, h: f32, active: usize) {
    let slant = 0.22;
    let max_h = h * 0.96;
    let inner = (w - max_h * slant).max(1.0);
    let bar_w = inner * 0.072;
    let gap = (inner - 7.0 * bar_w) / 6.0;
    let mid_y = y + h / 2.0;
    for i in 0..7 {
        let bh = max_h * BAR_HEIGHTS[i];
        let skew = bh * slant;
        let top = mid_y - bh / 2.0;
        let bot = mid_y + bh / 2.0;
        let left = x + i as f32 * (bar_w + gap);
        let pts = [
            left, bot,
            left + bar_w, bot,
            left + bar_w + skew, top,
            left + skew, top,
        ];
        let color = if i == active { 0xFF62_D8FF } else { 0xFFF3_F7FF };
        gfx.fill_polygon(&pts, color);
    }
}

fn draw_rail(gfx: &Canvas, x: f32, y: f32, levels: usize, active: usize, scale: f32) {
    let step = 32.0 * scale;
    let w = 18.0 * scale;
    for i in 0..levels.min(8) {
        let xi = x + i as f32 * step;
        if i == active {
            gfx.round_rect(xi, y, w, 8.0 * scale, 4.0 * scale, 0xFFFF_FFFF, 0);
        } else if i < active {
            gfx.round_rect(xi, y + 2.0 * scale, w, 4.0 * scale, 2.0 * scale, 0x5AFF_FFFF, 0);
        } else {
            gfx.round_rect(xi, y + 2.0 * scale, w, 4.0 * scale, 2.0 * scale, 0x24FF_FFFF, 0);
        }
    }
}

struct Canvas<'a> {
    pixels: &'a mut [u8],
    width: i32,
    height: i32,
    bitmap: *mut c_void,
    graphics: *mut c_void,
}

impl<'a> Canvas<'a> {
    fn new(pixels: &'a mut [u8], width: i32, height: i32) -> Self {
        let mut bitmap = std::ptr::null_mut();
        let mut graphics = std::ptr::null_mut();
        unsafe {
            // GDI+ does not reliably write through an external scan0 buffer.
            // Allocate the bitmap itself, draw, then lock the bits back out.
            GdipCreateBitmapFromScan0Alloc(width, height, PIXEL_FORMAT_32BPP_PARGB, &mut bitmap);
            GdipGetImageGraphicsContext(bitmap, &mut graphics);
            GdipSetSmoothingMode(graphics, SMOOTHING_MODE_ANTI_ALIAS);
            GdipSetTextRenderingHint(graphics, TEXT_RENDERING_HINT_ANTI_ALIAS);
        }
        Self { pixels, width, height, bitmap, graphics }
    }

    fn fill_polygon(&self, points: &[f32; 8], fill: u32) {
        unsafe {
            let mut path = std::ptr::null_mut();
            GdipCreatePath(FILL_MODE_ALTERNATE, &mut path);
            GdipAddPathPolygon(path, points.as_ptr(), 4);
            let mut brush = std::ptr::null_mut();
            GdipCreateSolidFill(fill, &mut brush);
            GdipFillPath(self.graphics, brush, path);
            GdipDeleteBrush(brush);
            GdipDeletePath(path);
        }
    }

    fn round_rect(&self, x: f32, y: f32, w: f32, h: f32, radius: f32, fill: u32, stroke: u32) {
        if w <= 2.0 || h <= 2.0 {
            return;
        }
        let r = radius.min(w / 2.0).min(h / 2.0);
        unsafe {
            let mut path = std::ptr::null_mut();
            GdipCreatePath(FILL_MODE_ALTERNATE, &mut path);
            let d = r * 2.0;
            GdipAddPathArc(path, x, y, d, d, 180.0, 90.0);
            GdipAddPathArc(path, x + w - d, y, d, d, 270.0, 90.0);
            GdipAddPathArc(path, x + w - d, y + h - d, d, d, 0.0, 90.0);
            GdipAddPathArc(path, x, y + h - d, d, d, 90.0, 90.0);
            GdipClosePathFigure(path);
            if fill != 0 {
                let mut brush = std::ptr::null_mut();
                GdipCreateSolidFill(fill, &mut brush);
                GdipFillPath(self.graphics, brush, path);
                GdipDeleteBrush(brush);
            }
            if stroke != 0 {
                let mut pen = std::ptr::null_mut();
                GdipCreatePen1(stroke, 1.0, UNIT_PIXEL, &mut pen);
                GdipDrawPath(self.graphics, pen, path);
                GdipDeletePen(pen);
            }
            GdipDeletePath(path);
        }
    }

    fn text(&self, fonts: &Fonts, text: &str, x: f32, y: f32, w: f32, h: f32, size: f32, bold: bool, color: u32, center: bool) {
        let wide_text = wide(text);
        let length = (wide_text.len() - 1) as i32;
        unsafe {
            let mut font = std::ptr::null_mut();
            GdipCreateFont(fonts.family, size, if bold { FONT_STYLE_BOLD } else { FONT_STYLE_REGULAR }, UNIT_PIXEL, &mut font);
            let mut brush = std::ptr::null_mut();
            GdipCreateSolidFill(color, &mut brush);
            let rect = RectF { x, y, w, h };
            let format = if center { fonts.center } else { fonts.format };
            GdipDrawString(self.graphics, wide_text.as_ptr(), length, font, &rect, format, brush);
            GdipDeleteBrush(brush);
            GdipDeleteFont(font);
        }
    }

    fn measure(&self, fonts: &Fonts, text: &str, size: f32, bold: bool) -> f32 {
        let wide_text = wide(text);
        let length = (wide_text.len() - 1) as i32;
        unsafe {
            let mut font = std::ptr::null_mut();
            GdipCreateFont(fonts.family, size, if bold { FONT_STYLE_BOLD } else { FONT_STYLE_REGULAR }, UNIT_PIXEL, &mut font);
            let layout = RectF { x: 0.0, y: 0.0, w: 1000.0, h: 200.0 };
            let mut bounds = RectF { x: 0.0, y: 0.0, w: 0.0, h: 0.0 };
            GdipMeasureString(self.graphics, wide_text.as_ptr(), length, font, &layout, fonts.format, &mut bounds, std::ptr::null_mut(), std::ptr::null_mut());
            GdipDeleteFont(font);
            bounds.w
        }
    }

    fn finish(self) {
        unsafe {
            GdipDeleteGraphics(self.graphics);
            let rect = GpRect { x: 0, y: 0, w: self.width, h: self.height };
            let mut data = BitmapData {
                width: 0,
                height: 0,
                stride: 0,
                pixel_format: 0,
                scan0: std::ptr::null_mut(),
                reserved: 0,
            };
            if GdipBitmapLockBits(self.bitmap, &rect, 1, PIXEL_FORMAT_32BPP_PARGB, &mut data) == 0 && !data.scan0.is_null() {
                let row_bytes = (self.width * 4) as usize;
                for y in 0..self.height as usize {
                    let src = data.scan0.cast::<u8>().add(y * data.stride as usize);
                    let dst = self.pixels.as_ptr().add(y * row_bytes) as *mut u8;
                    std::ptr::copy_nonoverlapping(src, dst, row_bytes);
                }
                GdipBitmapUnlockBits(self.bitmap, &mut data);
            }
            GdipDisposeImage(self.bitmap);
        }
    }
}

pub fn present(hwnd: Hwnd, frame: &Frame, x: i32, y: i32) {
    unsafe {
        let screen = GetDC(0);
        let mem = CreateCompatibleDC(screen);
        let bmi = BitmapInfo {
            header: BitmapInfoHeader {
                size: std::mem::size_of::<BitmapInfoHeader>() as u32,
                width: frame.width,
                height: -frame.height,
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
        let bmp = CreateDIBSection(mem, &bmi, DIB_RGB_COLORS, &mut bits, 0, 0);
        if !bits.is_null() {
            std::ptr::copy_nonoverlapping(frame.pixels.as_ptr(), bits.cast(), frame.pixels.len());
        }
        let old = SelectObject(mem, bmp);
        let dst = Point { x, y };
        let size = Size { cx: frame.width, cy: frame.height };
        let src = Point { x: 0, y: 0 };
        let blend = BlendFunction {
            blend_op: AC_SRC_OVER,
            blend_flags: 0,
            source_constant_alpha: 255,
            alpha_format: AC_SRC_ALPHA,
        };
        let ok = UpdateLayeredWindow(hwnd, screen, &dst, &size, mem, &src, 0, &blend, ULW_ALPHA);
        if ok == 0 {
            crate::ui::log(&format!("UpdateLayeredWindow failed {}", GetLastError()));
        }
        SelectObject(mem, old);
        DeleteObject(bmp);
        DeleteDC(mem);
        ReleaseDC(0, screen);
    }
}

pub fn work_area() -> Rect {
    let mut rect = Rect::default();
    let ok = unsafe { SystemParametersInfoW(SPI_GETWORKAREA, 0, (&mut rect as *mut Rect).cast(), 0) };
    if ok == 0 {
        rect.right = unsafe { crate::ffi::GetSystemMetrics(SM_CXSCREEN) };
        rect.bottom = unsafe { crate::ffi::GetSystemMetrics(SM_CYSCREEN) };
    }
    rect
}
