# DPI Peek：HP Professor 1 專用的 macOS DPI 顯示器

[English](README.md) | **繁體中文** | [简体中文](README.zh-CN.md)

---

**只支援 HP Professor 1**（`3151:4027` 2.4G 接收器、`3151:4028` 藍牙）。其他滑鼠請跑 `./royuan auto` 看偵測結果，細節見下面的「支援裝置」。

> 按下滑鼠的 DPI 鍵，螢幕上就顯示現在是哪一段、真實數值是多少。
> 2.4G 模式下，亦可直接在選單列面板上點擊按鈕切換 DPI。
> 數值直接從滑鼠的原廠 feature 通道讀出，不是猜的。

---

## 為什麼需要這個

DPI 是光學感測器的採樣解析度，作業系統底層通常只接收「相對移動量（counts）」，因此 macOS 原生無法得知滑鼠目前確切的 DPI 數值。這顆滑鼠原廠並未提供 macOS 控制軟體，切換時螢幕上毫無提示。

本專案逆向解出了滑鼠內建的兩條原廠通訊通道：

| 模式 | 通道 | 特性與功能 |
|---|---|---|
| **2.4G 接收器 / 有線** | usage page `0xFFFF` / usage `0x0002`、64-byte feature report | **完整原廠 API**：透過 `0xD4` 讀取原廠 DPI 表；透過 `0x54` 指令可**直接由軟體點擊切換感測器 DPI**。 |
| **藍牙 BLE** | usage page `0xFF55` / usage `0x0202`、Report ID 6、65 bytes | **硬體即時通知**：每按一次實體 DPI 鍵送出 `66 0C <段數>`；韌體為單向廣播，由實體鍵觸發。 |

原廠設定的 7 段真實 DPI 數值：

| 段數 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|
| **DPI** | **800** | **1000** | **1200** | **1600** | **2400** | **3200** | **4000** |

協定細節（包含校驗碼演算法、接收器中繼握手、opcode 對照表與封包格式）請參閱 [docs/VENDOR-API.md](docs/VENDOR-API.md)。

---

## 主要功能

- **懸浮 HUD 提示**：按下 DPI 鍵，螢幕上方出現半透明 HUD（如 `3200 DPI　第 6 / 7 段`），1.5 秒後平滑淡出，不搶焦點、不干擾全螢幕應用與遊戲。
- **依附於選單列的彈出面板**：
  - 點擊選單列 `DPI` 圖示展開，點擊外部自動收起，支援 `Esc` 關閉與「📌 釘選」保持開啟。
  - **點擊直切（2.4G 模式）**：在面板上直接點擊段數按鈕（`800` ~ `4000`），滑鼠硬體光學感測器即時切換至對應速度。
  - **雙模式動態辨識**：拔插 2.4G 接收器或撥動滑鼠連線開關時，面板毫秒級自動切換 `2.4G` 與 `藍牙` 狀態。
- **主題外觀切換**：
  - 支援 `💻 自動`（跟隨系統）、`☀️ 淺色`、`🌙 深色` 三段切換，原生磨砂玻璃質感，對比清晰無白邊。
- **低功耗與防休眠最佳化**：
  - 加入 `NSAppSleepDisabled` 與 Process Activity Assertion，解決 macOS App Nap 導致背景輪詢凍結的問題。
- **附帶開發與診斷 CLI**：
  - `probe`：HID 封包擷取、描述元解析與光學尺實測工具。
  - `royuan`：ROYUAN 家族原廠協定測試工具，含多滑鼠通用自動偵測（`./royuan auto`）。

---

## 支援裝置

| 裝置 | 支援狀態 | 說明 |
|---|---|---|
| **HP Professor 1**（`3151:4027` 2.4G、`3151:4028` 藍牙） | **完整支援** | 已完成實機逆向與驗證。 |
| 同家族相容滑鼠（ROYUAN / Compx 64-byte vendor feature） | 實驗性支援 | 跑 `./royuan auto` 偵測，若能辨識即可讀取。 |
| 其他廠牌（Logitech HID++、Razer、Sinowealth `258A` 等） | 不支援 | 需各自協定實作，見「新增支援裝置」。 |

*註：本專案僅使用安全讀取與切換 opcode，不觸碰韌體抹除與感測器校正命令（`0xAC`、`0x1C/0x1E`、`0x7F`）。*

---

## 安裝方式

### A. 自行編譯（推薦）

需求：macOS 11+ 與 Command Line Tools（執行 `xcode-select --install` 即可，不需要下載完整 Xcode）。

