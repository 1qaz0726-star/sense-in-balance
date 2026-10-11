from PIL import Image, ImageDraw, ImageFont
F='C:/Windows/Fonts/NotoSansTC-VF.ttf'
def font(sz, w='Regular'):
    f=ImageFont.truetype(F, sz)
    try: f.set_variation_by_name(w)
    except Exception: pass
    return f
BG=(11,11,13); HI=(242,242,244); LO=(138,138,146); LINE=(58,58,64); RED=(214,48,49); ACC=(120,200,170)
W,H=1920,1080
def base(): return Image.new('RGB',(W,H),BG)
def ctext(d,y,t,f,c):
    w=d.textlength(t,font=f); d.text(((W-w)/2,y),t,font=f,fill=c)

# 1 title
im=base(); d=ImageDraw.Draw(im)
ctext(d,370,'該說才說',font(150,'Bold'),HI)
ctext(d,570,'會自己動手的安靜座艙 AI',font(64),HI)
d.line([(W/2-60,690),(W/2+60,690)],fill=LINE,width=3)
ctext(d,730,'感知有度 Sense in Balance',font(40),LO)
ctext(d,800,'2026 AI 座艙感知與視覺化 Hackathon・實作組',font(30),LO)
im.save('F:/tmp/edit/card_title.png')

# 2 team
im=base(); d=ImageDraw.Draw(im)
ctext(d,200,'感知有度',font(96,'Bold'),HI)
ctext(d,330,'Sense in Balance',font(44),LO)
rows=[('葉士愷','標註資料・程式開發'),('黃昱羲','感知處理流程・Android HMI'),('胡馨','提案簡報・驗證證據整理')]
y=480
for n,r in rows:
    d.text((560,y),n,font=font(54,'Bold'),fill=HI); d.text((860,y+8),r,font=font(44),fill=LO); y+=130
im.save('F:/tmp/edit/card_team.png')

# 3 architecture
im=base(); d=ImageDraw.Draw(im)
def box(x,y,w,h,title,sub=None,col=LINE,tc=HI,dash=False):
    if dash:
        for i in range(x,x+w,24): d.line([(i,y),(min(i+12,x+w),y)],fill=col,width=3); d.line([(i,y+h),(min(i+12,x+w),y+h)],fill=col,width=3)
        for j in range(y,y+h,24): d.line([(x,j),(x,min(j+12,y+h))],fill=col,width=3); d.line([(x+w,j),(x+w,min(j+12,y+h))],fill=col,width=3)
    else: d.rounded_rectangle([x,y,x+w,y+h],radius=22,outline=col,width=3)
    f=font(40,'Bold'); tw=d.textlength(title,font=f); d.text((x+(w-tw)/2,y+(28 if sub else (h-50)/2)),title,font=f,fill=tc)
    if sub:
        f2=font(28); 
        for k,s in enumerate(sub.split('\n')):
            sw=d.textlength(s,font=f2); d.text((x+(w-sw)/2,y+86+k*40),s,font=f2,fill=LO)
def arrow(x1,y1,x2,y2,col=LO):
    d.line([(x1,y1),(x2,y2)],fill=col,width=4)
    import math; a=math.atan2(y2-y1,x2-x1)
    for s in (2.6,-2.6): d.line([(x2,y2),(x2+22*math.cos(a+s),y2+22*math.sin(a+s))],fill=col,width=4)
ctext(d,60,'判斷交給規則，說話交給車上的小模型',font(48,'Bold'),HI)
box(80,330,330,250,'車輛訊號','CO2・車溫・車速\n盲點訊號（模擬）・提問')
arrow(420,455,560,455)
d.rounded_rectangle([570,190,1290,800],radius=28,outline=(90,90,98),width=3)
d.text((600,205),'AI Box（車上・離線・Qwen2.5-1.5B 在手機上執行）',font=font(32,'Bold'),fill=LO)
box(620,270,620,140,'規則引擎：決定做什麼',None)
box(620,440,620,140,'端側小模型：講成一句話',None)
box(620,610,620,140,'知識庫：回答停車提問',None)
arrow(930,410,930,440); 
arrow(1300,360,1440,300); arrow(1300,560,1440,620)
box(1450,200,400,200,'儀表（手機）','時速・檔位・油量\n盲點圖示')
box(1450,520,400,200,'中控（平板）','告知卡片・語音\n停車提問')
d.text((620,812),'安全警示（盲點）：規則直出，不等模型、不靠網路',font=font(30),fill=RED)
box(560,860,740,86,'雲端增強（規劃中，有網路才用）',None,col=(80,80,88),tc=LO,dash=True)
im.save('F:/tmp/edit/card_arch.png')

# 4 end
im=base(); d=ImageDraw.Draw(im)
ctext(d,250,'該說才說',font(120,'Bold'),HI)
ctext(d,420,'會自己動手的安靜座艙 AI',font(54),HI)
d.line([(W/2-60,525),(W/2+60,525)],fill=LINE,width=3)
ctext(d,570,'規則決策｜端側 Qwen2.5-1.5B 措辭｜本地知識庫問答',font(38),HI)
ctext(d,640,'斷網照常運作（Offline First）',font(38),ACC)
ctext(d,740,'感知有度 Sense in Balance',font(36),LO)
im.save('F:/tmp/edit/card_end.png')
print('ok')
