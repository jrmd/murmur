# Writes a full ICNS (all PNG chunk types incl. 16/32 1x) from an .iconset, like `iconutil -c icns`.
import struct, io, sys
from PIL import Image
MAP=[('icp4','icon_16x16.png'),('icp5','icon_32x32.png'),('icp6',None),('ic07','icon_128x128.png'),
     ('ic08','icon_256x256.png'),('ic09','icon_512x512.png'),('ic10','icon_512x512@2x.png'),
     ('ic11','icon_16x16@2x.png'),('ic12','icon_32x32@2x.png'),('ic13','icon_128x128@2x.png'),('ic14','icon_256x256@2x.png')]
def build(iconset,out):
    chunks=[]
    for t,fn in MAP:
        if fn: data=open(f'{iconset}/{fn}','rb').read()
        else:
            b=io.BytesIO(); Image.open(f'{iconset}/icon_512x512@2x.png').resize((64,64),Image.LANCZOS).save(b,'PNG'); data=b.getvalue()
        chunks.append(t.encode()+struct.pack('>I',len(data)+8)+data)
    body=b''.join(chunks)
    open(out,'wb').write(b'icns'+struct.pack('>I',len(body)+8)+body)
build('Murmur.iconset','Murmur.icns'); build('Murmur-Dark.iconset','Murmur-Dark.icns')
