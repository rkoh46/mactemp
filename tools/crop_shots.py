from PIL import Image

im = Image.open("screenshot_1.png")
w, h = im.size

# Full showcase: open dropdown menu (tight crop, no desktop clutter)
menu = im.crop((w - 1290, 0, w - 710, 1620))
menu.save("assets/mactemp-menu.png")
print("menu", menu.size)

# Menu bar item close-up
bar = im.crop((w - 1420, 0, w - 830, 56))
bar.save("assets/mactemp-bar.png")
print("bar", bar.size)
