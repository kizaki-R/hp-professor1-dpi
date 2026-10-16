# HP Professor 1 DPI（Windows）

HP Professor 1 的常駐 DPI 顯示器。2.4G 接收器插著、滑鼠撥到 2.4G 就能用。數字從原廠通道讀出來，不是猜的。

## 下載後

1. 雙擊 `HP-Professor-1-DPI-windows.exe`。
2. 第一次會裝到 `%LOCALAPPDATA%\HP Professor 1 DPI\`，並加入這個使用者的開機啟動。不需要系統管理員。舊版裝過 `%LOCALAPPDATA%\DPIPeek\` 的話，這裡會把它清掉。
3. 工作列出現 VELOCITY 的七條斜線圖示，顏色跟著現在的段數跑。Windows 有時會先把它收進 `^`，可以拖到工作列上。

之後登入 Windows 會自己打開。

右鍵圖示可以取消「開機時啟動」，或結束程式。把 `%LOCALAPPDATA%\HP Professor 1 DPI` 刪掉就是移除。

藍牙模式讀不到原廠表，也不能用軟體切段。要看數字、要點面板切換，用 2.4G。

## 改圖示

`src/logo_icons.rs` 和 `assets/AppIcon.ico` 都是產生的，不要手改。改完 `gen_icons.py` 後跑：

```
python gen_icons.py
cargo build --release
```

幾何寫在 `gen_icons.py` 和 `src/paint.rs` 兩邊，值要一致——HUD 是用 GDI+ 畫的，不是貼圖。兩邊都抄自 VELOCITY 的 SVG：間距 44、線寬 29、斜率 0.24。

## 出發布檔

`cargo build` 的產物沒有資源區段，資料夾裡會是空圖示、內容也沒版本號。發布前補上：

```
python stamp_resources.py target/release/hp-professor-1-dpi.exe HP-Professor-1-DPI-windows.exe
```

它用 Windows SDK 的 `rc.exe` 編 `assets/app.rc`，把圖示和版本資訊接成 `.rsrc` 區段。`.res` 的格式和映像檔要的三層目錄不一樣，所以目錄是在這支腳本裡組的。SDK 標頭檔沒裝也能跑——`app.rc` 不 include `windows.h`。

找不到 `rc.exe` 時腳本會原樣複製並回傳 2，所以平常的 `cargo build` 不依賴 SDK。
