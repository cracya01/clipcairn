# Clipcairn

macOS 菜单栏剪贴板历史工具：记住你复制过的每一样东西，按一下快捷键就能找回来、改一改、再粘贴出去。

原生 Swift 编写，历史记录用 SQLCipher 整库加密，只存在本机。

## 功能

- **记录所有复制**：文本、带格式文本、图片、文件、链接、邮箱、颜色，保留复制时的全部原始格式；每次复制都新增一条
- **快捷键呼出**（默认 ⌃V，可自定义）：左边是列表，右边是预览和详细信息（来源 App、内容类型、字符数、单词数、尺寸、大小、复制时间）
- **搜索**：按内容搜索，开启文字识别后图片里的文字也能搜到；可按类型筛选（⌘P）
- **钉选**：常用内容钉在列表最上方，不随历史滚动，也不会过期被清理；可拖动记录到钉选区，或在钉选区内拖动排序；可重命名（⌘E）
- **预览区直接编辑**：在右侧改完内容后回车、双击或点底部按钮粘贴，改过的内容按纯文本粘贴并成为一条新记录，原记录不变；不粘贴则丢弃
- **粘贴方式**：回车 / 双击粘贴到当前 App，⌘↩ 只复制，⌥↩ 按纯文本粘贴，图片可按 PNG 粘贴
- **右键或 ⌘K 操作菜单**：钉选、重命名、分享、删除，图片可复制其中的文字或二维码内容，链接可在浏览器打开
- **连续粘贴**：每执行一次按时间从新到旧粘贴下一条
- **不记录的内容**：「密码」「钥匙串访问」等指定 App 里复制的内容，以及密码管理器标记为敏感的内容
- **通用剪贴板**：iPhone、iPad 复制的内容默认在这台 Mac 上粘贴后才保存，也可设为立即保存
- 保留时长（1 天到永久）、开机自动启动等设置；按时间段删除和删除全部记录放在设置里，删除前会确认

## 系统要求

- macOS 26 及以上
- Apple Silicon

## 下载安装

1. 到 [Releases](https://github.com/cracya01/clipcairn/releases) 下载最新的 `Clipcairn-*.dmg`，双击打开
2. 把 `Clipcairn.app` 拖进 `Applications` 文件夹
3. **首次打开需要手动放行**：app 没有经过苹果公证，直接双击会提示「无法验证开发者」。任选一种方法：
   - 双击打开一次后，到「系统设置 → 隐私与安全性」，在页面下方点「仍要打开」
   - 或在终端执行：
     ```bash
     xattr -dr com.apple.quarantine /Applications/Clipcairn.app
     ```

## 从源码编译安装

需要 Xcode 或 Xcode 命令行工具（`xcode-select --install`）。

```bash
./build.sh
```

脚本会在临时目录编译，装到 `/Applications/Clipcairn.app` 并启动。app 只在菜单栏显示图标，不出现在 Dock。

签名：如果钥匙串里有名为 `Local Self-Signed Code Signing` 的代码签名证书就用它，否则使用临时签名（ad-hoc）。用固定证书的好处是重新编译后系统授予的权限不会丢。

## 权限

| 权限 | 用途 | 位置 |
|---|---|---|
| 读取剪贴板 | 记录复制的内容 | macOS 第一次询问时选允许 |
| 辅助功能（macOS 27 中叫「设备控制与数据访问」） | 自动粘贴到当前 App；通用剪贴板内容粘贴后保存 | 系统设置 → 隐私与安全性 |

在系统设置里打开辅助功能后，需要退出并重新打开 Clipcairn 才会生效。

## 数据与加密

- 历史记录存在 `~/Library/Application Support/Clipcairn/history.db`，用 [SQLCipher](https://github.com/sqlcipher/sqlcipher) 整库加密（加密由 macOS 自带的 CommonCrypto 提供）
- 数据库密钥存在登录钥匙串，通过系统自带的 `/usr/bin/security` 工具存取。这样自签名的 app 更新后不会每次都要求输入登录密码；代价是本机以你的身份运行的其他程序也能通过同一工具读取这个密钥
- 显示链接的图标和预览图时会访问对应网站，可在设置里关闭；除此之外不联网

## 代码结构

| 文件 | 内容 |
|---|---|
| `Sources/App.swift` | 程序入口、菜单栏、启动流程 |
| `Sources/Capture.swift` | 监听剪贴板、类型判断、图片文字识别、链接预览 |
| `Sources/ClipStore.swift` | 记录的存储、钉选、保留时长清理 |
| `Sources/Database.swift` | SQLCipher 封装 |
| `Sources/KeyStore.swift` | 数据库密钥 |
| `Sources/Paster.swift` | 写回剪贴板、模拟粘贴、连续粘贴 |
| `Sources/Hotkeys.swift` | 全局快捷键 |
| `Sources/Panel.swift`、`HistoryController.swift`、`HistoryModel.swift`、`HistoryView.swift` | 剪贴板历史窗口 |
| `Sources/Settings.swift`、`SettingsUI.swift` | 设置 |
| `Vendor/sqlcipher/` | SQLCipher v4.20.0 源码（单文件版） |

## 致谢

- [SQLCipher](https://github.com/sqlcipher/sqlcipher)（BSD 3-Clause，许可证见 `Vendor/sqlcipher/LICENSE.md`）
- 剪贴板读写与模拟粘贴的若干细节参考了 [Maccy](https://github.com/p0deje/Maccy)（MIT）

## 许可证

[MIT](LICENSE)
