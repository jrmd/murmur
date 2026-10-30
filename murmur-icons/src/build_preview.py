from PIL import Image, ImageDraw, ImageFont
import numpy as np
F='/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'; FB='/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
font=ImageFont.truetype(F,22); small=ImageFont.truetype(F,16); title=ImageFont.truetype(FB,34); mb=ImageFont.truetype(F,26)
W,H=1800,1500
sheet=Image.new('RGBA',(W,H),(250,248,245,255)); d=ImageDraw.Draw(sheet)
d.text((40,28),'Murmur - macOS icon pack preview',font=title,fill=(30,30,30))
L=Image.open('murmur-light-1024.png'); D=Image.open('murmur-dark-1024.png')
sizes=[256,128,64,32,16]
def row(y,bg,fg,label):
    d.rectangle((0,y,W,y+330),fill=bg); d.text((40,y+12),label,font=font,fill=fg)
    x=40
    for icon,name in [(L,'light'),(D,'dark')]:
        for s in sizes:
            im=icon.resize((s,s),Image.LANCZOS)
            sheet.alpha_composite(im,(x,y+60+(256-s)//2)); d.text((x,y+300),f'{name} {s}',font=small,fill=fg)
            x+=max(s,40)+30
        x+=40
row(90,(242,242,247),(60,60,60),'On light background')
row(430,(30,30,32),(220,220,220),'On dark background')
def glyph(name,px,rgb):
    a=np.asarray(Image.open(f'menubar/{name}@2x.png' if px==36 else f'menubar/{name}.png').resize((px,px),Image.LANCZOS))[...,3]
    out=np.zeros((px,px,4),np.uint8); out[...,:3]=rgb; out[...,3]=a
    return Image.fromarray(out,'RGBA')
def menubar(y,bg,fg,label):
    d.text((40,y),label,font=font,fill=(40,40,40))
    y+=40; d.rectangle((40,y,W-40,y+48),fill=bg)   # 24pt bar at 2x
    d.text((70,y+9),'  Finder   File   Edit   View   Go   Window   Help',font=mb,fill=fg)
    x=W-560
    for name in ['MenuBarIcon','MenuBarIcon-Recording']:
        sheet.alpha_composite(glyph(name,36,fg),(x,y+6)); x+=70
    d.text((x+20,y+9),'Fri 30 Oct  12:30',font=mb,fill=fg)
    # 1x row (actual 18px)
    y+=70; d.rectangle((40,y,700,y+24),fill=bg)
    sheet.alpha_composite(glyph('MenuBarIcon',18,fg),(60,y+3)); sheet.alpha_composite(glyph('MenuBarIcon-Recording',18,fg),(90,y+3))
    d.text((720,y),'actual size @1x (18px): idle, recording',font=small,fill=(80,80,80))
menubar(790,(236,234,232),(0,0,0),'Menu bar glyph (template) - light menu bar, @2x: idle + recording')
menubar(990,(40,40,44),(255,255,255),'Menu bar glyph (template) - dark menu bar, @2x: idle + recording')
# big glyph
for i,name in enumerate(['MenuBarIcon','MenuBarIcon-Recording']):
    sheet.alpha_composite(glyph(name,36,(0,0,0)).resize((216,216),Image.NEAREST) if False else Image.open(f'/tmp/{name}-big.png').resize((220,220),Image.LANCZOS),(60+i*260,1220))
d.text((600,1300),'Vector glyphs (MenuBarIcon.svg / MenuBarIcon-Recording.svg), rendered large',font=font,fill=(60,60,60))
sheet.convert('RGB').save('preview.png')
