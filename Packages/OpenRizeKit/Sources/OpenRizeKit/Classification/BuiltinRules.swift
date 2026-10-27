import Foundation

/// Rules shipped with the app so common apps and sites never need a model call.
public enum BuiltinRules {
    private static let bundleIDs: [String: [String]] = [
        "code": [
            "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
            "dev.zed.Zed", "dev.zed.Zed-Preview", "com.exafunction.windsurf", "com.sublimetext.4", "com.panic.Nova",
            "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce",
            "com.jetbrains.goland", "com.jetbrains.WebStorm", "com.jetbrains.CLion", "com.jetbrains.rider",
            "com.jetbrains.rustrover", "com.jetbrains.datagrip", "com.jetbrains.fleet", "com.google.android.studio",
            "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
            "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
            "com.github.GitHubClient", "com.fournova.Tower3", "com.sublimemerge", "com.git-fork.Fork",
            "com.postmanlabs.mac", "com.insomnia.app", "com.tinyapp.TablePlus", "com.sequel-ace.sequel-ace",
            "com.docker.docker", "com.apple.Instruments", "com.apple.dt.FileMerge", "com.charlesproxy.charles",
            "com.proxyman.NSProxy", "com.anthropic.claudefordesktop", "com.openai.codex",
        ],
        "design": [
            "com.figma.Desktop", "com.bohemiancoding.sketch3", "com.adobe.Photoshop", "com.adobe.illustrator",
            "com.adobe.InDesign", "com.adobe.xd", "com.seriflabs.affinitydesigner2", "com.seriflabs.affinityphoto2",
            "com.pixelmatorteam.pixelmator.x", "com.apple.FinalCut", "com.blackmagic-design.DaVinciResolve",
            "com.adobe.PremierePro", "com.apple.motionapp", "com.apple.iMovieApp", "com.lukilabs.lukiapp",
            "com.apple.Keynote", "io.framer.desktop", "com.sketchup.SketchUp", "org.blenderfoundation.blender",
        ],
        "writing": [
            "com.apple.iWork.Pages", "com.microsoft.Word", "com.ulyssesapp.mac", "abnerworks.Typora",
            "com.literatureandlatte.scrivener3", "pro.writer.mac", "net.shinyfrog.bear", "md.obsidian",
            "com.agiletortoise.Drafts-OSX",
        ],
        "documenting": [
            "notion.id", "com.apple.Preview", "com.readdle.PDFExpert-Mac", "com.adobe.Reader",
            "com.adobe.Acrobat.Pro", "com.kapeli.dashdoc", "com.craft.docs",
        ],
        "productivity": [
            "com.apple.iCal", "com.apple.reminders", "com.apple.Notes", "com.culturedcode.ThingsMac",
            "com.omnigroup.OmniFocus3", "com.omnigroup.OmniFocus4", "com.todoist.mac.Todoist", "com.flexibits.fantastical2.mac",
            "com.apple.iWork.Numbers", "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.microsoft.onenote.mac",
            "com.linear", "com.electron.logseq", "com.amazon.Kindle",
        ],
        "email": [
            "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron",
            "it.bloop.airmail2", "com.mimestream.Mimestream", "com.tinyspeck.slackmacgap.mail",
        ],
        "messaging": [
            "com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "com.hnc.Discord", "ru.keepcoder.Telegram",
            "org.telegram.desktop", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.tencent.xinWeChat",
            "com.tencent.qq", "com.bytedance.macos.feishu", "com.electron.lark", "com.alibaba.DingTalkMac",
            "com.microsoft.teams2.chat", "jp.naver.line.mac", "org.whispersystems.signal-desktop",
            "com.facebook.archon", "com.microsoft.teams2",
        ],
        "video_conferencing": [
            "us.zoom.xos", "com.apple.FaceTime", "com.cisco.webexmeetingsapp", "com.tencent.meeting",
            "com.webex.meetingmanager", "com.logmein.GoToMeeting",
        ],
        "utility": [
            "com.apple.finder", "com.apple.systempreferences", "com.apple.ActivityMonitor", "com.apple.Console",
            "com.apple.AppStore", "com.apple.calculator", "com.apple.dock", "com.apple.loginwindow",
            "com.apple.Passwords", "com.1password.1password", "com.agilebits.onepassword7", "com.raycast.macos",
            "com.runningwithcrayons.Alfred", "com.apple.archiveutility", "com.apple.DiskUtility",
            "com.apple.ScreenSharing", "com.apple.screenshot.launcher", "com.cleanshot.CleanShot-X",
            "com.apple.Spotlight", "com.apple.controlcenter", "io.github.openrize.OpenRize",
            "com.abue-ammar.tinycast", "com.apple.UserNotificationCenter", "com.apple.SecurityAgent",
            "com.apple.coreservices.uiagent",
        ],
        "entertainment": [
            "com.apple.TV", "com.apple.Music", "com.spotify.client", "com.netflix.Netflix", "com.apple.podcasts",
            "com.netease.163music", "com.tencent.QQMusicMac", "com.colliderli.iina", "org.videolan.vlc",
            "tv.danmaku.bilianime", "com.apple.news",
        ],
        "gaming": [
            "com.valvesoftware.steam", "com.epicgames.EpicGamesLauncher", "com.blizzard.worldofwarcraft",
            "net.battle.app", "com.apple.Chess", "com.riotgames.LeagueofLegends.LeagueClient",
        ],
        "finance": [
            "com.moneymoney-app.retail", "com.apple.stocks", "com.futu.FutuOpenD", "com.futunn.FutuNiuNiu",
        ],
        "browsing": BrowserURLScripts.supportedBundleIDs + ["org.mozilla.firefox", "app.zen-browser.zen"],
    ]

