# Integrate DPI Peek VELOCITY in the macOS project

Repository: https://github.com/kizaki-R/hp-professor1-dpi

1. Copy 03_macOS_Ready/DPIPeek_dark.icns into your project at src/DPIPeek.icns
2. In src/Info.plist within <dict> add:
       <key>CFBundleIconFile</key>
       <string>DPIPeek.icns</string>
3. In build.sh add BEFORE the codesign step, right after the existing cp Info.plist command:
       cp src/DPIPeek.icns "$APP/Contents/Resources/DPIPeek.icns"
4. Rebuild with ./build.sh then ./install.sh

IMPORTANT: Don't modify the .app bundle after it is signed, since doing so invalidates its signature and can reset macOS input-monitoring consent.

MENU BAR
Use 05_macOS_MenuBar/Menu_Template_Stage_N_18pt@2x.png with NSImage.template=YES for automatic light/dark adaptation.
If you need the cyan active-stage accent, use Menu_dark_Stage_N_18pt@2x.png or Menu_light_Stage_N_18pt@2x.png respectively, and do NOT set template=YES.
Status menu bar icons are designed at 18x13 points (36x26 pixels at 2x).

DPI STAGES
1 = 800
2 = 1000
3 = 1200
4 = 1600
5 = 2400
6 = 3200
7 = 4000
For the status icon: current bar is cyan, all previous bars are light, later bars muted.

ASSET STRUCTURE
01_Vector_SVG: editable vector source (individual shapes; wordmarks use live editable text)
02_PNG_Transparent_and_App: app PNGs, logo mark transparent PNGs and wordmarks
03_macOS_Ready: ready-to-drop ICNS, .iconset and .appiconset
04_DPI_Stages_1_to_7: seven independent stage icon assets for dark/light
05_macOS_MenuBar: menu bar icons for each stage, including template masks
06_Extras: concept boards and optional Windows ICO
VELOCITY_Preview_Production.png: precise preview assembled from delivered files

BRAND COLORS
Deep navy #0B1320
Black blue #111827
White      #F3F7FF
Light gray #B8C1CF
Cyan       #39D5FF

All SVGs are 100% editable geometric vectors. Artwork is intentionally rendered with seven ascending angled bars to match the mouse's seven DPI stages.
