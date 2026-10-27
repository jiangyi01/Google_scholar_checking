# ScholarBar

A macOS menu-bar widget that shows your Google Scholar citation count and tells you which paper just got cited.
（macOS 菜单栏小组件：实时显示 Google Scholar 总引用数，并记录每篇论文的新增引用。）

## 功能

- **菜单栏**：🎓 总引用数，有新引用时显示绿色 `+N`；右键菜单可刷新 / 打开主页 / 设置 / 退出。
- **弹窗面板**：总引用、h-index、i10、近 7 / 30 天增量、按年引用柱状图；
  「最新引用」列出哪篇论文多了几次引用（点击查看最新的施引文献），「全部论文」按引用数排序。
- **通知**：有新引用时推送系统通知。
- **OpenAlex 补位**：Google Scholar 暂时限制自动访问（CAPTCHA / 429）时，自动改用
  [OpenAlex](https://openalex.org) 的开放 API 继续提示新增引用（标注 “OpenAlex”）；
  总引用数始终以 Scholar 为准，Scholar 恢复后同一条引用不会重复提醒。
- **入口**：Dock / 桌面 / 启动台点图标即打开面板（菜单栏图标被刘海挡住时改为独立窗口，开在鼠标所在的屏幕）；可设为登录时自动启动。

## 安装

需要 macOS 14+ 和 Swift 工具链（只装 Command Line Tools 即可，不需要 Xcode）。

```bash
./build_app.sh --run
```

构建后安装到 `~/Applications/ScholarBar.app`（ad-hoc 签名）并启动。首次打开时粘贴自己的
Scholar 个人主页链接（`https://scholar.google.com/citations?user=…`）即可。

可选：在设置里填一个免费的 OpenAlex API key（在 <https://openalex.org/settings/api> 自行申请），
否则与同一网络的其他用户共享 OpenAlex 每日免费额度。key 存在登录钥匙串里。

## 对 Google Scholar 的访问方式

Scholar 没有官方 API，本工具以较低频率读取**公开**的个人主页：

- 默认每 2 小时一次（可选 1–24 小时，±20% 随机间隔），手动刷新至少间隔 5 分钟；
- 凌晨 1–7 点不自动刷新；
- 被要求验证后依次退避 6 / 12 / 24 小时，并在之后一周内自动放慢到每 6 小时一次；
- 每次被拦截都记录在 `~/Library/Application Support/ScholarBar/blocks.log`。

工具不会尝试绕过 Scholar 的验证；受限期间用 OpenAlex 补位。

## 命令行

```bash
.build/release/ScholarBar --check <主页链接或 user ID>   # 抓取一次并打印结果
~/Applications/ScholarBar.app/Contents/MacOS/ScholarBar --login-item on|off|status
```

调试用：`SCHOLARBAR_STATE_DIR=<目录>` 使用临时数据目录；`--snapshot out.png` /
`--snapshot-window out.png` 把面板渲染成图片。

## 数据

全部保存在本机：`~/Library/Application Support/ScholarBar/state.json`（引用快照、新增记录、历史总数）。

## 项目结构

| 文件 | 作用 |
|---|---|
| `ScholarAPI.swift` | 读取并解析 Scholar 个人主页 |
| `OpenAlexAPI.swift` / `OpenAlexKey.swift` | OpenAlex 论文匹配与引用数查询；API key 钥匙串存取 |
| `AppModel.swift` / `Models.swift` | 调度、退避、差异比较、OpenAlex 补位与去重、持久化 |
| `PopoverView.swift` / `StatusBarController.swift` / `App.swift` | 菜单栏、弹窗、窗口与启动入口 |
| `Notifier.swift` | 系统通知 |
| `tools/make_icon.swift` | 生成 `Resources/AppIcon.icns` |
