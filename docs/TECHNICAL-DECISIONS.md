# V0 技术决定

当前版本为 0.0.6；任务隔离、停止收尾、恢复、导出及暂停计时的最新行为和验证边界见 [V0 Hardening 报告](NIGHTLY_HARDENING_REPORT.md)。下文保留各版本决定的背景。

## 一个麦克风入口，独立消费者

0.0.3：录音和回放都显式使用 default 模式。此前 measurement 会减少系统动态处理，回放只改变 category 又保留了 measurement，可能导致偏低音量。此处没有给原音频加数字增益；收音电平按全秒、所有通道统计 RMS、peak dBFS 和削波比例，并记录实际 input route、mode、格式与设备 input gain。CAF 编码通过实际写入/读取音调测试验证幅度，真机远场音量仍须比较。[Apple measurement 说明](https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/measurement)

`AVAudioEngine` tap 复制有界 PCM buffer，立即交给专用串行写盘队列。Speech 通过独立有界转换队列接收音频；API worker 从已持久化英文读取。录音不会等待 Speech 模型、结果或网络。写盘积压/失败属于真实录音故障，停止采集并明确显示错误；不静默丢音频。Speech 积压只影响实时文字，音频保留。

选择每 30 秒关闭一个 PCM CAF，优先可回收性和实现可验证性。已关闭片段独立可播放；当前片段的崩溃可恢复性需要真机验证。V0 暂未采用单个长时 M4A，避免未完成容器成为全部录音的风险。更大磁盘占用是明确代价；记录文件大小，开始时检查至少 500 MB 空间（此阈值并不保证足够录三小时）。后续可根据真实空间和功耗测量采用分段 AAC。

## Apple Speech 与意群

0.0.3：AVAudioConverter 在独立串行队列里生成输出时间轴。每个输出缓冲区按实际输出帧数累加，源音频中断则重建转换器并保留时间空档；停止时排空重采样尾帧。重采样器可保留 priming 帧，因此不再将每个原缓冲区的时间戳直接用于转换后的音频，以免重叠并触发 Speech 输入错误。用真实 AVAudioConverter 验证 48k/44.1k、单双声道和非整除缓冲区的帧数、单调时间、幅度。模型安装后检查 installed，显式 prepareToAnalyze；主引擎初始化失败时尝试 Dictation。完整 domain/code/underlying error 显示并记录，可单独重试 Speech 而不停止录音。用户报告的初始化故障仍需新版真机错误信息确认根因。[Apple AnalyzerInput 时间要求](https://developer.apple.com/documentation/speech/analyzerinput/init(buffer:bufferstarttime:))

最低 iOS26，运行时先检查 `SpeechTranscriber.isAvailable` 和 `supportedLocale`；不足时使用 `DictationTranscriber`。预留 locale、检查/安装系统模型，再取兼容 PCM 格式。AVAudioConverter 转换发生在独立队列。输入带 capture host-time 映射的 session 时间戳；暂停后新建分析器但保留 session 时间轴。

volatile 只更新当前英文，绝不作为 finalized 存档或请求 GPT。每个 finalized 事件先保留在 `speech-final.jsonl`；Buffer 根据最终音频结束位置去重，按句末标点、20 词上限、4.5 秒音频跨度或约 0.35 秒无新 final 事件进行合并/提交。quiet deadline 使用独立可取消任务，避免原来 1 秒 UI 计时器额外引入的等待。这是 batching 启发式，不是完整语义判断，不通过强行稳定 partial 换取速度。不会把一个 Apple final 结果强行拆成带虚构时间戳的小段；一个结果本身很长时仍整段提交。退出恢复时，尚未打包的 finalized 尾段补回待翻译队列。

首次模型下载期间只保证录音；对应文字缺口明确标记。V0 没有自动离线重转完整历史音频；已有 finalized 英文可补翻译。对于 Speech 中断/模型下载造成的缺失英文，原音频可导出进行后处理。针对课程的词汇偏置不假设所有新 Speech 引擎都支持；V0 只向翻译提供课程名称。

## 翻译、持久化与内存

默认 mock 清楚标识，不冒充真实中文。真实 GPT 使用 Responses API SSE，`store:false`，最多两个请求并行，交替选择最旧/最新 pending 片段，避免持续新增内容让历史饿死。共享一个 ephemeral URLSession 复用连接，25 秒请求超时、45 秒资源超时，最多三次请求与退避；仅网络、408/429/5xx 自动重试。认证/额度失败停止调度新片段，已在执行的另一段可以完成并保存。断网恢复通过 NWPathMonitor 唤醒；手动补翻译可以重试失败片段。取消并等待所有在途任务后才能切换课堂/worker；英文仍为 pending，完成事件之前不存为成功中文；early EOF/refusal/incomplete 是失败。Key 在本机 Keychain，配置可编辑模型，CI 不调用 API。

JSONL 每次记录同步写入，保留毫秒时间，读时跳过崩溃末尾的未终止行，续写时先修复末尾；完整的损坏行会报告错误。Metadata 原子替换。录音不依赖 transcript journal 成功，但文字/诊断写盘失败会明显提示。UI 当前窗口限制 30 段，历史分页 50 段；历史索引/导出允许短时读取全部文本（几千个片段），音频始终不整堂加载进内存。pending 索引只缓存一个课堂的未完成/失败片段，同一 actor 写入后更新，切换课堂/重开后从磁盘重建；完成译文不留在索引里。避免每段翻译重新扫描整堂课不断增长的文字日志，暂不引入数据库。

0.0.4：请求/首段中文/完成时间在事件发生时捕获，诊断通过独立有序任务落盘；首段中文先更新 UI，避免等待诊断 fsync。新片段增加可选 queuedAt，旧课堂无需迁移。统计分开显示 final→buffer、buffer→请求、请求→中文首段/完成；排队不再被误归为 buffer 延迟。保留用户已选模型和目前可运行的 Speech 配置。更短 final batching 可能增加请求数量、减小单段上下文，需用真机课堂比较准确度和 API 限流情况；不添加付费加速或推测固定延迟。

0.0.2：继续使用 iOS 沙盒 `Documents/Sessions`，由 SessionStore.prepare 统一递归创建并配置目录保护。启动恢复、历史读取、写入和首次空间检查均先准备目录；初始化完成前禁用开始按钮。已有目录和课堂保留，真实 I/O 错误仍显示。回归测试覆盖缺失的父目录、首次容量查询/保存、重复初始化及同名文件冲突；CI 另用新建 iOS 模拟器验证全新安装与再次启动。

最新中文仅向前显示，乱序完成及补历史不会把当前字幕跳回旧位置。两个在途请求及最旧/最新交替调度有自动回归测试；更多上下文与更精细切句仍需依赖真机测量后优化。

## 构建与验收边界

本地 Windows 无 Apple SDK；实际编译和 Core XCTest 由 GitHub macOS runner 执行。固定 Xcode/XcodeGen 版本，生成项目后打包未签名真机 IPA，Sideloadly 本地个人签名，不上传 Apple ID/证书。CI 成功不能证明麦克风、Speech 模型、锁屏、长时功耗、Sideloadly 续签已经可用；这些需要真机验证表。

来源：[Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)、[SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)、[WWDC25 长音频方案](https://developer.apple.com/videos/play/wwdc2025/277/)、[OpenAI streaming](https://developers.openai.com/api/docs/guides/streaming-responses)、[Sideloadly](https://sideloadly.io/)。
