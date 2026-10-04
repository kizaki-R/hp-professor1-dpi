# DPI Peek：专为 HP Professor 1 打造的 macOS DPI 显示与控制工具

[English](README.md) | [繁體中文](README.zh-TW.md) | **简体中文**

---

**仅支持 HP Professor 1**（`3151:4027` 2.4G 接收器、`3151:4028` 蓝牙）。其他鼠标请运行 `./royuan auto` 查看探测结果，详见下方的“支持设备”。

> 按下鼠标的 DPI 键，屏幕顶部即时显示当前档位与真实 DPI 数值。
> 在 2.4G 模式下，亦可直接在菜单栏面板上点击按钮切换 DPI。
> 数值直接从鼠标原厂 feature 通道读出，无需估算或推测。

---

## 为什么需要此工具

DPI 是光学传感器的硬件采样分辨率。操作系统底层通常仅接收相对位移计数值（counts），macOS 原生无法感知鼠标当前确切的硬件 DPI。该鼠标未提供 macOS 官方驱动，切换档位时屏幕上没有任何视觉提示。

本项目通过逆向工程解构了鼠标内置的两条原厂通信通道：

| 模式 | 通道 | 特性与功能 |
|---|---|---|
| **2.4G 接收器 / 有线** | usage page `0xFFFF` / usage `0x0002`、64-byte feature report | **完整原厂 API**：通过 `0xD4` 指令读取原厂 DPI 表；通过 `0x54` 指令**支持由软件点击直接修改传感器 DPI**。 |
| **蓝牙 BLE** | usage page `0xFF55` / usage `0x0202`、Report ID 6、65 bytes | **硬件即时通知**：每次按下物理 DPI 键发送 `66 0C <档位>`；固件为单向广播，由实体按键触发。 |

出厂预设的 7 档真实 DPI 数值：

| 档位 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|
| **DPI** | **800** | **1000** | **1200** | **1600** | **2400** | **3200** | **4000** |

协议技术细节（包括校验码算法、接收器中继握手、opcode 对照表与数据包格式）请参阅 [docs/VENDOR-API.md](docs/VENDOR-API.md)。

---

## 主要功能

- **轻量 HUD 提示**：按下 DPI 按键时，屏幕顶部出现半透明悬浮框（如 `3200 DPI　第 6 / 7 档`），1.5 秒后平滑淡出，不抢占焦点，不打扰全屏应用与游戏。
- **依附于菜单栏的弹出面板**：
  - 点击菜单栏 `DPI` 图标呼出，点击外部自动收起，支持 `Esc` 快捷关闭与“📌 钉选”固定显示。
  - **点击直切（2.4G 模式）**：在面板上直接点击档位按钮（`800` ~ `4000`），鼠标硬件传感器即时切换至对应速度。
  - **双模式动态识别**：插拔 2.4G 接收器或拨动鼠标底部开关时，面板毫秒级自动切换 `2.4G` 与 `蓝牙` 状态。
- **主题外观切换**：
  - 支持 `💻 自动`（跟随系统）、`☀️ 浅色`、`🌙 深色` 三档切换，采用原生磨砂玻璃材质，对比清晰无白边。
- **低功耗与防休眠优化**：
  - 内置 `NSAppSleepDisabled` 与活动断言（Activity Assertion），彻底解决 macOS App Nap 机制导致后台轮询被冻结的问题。
- **自带开发与诊断 CLI**：
  - `probe`：HID 抓包、描述符解析与移动计数值实测工具。
  - `royuan`：ROYUAN 家族原厂协议交互工具，包含多设备通用自动探测（`./royuan auto`）。

---

## 支持设备

| 设备 | 支持状态 | 说明 |
|---|---|---|
| **HP Professor 1**（`3151:4027` 2.4G、`3151:4028` 蓝牙） | **完整支持** | 已完成实机逆向与验证。 |
| 同家族兼容设备（ROYUAN / Compx 64-byte vendor feature） | 实验性支持 | 运行 `./royuan auto` 探测，若能识别即可读取。 |
| 其他品牌（Logitech HID++、Razer、Sinowealth `258A` 等） | 不支持 | 需针对各自私有协议单独适配，见“拓展支持设备”。 |

*注：本项目仅调用安全读取与切换指令，不执行固件擦除与传感器校准指令（`0xAC`、`0x1C/0x1E`、`0x7F`）。*

---

## 安装方法

### A. 自行编译（推荐）

运行环境需求：macOS 11+ 及 Command Line Tools（终端执行 `xcode-select --install` 即可，无需安装体积庞大的 Xcode）。

