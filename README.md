# William Lecture · V1

用于 iPhone/iPad 日常课堂：选择课程 → 开始录音 → 低头看英中字幕 → 结束并保存。沿用 V0.0.8 的录音、Apple Speech、本机中文、GPT 最终替换、增量保存和导出；V1 整理录课、记录、整节回放、笔记、导出与设置流程。

最低 iOS/iPadOS 26.0。目标设备：iPhone 14 Pro Max、M4 iPad Pro。第一次使用可能需要联网下载 Apple 英文模型。录音先开始；模型准备期间的实时转写缺口会标记，不会伪造文字。

首次安装默认正常翻译、本机中文开启；升级保留已有设置。先在设置准备英文→简体中文模型，录课期间不下载。无 Key 可使用本机中文，本机不可用继续走 GPT。有本机中文时，GPT 完成后一次替换；没有本机中文仍流式显示。关闭本机开关恢复 GPT 路径。演示模式仅供诊断测试，不能验证翻译质量。

录课页自动跟随最新字幕；上滑回看时暂停跟随，点击「回到最新」恢复。轻点一句标记，双击写笔记；底部「标记」快速记录当前句，长按写笔记。笔记独立保存，不修改原文。停止需一次确认，音频先关闭、文字随后保存；保存期间不能切换课程或再次开始。详情支持整节时间轴和 ±15 秒回听，录课期间禁用回放。

0.0.2 修复首次安装的存储初始化：启动时自动建立 `Documents/Sessions`，空间检查也会先确保目录存在。保持原 bundle ID，可覆盖安装保留已有课堂数据。CI 增加空沙盒存储测试和全新 iOS 模拟器首次启动/重启测试。

0.0.3 修正录音/回放的 measurement 模式，改用普通模式；修正重采样后输入 Speech 的时间戳，排空转换尾帧；检查模型状态并预热分析器，初始化失败尝试 Dictation 降级。系统状态显示可复制的完整 Speech 错误和收音平均/峰值 dBFS，可在持续录音时重试英文。原始音频没有额外数字放大。若仍无字幕，请复制完整 Speech 报错或分享 diagnostics，不能仅凭编译测试确认具体设备的 Speech 故障已经解决。

## Windows 获取 IPA

