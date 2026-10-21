from PIL import Image, ImageDraw, ImageFont, ImageFilter
import sys
S=1024
OUT=sys.argv[1]
def grad(c1,c2):
    im=Image.new('RGB',(S,S)); px=im.load()
    for y in range(S):
        for x in range(S):
            t=(x+y)/(2*S-2); px[x,y]=tuple(int(c1[i]+(c2[i]-c1[i])*t) for i in range(3))
    return im
def spikes(d, x0, x1, ybase, n, h, fill):
    w=(x1-x0)/n
    pts=[(x0,ybase)]
    for i in range(n):
        pts.append((x0+w*(i+0.5), ybase-h)); pts.append((x0+w*(i+1), ybase))
    pts.append((x1,ybase+2)); pts.append((x0,ybase+2))
    d.polygon(pts, fill=fill)
def keyboard(d, x0, y0, w, h, body, key, spiky):
    d.rounded_rectangle([x0,y0,x0+w,y0+h],radius=56,fill=body)
    if spiky:
        spikes(d, x0+34, x0+w-34, y0+4, 7, 92, body)
    cols=6; gap=18; pad=40; kw=(w-2*pad-(cols-1)*gap)/cols; kh=62
    for r in range(3):
        n=cols if r<2 else cols-1; off=0 if r<2 else (kw+gap)/2
        for i in range(n):
            kx=x0+pad+off+i*(kw+gap); ky=y0+pad+r*(kh+gap)
            d.rounded_rectangle([kx,ky,kx+kw,ky+kh],radius=14,fill=key)
    sy=y0+pad+3*(kh+gap)
    d.rounded_rectangle([x0+pad+kw+gap, sy, x0+w-pad-kw-gap, sy+kh-6],radius=14,fill=key)
font=ImageFont.truetype('/System/Library/Fonts/Avenir Next.ttc', 620, index=2)  # demi bold
variants=[]
# V1: keyboard with spiky top edge
bg=grad((64,128,255),(26,74,214)); fg=Image.new('RGBA',(S,S),(0,0,0,0)); d=ImageDraw.Draw(fg)
keyboard(d,212,330,600,400,(255,255,255,255),(40,96,235,255),True)
v=bg.convert('RGBA'); v.alpha_composite(fg); variants.append((v,bg,fg))
# V2: bold lowercase g with a spiky crown, navy + orange accent
bg=grad((28,40,72),(14,20,40)); fg=Image.new('RGBA',(S,S),(0,0,0,0)); d=ImageDraw.Draw(fg)
d.text((S/2, S/2+70), 'g', font=font, fill=(255,255,255,255), anchor='mm')
spikes(d, 330, 694, 300, 5, 95, (255,138,0,255))
v=bg.convert('RGBA'); v.alpha_composite(fg); variants.append((v,bg,fg))
# V3: white keycap with g and spiky top, on blue
bg=grad((64,128,255),(26,74,214)); fg=Image.new('RGBA',(S,S),(0,0,0,0)); d=ImageDraw.Draw(fg)
d.rounded_rectangle([262,300,762,760],radius=90,fill=(255,255,255,255))
spikes(d, 300, 724, 304, 5, 80, (255,255,255,255))
f2=ImageFont.truetype('/System/Library/Fonts/Avenir Next.ttc', 340, index=2)
d.text((S/2, 500), 'g', font=f2, fill=(36,92,232,255), anchor='mm')
v=bg.convert('RGBA'); v.alpha_composite(fg); variants.append((v,bg,fg))
# preview sheet with HarmonyOS-like rounded mask
sheet=Image.new('RGB',(3*300+4*40,380),(242,243,245)); dd=ImageDraw.Draw(sheet)
lab=ImageFont.truetype('/System/Library/Fonts/Avenir Next.ttc', 30, index=0)
for i,(v,bg,fg) in enumerate(variants):
    small=v.resize((300,300),Image.LANCZOS)
    mask=Image.new('L',(300,300),0); ImageDraw.Draw(mask).rounded_rectangle([0,0,299,299],radius=70,fill=255)
    x=40+i*340; sheet.paste(small,(x,30),mask)
    dd.text((x+150,355),f'Variante {i+1}',font=lab,fill=(40,40,40),anchor='mm')
    bg.save(f'{OUT}/v{i+1}_background.png'); fg.save(f'{OUT}/v{i+1}_foreground.png')
sheet.save(f'{OUT}/gbart_icon_varianten.png')
