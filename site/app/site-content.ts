export const locales = ["zh", "en", "ja"] as const;
export type Locale = (typeof locales)[number];

export const pageSlugs = [
  "releases",
  "known-issues",
  "privacy",
  "terms",
  "support",
  "security",
  "channels",
] as const;
export type PageSlug = (typeof pageSlugs)[number];

type Copy = {
  lang: string;
  localeLabel: string;
  brand: string;
  preview: string;
  nav: { features: string; channels: string; privacy: string; support: string };
  eyebrow: string;
  title: string;
  lead: string;
  betaStatus: string;
  betaDetail: string;
  download: string;
  requirements: string[];
  featuresTitle: string;
  features: Array<{ title: string; detail: string }>;
  screenshotsTitle: string;
  screenshots: string[];
  channelsTitle: string;
  channelLead: string;
  direct: string;
  directDetail: string;
  store: string;
  storeDetail: string;
  privacyTitle: string;
  privacyDetail: string;
  localDiagnostics: string;
  noTelemetry: string;
  footer: Record<PageSlug, string>;
  pages: Record<PageSlug, { title: string; intro: string; sections: Array<{ title: string; body: string }> }>;
};

export const copy: Record<Locale, Copy> = {
  zh: {
    lang: "zh-Hans",
    localeLabel: "简体中文",
    brand: "积木工具",
    preview: "发布前预览 · 尚未开放下载",
    nav: { features: "能力", channels: "渠道差异", privacy: "隐私", support: "支持" },
    eyebrow: "一个原生的 macOS 工具集",
    title: "把常用工具，收进一个安静的工作台。",
    lead: "积木工具把截图、剪贴板和翻译放在同一套原生交互里。它优先本地处理，外部服务只在你明确配置并触发时使用。",
    betaStatus: "Beta 1 准备中",
    betaDetail: "品牌、域名与 Bundle ID 已锁定；签名、公证和干净机器验收完成前仍不会开放下载。此页面当前不代表已经发布。",
    download: "下载尚未开放",
    requirements: ["免费公开 Beta", "仅 Apple Silicon", "macOS 14 或更高版本", "Beta 1–2 手动更新"],
    featuresTitle: "少一点切换，多一点连续",
    features: [
      { title: "截图", detail: "区域、窗口、全屏与滚动截图，配套标注、OCR、固定与导出。" },
      { title: "剪贴板", detail: "搜索、筛选、收藏、标签与安全粘贴，让历史内容可找回、可管理。" },
      { title: "翻译", detail: "手动输入、截图 OCR 与可配置翻译源；不同结果可以并排比较。" },
    ],
    screenshotsTitle: "真实应用画面",
    screenshots: ["统一的工具设置", "并排比较翻译结果", "快速检索剪贴板历史"],
    channelsTitle: "两个渠道，边界说清楚",
    channelLead: "官网版保留完整能力；TestFlight / App Store 版遵循商店审核与沙箱边界。",
    direct: "官网 Direct Beta",
    directDetail: "包含 CLI、ActionBroker、划词 Helper 与外部插件。Beta 1、Beta 2 从下载页手动更新。",
    store: "TestFlight / App Store Beta",
    storeDetail: "不包含 CLI、ActionBroker、独立 Helper 和外部插件；更新由 Apple 管理。",
    privacyTitle: "默认不把你的工作内容发走",
    privacyDetail: "应用不自动上传遥测。剪贴板原文、截图、API Key 和 Keychain 内容不会进入诊断导出。外部翻译服务只处理你主动提交的内容。",
    localDiagnostics: "诊断由你在本地导出、检查并决定是否提交。",
    noTelemetry: "无自动遥测",
    footer: { releases: "版本记录", "known-issues": "已知问题", privacy: "隐私政策", terms: "服务条款", support: "支持", security: "安全反馈", channels: "功能渠道差异" },
    pages: {
      releases: { title: "版本记录", intro: "正式 Beta 发布后，这里将保留每个不可变版本的说明、SHA-256、文件大小、最低系统与公证状态。", sections: [{ title: "0.1.0-beta.1", body: "准备中，尚未生成对外分发包，也没有公开下载地址。" }] },
      "known-issues": { title: "已知问题", intro: "只记录已经复现或仍待验证的问题，不把推测写成事实。", sections: [{ title: "发布前状态", body: "Developer ID 签名、公证、干净机器安装、手动升级和外部 App 验收尚未完成。" }, { title: "中国大陆访问", body: "仅使用全球托管，访问质量属于尽力而为，不承诺国内稳定下载。" }] },
      privacy: { title: "隐私政策（发布前草案）", intro: "这份草案描述当前产品边界；最终政策会在公开发布前完成主体和法律复核。", sections: [{ title: "本地数据", body: "剪贴板记录、截图历史、设置和插件数据默认保存在本机应用容器中。" }, { title: "外部服务", body: "只有在用户配置并主动触发时，翻译或 AI Provider 才会收到完成该请求所需的内容。" }, { title: "诊断", body: "应用不自动上传遥测。诊断报告由用户主动导出，排除剪贴板原文、截图、凭据、服务地址、文件路径和原始日志。" }, { title: "隐私联系", body: "公开发布后的隐私联系地址为 privacy@orangeforge.top；邮箱启用前不接受材料。" }] },
      terms: { title: "服务条款（发布前草案）", intro: "Beta 免费提供，功能可能调整；最终条款将在公开发布前完成主体与适用法律复核。", sections: [{ title: "Beta 性质", body: "测试版本不提供可用性或无错误保证。请自行备份重要数据。" }, { title: "可接受使用", body: "不得使用本应用侵犯他人权利、绕过授权或处理你无权访问的内容。" }] },
      support: { title: "支持", intro: "公开发布后的支持地址为 support@orangeforge.top。当前仓库草案不会收集或发送反馈，邮箱启用状态会在发布前复核。", sections: [{ title: "提交前请检查", body: "请移除剪贴板原文、截图中的隐私信息、API Key、Cookie、完整订阅链接和其他凭据。" }, { title: "建议提供", body: "版本、发布渠道、macOS 版本、复现步骤、权限状态，以及你已检查过的脱敏诊断报告。" }] },
      security: { title: "安全反馈", intro: "公开发布后的安全反馈地址为 security@orangeforge.top。邮箱与披露流程启用前，不要发送漏洞细节或凭据。", sections: [{ title: "范围", body: "应用签名、更新、权限、插件隔离、凭据存储和本地数据暴露属于优先处理范围。" }, { title: "敏感信息", body: "报告中不得包含真实 API Key、私钥、验证码、Cookie 或用户原始内容。" }] },
      channels: { title: "功能渠道差异", intro: "渠道差异是构建期边界，不是只隐藏界面。", sections: [{ title: "官网版", body: "包含截图、剪贴板、翻译、CLI、ActionBroker、划词 Helper、内置插件与外部插件。" }, { title: "商店兼容版", body: "保留截图、剪贴板、手动翻译、截图 OCR 和固定内置插件；移除 CLI、ActionBroker、LaunchAgent、Helper 下载配对和外部插件入口。" }] },
    },
  },
  en: {
    lang: "en",
    localeLabel: "English",
    brand: "Blocks for Mac",
    preview: "Pre-release preview · Downloads are not open",
    nav: { features: "Features", channels: "Editions", privacy: "Privacy", support: "Support" },
    eyebrow: "A native macOS utility collection",
    title: "Keep everyday tools in one quiet workspace.",
    lead: "Blocks for Mac brings screenshots, clipboard history, and translation into one native experience. It prefers local processing and only uses external services when you configure and invoke them.",
    betaStatus: "Beta 1 in preparation",
    betaDetail: "The brand, domain, and Bundle ID are locked. Downloads remain disabled until signing, notarization, and clean-machine acceptance are complete.",
    download: "Download not available yet",
    requirements: ["Free public beta", "Apple Silicon only", "macOS 14 or later", "Manual updates for Beta 1–2"],
    featuresTitle: "Less switching. More continuity.",
    features: [{ title: "Screenshots", detail: "Region, window, fullscreen, and scrolling capture with annotation, OCR, pinning, and export." }, { title: "Clipboard", detail: "Search, filters, favorites, tags, and safer paste flows for a history you can actually manage." }, { title: "Translation", detail: "Manual text, screenshot OCR, and configurable sources with side-by-side results." }],
    screenshotsTitle: "Real app screens",
    screenshots: ["One settings system", "Compare translation results", "Find clipboard history quickly"],
    channelsTitle: "Two editions with explicit boundaries",
    channelLead: "The direct edition keeps the complete feature set. TestFlight and App Store builds follow sandbox and review constraints.",
    direct: "Direct website beta",
    directDetail: "Includes the CLI, ActionBroker, Selection Helper, and external plugins. Beta 1 and Beta 2 update manually from the download page.",
    store: "TestFlight / App Store beta",
    storeDetail: "Excludes the CLI, ActionBroker, standalone Helper, and external plugins. Apple manages updates.",
    privacyTitle: "Your working content does not leave by default",
    privacyDetail: "The app does not upload telemetry automatically. Clipboard content, screenshots, API keys, and Keychain values are excluded from diagnostics. External translation services only receive content you explicitly submit.",
    localDiagnostics: "You export diagnostics locally, review them, and decide whether to send them.",
    noTelemetry: "No automatic telemetry",
    footer: { releases: "Release notes", "known-issues": "Known issues", privacy: "Privacy", terms: "Terms", support: "Support", security: "Security", channels: "Edition differences" },
    pages: {
      releases: { title: "Release notes", intro: "After launch, this page will list every immutable build with notes, SHA-256, size, minimum macOS, and notarization status.", sections: [{ title: "0.1.0-beta.1", body: "In preparation. No external distribution package or public URL exists yet." }] },
      "known-issues": { title: "Known issues", intro: "Only reproduced issues and explicit pending checks belong here; assumptions are not presented as facts.", sections: [{ title: "Pre-release status", body: "Developer ID signing, notarization, clean-machine installation, manual upgrade, and external-app acceptance remain incomplete." }, { title: "Mainland China access", body: "Hosting is global only and access is best effort. Stable mainland delivery is not promised." }] },
      privacy: { title: "Privacy policy — pre-release draft", intro: "This draft describes the current product boundary. It will receive a final entity and legal review before publication.", sections: [{ title: "Local data", body: "Clipboard records, screenshot history, settings, and plugin data are stored in the local app container by default." }, { title: "External services", body: "A configured translation or AI provider receives only the content needed for a request you explicitly invoke." }, { title: "Diagnostics", body: "No telemetry is uploaded automatically. User-exported diagnostics omit clipboard content, screenshots, credentials, endpoints, file paths, and raw logs." }, { title: "Privacy contact", body: "The post-launch privacy address is privacy@orangeforge.top. Do not send material until the mailbox is confirmed active." }] },
      terms: { title: "Terms — pre-release draft", intro: "The beta is free and may change. Final entity and governing-law language will be reviewed before publication.", sections: [{ title: "Beta status", body: "The test build is provided without availability or error-free guarantees. Back up important data." }, { title: "Acceptable use", body: "Do not use the app to violate rights, bypass authorization, or process content you are not permitted to access." }] },
      support: { title: "Support", intro: "The post-launch support address is support@orangeforge.top. This repository draft does not collect or send feedback; mailbox readiness will be verified before launch.", sections: [{ title: "Review before sending", body: "Remove private clipboard text, sensitive screenshots, API keys, cookies, subscription URLs, and credentials." }, { title: "Useful details", body: "Include version, channel, macOS version, reproduction steps, permission state, and a diagnostic report you have reviewed." }] },
      security: { title: "Security", intro: "The post-launch security address is security@orangeforge.top. Do not send vulnerability details or credentials until the mailbox and disclosure process are confirmed active.", sections: [{ title: "Scope", body: "Signing, updates, permissions, plugin isolation, credential storage, and local data exposure are priority areas." }, { title: "Sensitive data", body: "Never include real API keys, private keys, verification codes, cookies, or original user content." }] },
      channels: { title: "Edition differences", intro: "Edition boundaries are enforced at build time, not by hiding controls at runtime.", sections: [{ title: "Direct edition", body: "Screenshots, clipboard, translation, CLI, ActionBroker, Selection Helper, built-in plugins, and external plugins." }, { title: "Store-compatible edition", body: "Screenshots, clipboard, manual translation, screenshot OCR, and fixed built-in plugins remain. CLI, ActionBroker, LaunchAgent, Helper pairing, and external plugin entry points are removed." }] },
    },
  },
  ja: {
    lang: "ja",
    localeLabel: "日本語",
    brand: "Blocks for Mac",
    preview: "公開前プレビュー · ダウンロード未開始",
    nav: { features: "機能", channels: "配布版の違い", privacy: "プライバシー", support: "サポート" },
    eyebrow: "macOS ネイティブのツール集",
    title: "毎日のツールを、静かな一つの作業場所へ。",
    lead: "Blocks for Mac はスクリーンショット、クリップボード履歴、翻訳を一つのネイティブ体験にまとめます。ローカル処理を優先し、外部サービスは設定して明示的に実行した場合だけ利用します。",
    betaStatus: "Beta 1 準備中",
    betaDetail: "ブランド、ドメイン、Bundle ID は確定済みです。署名、公証、クリーン環境での検証が完了するまでダウンロードは無効です。",
    download: "ダウンロードはまだ利用できません",
    requirements: ["無料公開ベータ", "Apple Silicon のみ", "macOS 14 以降", "Beta 1–2 は手動更新"],
    featuresTitle: "切り替えを減らし、作業をつなげる",
    features: [{ title: "スクリーンショット", detail: "範囲、ウインドウ、全画面、スクロール撮影と注釈、OCR、固定、書き出し。" }, { title: "クリップボード", detail: "検索、絞り込み、お気に入り、タグ、安全な貼り付けで履歴を管理。" }, { title: "翻訳", detail: "手動入力、スクリーンショット OCR、設定可能な翻訳元を並べて比較。" }],
    screenshotsTitle: "実際のアプリ画面",
    screenshots: ["統一された設定", "翻訳結果を比較", "履歴をすばやく検索"],
    channelsTitle: "二つの配布版と明確な境界",
    channelLead: "公式サイト版は全機能を維持し、TestFlight / App Store 版はサンドボックスと審査要件に従います。",
    direct: "公式サイト Direct Beta",
    directDetail: "CLI、ActionBroker、選択ヘルパー、外部プラグインを含みます。Beta 1 と Beta 2 はダウンロードページから手動更新します。",
    store: "TestFlight / App Store ベータ",
    storeDetail: "CLI、ActionBroker、独立ヘルパー、外部プラグインは含まれません。更新は Apple が管理します。",
    privacyTitle: "作業内容は初期状態で外部へ送信しません",
    privacyDetail: "テレメトリは自動送信しません。クリップボード内容、スクリーンショット、API キー、Keychain 値は診断に含めません。外部翻訳サービスには明示的に送信した内容だけが渡ります。",
    localDiagnostics: "診断はローカルに書き出し、確認した上で送信するかを選べます。",
    noTelemetry: "自動テレメトリなし",
    footer: { releases: "リリースノート", "known-issues": "既知の問題", privacy: "プライバシー", terms: "利用規約", support: "サポート", security: "セキュリティ", channels: "配布版の違い" },
    pages: {
      releases: { title: "リリースノート", intro: "公開後は各固定バージョンの説明、SHA-256、サイズ、最低 macOS、公証状態を掲載します。", sections: [{ title: "0.1.0-beta.1", body: "準備中です。外部配布パッケージと公開 URL はまだありません。" }] },
      "known-issues": { title: "既知の問題", intro: "再現済み、または確認待ちの項目だけを記載し、推測を事実として扱いません。", sections: [{ title: "公開前の状態", body: "Developer ID 署名、公証、クリーン環境インストール、手動更新、外部アプリ検証は未完了です。" }, { title: "中国本土からのアクセス", body: "グローバル配信のみで、アクセス品質はベストエフォートです。安定配信は保証しません。" }] },
      privacy: { title: "プライバシーポリシー（公開前草案）", intro: "現在の製品境界を示す草案です。公開前に主体と法務の最終確認を行います。", sections: [{ title: "ローカルデータ", body: "クリップボード履歴、スクリーンショット履歴、設定、プラグインデータは初期状態でローカルコンテナに保存します。" }, { title: "外部サービス", body: "設定済みの翻訳・AI Provider には、明示的に実行した要求に必要な内容だけを送ります。" }, { title: "診断", body: "テレメトリは自動送信しません。ユーザーが書き出す診断には原文、画像、認証情報、接続先、パス、生ログを含めません。" }, { title: "プライバシー連絡先", body: "公開後の連絡先は privacy@orangeforge.top です。メールボックスの有効化を確認するまで送信しないでください。" }] },
      terms: { title: "利用規約（公開前草案）", intro: "ベータは無料で、内容は変更される場合があります。公開前に主体と準拠法を確認します。", sections: [{ title: "ベータ版", body: "可用性や無故障を保証しません。重要なデータはバックアップしてください。" }, { title: "適切な利用", body: "権利侵害、認可回避、アクセス権のない内容の処理に使用しないでください。" }] },
      support: { title: "サポート", intro: "公開後のサポート窓口は support@orangeforge.top です。この草案サイトはフィードバックを収集・送信せず、公開前にメールボックスの状態を確認します。", sections: [{ title: "送信前の確認", body: "クリップボード原文、機密画像、API キー、Cookie、購読 URL、認証情報を削除してください。" }, { title: "役立つ情報", body: "バージョン、チャネル、macOS、再現手順、権限状態、確認済みの診断レポートを添えてください。" }] },
      security: { title: "セキュリティ", intro: "公開後の窓口は security@orangeforge.top です。メールボックスと開示手順を確認するまで、脆弱性情報や認証情報を送らないでください。", sections: [{ title: "対象", body: "署名、更新、権限、プラグイン分離、認証情報保存、ローカルデータ露出を優先します。" }, { title: "機密情報", body: "実際の API キー、秘密鍵、確認コード、Cookie、ユーザー原文を含めないでください。" }] },
      channels: { title: "配布版の違い", intro: "違いは UI を隠すだけでなく、ビルド時に強制します。", sections: [{ title: "公式サイト版", body: "スクリーンショット、クリップボード、翻訳、CLI、ActionBroker、選択ヘルパー、内蔵・外部プラグイン。" }, { title: "App Store 対応版", body: "スクリーンショット、クリップボード、手動翻訳、OCR、固定内蔵プラグインを維持し、CLI、ActionBroker、LaunchAgent、ヘルパー連携、外部プラグイン入口を削除します。" }] },
    },
  },
};

export function isLocale(value: string): value is Locale {
  return locales.includes(value as Locale);
}

export function isPageSlug(value: string): value is PageSlug {
  return pageSlugs.includes(value as PageSlug);
}
