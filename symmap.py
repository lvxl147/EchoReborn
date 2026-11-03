
import subprocess
offsets = [656020, 66796, 309124, 565328]
out = subprocess.run(["nm","-n","/Users/admin/er174/.theos/obj/EchoReborn.dylib"],
                     capture_output=True, text=True).stdout
syms=[]
for line in out.splitlines():
    parts=line.split()
    if len(parts)>=3:
        try: addr=int(parts[0],16)
        except: continue
        syms.append((addr,parts[1],parts[2]))
syms.sort()
import bisect
addrs=[a for a,_,_ in syms]
for off in offsets:
    i=bisect.bisect_right(addrs, off)-1
    if i>=0:
        a,t,n=syms[i]
        nxt=syms[i+1][0] if i+1<len(syms) else a+0x10000
        inside = off < nxt
        print(f"offset {off} -> {n} ({t}) start=0x{a:x} {'<= inside' if inside else '(past end)'} delta={off-a}")
