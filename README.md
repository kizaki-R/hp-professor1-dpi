# DPI Peek：HP Professor 1 專用的 macOS DPI 顯示器

**只支援 HP Professor 1**（`3151:4027` 2.4G、`3151:4028` 藍牙）。其他滑鼠請先跑 `./royuan auto` 看偵測結果，細節見下面的「支援裝置」。

> 按下滑鼠的 DPI 鍵，螢幕上就顯示現在是哪一段、真實數值是多少。
> 數值直接從滑鼠的原廠 feature 通道讀出來，不是猜的。

**English**: a menu-bar app for macOS that shows the mouse's real DPI whenever you press the DPI
button. Built for the HP Professor 1 (`3151:4027` receiver, `3151:4028` Bluetooth); its DPI table
comes from the vendor HID channel (opcode `0xD4`). MIT licensed.

---

## 為什麼需要這個

DPI 是感測器的解析度，作業系統只收到「移動了幾個 count」，所以 macOS 不可能知道你的 DPI 是多少。這顆滑鼠也沒有 macOS 軟體，切換時畫面上沒有任何提示。

它的 HID 裡有兩條原廠通道，兩條都逆向出來了：

| 模式 | 通道 | 內容 |
|---|---|---|
| 藍牙 | usage page `0xFF55` / usage `0x0202`、Report ID 6、65 bytes | 每按一次 DPI 鍵送 `66 0C <段數>`；只有段數，也不接受主機命令 |
| 2.4G 接收器 / 有線 | usage page `0xFFFF` / usage `0x0002`、64 bytes feature report | 完整原廠 API，`0xD4` 直接讀出 DPI 表 |

`0xD4` 讀出來的就是原廠設定值：

| 段 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|
| DPI | 800 | 1000 | 1200 | 1600 | 2400 | 3200 | 4000 |

協定細節（checksum、接收器中繼握手、opcode 表、封包格式，還有開發時踩到的坑）寫在 [docs/VENDOR-API.md](docs/VENDOR-API.md)。

## 功能

- 按 DPI 鍵，螢幕上方出現 HUD：`3200 DPI　第 6 / 7 段`，1.5 秒後淡出，不搶焦點
- 2.4G 與有線模式輪詢原廠 `0xD4`：偵測到變動後 0.15 秒一次、閒置時放慢，讀到的表會自動填進設定
- 藍牙模式改用 `66 0C NN` 通知取段數，再對照同一張表顯示真值；事件驅動，不會漏段
- 滑鼠睡眠或切換模式後每 10 秒自動重連；在背景與全螢幕 Space 都看得到
- 附兩支 CLI：`probe`（HID 擷取與 descriptor）和 `royuan`（原廠協定，含通用自動偵測）

## 支援裝置

| 裝置 | 狀態 |
|---|---|
| HP Professor 1（`3151:4027` 2.4G、`3151:4028` 藍牙） | 已實機驗證 |
| 同家族（ROYUAN / Compx 系 64-byte vendor feature） | 用 `./royuan auto` 自動偵測，抓到就能用 |
| 其他廠牌（Logitech HID++、Razer、Sinowealth `258A` 等） | 不支援；要各自的協定實作，見「新增支援裝置」 |

本專案只送讀取類 opcode，不碰寫入與抹除命令（`0xAC`、`0x1C/0x1E`、`0x7F` 等）。

## 安裝

### A. 自己編譯（建議）

需要 macOS 11+ 與 Command Line Tools（`xcode-select --install`），不用裝 Xcode。

```sh
git clone https://github.com/kizaki-R/hp-professor1-dpi.git
cd hp-professor1-dpi
./make-identity.sh      # 產生本機自簽簽章身分（只需一次，讓權限在重新編譯後仍有效）
./build.sh              # 編譯 DPIPeek.app + probe + royuan
./install.sh            # 複製到 /Applications 並啟動
```

裝好後到系統設定 → 隱私權與安全性 → 輸入監控，把 **DPIPeek** 打開。macOS 要求每個讀 HID 的程式都由使用者自己授權；App 每 2 秒會檢查一次，授權完就自己開始監看。

### B. 下載打包好的 App

