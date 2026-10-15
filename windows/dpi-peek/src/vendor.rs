use crate::ffi::*;

pub const VID: u16 = 0x3151;
pub const PID_DONGLE: u16 = 0x4027;
pub const PID_BLE: u16 = 0x4028;
pub const FACTORY: [u32; 7] = [800, 1000, 1200, 1600, 2400, 3200, 4000];
pub const USAGE_PAGE: u16 = 0xFFFF;
pub const USAGE: u16 = 0x0002;
pub const DPI_GET: u8 = 0xD4;
pub const DPI_SET: u8 = 0x54;
pub const RELAY_MOUSE: u8 = 5;
const HIDP_STATUS_SUCCESS: i32 = 0x0011_0000;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reading {
    pub levels: usize,
    pub active: usize,
    pub values: Vec<u32>,
    pub dpi: u32,
    pub battery: i32,
    pub product: String,
    pub relay: bool,
}

pub struct Channel {
    handle: Handle,
    feature_len: u32,
    relay_target: i32,
    pub battery: i32,
    pub product: String,
}

impl Channel {
    pub fn connect() -> Result<Self, String> {
        let found = find_vendor().ok_or("找不到 2.4G 原廠通道。把底部開關撥到 2.4G，動一下滑鼠。")?;
        let handle = unsafe {
            CreateFileW(
                found.path.as_ptr(),
                0,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                std::ptr::null_mut(),
                OPEN_EXISTING,
                0,
                0,
            )
        };
        if handle == 0 || handle == INVALID_HANDLE {
            return Err(format!("原廠介面開啟失敗 ({})", unsafe { GetLastError() }));
        }
        let mut channel = Self {
            handle,
            feature_len: found.feature_len,
            relay_target: RELAY_MOUSE as i32,
            battery: -1,
            product: found.product,
        };
        for target in [RELAY_MOUSE as i32, -1] {
            channel.relay_target = target;
            if channel.read().is_some() {
                return Ok(channel);
            }
        }
        channel.relay_target = RELAY_MOUSE as i32;
        Ok(channel)
    }

    /// Receiver status byte 4 is 1 when the mouse radio is offline or asleep.
    pub fn asleep(&mut self) -> bool {
        self.status().is_some_and(|st| st[4] == 1)
    }

    pub fn read(&mut self) -> Option<Reading> {
        let mut cmd = [0u8; 64];
        cmd[0] = DPI_GET;
        let reply = self.exchange(&cmd)?;
        let mut reading = decode_dpi(&reply)?;
        reading.battery = self.battery;
        reading.product = self.product.clone();
        reading.relay = self.relay_target >= 0;
        Some(reading)
    }

    pub fn set_active(&mut self, index: usize, values: &[u32]) -> bool {
        if index >= values.len() || values.len() > 16 {
            return false;
        }
        let mut cmd = [0u8; 64];
        cmd[0] = DPI_SET;
        cmd[2] = index as u8;
        cmd[3] = values.len() as u8;
        for (i, value) in values.iter().enumerate() {
            let lo = (*value & 0xFF) as u8;
            let hi = ((*value >> 8) & 0xFF) as u8;
            cmd[8 + i * 2] = lo;
            cmd[9 + i * 2] = hi;
            cmd[24 + i * 2] = lo;
            cmd[25 + i * 2] = hi;
        }
        match self.exchange(&cmd) {
            Some(reply) => reply[0] == DPI_SET,
            None => false,
        }
    }

