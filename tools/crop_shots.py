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

# 2) Menu bar strip: tight crop of only the MacTemp readout (item at global x=1936pt @2x).
full = Image.open("win_full.png")
bar = full.crop((3872, 0, 4384, 48))
bar.save("assets/mactemp-bar.png")
print("bar:", bar.size)
