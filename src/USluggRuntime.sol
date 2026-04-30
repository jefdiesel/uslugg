// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Bytecode-stored Canvas2D animation runtime for uSlugg.
///
/// Each panel runs an imageData-shift smear loop. Per frame:
///   1. Shift entire imageData by direction × smearAmount
///   2. Trail blend (shifted * ti + current * (1-ti)) — old pixels fade
///   3. Decay toward bg (small fraction per frame) — pieces evolve
///   4. Every dirChgInterval ms, pick a random new direction
///   5. Every sourceInterval ms, regenerate the leading edge
///
/// Modes:
///   - MONOLITH (~0.006%, b(14)==0): forces 1-panel + heavy decay + giant
///     cells + slow speed. Compound-rare archetype.
///   - MIRROR (~6.25%): panel 1 is panel 0 with reversed direction +
///     same colors. Bilateral symmetry.
///   - THEMED (~25%): colors picked from a curated palette tuple instead
///     of random web-safe. Themes: cyber, sunset, noir, pastel, ocean, acid.
///
/// Patterns: noise, random-blocks, checkerboard, stripes, dashes, dots,
/// diagonal-stripes. The first three honor a 3rd "highlight" color in
/// 2-3% of pixels for visual depth.
contract USluggRuntime {
    bytes public constant data = bytes(
        "(()=>{"
        "const K=BigInt(window.KEY);"
        "let r=K;"
        "const b=n=>{const v=Number(r&((1n<<BigInt(n))-1n));r>>=BigInt(n);return v};"
        "const palRGB=i=>{const R=Math.floor(i/36),G=Math.floor((i%36)/6),B=i%6;return{r:R*51,g:G*51,b:B*51}};"
        "const PA=['noise','random-blocks','checkerboard','stripes','dashes','dots','diagonal-stripes'];"
        "const D=[{dx:1,dy:0},{dx:1,dy:1},{dx:0,dy:1},{dx:-1,dy:1},{dx:-1,dy:0},{dx:-1,dy:-1},{dx:0,dy:-1},{dx:1,dy:-1}];"
        // Palette themes — each is an array of palette indices (0..215) sorted dark→light.
        // Picking FG from one half + BG from the other gives natural contrast within theme.
        "const TH={"
        "cyber:[0,5,30,180,185,215],"           // black,blue,neonGreen,red,magenta,white
        "sunset:[78,180,192,196,202,213],"      // brown,red,orange,hotpink,pink,cream
        "noir:[0,43,86,129,172,215],"           // greyscale
        "pastel:[202,167,142,137,213,179],"     // pink,lavender,mint,sky,cream,paleblue
        "ocean:[2,10,21,57,101,179],"           // navy,blue,teal,seagreen,cyan,paleBlue
        "acid:[5,30,35,175,180,185]"            // blue,green,cyan,yellow,red,magenta
        "};"
        "const THK=Object.keys(TH);"
        // ─── PANEL MATH ───────────────────────────────────────────
        // Compound rarity: ~0.006% MONOLITH (1/16384). Forces 1-panel + heavy + giant + slow.
        "const monolith=b(14)===0;"
        "const cntRoll=b(10);const triRoll=b(4);"
        "const cnt=monolith?1:(cntRoll===0?1:(triRoll===0?3:2));"
        "const ori=b(1);"
        // Mirror mode (~6.25%, panel 1 = flipped panel 0). Only meaningful for 2-panel.
        "const mirror=cnt===2&&b(4)===0;"
        // Theme mode (~25%, b(2)===0): colors come from a curated theme.
        "const themed=b(2)===0;"
        "const themeKey=THK[b(3)%THK.length];"
        "const theme=TH[themeKey];"
        // Split: 94% main range 10..90%, 6% rare ultra-thin
        "const rareSplit=b(4)===0;let sp;"
        "if(rareSplit){const side=b(1),thin=1+b(3);sp=side?100-thin:thin}"
        "else{sp=10+(b(7)%81)}"
        "const crossAxis=b(1),splitSide=b(1),sp2=15+(b(6)%71);"
        // Unified mode (~0.78%, panels share an exact color)
        "const unified=!themed&&b(7)===0;"
        // ─── COLOR PICKERS ────────────────────────────────────────
        "const cCh=fc=>{const t=b(4);if(t<14)return fc<3?(4+b(1)):b(1);return Math.max(0,Math.min(5,fc+(b(1)?2:-2)))};"
        "const pickBG=f=>{const fR=Math.floor(f/36),fG=Math.floor((f%36)/6),fB=f%6;return cCh(fR)*36+cCh(fG)*6+cCh(fB)};"
        "const palDist=(a,c)=>{const aR=Math.floor(a/36),aG=Math.floor((a%36)/6),aB=a%6,cR=Math.floor(c/36),cG=Math.floor((c%36)/6),cB=c%6;return Math.abs(aR-cR)+Math.abs(aG-cG)+Math.abs(aB-cB)};"
        "const pickFar=ex=>{for(let a=0;a<6;a++){const c=b(8)%216;let ok=true;for(const e of ex){if(palDist(c,e)<4){ok=false;break}}if(ok)return c}return b(8)%216};"
        // Themed color pick: choose FG from low-half, BG from high-half (natural contrast).
        "const pickThemeFG=()=>theme[b(3)%Math.floor(theme.length/2)];"
        "const pickThemeBG=fg=>{const off=Math.floor(theme.length/2)+(b(3)%Math.ceil(theme.length/2));return theme[off%theme.length]};"
        // Highlight: a third color far from both fg and bg (used in 2-3% of noise/dot/block pixels).
        "const pickHL=(fg,bg)=>themed?theme[(theme.indexOf(fg)+3)%theme.length]:pickFar([fg,bg]);"
        // ─── SIZE / TIMING TIERS ─────────────────────────────────
        "const pickCS=()=>{const t=b(4);"
        "if(t<2)return 2+b(1);if(t<6)return 4+b(2);if(t<11)return 8+b(3);if(t<14)return 17+b(5)%24;return 41+b(6)%40};"
        "const pickSmear=cs=>cs<=6?(1+b(3)):(1+b(5));"
        "const pickTrail=()=>0.50+b(5)*0.015;"
        "const pickDecay=()=>{if(b(4)===0)return 60+b(5)*4;return 5+b(5)};"
        "const pickDirChg=()=>(1+b(2))*1000;"
        // ─── BUILD PANELS ────────────────────────────────────────
        "const ps=[];"
        "function build(fgIdx,bgIdx,patIdx,cs,speed,dirIdx,decay){"
        "const hlIdx=pickHL(fgIdx,bgIdx);"
        "return{patIdx,pattern:PA[patIdx],fgIdx,bgIdx,hlIdx,color1:palRGB(fgIdx),color2:palRGB(bgIdx),color3:palRGB(hlIdx),cellSize:cs,speed,smearAmount:pickSmear(cs),trailIntensity:pickTrail(),decayBps:decay,dirIdx,dirChgInterval:pickDirChg()}}"
        // Panel 0
        "{let fg,bg;"
        "if(themed){fg=pickThemeFG();bg=pickThemeBG(fg)}"
        "else{fg=b(8)%216;bg=pickBG(fg)}"
        "const pIdx=b(3)%7;"
        "const cs=monolith?(60+b(4)%20):pickCS();"
        "const sp0=monolith?(1+b(1)):(1+b(4)%10);"
        "const dec0=monolith?(150+b(5)*3):pickDecay();"
        "ps.push(build(fg,bg,pIdx,cs,sp0,b(3)%8,dec0))}"
        // Panel 1
        "if(cnt>=2){"
        "if(mirror){"
        "const p0=ps[0];"
        "ps.push({...p0,dirIdx:(p0.dirIdx+4)%8,dirChgInterval:pickDirChg()})"
        "}else{"
        "let fg,bg;"
        "if(unified){fg=b(1)?ps[0].fgIdx:ps[0].bgIdx;bg=pickBG(fg)}"
        "else if(themed){const fI=theme.indexOf(ps[0].fgIdx),off=(fI+2+b(2))%theme.length;fg=theme[off];bg=pickThemeBG(fg)}"
        "else{fg=pickFar([ps[0].fgIdx,ps[0].bgIdx]);bg=pickBG(fg)}"
        "let pIdx=b(3)%7;if(pIdx===ps[0].patIdx)pIdx=(pIdx+1)%7;"
        "const offs=b(3)-4;"
        "const spA=Math.max(1,Math.min(10,ps[0].speed+offs));"
        "const dir=(ps[0].dirIdx+2+b(2))%8;"
        "ps.push(build(fg,bg,pIdx,pickCS(),spA,dir,pickDecay()))"
        "}}"
        // Panel 2
        "if(cnt===3){"
        "let fg,bg;"
        "if(themed){const fI=theme.indexOf(ps[1].fgIdx),off=(fI+2+b(2))%theme.length;fg=theme[off];bg=pickThemeBG(fg)}"
        "else{fg=pickFar([ps[0].fgIdx,ps[0].bgIdx,ps[1].fgIdx,ps[1].bgIdx]);bg=pickBG(fg)}"
        "let pIdx=b(3)%7;while(pIdx===ps[0].patIdx||pIdx===ps[1].patIdx)pIdx=(pIdx+1)%7;"
        "const jitter=b(2)-1;"
        "const spA=Math.max(1,Math.min(10,((ps[0].speed+ps[1].speed)/2|0)+jitter));"
        "const dir=((ps[1].dirIdx+2+(b(2)===0?-1:0))+8)%8;"
        "ps.push(build(fg,bg,pIdx,pickCS(),spA,dir,pickDecay()))}"
        // ─── LAYOUT ──────────────────────────────────────────────
        "const SZ=400;"
        "document.body.style.cssText='margin:0;background:#000;display:flex;align-items:center;justify-content:center;height:100vh;overflow:hidden';"
        "const container=document.createElement('div');"
        "container.style.cssText='width:min(100vh,100vw);height:min(100vh,100vw);position:relative;background:#000';"
        "document.body.appendChild(container);"
        "const rs=(()=>{"
        "const sp1=Math.floor(SZ*sp/100);"
        "if(cnt===1)return[{x:0,y:0,w:SZ,h:SZ}];"
        "if(cnt===2)return ori?[{x:0,y:0,w:SZ,h:sp1},{x:0,y:sp1,w:SZ,h:SZ-sp1}]:[{x:0,y:0,w:sp1,h:SZ},{x:sp1,y:0,w:SZ-sp1,h:SZ}];"
        "if(crossAxis===0){"
        "let sec=sp+Math.max(10,Math.floor(sp2*(100-sp)/100));"
        "if(sec>96)sec=96;if(sec<=sp+5)sec=Math.min(96,sp+10);"
        "const sp2px=Math.floor(SZ*sec/100);"
        "return ori?[{x:0,y:0,w:SZ,h:sp1},{x:0,y:sp1,w:SZ,h:sp2px-sp1},{x:0,y:sp2px,w:SZ,h:SZ-sp2px}]:[{x:0,y:0,w:sp1,h:SZ},{x:sp1,y:0,w:sp2px-sp1,h:SZ},{x:sp2px,y:0,w:SZ-sp2px,h:SZ}];"
        "}"
        "const sp2px=Math.floor(SZ*sp2/100);"
        "if(ori===0){"
        "if(splitSide===0)return[{x:0,y:0,w:sp1,h:sp2px},{x:0,y:sp2px,w:sp1,h:SZ-sp2px},{x:sp1,y:0,w:SZ-sp1,h:SZ}];"
        "return[{x:0,y:0,w:sp1,h:SZ},{x:sp1,y:0,w:SZ-sp1,h:sp2px},{x:sp1,y:sp2px,w:SZ-sp1,h:SZ-sp2px}];"
        "}"
        "if(splitSide===0)return[{x:0,y:0,w:sp2px,h:sp1},{x:sp2px,y:0,w:SZ-sp2px,h:sp1},{x:0,y:sp1,w:SZ,h:SZ-sp1}];"
        "return[{x:0,y:0,w:SZ,h:sp1},{x:0,y:sp1,w:sp2px,h:SZ-sp1},{x:sp2px,y:sp1,w:SZ-sp2px,h:SZ-sp1}];"
        "})();"
        "rs.forEach(r=>{r.left=(r.x/SZ)*100;r.top=(r.y/SZ)*100;r.pw=(r.w/SZ)*100;r.ph=(r.h/SZ)*100});"
        "const det=s=>{let v=(s|0)^0x9E3779B9;v^=v<<13;v^=v>>>17;v^=v<<5;return((v>>>0)%10000)/10000};"
        // ─── SMEAR PARTITION ─────────────────────────────────────
        "class SP{"
        "constructor(rect,cfg){"
        "this.config=cfg;"
        "this.div=document.createElement('div');"
        "this.div.style.cssText='position:absolute;left:'+rect.left+'%;top:'+rect.top+'%;width:'+rect.pw+'%;height:'+rect.ph+'%;overflow:hidden';"
        "this.canvas=document.createElement('canvas');"
        "this.canvas.width=rect.w;this.canvas.height=rect.h;"
        "this.canvas.style.cssText='width:100%;height:100%;display:block;image-rendering:pixelated';"
        "this.ctx=this.canvas.getContext('2d');this.ctx.imageSmoothingEnabled=false;"
        "this.div.appendChild(this.canvas);container.appendChild(this.div);"
        "this.dirIdx=cfg.dirIdx;this.direction=D[this.dirIdx];"
        "this.lastSourceTime=0;this.lastDirChange=0;"
        "this.fgRGB=cfg.color1;this.bgRGB=cfg.color2;this.hlRGB=cfg.color3;"
        "const w=this.canvas.width,h=this.canvas.height;"
        "this.bufA=this.ctx.createImageData(w,h);"
        "this.bufB=this.ctx.createImageData(w,h);"
        "this.imageData=this.bufA;"
        "this.initPattern();this.start()"
        "}"
        "getColor(px,py,w){"
        "const cfg=this.config,cs=cfg.cellSize,fg=this.fgRGB,bg=this.bgRGB,hl=this.hlRGB,k=cfg.fgIdx*7+cfg.bgIdx;"
        "switch(cfg.pattern){"
        "case 'checkerboard':return((Math.floor(px/cs)+Math.floor(py/cs))%2===0)?fg:bg;"
        "case 'stripes':return(Math.floor(px/cs)%2===0)?fg:bg;"
        "case 'dashes':{const dl=4+(cfg.fgIdx%6),gl=2+(cfg.bgIdx%5),cyc=dl+gl;return(px%cyc<dl)?fg:bg}"
        "case 'dots':{const v=det(px*73856093^py*19349663^k);if(v<0.02)return hl;return v<0.18?fg:bg}"
        "case 'noise':{const v=det(px*73856093^py*19349663^k);if(v>0.97)return hl;return v>0.5?fg:bg}"
        "case 'random-blocks':{const cx=Math.floor(px/cs),cy=Math.floor(py/cs),v=det(cx*73856093^cy*19349663^k);if(v>0.95)return hl;return v>0.5?fg:bg}"
        "case 'diagonal-stripes':return(Math.floor((px+py)/cs)%2===0)?fg:bg;"
        "}"
        "return fg;"
        "}"
        "initPattern(){"
        "const w=this.canvas.width,h=this.canvas.height,dt=this.imageData.data;"
        "for(let y=0;y<h;y++)for(let px=0;px<w;px++){"
        "const c=this.getColor(px,y,w);"
        "const i=(y*w+px)*4;"
        "dt[i]=c.r;dt[i+1]=c.g;dt[i+2]=c.b;dt[i+3]=255;"
        "}"
        "this.ctx.putImageData(this.imageData,0,0);"
        "}"
        "generateSourceEdge(){"
        "const w=this.canvas.width,h=this.canvas.height,d=this.direction,dt=this.imageData.data;"
        "if(d.dy>0){for(let i=0;i<w;i++){const c=this.getColor(i,0,w),idx=i*4;dt[idx]=c.r;dt[idx+1]=c.g;dt[idx+2]=c.b;dt[idx+3]=255}}"
        "else if(d.dy<0){for(let i=0;i<w;i++){const c=this.getColor(i,h-1,w),idx=((h-1)*w+i)*4;dt[idx]=c.r;dt[idx+1]=c.g;dt[idx+2]=c.b;dt[idx+3]=255}}"
        "else if(d.dx>0){for(let i=0;i<h;i++){const c=this.getColor(0,i,w),idx=(i*w)*4;dt[idx]=c.r;dt[idx+1]=c.g;dt[idx+2]=c.b;dt[idx+3]=255}}"
        "else{for(let i=0;i<h;i++){const c=this.getColor(w-1,i,w),idx=(i*w+w-1)*4;dt[idx]=c.r;dt[idx+1]=c.g;dt[idx+2]=c.b;dt[idx+3]=255}}"
        "}"
        "smear(){"
        "const cfg=this.config,w=this.canvas.width,h=this.canvas.height;"
        "const dt=this.imageData.data;"
        "const next=this.imageData===this.bufA?this.bufB:this.bufA;"
        "const np=next.data;"
        "const ti=cfg.trailIntensity,oti=1-ti;"
        "const decay=cfg.decayBps/1000;"
        "const idecay=1-decay,bgr=this.bgRGB.r,bgg=this.bgRGB.g,bgb=this.bgRGB.b;"
        "const dx=this.direction.dx*cfg.smearAmount,dy=this.direction.dy*cfg.smearAmount;"
        "for(let y=0;y<h;y++)for(let px=0;px<w;px++){"
        "let sx=px-dx,sy=y-dy;sx=(sx+w*100)%w;sy=(sy+h*100)%h;"
        "const si=(sy*w+sx)*4,di=(y*w+px)*4;"
        "const r0=dt[si]*ti+dt[di]*oti;"
        "const g0=dt[si+1]*ti+dt[di+1]*oti;"
        "const b0=dt[si+2]*ti+dt[di+2]*oti;"
        "np[di]=r0*idecay+bgr*decay;"
        "np[di+1]=g0*idecay+bgg*decay;"
        "np[di+2]=b0*idecay+bgb*decay;"
        "np[di+3]=255;"
        "}"
        "this.imageData=next;this.ctx.putImageData(this.imageData,0,0)"
        "}"
        // Random next direction (was +1 deterministic — predictable)
        "rotateDir(){this.dirIdx=Math.floor(Math.random()*8);this.direction=D[this.dirIdx]}"
        "start(){"
        "const self=this;"
        "const animate=ts=>{"
        "if(!self.lastSourceTime)self.lastSourceTime=ts;"
        "if(!self.lastDirChange)self.lastDirChange=ts;"
        "if(ts-self.lastDirChange>=self.config.dirChgInterval){self.rotateDir();self.lastDirChange=ts}"
        "if(ts-self.lastSourceTime>=1000){self.generateSourceEdge();self.lastSourceTime=ts}"
        "self.smear();"
        "setTimeout(()=>requestAnimationFrame(animate),1000/self.config.speed);"
        "};"
        "requestAnimationFrame(animate);"
        "}"
        "}"
        "rs.forEach((r,i)=>new SP(r,ps[i]));"
        "})();"
    );
}