    fn exchange(&mut self, cmd: &[u8; 64]) -> Option<[u8; 64]> {
        if self.relay_target < 0 {
            self.set_feature(cmd)?;
            return self.get_feature();
        }
        let mut last = None;
        for _ in 0..2 {
            for _ in 0..12 {
                let st = self.status();
                if st.is_some_and(|s| s.len() > 5 && s[5] == 1) {
                    break;
                }
                unsafe { Sleep(15) };
            }
            let mut sel = [0u8; 64];
            sel[0] = 0xF6;
            sel[1] = self.relay_target as u8;
            self.set_feature(&sel)?;
            self.set_feature(cmd)?;
            for _ in 0..12 {
                unsafe { Sleep(20) };
                if self.status().is_some_and(|s| s[0] == 1) {
                    break;
                }
            }
            let mut rel = [0u8; 64];
            rel[0] = 0xFC;
            self.set_feature(&rel)?;
            let reply = self.get_feature()?;
            if reply[0] == cmd[0] {
                return Some(reply);
            }
            last = Some(reply);
            unsafe { Sleep(30) };
        }
        last
    }

    fn status(&mut self) -> Option<[u8; 64]> {
        let mut pkt = [0u8; 64];
        pkt[0] = 0xF7;
        self.set_feature(&pkt)?;
        let reply = self.get_feature()?;
        if reply[4] == 0 && (1..=100).contains(&reply[2]) {
            self.battery = reply[2] as i32;
        }
        Some(reply)
    }

    fn set_feature(&self, packet: &[u8; 64]) -> Option<()> {
        let mut buf = [0u8; 65];
        buf[1..].copy_from_slice(packet);
        let sum = buf[1..8].iter().fold(0u8, |acc, b| acc.wrapping_add(*b));
        buf[8] = 0xFFu8.wrapping_sub(sum);
        let ok = unsafe { HidD_SetFeature(self.handle, buf.as_mut_ptr(), self.feature_len) };
        if ok == 0 { None } else { Some(()) }
    }

    fn get_feature(&self) -> Option<[u8; 64]> {
        let mut buf = [0u8; 65];
        let ok = unsafe { HidD_GetFeature(self.handle, buf.as_mut_ptr(), self.feature_len) };
        if ok == 0 {
            return None;
        }
        let mut out = [0u8; 64];
        out.copy_from_slice(&buf[1..65]);
        Some(out)
    }
}

impl Drop for Channel {
    fn drop(&mut self) {
        if self.handle != 0 && self.handle != INVALID_HANDLE {
            unsafe { CloseHandle(self.handle) };
            self.handle = 0;
        }
    }
}

pub fn decode_dpi(reply: &[u8; 64]) -> Option<Reading> {
    if reply[0] != DPI_GET {
        return None;
    }
    let levels = reply[3] as usize;
    let active = reply[2] as usize;
    if !(1..=16).contains(&levels) || active >= levels {
        return None;
    }
    let mut values = Vec::with_capacity(levels);
    for i in 0..levels {
        let value = u32::from(reply[8 + i * 2]) | (u32::from(reply[9 + i * 2]) << 8);
        if !(100..=30_000).contains(&value) {
            return None;
        }
        if values.last().is_some_and(|prev| value <= *prev) {
            return None;
        }
        values.push(value);
    }
    let dpi = values[active];
    Some(Reading {
        levels,
        active,
        values,
        dpi,
        battery: -1,
        product: String::new(),
        relay: true,
    })
}

struct Found {
    path: Vec<u16>,
    feature_len: u32,
    product: String,
}

