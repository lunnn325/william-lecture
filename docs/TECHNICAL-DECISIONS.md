# William Lecture 技术决定

当前版本为 1.0.0；保留 0.0.8 的核心和 0.0.7 实际音频时间轴。下文保留历史背景。

## V1：阅读与日常操作

SwiftUI 展示层按录课、记录、设置拆分，录课隐藏 Tab 栏、底部固定控制。没有更换 AudioRecorder、SpeechService、AppleLocalTranslator、两个翻译 worker 或正式文字稿导出。首次安装默认正常翻译，升级保留旧模式和 Keychain。原 bundle ID 和 Documents/Sessions 不变。

CaptionFeed 是有界展示窗口，跟随时最多 180 段；回看时冻结行成员，只原位合并有效译文，新增内容继续落盘。加载更早页最多保留 360 段，回到最新从磁盘补入；不改变底层 30 段回调窗口和 revision 安全机制。稳定 UUID、无替换动画；用户滚动优先于自动跟随。

旋转或窗口尺寸变化后，等待 350 ms 的布局稳定时间再定位底部，仅在仍处于跟随模式且课堂身份未变化时执行。尺寸再次变化会取消旧任务；手动回看不会被该任务拉回最新。这是展示层等待，不增加 Speech、buffer 或翻译延迟。启用的 Key、模型和课程输入框使用自适应辅助文字色作为 prompt，避免系统默认浅灰提示难以辨认。

笔记以独立 notes.jsonl 存时间、字幕 ID、原文快照和用户文本。重复写入按笔记 ID 合并，空笔记取消标记后作为撤销记录，崩溃尾行使用现有 JSONL 修复。旧课堂不迁移。笔记另行 TXT/Markdown 导出，明确快照不代表定稿。

回放只读 CAF 头获取时长，按已录音位置跨片段播放，拖动和 ±15 秒跳转不用预先生成长 M4A。旧版暂停空档定位到下一段真实音频。播放与音频路由改变都在 MainActor 同步检查当前无录课；开始新课时停止播放器。停止收尾期间锁定课程和设置，防止清空尚待保存的课堂。

模拟器测试使用 DEBUG-only 离线夹具、隔离的 UIFixture 目录和明确演示译文；Release 不包含夹具。真实 Apple 翻译、麦克风、来电和功耗仍须设备验证。截图取自真实 SwiftUI 模拟器渲染，非网页仿制。

## 0.0.8：本机草稿与 GPT 最终版

本机路径是独立服务，默认开启；前台 partial 在 UI 内替换，不追加进正式文字稿。约 300 ms 合并，连续修订不重置等待期限，partial 请求至少间隔约 500 ms；一个实际请求和一个最新待处理 partial。稳定内容由磁盘日志索引读取，与草稿交替，稳定队列交替取最新/最旧。后台撤销未定稿任务身份，只处理稳定段；系统是否允许后台执行仍须真机确认。

字幕 ID 在 Buffer 形成时预分配，定稿沿用同 ID。revision、原文快照、课堂 ID、epoch/请求 token 防止迟到回调串台。只追加时可接受仍完整保留的旧词边界前缀；否定改写、撤销、重启不能接受旧结果。无法按时间可靠切分的重叠 partial 撤销，不猜字符边界。显示过的中文允许暂留，但只有完整稳定英文完全匹配的本机译文能作为导出兜底；partial 永不进入正式稿。请求执行期间若同 ID/全文/revision 已落盘定稿，结果可通过严格检查转为该完整段翻译，避免完全相同英文再请求一次。

