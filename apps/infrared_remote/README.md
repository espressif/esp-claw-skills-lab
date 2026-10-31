# 红外遥控器

红外遥控器是 ESP-Claw 触控屏上的多设备遥控 App。界面采用浅灰底色、白色浮起卡片和按设备类型区分的强调色，按屏幕短边自适应缩放，可铺满 240×240、320×240、480×320 等分辨率。首页保存用户添加的设备，选择设备后进入对应遥控面板；每台设备拥有独立的类型、协议、状态和学习按键。

## 功能

- `Remotes` 首页：以双列卡片显示最多六台设备，卡片包含类型图标、协议品牌和已学习按键数角标；标题栏显示设备数量和红外硬件状态，右上角为设置和添加入口。
- `Add remote`：选择 TV、Air、Media 或 Custom 类型，点击协议栏打开全屏协议列表（品牌、型号、`BETA` 实验标记），未知设备选 Custom 后逐键学习。
- `Air`：左侧温控卡片随运行模式变色，点阵圆环显示温度在协议范围内的位置；右侧为电源、模式、风速和摆风磁贴。全部可调项来自 `remote:capabilities()`，码集没有的字段会自动隐藏；关机时温控卡片变灰并锁定状态调节。只有按键的码集通过 Power、Swing 等按键控制。
- `TV`：音量和频道摇杆、带 OK 键的圆形方向盘，以及电源、输入源和静音，适合电视及机顶盒。
- `Media`：电源、输入、主页、返回、上一项、播放/暂停、下一项、音量和静音，适合播放器及音响。
- `Custom`：九个可重复学习的通用按键，可用于灯具、风扇或其他红外设备。
- 学习：长按任意按键直接学习；或点击标题栏的学习按钮进入学习模式后点击按键，长按该按钮进入删除模式以清除已学习按键。学习期间弹出倒计时面板，可随时取消，界面不会被阻塞；学习成功后提示识别出的协议（例如 `NEC 10:2A`）。已学习按键右上角显示强调色圆点，未配置的按键显示为浅色。
- `IR hardware`：设置发送、接收和使能 GPIO、使能电平及载波频率，修改项高亮，点击右上角确认后立即重新初始化红外硬件。
- 遥控面板右上角的删除按钮会弹出确认框。
- 设备列表、`ir_remote` 快照（协议、按键、空调状态、学习结果）和硬件配置保存到 DATA 分区的 `app_data/infrared_remote.json`。空调状态变化合并后延迟保存，以减少 Flash 写入。

## 协议配置

App 启动时通过 `ir.protocol.list()` 读取内置协议、SYSTEM 的 `ir/protocols.jsonl` 和 DATA 的 `ir/protocols/` JSON 码集：`category` 为 `air_conditioner` 的归入 Air，`tv` 归入 TV，`audio` 归入 Media。没有 `category` 且带 `command` 字段的协议（NEC、Samsung32、Sony、RC5 等）同时出现在 TV 和 Media 列表中，选中后按 `{protocol, fixed = {address}, keys}` 创建 remote。新增码集后无需修改 App。可在 `launcher.json.args` 中配置：

- `ac_protocol`：可选的首选空调码集 ID。
- `tv_protocol`、`media_protocol`：对应设备类别的可选首选码集 ID 或协议 ID。
- `protocol_address`：按键协议使用的设备地址。
- `tv_codes`、`media_codes`：按键名到数值命令码的映射。没有配置命令码时，App 会提示学习该按键。

电视示例配置：

```json
{
  "tv_protocol": "nec",
  "protocol_address": 16,
  "tv_codes": {
    "power": 18,
    "vol_up": 20,
    "vol_down": 21,
    "mute": 22
  }
}
```

命令码依赖具体品牌和型号，必须从设备资料确认；不要直接套用示例值。RC5 的 toggle 由 remote 在每次按键时自动切换。切换空调模式时，remote 会把未修改的温度和风速调整到新模式允许的范围内，例如 `xiaomi.96` 切到除湿时风速自动变为低风。

## 硬件要求

需要至少 240×200 的显示屏和触控输入。App 启动时通过 `board_manager.get_board_info()` 读取板名，并选择对应的默认引脚（载波均为 38 kHz）：

| 板子 | TX | RX | 使能 |
| --- | --- | --- | --- |
| `esp_box_3` | GPIO 39 | GPIO 38 | GPIO 44（低电平有效） |
| `esp_mosaico` | GPIO 47 | NC（不支持学习） | NC |

其他板子沿用 BOX-3 的默认值。可在首页右上角的设置页修改。发送、接收和使能 GPIO 必须互不相同；接收或使能 GPIO 可设为 `NC`（未连接）。应用后 App 会立即按新配置重开红外硬件，初始化失败时自动恢复旧配置。

可在 `launcher.json.args` 中加入 `tx_gpio`、`rx_gpio`、`ctrl_gpio`、`ctrl_active_level` 和 `carrier_hz`，覆盖板子默认值；它们只在首次启动时生效。界面保存的配置会记录所属板名，后续在同一块板子上启动时优先使用；板名不一致时（例如 SD 卡换到另一块板子）会回退到该板子的默认值。请使用合适的红外发射驱动电路，禁止直接用 GPIO 驱动大电流红外 LED。

## 实现

代码按职责拆分：

- `scripts/infrared_remote.lua`：App 生命周期、页面切换、学习流程和主循环。
- `scripts/ir_link.lua`：红外硬件的打开、配置回滚、发送和非阻塞接收（`start_receive` + `read({timeout_ms = 0})`）。
- `scripts/protocol_catalog.lua`：协议发现、显示名称、默认选择、`ir_remote` 配置生成和学习帧识别。
- `scripts/device_manager.lua`：设备列表、remote 恢复、创建/删除回滚和延迟保存。
- `scripts/remote_store.lua`：JSON 快照的原子保存与加载。
- `scripts/ui/`：设计令牌与基础控件（`kit.lua`）、线条图标（`icons.lua`）、提示条/确认框/学习面板/列表选择器（`overlays.lua`）。
- `scripts/pages/`：首页、添加页、设置页、通用遥控页及 TV/Media/Custom 键盘和空调面板。

界面使用原生 `lvgl` 控件和动态 TTF 字体：浮起控件使用主题按钮阴影，面板内按键为扁平按键，图标由折线绘制。`ir` 模块负责编解码和收发，`ir_remote` 库负责按键、空调状态、学习和快照，`storage` 与 `json` 模块负责持久化。关键硬件、编码、学习和存储错误都会写入日志。
