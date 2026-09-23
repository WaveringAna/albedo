#!/usr/bin/env python3
# /// script
# dependencies = ["pillow>=11,<13"]
# ///
"""Manual side-by-side atlas sheets; originals and PTY traces remain separate."""
import argparse,json,pathlib
from PIL import Image,ImageDraw,ImageFont
atlas=pathlib.Path('/tmp/albedo-visual-parity/atlas')
p=argparse.ArgumentParser();p.add_argument('--group',required=True);p.add_argument('--size',default='80x24');p.add_argument('--sides',nargs='+',default=['ts','before','after']);p.add_argument('--rows-per-sheet',type=int,default=4);args=p.parse_args()
coverage=json.loads((atlas/'coverage.json').read_text())
names=[name for name,item in coverage['matrix'].items() if item['group']==args.group]
folders=[atlas/f'{name}-{args.size}' for name in names]
token={'startup/session picker':'picker','chat/transcript':'chat','model/provider':'model','extension page':'page'}.get(args.group,args.group.lower().split('/')[0])
folders+=[d for d in atlas.glob(f'*{args.size}') if d.is_dir() and token in d.name and d not in folders]
font_path='/System/Library/Fonts/SFNSMono.ttf' if pathlib.Path('/System/Library/Fonts/SFNSMono.ttf').exists() else '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf'
font=ImageFont.truetype(font_path,15)
entries=[]
for directory in folders:
 if not directory.exists():continue
 selected_after='final' if list(directory.glob('final-*.png')) else 'after'
 effective=[selected_after if side=='after' else side for side in args.sides]
 labels={file.stem[len(side)+1:] for side in effective for file in directory.glob(f'{side}-*.png')}
 for label in sorted(labels):
  images={side:directory/f'{effective[index]}-{label}.png' for index,side in enumerate(args.sides)}
  if not any(path.exists() for path in images.values()):continue
  entries.append((directory.name,label,images))
if not entries:raise SystemExit('no screenshots for group/size')
width=max(Image.open(path).width for _,_,images in entries for path in images.values() if path.exists())
height=max(Image.open(path).height for _,_,images in entries for path in images.values() if path.exists())
outbase=atlas/f'contact-{args.group.replace("/","-").replace(" ","-")}-{args.size}'
for page,start in enumerate(range(0,len(entries),args.rows_per_sheet),1):
 chunk=entries[start:start+args.rows_per_sheet]
 canvas=Image.new('RGB',(width*len(args.sides),len(chunk)*(height+32)),(28,28,32));draw=ImageDraw.Draw(canvas)
 for i,(name,label,images) in enumerate(chunk):
  y=i*(height+32)
  for col,side in enumerate(args.sides):
   x=col*width;draw.text((x+8,y+5),f'{name} / {label} / {images[side].stem.split("-",1)[0]}',font=font,fill=(240,240,243))
   if images[side].exists():canvas.paste(Image.open(images[side]).convert('RGB'),(x,y+32))
   else:draw.text((x+16,y+48),'NOT CAPTURED',font=font,fill=(255,100,100))
 out=outbase.with_name(outbase.name+f'-{page:02}.png');canvas.save(out)
 print(out,len(chunk),canvas.size)
