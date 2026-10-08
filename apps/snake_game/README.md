# Snake

薄荷绿小蛇、橙色果实和深色棋盘。顶部显示本局得分与本次运行的最高分；右侧按钮用于暂停／继续和退出。

- 轻触棋盘或滑动开始；游戏中滑动转向，不能直接掉头。
- 暂停后轻触棋盘或继续按钮恢复；结束后轻触或滑动重开。
- 吃到果实后加分并逐渐加速；撞墙或碰到身体结束，填满棋盘获胜。

从设备 Launcher 启动，需要至少 160×160 的触摸屏，扬声器可选。支持浏览器模拟试玩，浏览器中无声。

`launcher.json.args` 可设置 `grid_size`（短边格数，默认 15，范围 12–30）、`target_size`（棋盘最大边长，默认随屏幕铺开）和 `run_time_ms`（运行毫秒数，`0` 持续运行）。格子保持正方形，长边格数随屏幕比例调整。

界面使用当前 `display` API 和 `display.load_font()`。字体按需加载，退出时释放；静止界面不持续重绘。`assets/ui-*.dfn` 是 Lato Bold 的 ASCII 位图字体，许可见 `assets/FONT-LICENSE.txt`。需要重新生成时，在安装 Pillow 的 Python 环境运行：

```sh
python3 apps/snake_game/tools/build_fonts.py /path/to/Lato-Bold.ttf
```
