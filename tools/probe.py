from PIL import Image

full = Image.open("win_full.png")
fw, fh = full.size
print("full:", full.size)
# secondary screen starts at global x=2560pt -> px 5120. Menu window x=1934pt: which screen?
# dump candidate strips to find the MacTemp readout
for i, (x0, x1) in enumerate([(3300, 3900), (3860, 4500), (4400, 5120), (0, 800), (560, 1200)]):
    strip = full.crop((x0, 0, x1, 60))
    strip.save(f"probe_strip_{i}.png")
    print(i, (x0, x1))
