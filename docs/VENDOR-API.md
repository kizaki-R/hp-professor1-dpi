# HP Professor 1 / ROYUAN 原廠協定（逆向結果）

本文件記錄在這台機器上實際逆向出來的**原廠 API**，以及可重現的驗證方式。
所有標記 `[HW]` 的內容都是在這顆滑鼠（`3151:4028` 藍牙 / `3151:4027` 2.4G 接收器）上實測得到的。

---

## 1. 兩種連線、兩條通道

| 模式 | USB ID | 通道 | 能拿到什麼 |
|---|---|---|---|
| 藍牙 BLE | `3151:4028` | HID Report ID 6、usage page `0xFF55`/usage `0x0202`、65 bytes input+output | **只有段數通知**（`66 0C NN`），裝置不接受主機命令 |
| 2.4G 接收器 / 有線 | `3151:4027` | **Feature report 64 bytes、report ID 0、usage page `0xFFFF`/usage `0x0002`** | **完整原廠 API**：可讀 DPI 表、電量、參數 |

藍牙模式沒有 feature report（`IOHIDDeviceGetReport` 一律回 `kIOReturnUnsupported`），
所以「讀取原廠數值」只能在 2.4G / 有線模式做。

### 藍牙通知封包（Report ID 6）

```
66 0C <段數> 00 …     每按一次 DPI 鍵送一個；<段數> = 0…6
66 0F 01|00 00 …      緊接其後的狀態旗標，可忽略
```

藍牙模式掃過 48 個 opcode（兩輪）都沒有任何回應，交替送 `66 0C 00`/`66 0C 06` 也無法改變 DPI，
因此判定藍牙這條 pipe 實務上是**單向**的。

## 2. 原廠 feature 通道（2.4G / 有線）

```
06 FF FF 09 02 A1 01 09 02 15 80 25 7F 95 40 75 08 B1 02 C0
Usage Page 0xFFFF, Usage 0x02, Collection(Application)
  Usage 0x02, Logical Min -128, Logical Max 127, Report Count 64, Report Size 8, Feature(Data,Var,Abs)
```

- 64 bytes，**無 report ID**（`IOHIDDeviceSetReport/GetReport` 用 reportID = 0）
- 傳送：`IOHIDDeviceSetReport(type=Feature, id=0, buf, 64)`
- 讀回：`IOHIDDeviceGetReport(type=Feature, id=0, buf, 64)`

### 封包格式（與 ROYUAN 鍵盤家族相同）

```
byte 0      : opcode
byte 1..6   : 參數
byte 7      : checksum = 0xFF - (sum of bytes 0..6) & 0xFF
byte 8..63  : 資料
```

- **GET = SET | 0x80**，而且成功的回覆**會回音 opcode 在 byte 0**
- 未支援的命令不會報錯，而是**回上一個回覆**（判斷是否支援要看 byte 0 是否等於送出的 opcode）

### 2.4G 接收器的中繼握手

接收器自己會回應 `0xF7`/`0xF6`/`0xFC` 等 opcode，其他 opcode 會中繼給被選定的裝置：

| 步驟 | 動作 |
|---|---|
| 1 | 送 `0xF7`（狀態）並讀回 |
| 2 | 送 `0xF6 05` → 選定滑鼠（target 5） |
| 3 | 送要中繼的命令（例如 `0xD4`） |
| 4 | 每 20~25 ms 讀一次 `0xF7`，直到 `byte0 == 1`（有回覆待取） |
| 5 | 送 `0xFC`（釋放） |
| 6 | 讀 feature report → 這就是滑鼠的回覆 |

`0xF7` 狀態封包在本機的實測：

```
00 00 58 01 00 00 02 …    [2]=0x58=88 → 滑鼠電量 88%
                          [4]=0 滑鼠在線（1 = 離線）
                          [6]=2 目前目標 = 滑鼠
```

## 3. 找到的 opcode

掃描範圍 `0x80–0xFF`（GET 形態，跳過文件標示為 flash erase 的 `0xAC`）後，**有實質資料**的：

| opcode | 內容 | 回覆 |
|---|---|---|
| `0x80` | 韌體版本 | `80 07 01 …` → `(reply[2]<<8)\|reply[1]` = `0x0107` |
| `0x8F` | identify | `8F 3C 06 00 00 05 00 70 …` → 裝置 ID `0x0000063C` = 1596 |
| `0x86` | 參數（bitfield） | `86 03 03 04 00 FF FF FF …` |
| `0x87` | LED 參數 | `87 01 00 00 00 FF FF FF …` |
| **`0xD4`** | **DPI 表 + 目前段數** | 見下節 |
| `0xD3` | 裝置設定（按鍵/燈效等） | 大 blob，尚未逐一解讀 |
| 其餘 `0x81–0xFF` | 存在但回全零（空欄位） | `xx 00 00 …` |

> 註：家族文件（ROYUAN 鍵盤）裡的 `0x1C`/`0x1E`（感測器校正）、`0x2C`/`0xAC`（flash/顯示器抹除）、
> `0x7F`（進入 bootloader，需 `55 AA 55 AA` 尾碼）屬於**破壞性**命令，本專案一律不送。

## 4. DPI 表：`0xD4`

實測回覆（本機滑鼠）：