    private static let domains: [String: [String]] = [
        "code": [
            "github.com", "gitlab.com", "bitbucket.org", "stackoverflow.com", "stackexchange.com",
            "developer.apple.com", "developer.mozilla.org", "docs.rs", "crates.io", "npmjs.com", "pypi.org",
            "swift.org", "vercel.com", "netlify.com", "cloudflare.com", "console.aws.amazon.com",
            "console.cloud.google.com", "portal.azure.com", "localhost", "127.0.0.1", "codesandbox.io",
            "replit.com", "huggingface.co", "kaggle.com", "sentry.io", "gitee.com", "v2ex.com", "juejin.cn",
            "pkg.go.dev", "docs.python.org", "go.dev", "rust-lang.org", "kotlinlang.org", "android.com",
        ],
        "design": ["figma.com", "dribbble.com", "behance.net", "canva.com", "excalidraw.com", "framer.com", "unsplash.com"],
        "writing": ["docs.google.com", "medium.com", "substack.com", "overleaf.com", "yuque.com"],
        "documenting": ["notion.so", "notion.site", "confluence.atlassian.net", "readthedocs.io", "gitbook.io", "feishu.cn", "larksuite.com"],
        "research": [
            "google.com", "bing.com", "duckduckgo.com", "baidu.com", "kagi.com", "perplexity.ai",
            "wikipedia.org", "arxiv.org", "scholar.google.com", "chatgpt.com", "claude.ai", "gemini.google.com",
            "news.ycombinator.com", "zhihu.com",
        ],
        "learning": ["coursera.org", "udemy.com", "edx.org", "khanacademy.org", "leetcode.com", "leetcode.cn", "duolingo.com", "brilliant.org"],
        "product": ["linear.app", "jira.atlassian.net", "atlassian.net", "trello.com", "asana.com", "clickup.com", "productboard.com", "monday.com"],
        "productivity": [
            "calendar.google.com", "sheets.google.com", "drive.google.com", "airtable.com", "todoist.com",
            "miro.com", "dropbox.com", "icloud.com", "onedrive.live.com",
        ],
        "email": ["mail.google.com", "outlook.live.com", "outlook.office.com", "mail.qq.com", "mail.163.com", "fastmail.com", "proton.me"],
        "messaging": [
            "slack.com", "app.slack.com", "discord.com", "web.whatsapp.com", "web.telegram.org", "messenger.com",
            "wx.qq.com", "teams.microsoft.com",
        ],
        "video_conferencing": ["meet.google.com", "zoom.us", "whereby.com", "meeting.tencent.com"],
        "finance": ["paypal.com", "stripe.com", "wise.com", "xueqiu.com", "tradingview.com"],
        "marketing": ["analytics.google.com", "ads.google.com", "mailchimp.com", "plausible.io", "search.google.com"],
        "sales": ["salesforce.com", "hubspot.com", "pipedrive.com"],
        "customer_support": ["zendesk.com", "intercom.com", "freshdesk.com", "help.scoutapp.com"],
        "entertainment": [
            "youtube.com", "netflix.com", "twitch.tv", "bilibili.com", "iqiyi.com", "youku.com", "v.qq.com",
            "spotify.com", "music.163.com", "primevideo.com", "disneyplus.com", "hulu.com", "9gag.com",
            "douyu.com", "huya.com",
        ],
        "social_media": [
            "x.com", "twitter.com", "facebook.com", "instagram.com", "reddit.com", "tiktok.com", "douyin.com",
            "weibo.com", "xiaohongshu.com", "threads.net", "linkedin.com", "pinterest.com", "bsky.app",
            "mastodon.social", "tieba.baidu.com", "douban.com",
        ],
        "shopping": [
            "amazon.com", "amazon.cn", "taobao.com", "tmall.com", "jd.com", "pinduoduo.com", "ebay.com",
            "aliexpress.com", "etsy.com", "smzdm.com",
        ],
        "gaming": ["store.steampowered.com", "steamcommunity.com", "epicgames.com", "chess.com", "lichess.org"],
    ]

    public static let all: [Rule] = {
        var rules: [Rule] = []
        for (category, ids) in bundleIDs {
            rules += ids.map { Rule(field: .bundleID, pattern: $0, categoryKey: category, source: .builtin) }
        }
        for (category, hosts) in domains {
            rules += hosts.map { Rule(field: .domain, pattern: $0, categoryKey: category, source: .builtin) }
        }
        return rules
    }()
}
