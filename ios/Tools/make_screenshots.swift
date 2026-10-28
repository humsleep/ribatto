import AppKit
import Foundation

// Builds App Store screenshots at the 6.9" size Apple asks for (1320x2868).
//
//   swift Tools/make_screenshots.swift <shots-dir> <out-dir>
//
// Each frame is a headline over a device screen, on the app's own near-black
// ground with a volt glow. The screens are real captures, not mockups — the
// only thing added is the text a store listing needs, because the first frame
// is read at thumbnail size in search results and a bare screenshot says
// nothing there.
//
// The hero frame uses a rendered 9:16 clip instead of a UI screen: what the app
// produces sells it better than what the app looks like.

// Usage: swift Tools/make_screenshots.swift <shots-dir> <out-dir> [locale]
// The locale (en ko ja es pt de fr it zh-Hans, default en) picks the copy.
// Captures are read from <shots-dir>; frames go to <out-dir>.
let shots = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
let locale = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "en"
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let W: CGFloat = 1320, H: CGFloat = 2868

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}
let volt = rgb(212, 255, 63)
let ground = rgb(11, 12, 10)
// Lifted from 150/156/168: that read 3.3:1 on the glow.
let dim = rgb(180, 186, 198)

// The bundled display face, so the store frames and the burned-in overlays are
// visibly the same product. Anton is Latin only: Korean, Japanese and Chinese
// headlines take the system's heaviest compressed face instead of a fallback.
for name in ["Anton-Regular", "BebasNeue-Regular"] {
    let u = URL(fileURLWithPath: "Ribatto/Fonts/\(name).ttf")
    CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil)
}
let cjk = ["ko", "ja", "zh-Hans"].contains(locale)
func display(_ size: CGFloat) -> NSFont {
    if cjk {
        let base = NSFont.systemFont(ofSize: size * 0.82, weight: .black)
        let d = base.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.width: -0.3,
                                                                 NSFontDescriptor.TraitKey.weight: NSFont.Weight.black]])
        return NSFont(descriptor: d, size: size * 0.82) ?? base
    }
    return NSFont(name: "Anton", size: size) ?? .systemFont(ofSize: size, weight: .black)
}
func body(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
    .systemFont(ofSize: size, weight: weight)
}

struct Frame {
    let file: String          // image in shots dir
    let headline: [String]    // one entry per line
    let sub: String
    let full: Bool            // true = image fills the frame (the hero clip)
}