```sh
git clone https://github.com/kizaki-R/hp-professor1-dpi.git
cd hp-professor1-dpi
./make-identity.sh      # 创建本机持久化自签名证书（仅需执行一次，后续重新编译无需重复授权）
./build.sh              # 编译 DPIPeek.app、probe 与 royuan
./install.sh            # 安装至 /Applications 并启动
```

安装完成后，打开 **系统设置 → 隐私与安全性 → 输入监控**，勾选并启用 **DPIPeek**。macOS 要求读取底层 HID 数据必须由用户主动授权；授权完成后应用将自动开始监听。

### B. 下载预编译打包程序

1. 前往 [Releases](https://github.com/kizaki-R/hp-professor1-dpi/releases) 页面下载最新发布的 `DPIPeek-*.zip`。
2. 解压后将 `DPIPeek.app` 拖入 `/Applications`（应用程序目录）。
3. 首次启动时，请在应用图标上**单击右键 → 打开**（开源项目未购买商业 Apple Developer 证书公证，直接双击会被系统 Gatekeeper 拦截）。
4. 在系统设置中授予“输入监控”权限即可。

---

## 使用指南

1. **实体按键切换**：按下鼠标滚轮下方的 DPI 键，屏幕顶部实时弹出 HUD 显示当前档位与真实数值。
2. **菜单栏操作**：
   - 左键点击菜单栏 `DPI` 图标：展开／折叠控制面板。
   - 右键点击菜单栏图标：呼出快速菜单（测试 HUD、切换外观主题、打开系统设置、退出）。
3. **软件点击直切**：
   - 处于 2.4G 接收器模式时，点击面板档位按钮（`800` ~ `4000`）可直接控制传感器切换速度。
   - 处于蓝牙模式时，点击将提示使用实体按键（蓝牙固件机制为单向通知）。
4. **开机自启**：如需开机后台运行，前往 **系统设置 → 通用 → 登录项** 添加 `DPIPeek` 即可。

---

## 开发与代码结构

```text
src/HIDWatcher.{h,m}    底层 HID 监听、热插拔事件处理、BLE 通知解析
src/DPIMapper.{h,m}     档位与 DPI 映射表管理、HUD 文本格式化
src/VendorChannel.{h,m} 原厂 feature 通道通信：中继握手、0xD4 读取、0x54 切换、插拔感知
src/DPIPeek.m           菜单栏 Popover 面板、HUD 悬浮框、主题渲染、单元测试
src/probe.m             HID 诊断 CLI：描述符解析、实时抓包、测速工具
src/royuan.m            ROYUAN 协议 CLI：通用设备探测、寄存器读写
build.sh                编译、打包 Bundle 与代码签名
make-identity.sh        创建本机持久签名身份（保留 TCC 输入监控权限）
make-release.sh         打包发布用 Zip 与源代码归档
```

验证指令：

```sh
./DPIPeek.app/Contents/MacOS/DPIPeek --selftest   # 运行 12 项单元测试
./royuan auto                                     # 通用设备探测
./royuan status                                   # 读取 2.4G 接收器与鼠标连接状态、电量
./probe list                                      # 查看 HID Report Descriptor
```

---

## 常见问题（FAQ）

| 问题 | 解决方法 |
|---|---|
| 权限显示“被拒绝” | 进入系统设置 → 隐私与安全性 → 输入监控，勾选 DPIPeek；如列表中存在失效旧项，可选中后点击 `-` 移除再重新添加。 |
| 切换为蓝牙后为什么无法点击切换 DPI？ | 鼠标蓝牙固件采用单向广播机制，不支持主机下发写指令。如需软件直切，请使用 2.4G USB 接收器。 |
| 重新编译后权限丢失 | 请先运行 `./make-identity.sh` 创建本机固定签名身份，后续编译将复用该证书，无需重复授予权限。 |
| 界面提示“2.4G 原厂通道未连接” | 鼠标若处于蓝牙模式，或长时间未移动进入低功耗休眠，原厂通道会短暂离线；移动唤醒鼠标或插入 2.4G 接收器即可恢复。 |

---

## 致谢

- ROYUAN 家族通信特征（`0xFFFF` usage page、校验码位置、`GET = SET | 0x80`、接收器中继交互）参考了 [sharkfin](https://github.com/dniminenn/sharkfin) 的开源逆向笔记，并在实际设备上完成了比对与功能验证。

---

## 许可证

[MIT License](LICENSE) © KizakiWorks
