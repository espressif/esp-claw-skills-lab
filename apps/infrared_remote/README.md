# 红外遥控器

红外遥控器是为 ESP-Claw 方形触控屏设计的多设备遥控 App，采用暖白底色、浅灰卡片和青绿色强调的简约平面界面。首页保存用户添加的设备，选择设备后才进入对应遥控面板；每台设备拥有独立的类型、协议、状态和学习按键。

## 功能

- `My devices`：显示最多六台已添加设备及其类型、协议和已学习按键数量，点击设备进入遥控面板。
- `Add device`：选择 TV、AIR、MEDIA 或 CUSTOM。已知设备可循环选择固件支持的红外协议，未知设备选择 CUSTOM 后逐键学习。
- `AIR`：通过空调协议发送完整状态帧，控制电源、温度、运行模式和风速；摆风按键支持独立学习。
- `TV`：包含方向、确认、音量、频道、电源、输入源和静音，适合电视及机顶盒。
- `MEDIA`：包含电源、输入、主页、返回、上一项、播放/暂停、下一项、音量和静音，适合播放器及音响。
- `CUSTOM`：提供九个可重复学习的通用按键，可用于灯具、风扇或其他红外设备。
- `PINS`：直接在界面中设置红外发送、接收和使能 GPIO、使能电平及载波频率，应用后立即重新初始化红外硬件。
- 进入已添加设备后，可通过右上角的 `DEL` 按钮二次确认并删除该设备。
- 每台设备独立保存学习结果。点击按键发送指令，长按按键直接学习原遥控器波形；已学习按键使用青绿色显示。
- 设备列表、协议、空调状态、GPIO 配置及学习结果保存到 DATA 分区的 `app_data/infrared_remote.json`。旧版 `airwave_remote.json` 数据会在首次启动时自动迁移。

## 协议配置

默认空调协议是 `gree.capture_v1`，默认消费电子协议是 `nec`。可在 `launcher.json.args` 中修改：

- `ac_protocol`：`midea.capture_v1`、`gree.capture_v1`、`haier.a6_capture_v1` 或 `lg.akb73315611`。
- `consumer_protocol`：固件 `ir` 模块支持的消费电子协议，如 `nec`、`nec.extended`、`samsung32`、`sony12`、`sony15`、`sony20`、`rc5`、`jvc` 或 `bose.wave`。
- `consumer_address`：消费电子协议地址。
- `tv_codes`、`media_codes`：按键名到数值命令码的映射。没有配置命令码时，App 会提示学习该按键。

电视示例配置：

```json
{
  "consumer_protocol": "nec",
  "consumer_address": 16,
  "tv_codes": {
    "power": 18,
    "vol_up": 20,
    "vol_down": 21,
    "mute": 22
  }
}
```

命令码依赖具体品牌和型号，必须从设备资料确认；不要直接套用示例值。

## 硬件要求

需要至少 240×240 的显示屏和触控输入。默认使用 BOX-3 的 TX GPIO 39、RX GPIO 38、控制 GPIO 44 和 38 kHz 载波，可从首页右上角的 `PINS` 页面修改。发送、接收和使能 GPIO 必须互不相同；接收或使能 GPIO 可设为 `OFF`。应用后 App 会立即按新配置重开红外硬件，初始化失败时自动恢复旧配置。

`launcher.json.args` 中的 `tx_gpio`、`rx_gpio`、`ctrl_gpio`、`ctrl_active_level` 和 `carrier_hz` 只提供首次启动默认值；界面保存的配置会在后续启动时优先使用。请使用合适的红外发射驱动电路，禁止直接用 GPIO 驱动大电流红外 LED。

浏览器模拟器缺少真实 IR 硬件时会自动进入演示模式，界面和设备切换仍可使用。

## 实现

界面使用原生 `lvgl` 控件和动态 TTF 字体。`ir` 模块负责协议编码、发送、波形学习和回放，`storage` 与 `json` 模块负责学习结果持久化。关键硬件、编码、学习和存储错误都会写入日志。