// [headline line 1, line 2, sub] per frame, per locale. Platform names stay
// out of the copy (guideline 2.3.7 risk); the app's own words for rally and
// season are used so the frames match the UI.
let copy: [String: [[String]]] = [
    "en": [["ONE TAP,", "MATCH TO REEL", "Every rally found and cut vertical, ready to post."],
           ["SKIP THE", "DEAD TIME", "A 30-minute match becomes the rallies worth watching."],
           ["FOUND BY", "SOUND", "It listens for the strike. Your best rally plays the moment detection ends."],
           ["BEST RALLIES,", "ONE REEL", "One tap makes a 30-second reel, best rally first. Post it."],
           ["YOUR SEASON,", "COUNTED", "Every rally, every court. Your video never leaves your iPhone."]],
    "ko": [["탭 한 번에", "경기가 릴스로", "랠리를 모두 찾아 세로로 잘라 두었어요. 바로 올리세요."],
           ["쉬는 시간은", "건너뛰기", "30분 경기가 볼 만한 랠리만 남습니다."],
           ["소리로", "랠리를 찾다", "타구음을 듣고 찾아냅니다. 감지가 끝나면 베스트 랠리부터 재생돼요."],
           ["베스트 랠리를", "릴스 하나로", "탭 한 번에 30초 릴스, 베스트 랠리부터. 바로 올리세요."],
           ["나의 시즌을", "기록으로", "모든 랠리, 모든 코트. 영상은 iPhone 밖으로 나가지 않습니다."]],
    "ja": [["ワンタップで", "試合がリールに", "ラリーをすべて見つけて縦型にカット。すぐ投稿できます。"],
           ["休憩は", "スキップ", "30分の試合が、見る価値のあるラリーだけに。"],
           ["音で", "ラリーを検出", "打球音を聞き分けます。検出が終わるとベストラリーから再生。"],
           ["ベストラリーを", "1本のリールに", "ワンタップで30秒のリール、ベストラリーから。そのまま投稿。"],
           ["シーズンを", "記録に", "すべてのラリー、すべてのコート。動画はiPhoneの外に出ません。"]],
    "es": [["UN TOQUE,", "DEL PARTIDO AL REEL", "Encuentra cada punto y lo recorta en vertical, listo para publicar."],
           ["SIN TIEMPOS", "MUERTOS", "Un partido de 30 minutos se queda en los puntos que vale la pena ver."],
           ["LO ENCUENTRA", "POR EL SONIDO", "Escucha cada golpe. Tu mejor punto se reproduce en cuanto termina la detección."],
           ["TUS MEJORES PUNTOS,", "UN REEL", "Un toque crea un reel de 30 segundos, con el mejor punto primero. Publícalo."],
           ["TU TEMPORADA,", "EN NÚMEROS", "Cada punto, cada pista. Tu vídeo nunca sale de tu iPhone."]],
    "pt": [["UM TOQUE,", "DA PARTIDA AO REEL", "Encontra cada ponto e corta na vertical, pronto para postar."],
           ["SEM TEMPO", "MORTO", "Uma partida de 30 minutos vira só os pontos que valem a pena."],
           ["ACHADO", "PELO SOM", "Ele ouve cada batida. Seu melhor ponto toca assim que a detecção termina."],
           ["SEUS MELHORES PONTOS,", "UM REEL", "Um toque cria um reel de 30 segundos, o melhor ponto primeiro. Poste."],
           ["SUA TEMPORADA,", "EM NÚMEROS", "Cada ponto, cada quadra. Seu vídeo nunca sai do seu iPhone."]],
    "de": [["EIN TIPPEN,", "VOM MATCH ZUM REEL", "Jeder Ballwechsel gefunden und hochkant geschnitten – bereit zum Posten."],
           ["OHNE", "LEERLAUF", "Aus 30 Minuten Match werden die Ballwechsel, die sich lohnen."],
           ["AM KLANG", "ERKANNT", "Es hört jeden Schlag. Dein bester Ballwechsel läuft, sobald die Erkennung fertig ist."],
           ["DIE BESTEN BALLWECHSEL,", "EIN REEL", "Ein Tippen macht ein 30-Sekunden-Reel, der beste Ballwechsel zuerst. Posten."],
           ["DEINE SAISON,", "GEZÄHLT", "Jeder Ballwechsel, jeder Platz. Dein Video verlässt nie dein iPhone."]],
    "fr": [["UN TOUCHER,", "DU MATCH AU REEL", "Chaque échange trouvé et recadré à la verticale, prêt à publier."],
           ["FINI LES", "TEMPS MORTS", "Un match de 30 minutes devient les échanges qui valent le coup."],
           ["TROUVÉ", "AU SON", "Il écoute chaque frappe. Votre meilleur échange démarre dès la fin de la détection."],
           ["VOS MEILLEURS ÉCHANGES,", "UN REEL", "Un toucher crée un reel de 30 secondes, meilleur échange en premier. Publiez-le."],
           ["VOTRE SAISON,", "EN CHIFFRES", "Chaque échange, chaque court. Votre vidéo ne quitte jamais votre iPhone."]],
    "it": [["UN TOCCO,", "DALLA PARTITA AL REEL", "Ogni scambio trovato e tagliato in verticale, pronto da pubblicare."],
           ["NIENTE", "TEMPI MORTI", "Una partita di 30 minuti diventa solo gli scambi che vale la pena vedere."],
           ["TROVATO", "DAL SUONO", "Ascolta ogni colpo. Il tuo scambio migliore parte appena finisce il rilevamento."],
           ["I TUOI MIGLIORI SCAMBI,", "UN REEL", "Un tocco crea un reel di 30 secondi, lo scambio migliore per primo. Pubblicalo."],
           ["LA TUA STAGIONE,", "IN NUMERI", "Ogni scambio, ogni campo. Il tuo video non lascia mai il tuo iPhone."]],
    "zh-Hans": [["轻点一下", "比赛变竖版视频", "找出每一个回合，裁成竖屏，随时发布。"],
                ["跳过", "无聊时间", "30 分钟的比赛，只留下值得看的回合。"],
                ["听声音", "找回合", "它能听出每一次击球。检测一结束，最佳回合就开始播放。"],
                ["最佳回合", "一条竖版视频", "轻点一下生成 30 秒竖版视频，最佳回合打头。直接发布。"],
                ["你的赛季", "尽在记录", "每个回合，每块球场。你的视频从不离开你的 iPhone。"]],
]
let files = ["hero.jpg", "s1_library.png", "s2_session.png", "s3_reel.png", "s4_season.png"]
let frames: [Frame] = files.enumerated().map { i, f in
    let c = (copy[locale] ?? copy["en"]!)[i]
    return Frame(file: f, headline: [c[0], c[1]], sub: c[2], full: i == 0)
}