使用独立 `TranslationSession(installedSource:target:)`，仅处理已安装模型；iOS 26.4+ 显式 `.lowLatency`，26.0–26.3 默认传统会话。设置页检查英语→简体中文，`.translationTask` 负责用户授权/下载。录课期间不调用 prepareTranslation。iPhone 14 Pro Max 不需要 Apple Intelligence；模拟器使用假译者，不能验证真实翻译。[Apple 会话接口](https://developer.apple.com/documentation/translation/translationsession/init(installedsource:target:))、[低延迟策略](https://developer.apple.com/documentation/translation/translationsession/strategy/lowlatency)、[设备限制](https://developer.apple.com/documentation/translation/translating-text-within-your-app)。

单次本机请求 4 秒截止。超时失效并尝试取消，但实际任务未返回前不释放名额；共享 actor 也保护跨课堂并发，防止取消不合作的旧模型与新模型重叠。失败后本轮关闭本机调度，录音/Speech/GPT 继续；可补翻译重试。没有 Key 也能本机运行；mock 本机内容显式带 MOCK。

GPT 只消费原 Buffer 的稳定段。有本机中文时隐藏 GPT 流式碎片，完整成功后一次替换；没有本机中文时沿用流式显示。较早段只更新历史行，不将主字幕拉回旧句。单条只显示一版中文，来源和状态在系统状态区，不加动画。

SessionStore 按课堂/ID/revision/原文/token 校验，以字段合并写盘，避免两个译者携带旧整段快照覆盖彼此。每个课堂缓存一次最新文字索引（几千段），切换课堂重建；UI 仍仅保留 30 行，音频不变。新增字段均可选，旧 JSON 无需迁移。进程恢复清除未完成的请求占用，保留已有有效中文。导出依次选择真实 GPT 完成版、完整匹配本机版、明确 mock、缺失标记；保留本机兜底身份。

诊断分别记录 partial、local 请求/结果/实际首次显示、Buffer stable、GPT 请求/首批/完成、实际可见替换与过期丢弃；没有显示过本机中文的 GPT 完成另记。分析脚本排除 mock 延迟。采集时间仍用 0.0.7 capture Date，不能用暂停后的音频秒数计算墙钟延迟。

0.0.7：0.0.6 只修正顶部采集时长，字幕仍用墙钟时间，暂停恢复后两者不同。新课堂统一用串行音频写盘队列上累计 PCM 帧数产生 packet offset；Speech、音频索引、metadata、字幕、文字稿和 M4A 使用相同录音轴，暂停和系统未采集时段不增加位置。M4A 直接串接已保存 CAF；中断仍有诊断和缺口标记，不将无音频时段插成静音。实际 capture host-time 映射到 Date，通过稀疏锚点还原 Speech 范围的真实采集日期并随 final/segment 保存，测量 ASR/GPT 延迟时使用该日期，不能将录音秒数加 startedAt 冒充恢复后的墙钟。锚点时钟映射允许约 50 ms 误差；教师参考的端到端延迟仍须真机测量。每次音频关闭额外落盘累计秒数，恢复时不把暂停长度当作录音。metadata 可选 timeline 标记区分旧课堂：没有标记的 0.0.6 及更早记录继续使用原始墙钟轴和带空档 M4A，不自动迁移或破坏已有文字定位。

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
# 1.1 补充（1.1.0 / build 10）

本轮不使用 Impeccable；录音编码、采集帧时间轴、Sentence Buffer 定稿条件与翻译 revision 校验保持现有实现。阅读层独立保存用户选择，避免跟随更新将标记目标改成最新句。主字幕隐藏译文来源，采用 22pt 常规中文、17pt 次级英文和纯图标控制，支持动态字号及深色模式。

麦克风前接入 Speech 输入；先写音频，再等待旧 AI 任务清理。串行桥缓存最多 10 秒/8MB 的原始 PCM，接入时先提交缓存再提交新包。实时积压的丢弃范围按音频轴记录，结束时排空转换队列再记录最后缺口。补转写独立读取已关闭 CAF，仅补未覆盖范围，拒绝重叠段，不修改实时 cursor。Speech 预热仅使用已安装资源；下载在设置触发。[Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)

实时 Responses API 使用 Luna Fast/none，附课程小词库及最近约 30 秒的英文上下文。课后队列独立于麦克风，录课期间暂停，结束后从持久化断点继续；后台有限执行时间到期取消，前台或重启恢复。[Fast 服务](https://developers.openai.com/api/docs/guides/fast-mode)、[Apple 后台限制](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)

课后按约两分钟、最多 80 个原段修订，提供前后 30 秒上下文。保留原始英文/时间/ID，只另存经 source revision 和英文快照校验的英中修订；数字与否定变动拒绝整批结果，不猜改。随后 Sol/high 生成一次严格结构化结果，摘要和原生导图共用节点及原段引用。界面与导出优先匹配修订，再选择现有 GPT/完整本机译文；原始导出保留。

内容快照使用稳定原文指纹，原子写盘并拒绝晚到旧快照。补转写若部分成功后失败，会重建有效指纹并保存明确失败状态，避免永久处理中。新内容文件为可选独立记录；旧课堂不自动发云端，手动整理才入队。课后缺少 Key、模型权限、网络或有效 Speech 资源时保存原因和断点，保留原音频。

真实用量从响应取得，响应 ID 去重；用量缺失明确显示，预算继续保留本次最大额度。请求前用官方 `/v1/responses/input_tokens` 计算同一结构输入，预留最大输出，每次重试单独预留；每节课后总额不超过 250k，实时另计。[官方计数接口](https://developers.openai.com/api/docs/guides/token-counting)

词库：ECON1111 外部性/信息不对称；FINN2003 支付/CBDC/DeFi（现有作业材料范围）；FINN3001 Python/NumPy/Pandas/财务建模。FINN2004 当前课件尚未核验，仅提供通用国际金融术语，不推断课堂内容。Key 复用设备 Keychain，日志和仓库不保存 Key。

