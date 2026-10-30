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

// [headline line 1, line 2, sub] per frame, per locale. Platform names stay
// out of the copy (guideline 2.3.7 risk); the app's own words for rally and
// season are used so the frames match the UI.
var copy: [String: [[String]]] = [
    "en": [["ONE TAP,", "MATCH TO REEL", "Every rally found by its sound and cut vertical, ready to post."],
           ["EDIT IT", "YOUR WAY", "Text anywhere, zoom keyframes, slow motion, color looks. All free."],
           ["FOUND BY", "SOUND", "It hears every strike and cuts the dead time. Best rally first."],
           ["ZOOM IN ON", "THE WINNER", "Zoom and pan keyframes on a real timeline. Slow the last shot to 0.5×."],
           ["30 SECONDS,", "BEST FIRST", "One tap makes a vertical reel, best rally first. Share it anywhere."],
           ["YOUR SEASON,", "COUNTED", "Every rally, every court. Your video never leaves your iPhone."]],
    "ko": [["탭 한 번에", "경기가 릴스로", "타구음으로 랠리를 모두 찾아 세로로 잘라 둡니다. 바로 올리세요."],
           ["내 마음대로", "편집하기", "자막은 원하는 곳에, 줌 키프레임, 슬로모션, 색감까지. 전부 무료."],
           ["소리로", "랠리를 찾다", "타구음을 듣고 쉬는 시간은 잘라냅니다. 베스트 랠리부터."],
           ["위닝샷을", "크게 당겨서", "타임라인에 줌·이동 키프레임을. 마지막 샷은 0.5× 슬로로."],
           ["30초 릴스,", "베스트부터", "탭 한 번에 세로 릴스, 베스트 랠리가 먼저. 어디든 공유하세요."],
           ["나의 시즌을", "기록으로", "모든 랠리, 모든 코트. 영상은 iPhone 밖으로 나가지 않습니다."]],
    "ja": [["ワンタップで", "試合がリールに", "打球音でラリーをすべて見つけ、縦型にカット。すぐ投稿できます。"],
           ["思いどおりに", "編集", "テキストは好きな位置に。ズーム、スロー、カラーまで。すべて無料。"],
           ["音で", "ラリーを検出", "打球音を聞き分けて空き時間をカット。ベストラリーから。"],
           ["決めの一打を", "ズームで", "タイムラインでズームと移動のキーフレーム。最後の一打は0.5×スローで。"],
           ["30秒リール、", "ベストから", "ワンタップで縦型リール。ベストラリーが最初。どこでもシェア。"],
           ["シーズンを", "記録に", "すべてのラリー、すべてのコート。動画はiPhoneの外に出ません。"]],
    "es": [["UN TOQUE,", "DEL PARTIDO AL REEL", "Encuentra cada punto por el sonido y lo corta en vertical. Publícalo."],
           ["EDÍTALO", "A TU MANERA", "Texto donde quieras, zoom, cámara lenta y colores. Todo gratis."],
           ["LO ENCUENTRA", "POR EL SONIDO", "Escucha cada golpe y quita los tiempos muertos. El mejor punto, primero."],
           ["ZOOM AL", "GOLPE GANADOR", "Fotogramas clave de zoom en la línea de tiempo. El último golpe a 0,5×."],
           ["30 SEGUNDOS,", "LO MEJOR PRIMERO", "Un toque crea un reel vertical con tu mejor punto primero. Compártelo."],
           ["TU TEMPORADA,", "EN NÚMEROS", "Cada punto, cada pista. Tu vídeo nunca sale de tu iPhone."]],
    "pt": [["UM TOQUE,", "DA PARTIDA AO REEL", "Acha cada ponto pelo som e corta na vertical. Pronto para postar."],
           ["EDITE DO", "SEU JEITO", "Texto onde quiser, zoom, câmera lenta e cores. Tudo grátis."],
           ["ACHADO", "PELO SOM", "Ouve cada batida e corta o tempo morto. O melhor ponto primeiro."],
           ["ZOOM NO", "GOLPE DECISIVO", "Quadros-chave de zoom na linha do tempo. O último golpe a 0,5×."],
           ["30 SEGUNDOS,", "O MELHOR PRIMEIRO", "Um toque cria um reel vertical com o melhor ponto primeiro. Compartilhe."],
           ["SUA TEMPORADA,", "EM NÚMEROS", "Cada ponto, cada quadra. Seu vídeo nunca sai do seu iPhone."]],
    "de": [["EIN TIPPEN,", "VOM MATCH ZUM REEL", "Jeder Ballwechsel am Klang erkannt und hochkant geschnitten."],
           ["SCHNEIDE,", "WIE DU WILLST", "Text überall, Zoom-Keyframes, Zeitlupe, Farblooks. Alles kostenlos."],
           ["AM KLANG", "ERKANNT", "Es hört jeden Schlag und schneidet Pausen weg. Der beste zuerst."],
           ["ZOOM AUF DEN", "SIEGSCHLAG", "Zoom- und Schwenk-Keyframes auf der Zeitleiste. Letzter Schlag in 0,5×."],
           ["30 SEKUNDEN,", "DAS BESTE ZUERST", "Ein Tippen macht ein Hochkant-Reel, der beste Ballwechsel zuerst."],
           ["DEINE SAISON,", "GEZÄHLT", "Jeder Ballwechsel, jeder Platz. Dein Video verlässt nie dein iPhone."]],
    "fr": [["UN TOUCHER,", "DU MATCH AU REEL", "Chaque échange repéré au son et recadré à la verticale, prêt à publier."],
           ["MONTEZ", "À VOTRE FAÇON", "Texte où vous voulez, zoom, ralenti, looks couleur. Tout est gratuit."],
           ["TROUVÉ", "AU SON", "Il écoute chaque frappe et coupe les temps morts. Le meilleur d'abord."],
           ["ZOOMEZ SUR", "LE COUP GAGNANT", "Images clés de zoom sur la timeline. Le dernier coup ralenti à 0,5×."],
           ["30 SECONDES,", "LE MEILLEUR D'ABORD", "Un toucher crée un reel vertical, meilleur échange en premier. Partagez."],
           ["VOTRE SAISON,", "EN CHIFFRES", "Chaque échange, chaque court. Votre vidéo ne quitte jamais votre iPhone."]],
    "it": [["UN TOCCO,", "DAL MATCH AL REEL", "Ogni scambio riconosciuto dal suono e tagliato in verticale. Pubblicalo."],
           ["MONTA", "A MODO TUO", "Testo ovunque, zoom, rallenty e look colore. Tutto gratis."],
           ["TROVATO", "DAL SUONO", "Ascolta ogni colpo e taglia i tempi morti. Il migliore per primo."],
           ["ZOOM SUL", "COLPO VINCENTE", "Fotogrammi chiave di zoom sulla timeline. L'ultimo colpo a 0,5×."],
           ["30 SECONDI,", "IL MEGLIO PRIMA", "Un tocco crea un reel verticale, lo scambio migliore per primo."],
           ["LA TUA STAGIONE,", "IN NUMERI", "Ogni scambio, ogni campo. Il tuo video non lascia mai il tuo iPhone."]],
    "zh-Hans": [["轻点一下", "比赛变竖版视频", "凭击球声找出每一个回合，裁成竖屏，随时发布。"],
                ["随心", "剪辑", "文字随处摆放，缩放关键帧、慢动作、调色。全部免费。"],
                ["听声音", "找回合", "听出每一次击球，剪掉空闲时间。最佳回合优先。"],
                ["致胜一击", "放大看", "在时间线上设置缩放与平移关键帧，最后一击 0.5× 慢放。"],
                ["30 秒竖版视频", "最佳回合打头", "轻点一下生成竖版视频，最佳回合排第一。随处分享。"],
                ["你的赛季", "尽在记录", "每个回合，每块球场。你的视频从不离开你的 iPhone。"]],
    "pt-PT": [["UM TOQUE,", "DO JOGO AO REEL", "Encontra cada ponto pelo som e corta na vertical. Pronto a publicar."],
              ["EDITE À", "SUA MANEIRA", "Texto onde quiser, zoom, câmara lenta e cores. Tudo grátis."],
              ["ENCONTRADO", "PELO SOM", "Ouve cada pancada e corta o tempo morto. O melhor ponto primeiro."],
              ["ZOOM NO", "PONTO VENCEDOR", "Keyframes de zoom na linha temporal. A última pancada a 0,5×."],
              ["30 SEGUNDOS,", "O MELHOR PRIMEIRO", "Um toque cria um reel vertical com o melhor ponto primeiro. Partilhe."],
              ["A SUA ÉPOCA,", "EM NÚMEROS", "Cada ponto, cada campo. O seu vídeo nunca sai do seu iPhone."]],
]
// Storefront variants: British spelling for UK/Australia/Canada, Latin American
// words for Mexico and the US Spanish index.
copy["en-GB"] = copy["en"]!.map { $0.map { $0.replacingOccurrences(of: "color", with: "colour") } }
copy["es-MX"] = copy["es"]!.map { $0.map { $0.replacingOccurrences(of: "vídeo", with: "video")
                                              .replacingOccurrences(of: "pista", with: "cancha") } }
