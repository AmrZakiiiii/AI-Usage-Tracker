#!/usr/bin/env python3
"""Generate professional mockup PNG screenshots for AI Usage Tracker macOS menu bar app."""

from PIL import Image, ImageDraw, ImageFont
import os

FONT_PATH = "/System/Library/Fonts/Helvetica.ttc"
OUTPUT_DIR = os.path.dirname(os.path.abspath(__file__))

W = 400
BG = (30, 30, 30)         # #1e1e1e
CARD_BG = (42, 42, 42)    # #2a2a2a
TEXT_WHITE = (255, 255, 255)
TEXT_GRAY = (160, 160, 160)
TEXT_LIGHT = (200, 200, 200)
TEXT_GREEN = (34, 197, 94)
TEXT_ORANGE = (249, 115, 22)
TRACK_BG = (60, 60, 60)

COLOR_CODEX = (59, 130, 246)
COLOR_CLAUDE = (249, 115, 22)
COLOR_ANTIGRAVITY = (34, 197, 94)
COLOR_WINDSURF = (168, 85, 247)
COLOR_YELLOW = (234, 179, 8)
COLOR_GREEN = (34, 197, 94)


def load_font(size, bold=False):
    try:
        return ImageFont.truetype(FONT_PATH, size)
    except Exception:
        return ImageFont.load_default()


def rounded_rectangle(draw, xy, radius, fill=None, outline=None, width=1):
    x0, y0, x1, y1 = xy
    draw.rounded_rectangle([x0, y0, x1, y1], radius=radius, fill=fill, outline=outline, width=width)


def draw_progress_bar(draw, x, y, w, h, pct, color, radius=4):
    # Track
    rounded_rectangle(draw, [x, y, x + w, y + h], radius=radius, fill=TRACK_BG)
    # Fill
    fill_w = max(int(w * pct / 100), 0)
    if fill_w > 0:
        rounded_rectangle(draw, [x, y, x + fill_w, y + h], radius=radius, fill=color)


def draw_dot(draw, x, y, r, color):
    draw.ellipse([x - r, y - r, x + r, y + r], fill=color)