fn find_vendor() -> Option<Found> {
    unsafe {
        let info = SetupDiGetClassDevsW(
            &HID_GUID,
            std::ptr::null(),
            0,
            DIGCF_PRESENT | DIGCF_DEVICEINTERFACE,
        );
        if info == 0 || info == INVALID_HANDLE {
            return None;
        }
        let mut index = 0u32;
        let mut found = None;
        loop {
            let mut data = SpDeviceInterfaceData {
                cb_size: std::mem::size_of::<SpDeviceInterfaceData>() as u32,
                interface_class_guid: HID_GUID,
                flags: 0,
                reserved: 0,
            };
            if SetupDiEnumDeviceInterfaces(info, std::ptr::null_mut(), &HID_GUID, index, &mut data) == 0 {
                break;
            }
            index += 1;
            let mut needed = 0u32;
            SetupDiGetDeviceInterfaceDetailW(
                info,
                &data,
                std::ptr::null_mut(),
                0,
                &mut needed,
                std::ptr::null_mut(),
            );
            if needed < 8 {
                continue;
            }
            let mut buf = vec![0u8; needed as usize];
            buf[0] = 8;
            if SetupDiGetDeviceInterfaceDetailW(
                info,
                &data,
                buf.as_mut_ptr().cast(),
                needed,
                &mut needed,
                std::ptr::null_mut(),
            ) == 0
            {
                continue;
            }
            let path = wide_from_offset(&buf, 4);
            if let Some(hit) = inspect(&path) {
                found = Some(hit);
                break;
            }
        }
        SetupDiDestroyDeviceInfoList(info);
        found
    }
}

fn wide_from_offset(buf: &[u8], offset: usize) -> Vec<u16> {
    let mut out = Vec::new();
    let mut i = offset;
    while i + 1 < buf.len() {
        let unit = u16::from_le_bytes([buf[i], buf[i + 1]]);
        out.push(unit);
        if unit == 0 {
            break;
        }
        i += 2;
    }
    if out.last().copied() != Some(0) {
        out.push(0);
    }
    out
}

fn inspect(path: &[u16]) -> Option<Found> {
    unsafe {
        let handle = CreateFileW(
            path.as_ptr(),
            0,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            std::ptr::null_mut(),
            OPEN_EXISTING,
            0,
            0,
        );
        if handle == 0 || handle == INVALID_HANDLE {
            return None;
        }
        let mut attrs = HiddAttributes {
            size: std::mem::size_of::<HiddAttributes>() as u32,
            vendor_id: 0,
            product_id: 0,
            version_number: 0,
        };
        if HidD_GetAttributes(handle, &mut attrs) == 0 {
            CloseHandle(handle);
            return None;
        }
        let mut preparsed = std::ptr::null_mut();
        if HidD_GetPreparsedData(handle, &mut preparsed) == 0 {
            CloseHandle(handle);
            return None;
        }
        let mut caps = std::mem::zeroed::<HidpCaps>();
        let status = HidP_GetCaps(preparsed, &mut caps);
        HidD_FreePreparsedData(preparsed);
        let mut name = [0u16; 128];
        HidD_GetProductString(handle, name.as_mut_ptr(), (name.len() * 2) as u32);
        CloseHandle(handle);
        if status != HIDP_STATUS_SUCCESS {
            return None;
        }
        if attrs.vendor_id == VID
            && attrs.product_id == PID_DONGLE
            && caps.usage_page == USAGE_PAGE
            && caps.usage == USAGE
            && caps.feature_report_byte_length >= 65
        {
            Some(Found {
                path: path.to_vec(),
                feature_len: u32::from(caps.feature_report_byte_length),
                product: from_wide(&name),
            })
        } else {
            None
        }
    }
}

pub fn format_reading(reading: &Reading) -> String {
    let mode = if reading.relay { "接收器中繼" } else { "直接" };
    let battery = if reading.battery >= 0 {
        format!("{}%", reading.battery)
    } else {
        "未知".into()
    };
    let table = reading
        .values
        .iter()
        .map(|v| v.to_string())
        .collect::<Vec<_>>()
        .join("  ");
    format!(
        "已連上 {} 3151:4027（{}）\n電量 {battery}  |  第 {}/{} 段  |  {} DPI\n表：{table}",
        if reading.product.is_empty() { "HP Professor 1" } else { &reading.product },
        mode,
        reading.active + 1,
        reading.levels,
        reading.dpi,
    )
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LinkMode {
    Offline = 0,
    Asleep = 1,
    Dongle = 2,
    Bluetooth = 3,
}

impl LinkMode {
    pub fn label(self) -> &'static str {
        crate::lang::link(self)
    }
}