let files = ["hero.jpg", "s5_editor_text.png", "s2_session.png", "s6_editor_zoom.png", "s3_reel.png", "s4_season.png"]
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

    let margin: CGFloat = 90
    var y = H - 250     // AppKit's origin is bottom-left; we lay out downward

    // A "NEW" chip over the editor frame. Outlined, not filled: a solid volt
    // capsule is the app's primary-button shape. Drop it next version.
    if index == 1 {
        let word = ["es": "NUEVO", "pt": "NOVO", "de": "NEU", "fr": "NOUVEAU",
                    "it": "NUOVO", "zh": "新功能"][String(locale.prefix(2))] ?? "NEW"
        let t = NSAttributedString(string: word, attributes: [.font: body(38, .bold),
                                                               .foregroundColor: volt, .kern: 2])
        let ts = t.size()
        let chip = CGRect(x: margin, y: H - 175, width: ts.width + 52, height: ts.height + 22)
        let p = CGPath(roundedRect: chip, cornerWidth: chip.height / 2, cornerHeight: chip.height / 2,
                       transform: nil)
        g.setStrokeColor(volt.cgColor); g.setLineWidth(3); g.addPath(p); g.strokePath()
        t.draw(at: CGPoint(x: chip.minX + 26, y: chip.minY + 11))
        y -= 40
    }

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
    let url = outDir.appendingPathComponent(String(format: "%02d_%@.png", index + 1,
                                                   f.file.replacingOccurrences(of: ".png", with: "")
                                                        .replacingOccurrences(of: ".jpg", with: "")))
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: url)
        print("wrote", url.lastPathComponent)
    }
}

for (i, f) in frames.enumerated() { draw(f, index: i) }