def draw_pill_badge(draw, x, y, text, color, font):
    bbox = font.getbbox(text)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    pad_x, pad_y = 10, 4
    bw = tw + pad_x * 2
    bh = th + pad_y * 2
    rounded_rectangle(draw, [x, y, x + bw, y + bh], radius=bh // 2, fill=(*color, 50))
    draw.text((x + pad_x, y + pad_y), text, font=font, fill=color)
    return bw


def draw_header(draw, img_w, fonts):
    """Draw top header: title + icons."""
    f_title = fonts['bold_14']
    f_icon = fonts['regular_16']
    y = 16
    draw.text((16, y), "AI Usage Tracker", font=f_title, fill=TEXT_WHITE)
    # Icons right side
    icon_y = y
    draw.text((img_w - 38, icon_y), "⚙", font=f_icon, fill=TEXT_GRAY)
    draw.text((img_w - 58, icon_y), "↻", font=f_icon, fill=TEXT_GRAY)


def draw_tab_bar(draw, img_w, active_tab, fonts):
    """Draw pill-shaped tab bar."""
    tabs = ["Codex", "Claude", "Antigravity", "Windsurf"]
    tab_colors = {
        "Codex": COLOR_CODEX,
        "Claude": COLOR_CLAUDE,
        "Antigravity": COLOR_ANTIGRAVITY,
        "Windsurf": COLOR_WINDSURF,
    }
    f = fonts['regular_11']
    bar_y = 48
    bar_h = 28
    total_w = img_w - 32
    tab_w = total_w // len(tabs)
    bar_x = 16

    # Bar background
    rounded_rectangle(draw, [bar_x, bar_y, bar_x + total_w, bar_y + bar_h], radius=bar_h // 2, fill=(50, 50, 50))

    for i, tab in enumerate(tabs):
        tx = bar_x + i * tab_w
        if tab == active_tab:
            color = tab_colors[tab]
            rounded_rectangle(draw, [tx + 2, bar_y + 2, tx + tab_w - 2, bar_y + bar_h - 2],
                               radius=(bar_h - 4) // 2, fill=color)
            draw.text((tx + tab_w // 2, bar_y + bar_h // 2), tab,
                      font=f, fill=TEXT_WHITE, anchor="mm")
        else:
            draw.text((tx + tab_w // 2, bar_y + bar_h // 2), tab,
                      font=f, fill=TEXT_GRAY, anchor="mm")


def draw_provider_header(draw, y, name, dot_color, status, fonts, img_w, badge_text=None, badge_color=None, extra_badge=None):
    """Draw provider status row."""
    f = fonts['bold_13']
    f_status = fonts['regular_12']
    f_badge = fonts['regular_10']

    dot_r = 5
    dot_x = 22
    dot_y = y + 8
    draw_dot(draw, dot_x, dot_y, dot_r, dot_color)

    draw.text((32, y), name, font=f, fill=TEXT_WHITE)

    # Status right
    status_color = TEXT_GREEN if status == "Healthy" else TEXT_ORANGE
    status_x = img_w - 16
    draw.text((status_x, y + 1), status, font=f_status, fill=status_color, anchor="ra")

    # Badge after name
    if badge_text and badge_color:
        name_bbox = f.getbbox(name)
        name_w = name_bbox[2] - name_bbox[0]
        bx = 36 + name_w + 4
        bw = draw_pill_badge(draw, bx, y, badge_text, badge_color, f_badge)
        if extra_badge:
            draw_pill_badge(draw, bx + bw + 6, y, extra_badge[0], extra_badge[1], f_badge)


def draw_card(draw, x, y, w, h, fonts, label, pct, bar_color, reset_left, reset_date, note=None, right_label=None):
    """Draw a usage card."""
    f_label = fonts['regular_11']
    f_pct = fonts['bold_13']
    f_sub = fonts['regular_10']

    rounded_rectangle(draw, [x, y, x + w, y + h], radius=8, fill=CARD_BG)

    # Label row
    draw.text((x + 12, y + 10), label, font=f_label, fill=TEXT_LIGHT)

    pct_text = right_label if right_label else f"{pct}%  {pct}%"
    draw.text((x + w - 12, y + 10), pct_text, font=f_pct, fill=TEXT_WHITE, anchor="ra")

    # Progress bar
    bar_x = x + 12
    bar_y = y + 30
    bar_w = w - 24
    draw_progress_bar(draw, bar_x, bar_y, bar_w, 8, pct, bar_color)

    # Sub text
    draw.text((x + 12, y + 46), reset_left, font=f_sub, fill=TEXT_GRAY)
    draw.text((x + w - 12, y + 46), reset_date, font=f_sub, fill=TEXT_GRAY, anchor="ra")

    if note:
        draw.text((x + 12, y + 60), note, font=f_sub, fill=(100, 100, 100))


def draw_bottom_bar(draw, y, img_w, updated_text, source_text, fonts):
    f = fonts['regular_10']
    # Divider
    draw.line([(16, y), (img_w - 16, y)], fill=(60, 60, 60), width=1)
    draw.text((16, y + 8), updated_text, font=f, fill=TEXT_GRAY)
    draw.text((img_w - 16, y + 8), source_text, font=f, fill=TEXT_GRAY, anchor="ra")


def make_base_image(height):
    img = Image.new("RGBA", (W, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    rounded_rectangle(draw, [0, 0, W - 1, height - 1], radius=12, fill=(*BG, 255))
    return img, draw


def build_fonts():
    return {
        'regular_10': load_font(10),
        'regular_11': load_font(11),
        'regular_12': load_font(12),
        'regular_13': load_font(13),
        'regular_16': load_font(16),
        'bold_13': load_font(13, bold=True),
        'bold_14': load_font(14, bold=True),
    }


# ─────────────────────────────────────────────
# Screenshot 1: Codex
# ─────────────────────────────────────────────
def make_codex():
    H = 280
    img, draw = make_base_image(H)
    fonts = build_fonts()

    draw_header(draw, W, fonts)
    draw_tab_bar(draw, W, "Codex", fonts)

    y = 90
    draw_provider_header(draw, y, "Codex", COLOR_CODEX, "Healthy", fonts, W,
                         badge_text="Free", badge_color=TEXT_GRAY)

    # Card
    card_x, card_y, card_w, card_h = 16, 118, W - 32, 80
    draw_card(draw, card_x, card_y, card_w, card_h, fonts,
              label="Weekly Usage",
              pct=68,
              bar_color=TEXT_ORANGE,
              reset_left="Resets in 5 days",
              reset_date="31 Mar 2026 at 10:00 am",
              note="7d window",
              right_label="68%  68%")

    draw_bottom_bar(draw, H - 30, W, "Updated 2 sec ago", "Codex local server", fonts)

    out = os.path.join(OUTPUT_DIR, "screenshot_codex.png")
    img.save(out)
    print(f"Saved: {out}")


# ─────────────────────────────────────────────
# Screenshot 2: Claude
# ─────────────────────────────────────────────
def make_claude():
    H = 390
    img, draw = make_base_image(H)
    fonts = build_fonts()

    draw_header(draw, W, fonts)
    draw_tab_bar(draw, W, "Claude", fonts)

    y = 90
    draw_provider_header(draw, y, "Claude", COLOR_CLAUDE, "Healthy", fonts, W,
                         badge_text="Pro", badge_color=COLOR_CLAUDE,
                         extra_badge=("2x", COLOR_CLAUDE))

    # Info bar
    info_y = 116
    rounded_rectangle(draw, [16, info_y, W - 16, info_y + 24], radius=6,
                       fill=(*COLOR_CLAUDE, 30))
    draw.text((W // 2, info_y + 12), "2x active · ends in 3h 42m 15s",
              font=fonts['regular_11'], fill=COLOR_CLAUDE, anchor="mm")

    # Card 1
    card_x = 16
    card_w = W - 32

    c1_y = 150
    draw_card(draw, card_x, c1_y, card_w, 82, fonts,
              label="Session (5h)",
              pct=42,
              bar_color=COLOR_CLAUDE,
              reset_left="Resets in 2h 18m",
              reset_date="26 Mar 2026 at 3:00 pm",
              note="5h window",
              right_label="42%  42%")

    # Card 2
    c2_y = 244
    draw_card(draw, card_x, c2_y, card_w, 74, fonts,
              label="Weekly (7d)",
              pct=10,
              bar_color=COLOR_GREEN,
              reset_left="Resets in 5 days",
              reset_date="31 Mar 2026 at 2:00 pm",
              note=None,
              right_label="10%  10%")

    draw_bottom_bar(draw, H - 30, W, "Updated 4 sec ago", "Claude API + isclaude2x.com", fonts)

    out = os.path.join(OUTPUT_DIR, "screenshot_claude.png")
    img.save(out)
    print(f"Saved: {out}")


# ─────────────────────────────────────────────
# Screenshot 3: Windsurf
# ─────────────────────────────────────────────
def make_windsurf():
    H = 430
    img, draw = make_base_image(H)
    fonts = build_fonts()

    draw_header(draw, W, fonts)
    draw_tab_bar(draw, W, "Windsurf", fonts)

    y = 90
    draw_provider_header(draw, y, "Windsurf", COLOR_WINDSURF, "Healthy", fonts, W,
                         badge_text="Pro", badge_color=COLOR_WINDSURF)

    card_x = 16
    card_w = W - 32

    # Card 1 - Daily
    c1_y = 118
    draw_card(draw, card_x, c1_y, card_w, 74, fonts,
              label="Daily Quota Usage",
              pct=8,
              bar_color=COLOR_GREEN,
              reset_left="Resets in 22 hr",
              reset_date="25 Mar 2026 at 10:00 am",
              note=None,
              right_label="8%  8%")

    # Card 2 - Weekly
    c2_y = 204
    draw_card(draw, card_x, c2_y, card_w, 74, fonts,
              label="Weekly Quota Usage",
              pct=32,
              bar_color=COLOR_YELLOW,
              reset_left="Resets in 4 days",
              reset_date="29 Mar 2026 at 10:00 am",
              note=None,
              right_label="32%  32%")

    # Card 3 - Extra Balance
    c3_y = 290
    rounded_rectangle(draw, [card_x, c3_y, card_x + card_w, c3_y + 56], radius=8, fill=CARD_BG)
    draw.text((card_x + 12, c3_y + 10), "Extra Usage Balance", font=fonts['regular_11'], fill=TEXT_LIGHT)
    draw.text((card_x + card_w - 12, c3_y + 10), "$6.42", font=fonts['bold_13'], fill=TEXT_WHITE, anchor="ra")
    bar_x = card_x + 12
    bar_y = c3_y + 30
    bar_w = card_w - 24
    draw_progress_bar(draw, bar_x, bar_y, bar_w, 8, 100, COLOR_GREEN)

    draw_bottom_bar(draw, H - 30, W, "Updated 1 sec ago", "Windsurf API", fonts)

    out = os.path.join(OUTPUT_DIR, "screenshot_windsurf.png")
    img.save(out)
    print(f"Saved: {out}")


# ─────────────────────────────────────────────
# Screenshot 4: Antigravity
# ─────────────────────────────────────────────
def make_antigravity():
    H = 490
    img, draw = make_base_image(H)
    fonts = build_fonts()

    draw_header(draw, W, fonts)
    draw_tab_bar(draw, W, "Antigravity", fonts)

    y = 90
    draw_provider_header(draw, y, "Antigravity", COLOR_ANTIGRAVITY, "Healthy", fonts, W,
                         badge_text="Pro", badge_color=COLOR_ANTIGRAVITY)

    card_x = 16
    card_w = W - 32
    f_sub = fonts['regular_10']

    models = [
        ("Gemini 3.1 Pro (High)", 45, COLOR_CLAUDE,   "45%  45%", "Resets in 1h 30m"),
        ("Gemini 3.1 Pro (Low)",  20, COLOR_GREEN,    "20%  20%", "Resets in 1h 30m"),
        ("Gemini 3 Flash",         5, COLOR_GREEN,     "5%  5%",  "Resets in 1h 30m"),
        ("Claude Sonnet Thinking", 0, COLOR_GREEN,     "0%  0%",  "Resets in 1h 30m"),
    ]

    cy = 118
    for label, pct, bar_color, right_label, reset_left in models:
        card_h = 66
        rounded_rectangle(draw, [card_x, cy, card_x + card_w, cy + card_h], radius=8, fill=CARD_BG)
        draw.text((card_x + 12, cy + 10), label, font=fonts['regular_11'], fill=TEXT_LIGHT)
        draw.text((card_x + card_w - 12, cy + 10), right_label, font=fonts['bold_13'], fill=TEXT_WHITE, anchor="ra")
        draw_progress_bar(draw, card_x + 12, cy + 28, card_w - 24, 8, pct, bar_color)
        draw.text((card_x + 12, cy + 44), reset_left, font=f_sub, fill=TEXT_GRAY)
        cy += card_h + 8

    draw_bottom_bar(draw, H - 30, W, "Updated 3 sec ago", "Local Antigravity state", fonts)

    out = os.path.join(OUTPUT_DIR, "screenshot_antigravity.png")
    img.save(out)
    print(f"Saved: {out}")


if __name__ == "__main__":
    make_codex()
    make_claude()
    make_windsurf()
    make_antigravity()
    print("All screenshots generated.")
