#!/usr/bin/env python3
"""Build the four branded HTML scenes without redrawing product UI."""
from pathlib import Path
import math, wave, struct

root=Path(__file__).resolve().parent
scenes=root/'compositions/frames';scenes.mkdir(parents=True,exist_ok=True)
base='''#root{position:relative;width:100%;height:100%;overflow:hidden;font-family:system-ui,sans-serif;color:#24262b} .clip{position:absolute;inset:0}.ground{background:radial-gradient(ellipse at 82% 90%,#e4f2fc 0,transparent 65%),#fcfdff}.content{position:absolute;inset:0}.label{font-size:28px;color:#4e68b1;font-weight:550;letter-spacing:2px}.headline{font-size:86px;font-weight:650;line-height:1.22;letter-spacing:-3px;margin:24px 0 34px}.support{font-size:33px;color:#626b78;line-height:1.65}.note{font-size:28px;color:#626b78;line-height:1.6}.product{position:absolute;border-radius:30px;box-shadow:0 22px 70px #42527314}.brand{position:absolute;display:flex;align-items:center;gap:20px}.brand img{width:110px;height:110px}.brand b{font-size:46px;font-weight:600}.brand small{display:block;font-size:28px;letter-spacing:4px;color:#626b78;margin-top:6px}'''
def frame(id,body,css,tweens):
    cid='f-'+id
    duration = 8 if id == '04-night' else 8.5
    scoped=base+css
    # Scope authored classes. Runtime-scoped #root remains the root contract.
    import re
    classes=set(re.findall(r'class="([^"]+)"',body))
    names=(set(' '.join(classes).split())-{'clip'}) | {'ground','content'}
    for name in sorted(names,key=len,reverse=True):
        body=re.sub(r'(?<=class=")'+re.escape(name)+r'(?=[" ])',cid+'-'+name,body)
        # also process second/third class in attributes
        body=re.sub(r'(?<= )'+re.escape(name)+r'(?=[" ])',cid+'-'+name,body)
        scoped=re.sub(r'\.'+re.escape(name)+r'(?![\w-])','.'+cid+'-'+name,scoped)
        tweens=tweens.replace('.'+name, '.'+cid+'-'+name)
    html=f'''<template><style>{scoped}</style><div id="root" data-composition-id="{id}" data-width="1920" data-height="1080" data-duration="{duration}"><div id="{id}-ground" class="clip {cid}-ground" data-start="0" data-duration="{duration}" data-track-index="0"></div><div id="{id}-layer" class="clip" data-start="0" data-duration="{duration}" data-track-index="1"><div class="{cid}-content">{body}</div></div></div><script src="assets/gsap.min.js"></script><script>const tl=gsap.timeline({{paused:true}});{tweens}window.__timelines["{id}"]=tl;</script></template>'''
    (scenes/(id+'.html')).write_text(html,encoding='utf-8')

