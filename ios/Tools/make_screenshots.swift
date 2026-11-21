import AppKit
import Foundation

// Builds App Store screenshots at the 6.9" size Apple asks for (1320x2868).
//
//   swift Tools/make_screenshots.swift <shots-dir> <out-dir>
//
// Each frame is a headline over a device screen, on the app's own near-black
// ground with a soft neutral glow. The screens are real captures, not mockups — the
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
let ground = rgb(10, 10, 11)
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

// 3.0 (2026-11-20): benchmarked against SwingVision, Clutch, PerfectSwing and
// others — none says "send your partner the match without the dead time", and
// only one shows a before/after. Frame 1 leads with that, full-bleed footage
// from the test sample (~/Downloads/IMG_0939.MOV) and its measured numbers.
// Numbers here must come from a real run: 15:09 of video, 14 rallies, 2:53.
// No shot counts or "every rally" — both can be wrong.
//
// [headline line 1, line 2, sub] per frame, per locale.
var copy: [String: [[String]]] = [
    "en": [["YOUR WHOLE MATCH.", "JUST THE RALLIES.", "Example match: 15:09 of video, 2:53 of rallies."],
           ["SEND IT TO", "YOUR PARTNER", "All the rallies in one video, point by point."],
           ["FOUND BY THE", "SOUND OF THE BALL", "Tennis, padel, pickleball, badminton. The dead time is cut for you."],
           ["A 30-SECOND REEL", "IN ONE TAP", "Vertical, best rally first, ready to post."],
           ["SLOW-MO, FREEZE,", "REPLAY THE WINNER", "One tap snaps zoom and slow motion to the shot."],
           ["CAPTIONS, ZOOM,", "STICKERS. FREE.", "The whole editor is free. Text anywhere, keyframes, color."],
           ["YOUR VIDEO", "STAYS ON YOUR PHONE", "Detection and editing run on your iPhone. No account."]],
    "ko": [["경기 전체에서", "랠리만 쏙.", "예시 경기: 영상 15:09 → 랠리 2:53"],
           ["복식 파트너에게", "바로 보내기", "랠리만 이은 영상 하나로 포인트마다 넘겨 봐요."],
           ["공 소리로", "랠리를 찾아요", "테니스·파델·피클볼·배드민턴. 쉬는 시간은 알아서 잘라요."],
           ["탭 한 번에", "30초 릴스", "세로 영상, 베스트 랠리부터. 바로 올리세요."],
           ["슬로모션·정지·", "위닝샷 리플레이", "탭 한 번이면 그 타구에 줌과 슬로모션이 붙어요."],
           ["자막·줌·스티커,", "전부 무료", "편집기는 모두 무료. 어디든 자막, 키프레임, 색감."],
           ["영상은", "내 폰에만", "감지와 편집이 모두 iPhone에서 돌아요. 계정도 없어요."]],
    "ja": [["試合まるごと、", "ラリーだけ。", "試合例: 動画 15:09 → ラリー 2:53"],
           ["ダブルスの相方に", "そのまま送る", "ラリーだけをつないだ動画で、ポイントごとに見返せます。"],
           ["打球音で", "ラリーを検出", "テニス・パデル・ピックルボール・バドミントン。待ち時間は自動でカット。"],
           ["ワンタップで", "30秒リール", "縦型で、ベストラリーから。すぐ投稿できます。"],
           ["スロー・静止・", "決めの一打をリプレイ", "ワンタップでその一打にズームとスローが付きます。"],
           ["字幕・ズーム・", "スタンプ。無料。", "編集機能はすべて無料。好きな位置に字幕、キーフレーム、カラー。"],
           ["動画は", "あなたのiPhoneだけに", "検出も編集もiPhoneの中だけ。アカウントも不要です。"]],
    "es": [["TODO EL PARTIDO.", "SOLO LOS PUNTOS.", "Partido de ejemplo: 15:09 de vídeo, 2:53 de puntos."],
           ["ENVÍASELO", "A TU PAREJA", "Todos los puntos en un vídeo, de punto en punto."],
           ["LO ENCUENTRA POR", "EL SONIDO DE LA BOLA", "Tenis, pádel, pickleball, bádminton. Los tiempos muertos se cortan solos."],
           ["UN REEL DE 30 S", "CON UN TOQUE", "En vertical, el mejor punto primero, listo para publicar."],
           ["CÁMARA LENTA, PAUSA,", "REPETICIÓN DEL GANADOR", "Un toque añade zoom y cámara lenta al golpe."],
           ["SUBTÍTULOS, ZOOM,", "STICKERS. GRATIS.", "Todo el editor es gratis. Texto donde quieras, fotogramas clave, color."],
           ["TU VÍDEO", "SE QUEDA EN TU MÓVIL", "La detección y la edición ocurren en tu iPhone. Sin cuenta."]],
    "pt": [["A PARTIDA INTEIRA.", "SÓ OS PONTOS.", "Partida de exemplo: 15:09 de vídeo, 2:53 de pontos."],
           ["MANDE PARA", "SUA DUPLA", "Todos os pontos em um vídeo, de ponto em ponto."],
           ["ACHADOS PELO", "SOM DA BOLA", "Tênis, padel, pickleball, badminton. O tempo morto é cortado sozinho."],
           ["UM REEL DE 30 S", "EM UM TOQUE", "Na vertical, o melhor ponto primeiro, pronto para postar."],
           ["CÂMERA LENTA, PAUSA,", "REPLAY DO VENCEDOR", "Um toque coloca zoom e câmera lenta no golpe."],
           ["LEGENDAS, ZOOM,", "FIGURINHAS. GRÁTIS.", "O editor inteiro é grátis. Texto onde quiser, quadros-chave, cor."],
           ["SEU VÍDEO", "FICA NO SEU CELULAR", "Detecção e edição acontecem no seu iPhone. Sem conta."]],
    "de": [["DAS GANZE MATCH.", "NUR DIE BALLWECHSEL.", "Beispielmatch: 15:09 Video, 2:53 Ballwechsel."],
           ["SCHICK ES", "DEINEM PARTNER", "Alle Ballwechsel in einem Video, Punkt für Punkt."],
           ["AM KLANG", "DES BALLS ERKANNT", "Tennis, Padel, Pickleball, Badminton. Pausen werden automatisch geschnitten."],
           ["EIN 30-S-REEL", "MIT EINEM TIPPEN", "Hochkant, der beste Ballwechsel zuerst, bereit zum Posten."],
           ["ZEITLUPE, STANDBILD,", "SIEGSCHLAG-REPLAY", "Ein Tippen legt Zoom und Zeitlupe auf den Schlag."],
           ["UNTERTITEL, ZOOM,", "STICKER. KOSTENLOS.", "Der ganze Editor ist kostenlos. Text überall, Keyframes, Farbe."],
           ["DEIN VIDEO", "BLEIBT AUF DEINEM HANDY", "Erkennung und Schnitt laufen auf deinem iPhone. Kein Konto."]],
    "fr": [["TOUT LE MATCH.", "JUSTE LES ÉCHANGES.", "Match d'exemple : 15:09 de vidéo, 2:53 d'échanges."],
           ["ENVOYEZ-LE", "À VOTRE PARTENAIRE", "Tous les échanges dans une vidéo, point par point."],
           ["REPÉRÉS AU", "BRUIT DE LA BALLE", "Tennis, padel, pickleball, badminton. Les temps morts sont coupés pour vous."],
           ["UN REEL DE 30 S", "EN UN TOUCHER", "À la verticale, le meilleur échange d'abord, prêt à publier."],
           ["RALENTI, ARRÊT,", "REPLAY DU COUP GAGNANT", "Un toucher ajoute zoom et ralenti sur le coup."],
           ["SOUS-TITRES, ZOOM,", "STICKERS. GRATUIT.", "Tout l'éditeur est gratuit. Texte partout, images clés, couleur."],
           ["VOTRE VIDÉO", "RESTE SUR VOTRE TÉLÉPHONE", "Détection et montage se font sur votre iPhone. Sans compte."]],
    "it": [["TUTTA LA PARTITA.", "SOLO GLI SCAMBI.", "Partita d'esempio: 15:09 di video, 2:53 di scambi."],
           ["MANDALA AL", "TUO COMPAGNO", "Tutti gli scambi in un video, punto per punto."],
           ["TROVATI DAL", "SUONO DELLA PALLA", "Tennis, padel, pickleball, badminton. I tempi morti si tagliano da soli."],
           ["UN REEL DA 30 S", "CON UN TOCCO", "In verticale, lo scambio migliore per primo, pronto da pubblicare."],
           ["RALLENTY, FERMO,", "REPLAY DEL VINCENTE", "Un tocco aggiunge zoom e rallenty al colpo."],
           ["SOTTOTITOLI, ZOOM,", "STICKER. GRATIS.", "Tutto l'editor è gratis. Testo ovunque, fotogrammi chiave, colore."],
           ["IL TUO VIDEO", "RESTA SUL TUO TELEFONO", "Rilevamento e montaggio avvengono sul tuo iPhone. Nessun account."]],
    "zh-Hans": [["整场比赛，", "只留回合。", "示例比赛：视频 15:09 → 回合 2:53"],
                ["直接发给", "双打搭档", "只含回合的一段视频，可一分一分地看。"],
                ["凭击球声", "找出回合", "网球、板式网球、匹克球、羽毛球。空档自动剪掉。"],
                ["轻点一下", "30 秒竖版视频", "竖屏，最佳回合打头，随时发布。"],
                ["慢动作·定格·", "致胜一击回放", "轻点一下，就给那一击加上缩放和慢动作。"],
                ["字幕·缩放·", "贴纸，全部免费", "编辑器全部免费。随处加字，关键帧，调色。"],
                ["视频只在", "你的手机里", "识别和剪辑都在 iPhone 上完成。无需账号。"]],
]
let files = ["hero_still.jpg", "s2_partner.png", "s3_found.png", "s4_reel.png", "s5_moments.png", "s6_captions.png", "s7_privacy.png"]
let frames: [Frame] = files.enumerated().map { i, f in
    let c = (copy[locale] ?? copy["en"]!)[i]
    return Frame(file: f, headline: [c[0], c[1]], sub: c[2], full: f == "hero_still.jpg")
}