```
D4 00 04 07 00 00 00 2B │ 20 03 E8 03 B0 04 40 06 60 09 80 0C A0 0F 00 00 │ (整組再重複一次)
   │  │  │  └ checksum
   │  │  └ [3] = 7      = 段數
   │  └ [2] = 4         = 目前段數（0 起算，所以是第 5 段）
   └ [0] = 0xD4 回音
```

byte 8 之後是 **7 個 u16 小端**的 DPI 值，接著同樣 7 個再重複一次（兩組 profile）：

| 段 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|
| DPI | **800** | **1000** | **1200** | **1600** | **2400** | **3200** | **4000** |
| u16 | 0x0320 | 0x03E8 | 0x04B0 | 0x0640 | 0x0960 | 0x0C80 | 0x0FA0 |

`[2]` 會**即時跟著 DPI 鍵變動**（實測連續按 10 次：4→5→6→0→1→2→3→4→5→6），
也就是這就是「目前 DPI」的讀取方式，不需要任何猜測或實測換算。

## 5. 通用化：自動偵測（`royuan auto`）

```sh
./royuan auto          # 枚舉所有 HID 裝置 → 找候選原廠通道 → 確認家族 → 讀 DPI 表
./royuan auto --wide   # 再加掃 0x80–0xFF（風險較高）
```

流程（不綁特定裝置）：

1. 枚舉所有 HID 裝置，挑出 `MaxFeatureReportSize >= 32` 或含 vendor usage page（>= 0xFF00）者。
2. 對每個候選：先試**直接**送 `0x8F` identify；沒回音就依序試**接收器中繼** target 5 / 10 / 13 / 2 / 1 / 0。
3. 只有 identify 有回音（家族確認）才繼續，避免對陌生裝置亂送命令。
4. 讀 `0xD4` 並同時用**通用啟發式**（在 offset 4–40 找 ≥4 個 100–30000 的嚴格遞增 u16）找 DPI 表。

本機實測輸出：

```
── 2.4G Wireless Mouse  3151:4027  feature=64  page=0xFFFF
    ✔ 家族確認（接收器中繼，target=5）
    identify: 8F 3C 06 00 00 05 00 70 00 00 00 00
    韌體版本: 0x0107
    op 0xD4: D4 00 06 07 …   → 段數 7，目前第 7 段，數值：800 1000 1200 1600 2400 3200 4000
── Gaming Keyboard  258A:01AF  feature=1032  page=0x0001
    identify(0x8F) 無回應 → 不屬於此協定家族
```

也就是說：**同一家族的無線滑鼠可以自動通用**；不同家族需要各自的 opcode 表（本工具可當探測起點）。

## 6. 驗證指令

```sh
./royuan status      # 讀接收器狀態（含滑鼠電量）
./royuan id          # 中繼 identify，確認通道
./royuan probe D4    # 讀 DPI 表（完整 64 bytes）
./royuan watchdpi 60 # 每 0.3 秒讀一次，段數變動時印出 → 按 DPI 鍵即可看到
./royuan raw 66 0C 00        # 送自訂封包（byte 7 自動補 checksum）
./royuan raw 66 0C 00 --nock # 不補 checksum
```

實測輸出（按 DPI 鍵 10 次）：

```
levels=7  active index=4  ->  2400 DPI   (table: 800 1000 1200 1600 2400 3200 4000)
levels=7  active index=5  ->  3200 DPI   ...
levels=7  active index=6  ->  4000 DPI   ...
levels=7  active index=0  ->  800 DPI    ...
```

## 7. App 如何使用

- **2.4G / 有線模式**：`VendorChannel` 每 0.6 秒做一次上述握手 + `0xD4`，
  段數一變就跳 HUD，並把讀到的表寫進 DPI 段數欄位（`DPIPeek.presets.v2`）。
- **藍牙模式**：沿用 `66 0C NN` 通知取得段數，再對照同一張表顯示真實 DPI。
- 兩條通道可以同時開著：滑鼠同時只會連一種模式，所以不會重複觸發。

## 8. 實作踩到的兩個坑（給後續開發者）

1. **`IOHIDManagerClose` 會讓它產生的 `IOHIDDevice` handle 失效**——即使你 `CFRetain` 了 device。
   症狀：偵測階段讀得到 DPI，回傳通道物件後再讀就全部失敗。
   修法：manager 要一直留著（本專案存在 `gKeptManagers`）。
2. **接收器中繼需要前置等待**：送命令前要先輪詢 `0xF7` 直到 `[5]==1`（「可以中繼」），
   送完後輪詢到 `[0]==1`，再 `0xFC` 釋放。少了前置等待時，連續交換會間歇性失敗。
   另外每次交換之間留 ~30 ms 餘裕，失敗時重試一次。

## 9. 已知限制

- 只驗證過這顆滑鼠的接收器 `3151:4027`；接收器 opcode 與 target id 在這家族中可能不同（文件記載鍵盤為 10、滑鼠為 5、兩者為 13）。
- `0xD3` 這個大 blob 尚未解讀（按鍵/燈效/回報率等）。
- 寫入類 opcode（`0xD4` 的 SET 形態 `0x54` 等）**未經測試**，要改 DPI 值請自行承擔風險。
