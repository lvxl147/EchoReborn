
import subprocess, bisect
offsets = [656020, 66796, 309124, 565328]
dylib = "/Users/admin/er174/.theos/obj/debug/arm64/EchoReborn.dylib"
out = subprocess.run(["nm","-n",dylib], capture_output=True, text=True).stdout
syms=[]
for line in out.splitlines():
    parts=line.split()
    if len(parts)>=3:
        try: addr=int(parts[0],16)
        except: continue
        syms.append((addr,parts[1],parts[2]))
syms.sort()
addrs=[a for a,_,_ in syms]
for off in offsets:
    i=bisect.bisect_right(addrs, off)-1
    if i>=0:
        a,t,n=syms[i]
        nxt=syms[i+1][0] if i+1<len(syms) else a+0x20000
        mark = "INSIDE" if off < nxt else "past"
        print(f"offset {off} -> {n} [{t}] start=0x{a:x} delta={off-a} {mark}")
    else:
        print(off, "no symbol before")