1. 打开 [GitHub Actions](https://github.com/lunnn325/william-lecture/actions/workflows/ios-validation.yml)，选择最新成功的 `iOS Validation IPA`。
2. 下载 artifact `WilliamLecture-V1-unsigned-IPA`，解压得到 `WilliamLecture-V1-unsigned.ipa`。
3. 从 [Sideloadly 官网](https://sideloadly.io/) 安装 Windows 版。官网要求使用 Apple 网站版本的 iTunes/iCloud；已有 Microsoft Store 版本时按官网说明处理。
4. USB 连接 iPhone，解锁并信任电脑；把 IPA 拖入 Sideloadly，选设备，在 Sideloadly 本地登录个人 Apple ID 并安装。Apple ID 密码不交给 Codex、不放 GitHub。
5. 按 iPhone 提示开启 Developer Mode；在「设置 → 通用 → VPN 与设备管理」信任开发者后打开 App。
6. 后续更新维持同一个 Apple ID 和 bundle ID。升级前先导出重要课堂数据；不要通过卸载 App 来升级，否则本地数据会被删除。

IPA 尚未签名，无法直接点开安装；Sideloadly 在电脑上完成个人签名。免费 Apple ID 签名通常有效七天，Sideloadly 提供电脑辅助续签。实际配对、安装、续签、升级后数据保留仍需在你的设备验证。参考 [官方安装与 FAQ](https://sideloadly.io/)。

## 第一次测试

1. 设置中准备本机中文模型，配置已有 OpenAI Key；没有 Key 也可先验证本机中文。选择课程，开始录音，授权麦克风。
2. 等系统状态出现 `SpeechTranscriber · 本机英文` 或 `DictationTranscriber`。如果正在下载模型，先保持联网。
3. 播放清晰英文，观察本机草稿和 GPT 升级；上滑回看，确认译文更新不会把你拉走。
4. 标记、写笔记、暂停、恢复、停止。在「记录」中回听、拖动进度，导出英/中/双语 TXT/Markdown，可同时带走独立笔记、M4A 与 diagnostics。
5. 默认模型 `gpt-4.1-mini`，可按账户可用模型调整。Key 只在设备 Keychain；CI 不调用真实 API。GPT 只收到稳定英文片段，不收到原始音频。
6. 网络恢复自动唤醒队列；错误 Key/额度修复后在详情「补全翻译」。点录课顶部状态进入诊断。停止不等待 GPT；导出是生成时快照，补翻译后可重新导出。

## 真机验证顺序

先做 5–10 分钟测试，再做 30 分钟，最后分别在两台设备上做 2 小时及一次 3 小时测试。填写 [验证记录](docs/DEVICE-VALIDATION.md)。

- 前台录音、英文、真实中文、暂停恢复、停止、回放、三种语言导出。
- 锁屏、切换 App 后确认音频文件持续增长；回来检查最新字幕和历史。
- 飞行模式/断网、错误 Key、API 超时：音频持续写盘，英文保留，中文明确待处理。
- 系统中断、换音频路由、强制结束 App 后重开：已有片段可播放，缺口被标记。
- 升级同 bundle ID 的新 IPA、七天续签后检查课堂数据。

V0 核心已有你的真机测试反馈；V1 新界面的阅读、回听和升级仍需真机复测，来电尚未验证。系统可能挂起/终止进程或中断录音；已有内容保留、缺口记录，系统停止后无法保证继续采集。

## 数据与诊断

`Documents/Sessions/<UUID>/`：

- `session.json`：课程、状态、开始时间、音频列表。
- `notes.jsonl`：时间标记、原文快照和笔记，独立增量写入；旧记录无此文件也可正常读取。
- `audio-xxxxx.caf`：每 30 秒关闭一个 16-bit PCM 片段，保持设备采样率和通道数。48 kHz 单声道约 330 MB/小时；双声道约两倍。
- `audio-index.jsonl`：片段开始位置、格式。连续片段自动续播。
- `speech-final.jsonl`：Apple finalized 英文事件；volatile 仅显示，不送 GPT。
- `transcript.jsonl`：意群及翻译状态的追加记录；同一 ID 的最后一次更新为有效状态。
- `diagnostics.jsonl`：音频、ASR、buffer、API、中断、内存、文件大小的时间点与指标。
- `Exports/`：UTF-8 TXT/Markdown，标记 mock、待翻译和已知缺口。

时间戳为保留毫秒精度的 Unix milliseconds。0.0.7 新课堂的主计时、字幕起止、TXT/Markdown、回放和 M4A 共用实际采集的音频秒数，暂停不计时；真实采集日期另存，延迟统计不把暂停算成等待。旧课堂保留原时间轴及暂停空档并明确标识，不改写已有定位。文件使用解锁后可访问的本机保护，允许锁屏写盘。通过 Windows iTunes 文件共享或 iPhone「文件 → 我的 iPhone → William Lecture」保存整个 Sessions 文件夹。V0 不自动删除音频；手动清理前先备份文字稿。

分析导出的诊断（Windows 已有 Node.js 即可）：

```powershell
node scripts/analyze-diagnostics.mjs "C:\path\diagnostics.jsonl"
```

报告区分英文首次结果、partial、final、缓冲、翻译队列、中文首段流式输出和完成，给出 p50/p95；mock 排除在 GPT 指标之外。数值依据 Apple 音频范围和本机接收时间，尚不是与教师参考录音对齐的客观词级延迟。不要先承诺 1–2 秒。

0.0.4 缩短已定稿英文的额外缓冲等待，最多同时翻译两段，复用网络连接，并让首段中文先显示再写诊断。旧课堂和设备上已有的设置/Keychain 可继续使用。比较版本时保留同一音源、模型和网络，导出 diagnostics 查看 `buffer_after_final_receipt`、`translation_queue_after_buffer`、`gpt_request_to_first`，再判断等待主要发生在哪里。

0.0.5 加固暂停收尾、跨课堂回调、网络恢复/手动取消、异常退出恢复与导出。历史页可生成整堂 M4A；分块编码为 48 kHz 单声道 AAC 96 kbps，已知录音空档保留为静音，原 CAF 不变。录音停止且保存完成后才能导出；文字与诊断为独立快照，补翻译后可再次生成。范围、验证数据及真机待测事项见 [本轮加固报告](docs/NIGHTLY_HARDENING_REPORT.md)。

0.0.6 修复暂停后计时继续增长：主计时显示实际音频采集时长，暂停和中断不计时，恢复后继续累加；字幕/诊断及 M4A 保留原课堂时间轴，历史页区分这两个时长。旧课堂数据兼容。

## 构建与结构

Windows 修改后提交即可触发 CI。CI 使用 `macos-26`、Xcode 26.5、XcodeGen 2.46.0；先运行 `swift test`，再编译真机 arm64 App，生成未签名 IPA。Apple 证书和 OpenAI Key 都不需要上传到 CI。私有仓库使用你的 Actions 额度，详见 [GitHub runner 说明](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。

有 Mac 时：

```bash
bash scripts/build-ios.sh
```

`WLCore`：Foundation 模型、final 意群缓冲、JSONL 恢复、导出、SSE 及可注入测试传输的独立翻译 worker；`WLAppleAudio`：可在 macOS XCTest 验证的 PCM 重采样、时间轴、录音电平和 CAF 写入；`App`：音频、Speech、Keychain、最小 SwiftUI。重要决定与当前限制在 [技术决定](docs/TECHNICAL-DECISIONS.md)。
