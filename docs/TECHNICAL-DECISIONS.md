# V0 技术决定

## 一个麦克风入口，独立消费者

`AVAudioEngine` tap 复制有界 PCM buffer，立即交给专用串行写盘队列。Speech 通过独立有界转换队列接收音频；API worker 从已持久化英文读取。录音不会等待 Speech 模型、结果或网络。写盘积压/失败属于真实录音故障，停止采集并明确显示错误；不静默丢音频。Speech 积压只影响实时文字，音频保留。

选择每 30 秒关闭一个 PCM CAF，优先可回收性和实现可验证性。已关闭片段独立可播放；当前片段的崩溃可恢复性需要真机验证。V0 暂未采用单个长时 M4A，避免未完成容器成为全部录音的风险。更大磁盘占用是明确代价；记录文件大小，开始时检查至少 500 MB 空间（此阈值并不保证足够录三小时）。后续可根据真实空间和功耗测量采用分段 AAC。

## Apple Speech 与意群

最低 iOS26，运行时先检查 `SpeechTranscriber.isAvailable` 和 `supportedLocale`；不足时使用 `DictationTranscriber`。预留 locale、检查/安装系统模型，再取兼容 PCM 格式。AVAudioConverter 转换发生在独立队列。输入带 capture host-time 映射的 session 时间戳；暂停后新建分析器但保留 session 时间轴。

volatile 只更新当前英文，绝不作为 finalized 存档或请求 GPT。每个 finalized 事件先保留在 `speech-final.jsonl`；Buffer 根据最终音频结束位置去重，按句末标点、28 词上限或约 0.8 秒无新 final 事件进行合并/提交。计时器约 1 秒检查一次，这是第一版 batching 启发式，不是完整语义判断，不通过强行稳定 partial 换取速度。退出恢复时，尚未打包的 finalized 尾段补回待翻译队列。

首次模型下载期间只保证录音；对应文字缺口明确标记。V0 没有自动离线重转完整历史音频；已有 finalized 英文可补翻译。对于 Speech 中断/模型下载造成的缺失英文，原音频可导出进行后处理。针对课程的词汇偏置不假设所有新 Speech 引擎都支持；V0 只向翻译提供课程名称。

## 翻译、持久化与内存

默认 mock 清楚标识，不冒充真实中文。真实 GPT 使用 Responses API SSE，`store:false`，一次一个请求，25 秒请求超时、45 秒资源超时，最多三次请求与退避；仅网络、408/429/5xx 自动重试。认证/额度失败停止队列，英文保留。断网恢复通过 NWPathMonitor 唤醒；手动补翻译可以重试失败片段。取消后英文仍为 pending，完成事件之前不存为成功中文；early EOF/refusal/incomplete 是失败。Key 在本机 Keychain，配置可编辑模型，CI 不调用 API。

JSONL 每次记录同步写入，保留毫秒时间，读时跳过崩溃末尾的未终止行，续写时先修复末尾；完整的损坏行会报告错误。Metadata 原子替换。录音不依赖 transcript journal 成功，但文字/诊断写盘失败会明显提示。UI 当前窗口限制 30 段，历史分页 50 段；历史索引/导出允许短时读取全部文本（几千个片段），音频始终不整堂加载进内存。当前 pending 查询扫描文字日志，必要时再建立 SQLite 索引；不要为 V0 添加无法测量收益的数据库层。

0.0.2：继续使用 iOS 沙盒 `Documents/Sessions`，由 SessionStore.prepare 统一递归创建并配置目录保护。启动恢复、历史读取、写入和首次空间检查均先准备目录；初始化完成前禁用开始按钮。已有目录和课堂保留，真实 I/O 错误仍显示。回归测试覆盖缺失的父目录、首次容量查询/保存、重复初始化及同名文件冲突；CI 另用新建 iOS 模拟器验证全新安装与再次启动。

最新中文仅向前显示，补历史不会把当前字幕跳回旧位置。V0 的恢复补翻译是顺序处理；后台大量积压的优先调度、更多上下文以及更精细切句需依赖测量后优化。

## 构建与验收边界

本地 Windows 无 Apple SDK；实际编译和 Core XCTest 由 GitHub macOS runner 执行。固定 Xcode/XcodeGen 版本，生成项目后打包未签名真机 IPA，Sideloadly 本地个人签名，不上传 Apple ID/证书。CI 成功不能证明麦克风、Speech 模型、锁屏、长时功耗、Sideloadly 续签已经可用；这些需要真机验证表。

来源：[Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)、[SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)、[WWDC25 长音频方案](https://developer.apple.com/videos/play/wwdc2025/277/)、[OpenAI streaming](https://developers.openai.com/api/docs/guides/streaming-responses)、[Sideloadly](https://sideloadly.io/)。
