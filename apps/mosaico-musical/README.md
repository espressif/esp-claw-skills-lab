# Mosaico Musical

点击和弦区选和弦，滑过琴弦弹奏钢弦吉他采样；当前为单设备独奏。

从设备 Launcher 启动。屏幕高度 480、宽度至少 480，触摸输入；音频需要 16 位单声道或双声道输出。退出可使用设备 Launcher 的返回操作。

配置写在 `launcher.json.args`，默认无需修改。采样文件位于 `assets/steel/`，由 Lua 混音器按设备实际采样率重采样。触摸使用屏幕快照，快速划过的中间采样点可能丢失。

已开放浏览器试玩，实际运行效果待验证。

采样来源与许可见 [ATTRIBUTION](assets/ATTRIBUTION.md) 和 [LICENSE](LICENSE)。

浏览器可试玩触摸界面；模拟器没有音频输出时为静音模式。