到 Releases 下載 `DPIPeek-*.zip`，解壓後把 `DPIPeek.app` 放進 `/Applications`。第一次開啟要按右鍵 → 打開（這個專案沒做 Apple 公證，直接雙擊會被 Gatekeeper 擋下），一樣得到輸入監控授權。

想免掉右鍵這一步，需要 Apple Developer ID 簽章與公證（付費帳號）。自己編譯的路徑沒有隔離屬性，不會遇到這問題。

## 使用

1. 按滑鼠滾輪後方的 DPI 鍵，HUD 顯示目前真實 DPI
2. 選單列 DPI 圖示：顯示主視窗、開始或停止監看、測試 HUD、輸入監控設定、結束
3. 主視窗內可：看即時記錄、手動填 7 段數值、讀取滑鼠 DPI 表、重連原廠通道、送自訂封包

想開機常駐，到系統設定 → 一般 → 登入項目把 DPIPeek 加進去。

## 開發

```
src/HIDWatcher.{h,m}    逐裝置 HID 監聽（BLE 睡眠 / 重連可恢復）、權限、輸出封包
src/DPIMapper.{h,m}     藍牙通知解碼（66 0C NN）+ 7 段 DPI 表
src/VendorChannel.{h,m} 原廠 feature 通道：checksum、接收器中繼、0xD4 DPI 表、背景輪詢
src/DPIPeek.m           選單列 App、HUD、記錄、自我測試
src/probe.m             診斷 CLI：list / watch / watch6 / watchall / watchdev / measure / feature
src/royuan.m            原廠協定 CLI：auto / id / status / get / watchdpi / probe / raw / scan
build.sh                編譯 + 打包 + 簽章
make-identity.sh        建立本機自簽簽章身分（只需跑一次）
make-release.sh         產生可上傳 Releases 的 zip
```

驗證指令：

```sh
./DPIPeek.app/Contents/MacOS/DPIPeek --selftest   # 12 項單元測試
./DPIPeek.app/Contents/MacOS/DPIPeek --scan       # 列出滑鼠 HID 介面
./royuan auto                                     # 通用偵測（換別顆滑鼠先跑這個）
./royuan watchdpi 60                              # 即時監看原廠 DPI 段數
./probe list                                      # 完整 246 bytes report descriptor
```

### 新增支援裝置

1. `./probe list` 取得該裝置的 report descriptor 與 vendor usage page
2. `./royuan auto --wide` 或 `./royuan scan 0x80 0xFF` 找可讀的 opcode。動手前先讀 [docs/VENDOR-API.md](docs/VENDOR-API.md) 的風險段落，跨家族亂掃有可能觸發寫入
3. 把結果寫成 `src/VendorChannel.m` 的常數（`kVID` / `kDPIOpcode` / `kRelayMouse`）與判別邏輯
4. 送 PR 時附上 `--selftest` 結果與原始回覆封包

## 疑難排解

| 症狀 | 處理 |
|---|---|
| 權限顯示「被拒絕」 | 系統設定 → 隱私權與安全性 → 輸入監控 → 打開 DPIPeek；清單有兩列就刪掉舊的 |
| 找不到原廠通道 | 滑鼠要切到 2.4G 或有線模式，藍牙沒有 feature 通道；App 每 10 秒會自動重試 |
| HUD 在背景不見了 | 舊版會被 macOS App Nap 凍結輪詢，已修（`NSAppSleepDisabled` 加 activity assertion） |
| 2.4G 偶爾漏一段 | 輪詢的先天限制；切回藍牙模式是事件驅動，不會漏 |
| 每次重編都要重給權限 | 先跑 `make-identity.sh`，簽章身分固定後就不會 |

## 免責

- 原廠協定是黑箱觀察得來的，只讀取、不寫入；與 HP、ROYUAN 都沒有任何關聯，也沒有使用他們的程式碼或韌體。
- 請只在自己的裝置上使用；跨家族亂掃 opcode 可能在別的裝置觸發寫入。
- 依 MIT 授權按現狀提供，不負任何損害責任。

## 致謝

- ROYUAN 家族協定（`0xFFFF` usage page、checksum 位置、`GET = SET | 0x80`、接收器中繼）與 [sharkfin](https://github.com/dniminenn/sharkfin) 的公開筆記交互比對後，在本裝置上實測確認。

## 授權

[MIT](LICENSE) © KizakiWorks