func draw(_ f: Frame, index: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let g = ctx.cgContext

    // ground + a volt glow behind the headline
    g.setFillColor(ground.cgColor)
    g.fill(CGRect(x: 0, y: 0, width: W, height: H))
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [volt.withAlphaComponent(0.28).cgColor,
                                      volt.withAlphaComponent(0).cgColor] as CFArray,
                             locations: [0, 1]) {
        g.drawRadialGradient(grad, startCenter: CGPoint(x: W * 0.5, y: H * 0.86),
                             startRadius: 0, endCenter: CGPoint(x: W * 0.5, y: H * 0.86),
                             endRadius: W * 0.95, options: [])
    }

    let margin: CGFloat = 90
    var y = H - 250     // AppKit's origin is bottom-left; we lay out downward

    // Headline. Sized to dominate: in search results this frame is a thumbnail
    // and the words are the only thing that survives the shrink.
    // One size for both lines, shrunk until the longest fits: "DALLA PARTITA
    // AL REEL" is half again as wide as "MATCH TO REEL".
    var size: CGFloat = 150
    let maxLine = W - margin * 2
    while size > 80, f.headline.contains(where: {
        NSAttributedString(string: $0, attributes: [.font: display(size), .kern: 1.5]).size().width > maxLine
    }) { size -= 4 }
    for line in f.headline {
        let font = display(size)
        let at: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white,
                                                 .kern: 1.5]
        let s = NSAttributedString(string: line, attributes: at)
        s.draw(at: CGPoint(x: margin, y: y - font.ascender))
        // Room for capital accents (Ä, É) above the second line.
        y -= size * 1.12
    }

    // sub-line, wrapped
    y -= 34
    let para = NSMutableParagraphStyle(); para.lineSpacing = 10
    let sub = NSAttributedString(string: f.sub, attributes: [
        .font: body(46), .foregroundColor: dim, .paragraphStyle: para])
    let subBox = CGRect(x: margin, y: y - 150, width: W - margin * 2 - 40, height: 150)
    sub.draw(with: subBox, options: [.usesLineFragmentOrigin])
    y -= 168

    // The screen, run off the bottom edge so it reads as a device in hand
    // rather than a stamp floating in a box.
    let img = NSImage(contentsOf: shots.appendingPathComponent(f.file))
    if let img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        let bleed: CGFloat = 150
        let availH = y + bleed
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        let maxW = W - margin * 2 + 40
        let scale = min(maxW / iw, availH / ih)
        let w = iw * scale, h = ih * scale
        let rect = CGRect(x: (W - w) / 2, y: y - h, width: w, height: h)
        let radius: CGFloat = f.full ? 44 : 52
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                          transform: nil)
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: -18), blur: 60,
                    color: NSColor.black.withAlphaComponent(0.75).cgColor)
        g.setFillColor(ground.cgColor)
        g.addPath(path); g.fillPath()
        g.restoreGState()
        g.saveGState()
        g.addPath(path); g.clip()
        g.draw(cg, in: rect)
        g.restoreGState()
        g.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        g.setLineWidth(3)
        g.addPath(path); g.strokePath()
    }

    NSGraphicsContext.restoreGraphicsState()
    let url = outDir.appendingPathComponent(String(format: "%02d_%@.png", index + 1,
                                                   f.file.replacingOccurrences(of: ".png", with: "")
                                                        .replacingOccurrences(of: ".jpg", with: "")))
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: url)
        print("wrote", url.lastPathComponent)
    }
}

for (i, f) in frames.enumerated() { draw(f, index: i) }
