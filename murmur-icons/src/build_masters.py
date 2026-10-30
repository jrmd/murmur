from PIL import Image, ImageFilter
import numpy as np
SS=4; C=1024; T=824; OFF=(C-T)//2
def squircle(size, n=5.0):
    s=size*SS; c=(s-1)/2
    y,x=np.mgrid[0:s,0:s]
    v=np.abs((x-c)/(s/2))**n+np.abs((y-c)/(s/2))**n
    m=Image.fromarray(((v<=1)*255).astype(np.uint8))
    return m.resize((size,size),Image.LANCZOS)
def tile_bounds(path):
    hsv=np.asarray(Image.open(path).convert('HSV')).astype(int)
    rgb=np.asarray(Image.open(path).convert('RGB')).astype(int)
    bg=np.median(rgb[:20,:20].reshape(-1,3),0)
    m=(np.abs(rgb-bg).sum(2)>45)&(hsv[...,1]>30) if bg.mean()>128 else (np.abs(rgb-bg).sum(2)>45)
    mid=slice(380,640)
    cols=np.where(m[mid].mean(0)>0.5)[0]; rows=np.where(m[:,mid].mean(1)>0.5)[0]
    return cols.min(),rows.min(),cols.max(),rows.max()
mask=squircle(T)
for name,src in [('light','/tmp/light.jpg'),('dark','/tmp/dark.jpg')]:
    x0,y0,x1,y1=tile_bounds(src); print(name,'tile bounds',x0,y0,x1,y1)
    ins=3
    tile=Image.open(src).convert('RGB').crop((x0+ins,y0+ins,x1-ins+1,y1-ins+1)).resize((T,T),Image.LANCZOS).convert('RGBA')
    tile.putalpha(mask)
    canvas=Image.new('RGBA',(C,C),(0,0,0,0))
    # Apple-style drop shadow: ~30% black, 12px down, soft blur
    sh=Image.new('L',(C,C),0); sh.paste(mask.point(lambda a:int(a*0.32)),(OFF,OFF+12))
    sh=sh.filter(ImageFilter.GaussianBlur(14))
    shadow=Image.new('RGBA',(C,C),(0,0,0,0)); shadow.putalpha(sh)
    canvas=Image.alpha_composite(canvas,shadow)
    layer=Image.new('RGBA',(C,C),(0,0,0,0)); layer.paste(tile,(OFF,OFF))
    canvas=Image.alpha_composite(canvas,layer)
    canvas.save(f'/workspace/murmur-icons/murmur-{name}-1024.png')
