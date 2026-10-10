"""Convert this FigJam PDF's filled vector paths and text layer to native shapes."""
import fitz, json, pathlib, sys
source, output = map(pathlib.Path, sys.argv[1:3])
doc=fitz.open(source); assert len(doc)==1
page=doc[0]; drawings=page.get_drawings()
lines=[l for b in page.get_text('dict',clip=fitz.INFINITE_RECT())['blocks'] for l in b.get('lines',[])]
groups={}; owners={}
for i,d in enumerate(drawings):
 r=d['rect']; possible=[]
 if len(d['items'])<12 or len(d['items'])==48: continue
 if not (max(d['fill'])-min(d['fill'])<.001 and (max(d['fill'])<.5 or min(d['fill'])>.99)): continue
 for j,l in enumerate(lines):
  b=fitz.Rect(l['bbox']); size=max(s['size'] for s in l['spans'])
  if b.x0>=r.x0-size*.7 and b.x1<=r.x1+max(size,b.width*.06) and b.y0>=r.y0-size*.8 and b.y1<=r.y1+size*.8: possible.append(j)
 if not possible: continue
 union=fitz.Rect(lines[possible[0]]['bbox'])
 for j in possible[1:]: union|=fitz.Rect(lines[j]['bbox'])
 size=max(s['size'] for j in possible for s in lines[j]['spans'])
 if max(abs(union.x0-r.x0),abs(union.x1-r.x1))<max(size,r.width*.04) and max(abs(union.y0-r.y0),abs(union.y1-r.y1))<size:
  groups[i]=possible
  for j in possible: owners.setdefault(j,[]).append(i)
# Reject ambiguous text-to-artwork mapping instead of silently dropping artwork.
unmatched=[j for j in range(len(lines)) if j not in owners]
print('text lines',len(lines),'matched',len(owners),'removed glyph paths',len(groups),'unmatched',unmatched)
for j in unmatched: print(j, ''.join(s['text'] for s in lines[j]['spans']))
P='com.apple.apps.content-language.'
def model(t,**k):return {'type_identifier':P+t,'version':'1.0',**k}
def color(rgb,alpha=1):return model('fill',primary_case='color',color=model('color',primary_case='rgba',rgba={**model('color.rgba',red=rgb[0],green=rgb[1],blue=rgb[2],alpha=alpha,headroom=1,color_space='srgb'),'version':'1.1'}))
def shape(r,path,rgb,opacity=1):
 return model('shape',description='',aspect_ratio_locked=False,tail='none',head='none',stroke='empty',opacity=opacity,fill=color(rgb),path=model('path',primary_case='bezier',bezier=model('path.bezier-path',path=path)),text=model('text',primary_case='attributed_string',attributed_string=['',{}]),geometry=model('geometry',position=model('position',x=r.x0,y=r.y0),size=model('size',width=max(r.width,.01),height=max(r.height,.01)),flip_horizontally=False,width_valid=True,height_valid=True,angle=0),layout_properties=model('layout-properties',shrink_to_fit=False,vertical_alignment='top',padding=model('insets',left=0,right=0,top=0,bottom=0)))
objects=[]
for i,d in enumerate(drawings):
 if i in groups: continue
 r=d['rect']; commands=[]; last=None
 def xy(pt): return f'{pt.x-r.x0:.5f} {pt.y-r.y0:.5f}'
 for item in d['items']:
  kind=item[0]
  if kind in ('l','c'):
   start=item[1]
   if last is None or abs(start.x-last.x)+abs(start.y-last.y)>.001:
    if last is not None: commands.append('Z')
    commands.append('M '+xy(start))
   commands.append(('L ' if kind=='l' else 'C ')+' '.join(xy(v) for v in item[2:]))
   last=item[-1]
  elif kind=='re':
   q=item[1];commands.append(f'M {xy(q.tl)} L {xy(q.tr)} L {xy(q.br)} L {xy(q.bl)} Z');last=None
  elif kind=='qu':
   q=item[1];commands.append(f'M {xy(q.ul)} L {xy(q.ur)} L {xy(q.lr)} L {xy(q.ll)} Z');last=None
  else:raise ValueError(kind)
 commands.append('Z')
 objects.append(shape(r,' '.join(commands),d['fill'],d['fill_opacity']))
texts=[]
for j,l in enumerate(lines):
 text=''.join(s['text'] for s in l['spans']).strip('\n')
 if not text:continue
 r=fitz.Rect(l['bbox']);size=max(s['size'] for s in l['spans'])
 owner=owners.get(j,[])
 rgb=drawings[owner[0]]['fill'] if owner else (0.1176,)*3
 # Body copy is 14pt; the PDF's unnamed Type3 font loses weight metadata.
 bold=size>=24 or (size==16 and any(s['text'].endswith('\n') for s in l['spans']))
 texts.append({'text':text,'x':r.x0,'baseline':l['spans'][0]['origin'][1],'width':r.width,'size':size,'bold':bold,'color':rgb})
output.mkdir(parents=True,exist_ok=True)
(output/'vectors.json').write_text(json.dumps(objects))
(output/'texts.json').write_text(json.dumps(texts,ensure_ascii=False))
(output/'mapping.json').write_text(json.dumps({'glyphPaths':groups,'unmatchedLines':unmatched,'sourcePathCount':len(drawings),'vectorObjects':len(objects),'textObjects':len(texts)},indent=2))
print('vectors',len(objects),'texts',len(texts))
