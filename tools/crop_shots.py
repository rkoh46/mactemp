from PIL import Image, ImageDraw

# 1) Menu: composite the window-only capture (screencapture -l <menu window>) onto a
#    solid dark card so nothing shows behind the translucent menu.
menu = Image.open("win_menu.png").convert("RGBA")
mw, mh = menu.size
pad = 24
W, H = mw + pad * 2, mh + pad * 2
card = Image.new("RGBA", (W, H), (28, 30, 38, 255))
card.alpha_composite(menu, (pad, pad))
mask = Image.new("L", (W, H), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, W - 1, H - 1], radius=16, fill=255)
out = Image.composite(card, Image.new("RGBA", (W, H), (0, 0, 0, 0)), mask)
out.save("assets/mactemp-menu.png")
print("menu:", out.size)

# 2) Menu bar readout: the status-item button rendered with alpha — composite it onto
#    a dark bar-height strip so it reads like the menu bar without any neighbors.
btn = Image.open("bar_button.png").convert("RGBA")
scale = 2
bw, bh = btn.width * scale, btn.height * scale
btn = btn.resize((bw, bh), Image.LANCZOS)
strip = Image.new("RGBA", (bw + 48, bh + 20), (30, 32, 40, 255))
strip.alpha_composite(btn, (24, 10))
mask = Image.new("L", strip.size, 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, strip.width - 1, strip.height - 1], radius=12, fill=255)
out2 = Image.composite(strip, Image.new("RGBA", strip.size, (0, 0, 0, 0)), mask)
out2.save("assets/mactemp-bar.png")
print("bar:", out2.size)