/// Frame 1: the footage fills the frame, headline on a top scrim, and the
/// before/after bars on a bottom one. The bars are the measured run, drawn to
/// scale (2:53 is 19% of 15:09).
func drawHero(_ f: Frame, _ g: CGContext, _ cg: CGImage) {
    // Portrait window on the player (left third of the 4K frame).
    let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
    let cropW = ih * W / H
    let cx = iw * 0.36
    let crop = CGRect(x: max(0, min(iw - cropW, cx - cropW / 2)), y: 0, width: cropW, height: ih)
    if let part = cg.cropping(to: crop) { g.draw(part, in: CGRect(x: 0, y: 0, width: W, height: H)) }
    func scrim(_ y0: CGFloat, _ y1: CGFloat, _ a0: CGFloat, _ a1: CGFloat) {
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor.black.withAlphaComponent(a0).cgColor,
                                       NSColor.black.withAlphaComponent(a1).cgColor] as CFArray,
                              locations: [0, 1])!
        g.drawLinearGradient(grad, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
    }
    scrim(H, H * 0.62, 0.85, 0)
    scrim(0, H * 0.34, 0.9, 0)

    let margin: CGFloat = 90
    var y = H - 210
    var size: CGFloat = 150
    while size > 80, f.headline.contains(where: {
        NSAttributedString(string: $0, attributes: [.font: display(size), .kern: 1.5]).size().width > W - margin * 2
    }) { size -= 4 }
    for (i, line) in f.headline.enumerated() {
        let font = display(size)
        NSAttributedString(string: line, attributes: [.font: font, .kern: 1.5,
            .foregroundColor: i == 1 ? volt : NSColor.white]).draw(at: CGPoint(x: margin, y: y - font.ascender))
        y -= size * 1.12
    }

    // Bars, bottom up: caption, rallies bar, video bar.
    let barW = W - margin * 2, barH: CGFloat = 46
    let video: Double = 909, rallies: Double = 172.6
    let label = body(44, .semibold)
    let parts = f.sub.replacingOccurrences(of: "：", with: ": ").components(separatedBy: ":")
    let caption = parts.count > 1 ? parts[0] : ""
    NSAttributedString(string: caption, attributes: [.font: body(36), .foregroundColor: dim])
        .draw(at: CGPoint(x: margin, y: 150))
    func bar(_ y: CGFloat, _ frac: CGFloat, _ color: NSColor, _ name: String, _ time: String) {
        let track = CGPath(roundedRect: CGRect(x: margin, y: y, width: barW, height: barH),
                           cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil)
        g.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor); g.addPath(track); g.fillPath()
        let fill = CGPath(roundedRect: CGRect(x: margin, y: y, width: max(barH, barW * frac), height: barH),
                          cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil)
        g.setFillColor(color.cgColor); g.addPath(fill); g.fillPath()
        NSAttributedString(string: name, attributes: [.font: label, .foregroundColor: NSColor.white])
            .draw(at: CGPoint(x: margin, y: y + barH + 14))
        let t = NSAttributedString(string: time, attributes: [.font: display(64), .foregroundColor: color == volt ? volt : NSColor.white])
        t.draw(at: CGPoint(x: margin + barW - t.size().width, y: y + barH + 6))
    }
    let names = ["ko": ["영상", "랠리만"], "ja": ["動画", "ラリーだけ"], "es": ["Vídeo", "Solo los puntos"],
                 "pt": ["Vídeo", "Só os pontos"], "de": ["Video", "Nur die Ballwechsel"],
                 "fr": ["Vidéo", "Juste les échanges"], "it": ["Video", "Solo gli scambi"],
                 "zh-Hans": ["视频", "只留回合"]][locale] ?? ["Video", "Just the rallies"]
    bar(430, 1, rgb(150, 150, 156), names[0], "15:09")
    bar(240, CGFloat(rallies / video), volt, names[1], "2:53")
}

