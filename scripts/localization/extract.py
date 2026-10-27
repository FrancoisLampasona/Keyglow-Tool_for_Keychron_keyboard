#!/usr/bin/env python3
"""Inventory Swift display strings without changing protocol identifiers or storage."""
import re,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]

def strings(source):
    def read(pos):
        triple=source.startswith('"""',pos);q='"""' if triple else '"';i=pos+len(q);text='';args=[]
        while i<len(source):
            if source.startswith(q,i): return i+len(q),text,args
            if source.startswith('\\(',i):
                start=i+2;j=start;depth=1
                while j<len(source) and depth:
                    if source[j]=='"':j,_,_=read(j);continue
                    if source[j]=='(':depth+=1
                    if source[j]==')':depth-=1
                    j+=1
                args.append(source[start:j-1]);text+='{'+str(len(args)-1)+'}';i=j
            elif source[i]=='\\' and i+1<len(source):
                text+={'n':'\n','t':'\t','r':'\r','"':'"','\\':'\\','0':'\0'}.get(source[i+1],'\\'+source[i+1]);i+=2
            else:text+=source[i];i+=1
        raise ValueError('Unterminated Swift string')
    i=0
    while i<len(source):
        if source.startswith('//',i):
            end=source.find('\n',i);i=len(source) if end<0 else end+1;continue
        if source.startswith('/*',i):
            end=source.find('*/',i+2);i=len(source) if end<0 else end+2;continue
        if source[i]=='"':
            end,text,args=read(i);yield i,end,text,args
            for arg in args:
                for _,_,nested,nargs in strings(arg):yield i,i,nested,nargs
            i=end
        else:i+=1

def inventory():
    found={}
    for p in sorted((ROOT/'macOS/Sources').glob('*.swift')):
        if p.name.startswith('Localization'):continue
        for start,end,text,args in strings(p.read_text()):
            if not re.search(r'[A-Za-zÀ-ÿ]',text):continue
            found.setdefault(text,[]).append({'file':p.name,'line':p.read_text()[:start].count('\n')+1})
    return found
if __name__=='__main__':
    result=inventory();target=Path(sys.argv[1]) if len(sys.argv)>1 else ROOT/'build/localization-inventory.json'
    target.parent.mkdir(parents=True,exist_ok=True)
    target.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(len(result),'unique strings;',target)
