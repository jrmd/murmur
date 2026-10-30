from PIL import Image
import json, os
SIZES=[16,32,128,256,512]
def resized(im,px): return im.resize((px,px),Image.LANCZOS)
for variant,setname,icns in [('light','AppIcon.appiconset','Murmur.icns'),('dark','AppIcon-Dark.appiconset','Murmur-Dark.icns')]:
    master=Image.open(f'murmur-{variant}-1024.png').convert('RGBA')
    os.makedirs(setname,exist_ok=True)
    iconset=f'Murmur{"" if variant=="light" else "-Dark"}.iconset'; os.makedirs(iconset,exist_ok=True)
    images=[]
    for s in SIZES:
        for sc in (1,2):
            px=s*sc; suffix='' if sc==1 else '@2x'
            fn=f'icon_{s}x{s}{suffix}.png'
            im=resized(master,px)
            im.save(f'{setname}/{fn}'); im.save(f'{iconset}/{fn}')
            images.append({"filename":fn,"idiom":"mac","scale":f"{sc}x","size":f"{s}x{s}"})
    json.dump({"images":images,"info":{"author":"xcode","version":1}},open(f'{setname}/Contents.json','w'),indent=2)
    master.save(icns,format='ICNS',append_images=[resized(master,p) for p in (16,32,64,128,256,512)])