frame('01-hang','''<div class="brand"><img src="assets/icon-light.png"><div><b>拾片</b><small>截图 · 闪念</small></div></div><div class="copy"><div class="label">留住眼前，接着想。</div><div class="headline">把截图与灵感，<br>挂在眼前。</div></div><img class="rope" src="assets/rope-native.png"><div class="support">截图、闪念、待办，在同一条挂绳上。</div>''','''.brand{left:110px;top:68px}.copy{position:absolute;left:110px;top:266px}.headline{font-size:112px}.rope{position:absolute;left:125px;top:640px;width:1670px;border-radius:24px}.support{position:absolute;left:110px;top:920px;font-size:32px}''','''tl.fromTo('.brand',{y:18,opacity:1},{y:0,opacity:1,duration:.8,ease:'power2.out'},0);tl.fromTo('.copy',{y:28,opacity:1},{y:0,opacity:1,duration:1,ease:'power3.out'},.2);tl.fromTo('.rope',{y:-38,opacity:0},{y:0,opacity:1,duration:1.4,ease:'power2.out'},1.8);tl.fromTo('.support',{y:14,opacity:0},{y:0,opacity:1,duration:.8,ease:'power2.out'},4.8);tl.to('.rope',{x:6,duration:3.5,ease:'sine.inOut'},4.3);''')
frame('02-notes','''<div class="copy"><div class="label">给灵感，添上你的注解</div><div class="headline">不只一张图。<br>还有你的想法。</div><div class="support">文字 · 清单 · 图片 · 附件</div><div class="note">自动保存到本机，写完再收回。</div></div><img class="product" src="assets/editor-light.png">''','''.copy{position:absolute;left:100px;top:235px;width:650px}.product{left:830px;top:160px;width:990px}.note{margin-top:80px}.support{font-size:30px}''','''tl.fromTo('.product',{y:18,opacity:.65},{y:0,opacity:1,duration:1,ease:'power2.out'},0);tl.fromTo('.copy',{x:-25,opacity:0},{x:0,opacity:1,duration:.8,ease:'power3.out'},.15);tl.fromTo('.support',{y:15,opacity:0},{y:0,opacity:1,duration:.8,ease:'power2.out'},2.4);tl.fromTo('.note',{y:10,opacity:0},{y:0,opacity:1,duration:.8,ease:'power2.out'},5);tl.to('.product',{scale:1.012,duration:6,ease:'sine.inOut'},1.5);''')
frame('03-library','''<div class="copy"><div class="label">眼前的重点，有序的收藏</div><div class="headline">挂在眼前，也收进记忆里。</div></div><img class="product" src="assets/library-light.png"><div class="support">搜索、排序、取下、恢复</div><div class="note">从绳上取下，内容仍保留。</div>''','''.copy{position:absolute;left:110px;top:70px}.headline{font-size:72px}.product{width:1030px;left:445px;top:260px}.support{position:absolute;left:110px;top:990px;font-size:30px}.note{position:absolute;right:110px;top:995px;font-size:28px}''','''tl.fromTo('.copy',{y:18,opacity:0},{y:0,opacity:1,duration:.8,ease:'power2.out'},0);tl.fromTo('.product',{y:25,opacity:.6},{y:0,opacity:1,duration:1.1,ease:'power3.out'},.15);tl.fromTo('.support',{x:-16,opacity:0},{x:0,opacity:1,duration:.8,ease:'power2.out'},2.3);tl.fromTo('.note',{x:16,opacity:0},{x:0,opacity:1,duration:.8,ease:'power2.out'},5);tl.to('.product',{y:-7,duration:5.8,ease:'sine.inOut'},1.5);''')
frame('04-night','''<div class="copy"><div class="label">轻一点，静一点</div><div class="headline">白天与夜里，<br>都安静。</div><div class="support">本地保存 · macOS 原生 · 开源</div></div><img class="product" src="assets/editor-dark.png"><div class="brand"><img src="assets/icon-dark.png"><div><b>拾片</b><small>github.com/LeeYH95/withinsight</small></div></div><div class="note">0.5.14 · macOS 14+ · Apple Silicon</div>''','''.ground{background:radial-gradient(ellipse at 90% 88%,#29364b 0,transparent 68%),#20242c}.copy{position:absolute;left:100px;top:180px;width:650px}.headline{color:#f0f2f7}.label{color:#a9bdf5}.support{color:#b5bfce;font-size:29px}.product{left:835px;top:115px;width:980px}.brand{left:100px;top:760px;color:#f0f2f7}.brand small{color:#b5bfce;letter-spacing:0;font-size:28px}.note{position:absolute;left:115px;top:935px;color:#b5bfce;font-size:28px}''','''tl.fromTo('.product',{y:20,opacity:.5},{y:0,opacity:1,duration:1.1,ease:'power2.out'},0);tl.fromTo('.copy',{y:20,opacity:0},{y:0,opacity:1,duration:.9,ease:'power3.out'},.1);tl.fromTo('.support',{y:12,opacity:0},{y:0,opacity:1,duration:.7,ease:'power2.out'},2.3);tl.fromTo('.brand',{y:18,opacity:0},{y:0,opacity:1,duration:.8,ease:'power2.out'},4.8);tl.fromTo('.note',{opacity:0},{opacity:1,duration:.7},5.5);''')
# Original quiet score: four chords, soft bell phrases, no third-party recording.
rate=22050;length=32
chords=[(130.8128,164.8138,195.9977,246.9417),(110,130.8128,164.8138,195.9977),(87.3071,110,130.8128,164.8138),(97.9989,123.4708,146.8324,174.6141)]
melody=[523.2511,659.2551,783.9909,659.2551,440,523.2511,659.2551,587.3295,349.2282,440,523.2511,659.2551,391.9954,493.8833,587.3295,783.9909]
score=root/'assets/score.wav'
with wave.open(str(score),'wb') as out:
    out.setnchannels(2);out.setsampwidth(2);out.setframerate(rate)
    block=bytearray()
    for i in range(rate*length):
        t=i/rate;part=min(int(t/8),3);u=t%8
        envelope=min(1,u/.9)*min(1,(8-u)/1.7)
        pad=sum(math.sin(2*math.pi*f*t)+.16*math.sin(2*math.pi*2*f*t) for f in chords[part])*.019*envelope
        beat=min(int(t/2),15);dt=t-beat*2;f=melody[beat]
        bell=(math.sin(2*math.pi*f*dt)+.12*math.sin(2*math.pi*2.003*f*dt))*math.exp(-dt*2.1)*min(1,dt/.018)*.065
        fade=min(1,t/.8)*min(1,(length-t)/2)
        val=int(max(-.9,min(.9,(pad+bell)*fade))*32767)
        block.extend(struct.pack('<hh',val,val))
    out.writeframes(block)
print('4 scenes and original score written')
