
import subprocess, bisect
offsets = [656020, 66796, 309124, 565328]
dylib = "/Users/admin/er174/.theos/obj/debug/arm64/EchoReborn.dylib"
out = subprocess.run(["nm","-n",dylib], capture_output=True, text=True).stdout
syms=[]
for line in out.splitlines():
    parts=line.split(" ",2)
    if len(parts)>=3:
        try: addr=int(parts[0],16)
        except: continue
        sym=parts[2].strip()
        # 跳过 dSYM 行
        syms.append((addr,sym))
syms.sort()
addrs=[a for a,_ in syms]
for off in offsets:
    i=bisect.bisect_right(addrs, off)-1
    a,n=syms[i]
    nxt=syms[i+1][0] if i+1<len(syms) else a+0x20000
    print(f"offset {off}: {n}  (delta {off-a})")
