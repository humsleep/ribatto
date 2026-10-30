# App Store screenshot plan — 1.2.0 (6 frames)

Story arc: **payoff** (the clip you'll post) → **new power** (edit it your way) → **why it's different** (found by sound) → **craft detail** (zoom/slow-mo) → **speed** (30-s reel) → **retention + trust** (season, on-device).
Search results show frames 1–3: outcome, the new free editor, and the sound differentiator. Library ("My Matches") is dropped — weakest frame, and the session frame already shows the clip grid.

## Frame plan

| # | File | Capture — exactly what is on screen | EN headline |
|---|------|------|------|
| 1 | `hero.jpg` (full-bleed, as now) | Rendered 9:16 Pass clip, mid-swing frame (player in the bottom half, ball visible). Zoom keyframe ~1.3× on the near player so he fills the frame. Subtitle **"MATCH POINT"** in volt, upper third, large; keep the small place·date line under it. No watermark. | ONE TAP, / MATCH TO REEL |
| 2 | `s5_editor_text.png` | Clip editor, **Text panel open**. Preview: subtitle "MATCH POINT" selected (handles visible), volt colour, placed upper third — the same clip as frame 1 so the viewer sees it's being made. Font chips show one selected; volt swatch selected. Timeline below the fixed playhead shows the text bar + 2 zoom diamonds. Tool bar visible (Text active). | EDIT IT / YOUR WAY |
| 3 | `s2_session.png` | Session screen as now: hero best rally ("★ Best · 17 shots", big "19 s"), white "30-second highlight reel" button, summary line, clip grid #1–#3. Recapture with the 2026-10-30 neutral palette (white primary button, no olive). | FOUND BY / SOUND |
| 4 | `s6_editor_zoom.png` | Clip editor, **Zoom panel open**, playhead parked on a diamond near the last strike; preview zoomed ~1.6× on the hitter. Speed shown as 0.5× on the clip (or Speed chip highlighted). Strike ticks (court blue) visible on the timeline so "sound" is echoed. | ZOOM IN ON / THE WINNER |
| 5 | `s3_reel.png` | Reel result screen: the 30-s vertical reel playing with the hook caption ("17-shot rally"), share/save actions below. | 30 SECONDS, / BEST FIRST |
| 6 | `s4_season.png` | Season stats as now (rallies, courts, longest). | YOUR SEASON, / COUNTED |

Capture rules unchanged: UI in each locale's language (`-rc_lang <code>`), Debug Pass on (no test banner), `simctl status_bar override --time 9:41`, demo `placeName` per locale. For frames 1, 2 and 4 keep "MATCH POINT" in English on every locale's video (it's burned-in video content, reads as sport jargon everywhere, and saves 8 recaptures of the editor). Only the UI chrome changes language.

## `copy` table (replace the existing one)

```swift
let copy: [String: [[String]]] = [
    "en": [["ONE TAP,", "MATCH TO REEL", "Every rally found by its sound and cut vertical, ready to post."],
           ["EDIT IT", "YOUR WAY", "Text anywhere, zoom keyframes, slow motion, colour looks. All free."],
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
]
let files = ["hero.jpg", "s5_editor_text.png", "s2_session.png", "s6_editor_zoom.png", "s3_reel.png", "s4_season.png"]
```

Copy notes
- "All free" / "전부 무료" refers to the editor only (true in 1.2.0). No "no ads", "no uploads", "Pro", or platform names. "reel" stays generic as in the app.
- Longest Latin lines: fr "LE MEILLEUR D'ABORD" (19), es "DEL PARTIDO AL REEL" (19), pt "O MELHOR PRIMEIRO" (17). The shrink loop handles them, but the headline drops toward ~120pt — check fr frame 5 by eye.
- it frame 1 shortened from "DALLA PARTITA AL REEL" (21) to "DAL MATCH AL REEL" (17) so it no longer forces the smallest size; "match" is common Italian sports usage.
- 0,5× uses a decimal comma in es/pt/de/fr/it.

## Generator tweaks (cheap, optional)

1. **Swap `copy` and `files`** above. Output names come from the file name, so frame numbers shift (`02_s5_editor_text.png`…). Empty each `marketing/screenshots/<locale>/` first or the old `02_s1_library.png` etc. get left behind and uploaded by mistake.
2. **"NEW" chip on frame 2** (index 1 only): a volt-outlined capsule (3pt stroke, volt text, `body(36, .bold)`, ~24pt padding) drawn at `y = H - 170` above the headline, before the headline loop. Localized: NEW / NEW / NEW / NUEVO / NOVO / NEU / NOUVEAU / NUOVO / 新功能 (ko/ja "NEW" reads fine). Outline, not fill — matches the ProBadge rule (solid volt reads as a button). Drop it in the next version.
3. **Glow colour**: the current gradient reads olive (the "촌스럽다" feedback that drove the 10-30 neutral palette). Lower volt alpha 0.28 → 0.16, or blend toward neutral white at 0.10, so the ground matches #0A0A0B. Also set `ground` to `rgb(10, 10, 11)` to match the app.