func draw(_ f: Frame, index: Int) {
    // Lets one new frame be made without every other capture on hand.
    guard FileManager.default.fileExists(atPath: shots.appendingPathComponent(f.file).path) else {
        print("skip", f.file, "(no capture)"); return
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                               bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,  // App Store rejects alpha
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 32)!
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let g = ctx.cgContext

    // ground + a neutral glow behind the headline. Volt at any low alpha
    // over near-black mixes to olive, the look the 2026-10-30 palette dropped.
    g.setFillColor(ground.cgColor)
    g.fill(CGRect(x: 0, y: 0, width: W, height: H))
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [NSColor.white.withAlphaComponent(0.09).cgColor,
                                      NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                             locations: [0, 1]) {
        g.drawRadialGradient(grad, startCenter: CGPoint(x: W * 0.5, y: H * 0.86),
                             startRadius: 0, endCenter: CGPoint(x: W * 0.5, y: H * 0.86),
                             endRadius: W * 0.95, options: [])
    }

    // Frame 1 is its own layout: footage full-bleed with the before/after bars.
    if f.full, let img = NSImage(contentsOf: shots.appendingPathComponent(f.file)),
       let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        drawHero(f, g, cg)
        NSGraphicsContext.restoreGraphicsState()
        save(rep, f, index)
        return
    }

    let margin: CGFloat = 90
    var y = H - 250     // AppKit's origin is bottom-left; we lay out downward
    // Apple bars "NEW" in previews; the old chip is gone from screenshots too.
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

    // sub-line: one sentence per line, so wrapping never breaks mid-phrase
    // ("…nunca sale de / tu iPhone"). The box grows if a sentence still wraps.
    y -= 34
    let para = NSMutableParagraphStyle(); para.lineSpacing = 10
    let lines = f.sub.replacingOccurrences(of: ". ", with: ".\n")
        .replacingOccurrences(of: "。", with: "。\n")
        .trimmingCharacters(in: .newlines)
    let sub = NSAttributedString(string: lines, attributes: [
        .font: body(46), .foregroundColor: dim, .paragraphStyle: para])
    let subW = W - margin * 2 - 40
    let subH = ceil(sub.boundingRect(with: CGSize(width: subW, height: 1000),
                                     options: [.usesLineFragmentOrigin]).height)
    sub.draw(with: CGRect(x: margin, y: y - subH, width: subW, height: subH),
             options: [.usesLineFragmentOrigin])
    y -= subH + 18

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
    save(rep, f, index)
}

func save(_ rep: NSBitmapImageRep, _ f: Frame, _ index: Int) {
    let name = f.file.replacingOccurrences(of: ".png", with: "").replacingOccurrences(of: ".jpg", with: "")
    let url = outDir.appendingPathComponent(String(format: "%02d_%@.png", index + 1, name))
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: url)
        print("wrote", url.lastPathComponent)
    }
}

for (i, f) in frames.enumerated() { draw(f, index: i) }
