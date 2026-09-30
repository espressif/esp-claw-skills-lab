# Tetris Clock

用落下的俄罗斯方块拼出当前时间。

从设备 Launcher 启动。显示屏；需设备系统时间正确。退出可使用设备 Launcher 的返回操作。

配置写在 `launcher.json.args`，默认无需修改。`twenty_four_hour`、`leading_zero`、`show_date` 控制格式，`color_scheme` 选择主题，`frame_rate` 控制帧率，`duration_ms = 0` 持续显示。

已开放浏览器模拟入口；音频和传感器效果以真机为准，本次 API 迁移尚未运行验证。
