import subprocess, sys, os, struct

def key(src, dst, pad=14, max_dim=512):
    probe = subprocess.check_output([
        'ffprobe','-v','error','-select_streams','v:0',
        '-show_entries','stream=width,height','-of','csv=p=0',src
    ]).decode().strip().split(',')
    w,h = int(probe[0]), int(probe[1])
    raw = subprocess.check_output(['ffmpeg','-v','error','-i',src,'-f','rawvideo','-pix_fmt','rgba','-'])
    assert len(raw) == w*h*4, (len(raw), w, h)
    buf = bytearray(raw)
    minx,miny,maxx,maxy = w,h,-1,-1
    for y in range(h):
        base = y*w*4
        for x in range(w):
            i = base + x*4
            r,g,b,a = buf[i],buf[i+1],buf[i+2],buf[i+3]
            if a == 0:
                continue
            green = g - max(r,b)
            if green > 34:
                buf[i+3] = 0
                continue
            if green > 0:
                buf[i+1] = max(r,b)
                buf[i+3] = int(a * (1.0 - green/34.0))
                a = buf[i+3]
            if a > 8:
                if x < minx: minx = x
                if x > maxx: maxx = x
                if y < miny: miny = y
                if y > maxy: maxy = y
    if maxx < 0:
        raise SystemExit('no foreground')
    x0=max(0,minx-pad); y0=max(0,miny-pad); x1=min(w,maxx+pad+1); y1=min(h,maxy+pad+1)
    cw,ch=x1-x0,y1-y0
    out=bytearray()
    for y in range(y0,y1):
        out += buf[(y*w+x0)*4:(y*w+x1)*4]
    scale = min(1.0, max_dim/max(cw,ch))
    ow,oh = int(round(cw*scale)), int(round(ch*scale))
    if (ow,oh)!=(cw,ch):
        p=subprocess.run(['ffmpeg','-v','error','-f','rawvideo','-pix_fmt','rgba','-s',f'{cw}x{ch}','-i','-',
                          '-vf',f'scale={ow}:{oh}:flags=lanczos','-f','rawvideo','-pix_fmt','rgba','-'],
                         input=bytes(out),capture_output=True,check=True)
        out=bytearray(p.stdout); cw,ch=ow,oh
    p=subprocess.run(['ffmpeg','-v','error','-f','rawvideo','-pix_fmt','rgba','-s',f'{cw}x{ch}','-i','-',
                      '-frames:v','1','-y',dst],input=bytes(out),capture_output=True,check=True)
    print(dst, cw, ch)

if __name__ == '__main__':
    key(sys.argv[1], sys.argv[2])