pub fn reading_for_step(step: usize, table: &[u32], battery: i32) -> Option<Reading> {
    let values = if table.len() == 7 { table.to_vec() } else { FACTORY.to_vec() };
    if step >= values.len() {
        return None;
    }
    Some(Reading {
        levels: values.len(),
        active: step,
        dpi: values[step],
        values,
        battery,
        product: "HP Professor 1".into(),
        relay: false,
    })
}

/// Bluetooth mouse is a separate HID device. It only notifies; it does not accept writes.
pub fn bluetooth_present() -> bool {
    unsafe {
        let info = SetupDiGetClassDevsW(&HID_GUID, std::ptr::null(), 0, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if info == 0 || info == INVALID_HANDLE {
            return false;
        }
        let mut index = 0u32;
        let mut found = false;
        loop {
            let mut data = SpDeviceInterfaceData {
                cb_size: std::mem::size_of::<SpDeviceInterfaceData>() as u32,
                interface_class_guid: HID_GUID,
                flags: 0,
                reserved: 0,
            };
            if SetupDiEnumDeviceInterfaces(info, std::ptr::null_mut(), &HID_GUID, index, &mut data) == 0 {
                break;
            }
            index += 1;
            let mut needed = 0u32;
            SetupDiGetDeviceInterfaceDetailW(info, &data, std::ptr::null_mut(), 0, &mut needed, std::ptr::null_mut());
            if needed < 8 {
                continue;
            }
            let mut buf = vec![0u8; needed as usize];
            buf[0] = 8;
            if SetupDiGetDeviceInterfaceDetailW(info, &data, buf.as_mut_ptr().cast(), needed, &mut needed, std::ptr::null_mut()) == 0 {
                continue;
            }
            let path = wide_from_offset(&buf, 4);
            let handle = CreateFileW(path.as_ptr(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE, std::ptr::null_mut(), OPEN_EXISTING, 0, 0);
            if handle == 0 || handle == INVALID_HANDLE {
                continue;
            }
            let mut attrs = HiddAttributes {
                size: std::mem::size_of::<HiddAttributes>() as u32,
                vendor_id: 0,
                product_id: 0,
                version_number: 0,
            };
            let ok = HidD_GetAttributes(handle, &mut attrs);
            CloseHandle(handle);
            if ok != 0 && attrs.vendor_id == VID && attrs.product_id == PID_BLE {
                found = true;
                break;
            }
        }
        SetupDiDestroyDeviceInfoList(info);
        found
    }
}

pub fn read_once() -> Result<String, String> {
    let mut channel = Channel::connect()?;
    if let Some(reading) = channel.read() {
        return Ok(format_reading(&reading));
    }
    if channel.asleep() {
        return Err("接收器在，滑鼠睡著了或切到藍牙。動一下滑鼠，並確認底部是 2.4G。".into());
    }
    Err("DPI 表讀取失敗".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_factory_table() {
        let mut reply = [0u8; 64];
        reply[0] = DPI_GET;
        reply[2] = 4;
        reply[3] = 7;
        let vals = [0x0320u16, 0x03E8, 0x04B0, 0x0640, 0x0960, 0x0C80, 0x0FA0];
        for (i, value) in vals.iter().enumerate() {
            reply[8 + i * 2] = (value & 0xFF) as u8;
            reply[9 + i * 2] = (value >> 8) as u8;
        }
        let reading = decode_dpi(&reply).unwrap();
        assert_eq!(reading.active, 4);
        assert_eq!(reading.dpi, 2400);
        assert_eq!(reading.values, vec![800, 1000, 1200, 1600, 2400, 3200, 4000]);
    }

    #[test]
    fn rejects_echo_mismatch() {
        let mut reply = [0u8; 64];
        reply[0] = 0x00;
        assert!(decode_dpi(&reply).is_none());
    }
}