```sh
git clone https://github.com/kizaki-R/hp-professor1-dpi.git
cd hp-professor1-dpi
./make-identity.sh      # 建立本機自簽身分（只需執行一次，重新編譯無需重給權限）
./build.sh              # 編譯 DPIPeek.app、probe 與 royuan
./install.sh            # 安裝至 /Applications 並啟動
```

安裝完成後，請前往 **系統設定 → 隱私權與安全性 → 輸入監控**，將 **DPIPeek** 勾選開啟。macOS 規定讀取 HID 資料必須由使用者手動授權；App 授權完成後會自動開始監看。

### B. 下載 Release 打包檔

1. 前往 [Releases](https://github.com/kizaki-R/hp-professor1-dpi/releases) 下載最新的 `DPIPeek-*.zip`。
2. 解壓後將 `DPIPeek.app` 拖入 `/Applications`。
3. 第一次開啟時，請在 App 圖示上**按右鍵 → 打開**（因開源專案未購買 Apple 商業開發者證書公證，直接雙擊會被 Gatekeeper 阻擋）。
4. 至系統設定授予「輸入監控」權限即可。

---

## 使用說明

1. **實體切換**：按下滑鼠滾輪後方的 DPI 鍵，螢幕頂部即時彈出 HUD 顯示段數與數值。
2. **選單列操作**：
   - 左鍵點擊選單列 `DPI` 圖示：展開／收合控制面板。
   - 右鍵點擊選單列圖示：快速選單（測試 HUD、切換主題、開啟設定、結束）。
3. **軟體點擊直切**：
   - 在 2.4G 接收器模式下，點擊段數按鈕（`800` ~ `4000`）可直接控制感測器變更速度。
   - 藍牙模式下點擊會提示使用實體鍵（藍牙韌體為單向通知）。
4. **開機啟動**：若希望開機常駐，至 **系統設定 → 一般 → 登入項目** 加入 `DPIPeek`。

---

## 開發與原始碼結構

```text
src/HIDWatcher.{h,m}    底層 HID 監聽、熱插拔事件處理、BLE 通知解析
src/DPIMapper.{h,m}     段數與 DPI 對照表管理、HUD 文字格式化
src/VendorChannel.{h,m} 原廠 feature 通道通訊：中繼握手、0xD4 讀取、0x54 切換、拔插感應
src/DPIPeek.m           選單列 Popover 面板、HUD 浮動視窗、主題渲染、單元測試
src/probe.m             HID 診斷 CLI：描述元解析、即時封包監看、實測工具
src/royuan.m            ROYUAN 協定 CLI：通用裝置探索、暫存器讀寫
build.sh                編譯、組裝 Bundle 與代碼簽章
make-identity.sh        產生本機持久性簽章身分（保留 TCC 輸入監控授權）
make-release.sh         打包發布用 Zip 與原始碼壓縮檔
```

驗證指令：

```sh
./DPIPeek.app/Contents/MacOS/DPIPeek --selftest   # 執行 12 項單元測試
./royuan auto                                     # 通用裝置探索
./royuan status                                   # 讀取 2.4G 接收器與滑鼠狀態、電量
./probe list                                      # 查看 HID Report Descriptor
```

---

## 常見問題（FAQ）

| 問題 | 解答 |
|---|---|
| 權限顯示「被拒絕」 | 至系統設定 → 隱私權與安全性 → 輸入監控，將 DPIPeek 開啟；若清單內有重複項目，可先選取後按 `-` 移除再重新加入。 |
| 換成藍牙後為什麼不能軟體直切？ | 滑鼠藍牙韌體為單向廣播架構，不接收主機寫入指令。若需要軟體點擊直切，請插上 2.4G USB 接收器。 |
| 重新編譯後權限失效 | 請先執行 `./make-identity.sh` 建立本機固定簽章身分，之後重新編譯皆會沿用同一身分，無需重複授權。 |
| 為什麼畫面上出現「2.4G 原廠通道未連上」？ | 滑鼠若切至藍牙模式，或長時間未使用進入省電休眠，原廠通道會暫時離線；移動喚醒滑鼠或插上 2.4G 接收器即會自動連線。 |

---

## 致謝

- ROYUAN 家族協定特徵（`0xFFFF` usage page、校驗碼位置、`GET = SET | 0x80`、接收器中繼機制）參考自 [sharkfin](https://github.com/dniminenn/sharkfin) 的公開逆向筆記，並於本裝置完成實機比對與驗證。

---

## 授權

[MIT License](LICENSE) © KizakiWorks
