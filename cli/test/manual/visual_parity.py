#!/usr/bin/env python3
# /// script
# dependencies = ["pillow>=11,<13"]
# ///
"""Real PTY -> xterm/headless cells -> fixed-font terminal PNG; fake daemon only."""
import argparse, fcntl, hashlib, http.server, json, os, pathlib, pty, selectors, shutil, signal, struct, subprocess, tempfile, termios, threading, time
from PIL import Image, ImageDraw, ImageFont
ROOT=pathlib.Path(__file__).resolve().parents[3]
OUT=pathlib.Path('/tmp/albedo-visual-parity')
SID='deadbeef12345678'
SESSION={'id':SID,'title':'Visual parity session','last_assistant_at':1700000000,'workspace':'/tmp/albedo-visual-fixture','model':'gpt-4o','protocol':'responses','provider':'fixture'}
CAPS=['session_provider','session_workspace','session_extensions','session_tree','session_context','session_commands']
EVENTS={
 'empty':[],
 'markdown':[{'type':'user','text':'show markdown, code, and diff','source':'chat','triggeredAt':'fixture','timestamp':1700000000000},{'type':'message','role':'assistant','text':'# heading\n\n**bold** and *emphasis* with [link](https://example.test)\n\n```go\nfunc main() { fmt.Println("hello") }\n```\n\n- first\n- second\n','timestamp':1700000001000},{'type':'usage','model':'gpt-4o','promptTokens':123,'completionTokens':45,'totalTokens':168}],
 'tool':[{'type':'user','text':'inspect source and change code','source':'chat','triggeredAt':'fixture','timestamp':1700000000000},{'type':'thinking','text':'checking the old function before editing\n'},{'type':'tool','name':'edit','args':{'path':'main.go'},'result':'success','trace':{'activities':[{'kind':'read','target':'main.go'}],'changes':[{'path':'main.go','kind':'diff','diff':'@@ -1,3 +1,3 @@\n-old value\n+new value','added':1,'removed':1}]}},{'type':'message','role':'assistant','text':'Updated main.go and verified the change.','timestamp':1700000001000}],
 'chat-error':[{'type':'error','text':'fixture generated recoverable error'}],
 'long':[{'type':'user','text':'show long response','source':'chat','triggeredAt':'fixture'}, {'type':'message','role':'assistant','text':'\n'.join(f'line {i:02d} of a long answer' for i in range(1,91))}],
 'queued':[{'type':'user','text':'first prompt','source':'chat','triggeredAt':'fixture'},{'type':'thinking','text':'still processing the first request'}],
}
EVENTS['scroll']=[entry for i in range(1,31) for entry in ({'type':'user','text':f'question {i:02d}','source':'chat','triggeredAt':'fixture'},{'type':'message','role':'assistant','text':f'answer {i:02d} with detailed context ' + ('more text ' * 6) + ('FINAL_SCROLL_ANCHOR' if i==30 else '')})]
class Fixture:
 def __init__(self,home,scenario,variant='default'):
  self.home=home;self.scenario=scenario;self.variant=variant;self.logs=[];self.stop=threading.Event();self.server=None
 def start(self):
  outer=self
  class Handler(http.server.BaseHTTPRequestHandler):
   def log_message(self,*args): pass
   def answer(self,value,status=200):
    data=json.dumps(value).encode();self.send_response(status);self.send_header('content-type','application/json');self.send_header('content-length',str(len(data)));self.end_headers();self.wfile.write(data)
   def do_GET(self):
    if self.headers.get('authorization')!='Bearer visual-fixture': return self.answer({'error':'unauthorized'},401)
    path=self.path.split('?')[0];outer.logs.append(['GET',self.path]);s=outer.scenario;v=outer.variant
    if path=='/health':return self.answer({'ok':True,'version':2,'capabilities':CAPS})
    if path=='/sessions' and v=='picker-error':
     outer.session_reads=getattr(outer,'session_reads',0)+1
     if outer.session_reads>1:return self.answer({'error':'fixture session listing unavailable'},503)
    if path=='/sessions':return self.answer([] if s in ('empty-picker','first-login') else [SESSION])
    if path.startswith('/models/') and v=='model-catalog-error':return self.answer({'error':'fixture model catalog unavailable'},503)
    if path.startswith('/models/'):return self.answer(['gpt-4o','gpt-4o-mini','o3-mini'])
    if path.endswith('/status'):return self.answer({'running':s in ('queued','tool-progress'),'idle':s not in ('queued','tool-progress'),'phase':'reasoning' if s=='queued' else 'resting'})
    if path.endswith('/stream'):
     self.send_response(200);self.send_header('content-type','text/event-stream');self.send_header('cache-control','no-cache');self.end_headers()
     events=EVENTS.get(s,[])
     if s=='tool-progress':events=[{'type':'user','text':'inspect and edit src/main.go','source':'chat','triggeredAt':'fixture'}]
     if v=='stream-reconnect':
      outer.stream_connections=getattr(outer,'stream_connections',0)+1
      events=[{'type':'user','text':'stream before reconnect','source':'chat','triggeredAt':'fixture'}] if outer.stream_connections==1 else [{'type':'retry'},{'type':'message','text':'stream recovered after reconnect','timestamp':1700000001000}]
     try:
      self.wfile.write(('data: '+json.dumps({'cursor':1,'events':[{'type':'reset'},*events]})+'\n\n').encode());self.wfile.flush()
      if s=='tool-progress':
       if outer.stop.wait(.3):return
       making={'type':'tool_progress','progress':{'callId':'fixture-call-1','name':'edit','phase':'generating','intent':{'kind':'read','target':'src/main.go'},'code':{'offset':0,'text':'console.log(\"fixture\")'}}}
       self.wfile.write(('data: '+json.dumps({'cursor':2,'events':[making]})+'\n\n').encode());self.wfile.flush()
       if outer.stop.wait(1.0):return
       running={'type':'tool_progress','progress':{'callId':'fixture-call-1','name':'edit','phase':'running','intent':{'kind':'edit','target':'src/main.go'}}}
       self.wfile.write(('data: '+json.dumps({'cursor':3,'events':[running]})+'\n\n').encode());self.wfile.flush()
      if v=='stream-reconnect' and outer.stream_connections==1:return
      while not outer.stop.wait(.25):self.wfile.write(b': alive\n\n');self.wfile.flush()
     except (BrokenPipeError,ConnectionResetError):pass
     return
    if path.endswith('/commands'):return self.answer([{'name':'/work','description':'manage work','method':'work','arguments':[],'modelCallable':False,'userTurn':False,'page':True},{'name':'/review','description':'review changes','method':'review','arguments':[],'modelCallable':False,'userTurn':True}])
    if path.endswith('/extensions') and v=='extension-error':return self.answer({'error':'fixture extension unavailable'},503)
    if path.endswith('/extensions') and v=='extension-empty':return self.answer([])
    if path.endswith('/extensions'):return self.answer([{'name':'search','description':'search repository','enabled':True,'context':True,'tools':['search'],'python_modules':[],'requires':[]},{'name':'notes','description':'session notes','enabled':False,'context':False,'tools':[],'python_modules':['notes'],'requires':[]}])
    if path.endswith('/tree') and v=='tree-pages':
     after=int((self.path.split('after=')[-1].split('&')[0] if 'after=' in self.path else '0'))
     return self.answer({'items':[{'id':after+1,'type':'user','preview':f'checkpoint {after+1}'},{'id':after+2,'type':'assistant','preview':f'checkpoint {after+2}'}],'nextCursor':after+2 if after<2 else None,'hasMore':after<2})
    if path.endswith('/tree') and v=='tree-error':return self.answer({'error':'fixture tree unavailable'},503)
    if path.endswith('/tree') and v=='tree-empty':return self.answer({'items':[],'nextCursor':None,'hasMore':False})
    if path.endswith('/tree'):return self.answer({'items':[{'id':1,'type':'user','preview':'show markdown, code, and diff'},{'id':2,'type':'assistant','preview':'heading and examples'}],'nextCursor':None,'hasMore':False})
    if path.endswith('/context') and v=='context-pages':return self.answer({'state':'ready','model':'gpt-4o','provider':'fixture','context_window_tokens':128000,'sections':[{'id':'instructions','label':'Instructions','kind':'instructions','source':'fixture','item_count':60,'byte_count':4000,'preview':'long prepared request','pages':2}],'compaction':{'status':'not_needed'}})
    if path.endswith('/context') and v=='context-pending':return self.answer({'state':'pending','reason':'no request has been prepared'})
    if path.endswith('/context') and v=='context-error':return self.answer({'error':'fixture context unavailable'},503)
    if path.endswith('/context'):return self.answer({'state':'ready','model':'gpt-4o','provider':'fixture','context_window_tokens':128000,'sections':[{'id':'instructions','label':'Instructions','kind':'instructions','source':'fixture','item_count':2,'byte_count':256,'preview':'You are an assistant','pages':1}],'compaction':{'status':'not_needed'}})
    if '/context/' in path and v=='context-page-error':return self.answer({'error':'fixture context page unavailable'},503)
    if '/context/' in path and v=='context-pages':
     page=int(path.rsplit('/',1)[-1]);return self.answer({'section':'instructions','page':page,'pages':2,'content':'\n'.join(f'prepared context page {page+1} line {i:02d} with wrapped words '+('detail '*12) for i in range(1,61))})
    if '/context/' in path:return self.answer({'section':'instructions','page':0,'pages':1,'content':'You are an assistant.\nFollow instructions.'})
    return self.answer({'error':'unhandled fixture GET '+self.path},404)
   def do_POST(self):
    if self.headers.get('authorization')!='Bearer visual-fixture':return self.answer({'error':'unauthorized'},401)
    data=self.rfile.read(int(self.headers.get('content-length',0)));body=json.loads(data or b'{}');outer.logs.append(['POST',self.path,body]);path=self.path.split('?')[0]
    if path=='/sessions':return self.answer(SESSION,201)
    if path.endswith('/events') and outer.scenario=='chat-recovery' and not hasattr(outer,'workspace_fixed'):return self.answer({'code':'workspace_missing','workspace':'/tmp/missing-workspace','error':'workspace not found'},404)
    if path.endswith('/events'):return self.answer({'ok':True,'queued':outer.scenario=='queued'})
    if path.endswith('/workspace') and outer.variant=='workspace-replace-error':return self.answer({'error':'fixture workspace replacement rejected'},503)
    if path.endswith('/workspace'):
     outer.workspace_fixed=True;return self.answer({'workspace':body.get('workspace','/tmp/albedo-visual-fixture')})
    if path.endswith('/interrupt'):return self.answer({'ok':True,'interrupted':True})
    if path.endswith('/extensions') and outer.variant=='extension-toggle-error':return self.answer({'error':'fixture extension toggle unavailable'},503)
    if path.endswith('/extensions'):return self.answer([{'name':'search','description':'search repository','enabled':False,'context':True,'tools':['search'],'python_modules':[],'requires':[]},{'name':'notes','description':'session notes','enabled':False,'context':False,'tools':[],'python_modules':['notes'],'requires':[]}])
    if path.endswith('/commands'):
     name=body.get('name');args=body.get('args') or {}
     if name=='/model' and outer.variant=='model-switch-error':return self.answer({'error':'fixture model switch unavailable'},503)
     if name=='/model' and outer.variant=='model-switch-delayed':time.sleep(.8)
     if name=='/model':return self.answer({'result':{'model':args.get('model','gpt-4o-mini'),'provider':args.get('provider','fixture'),'protocol':'responses'}})
     if name=='/work' and args.get('action') and outer.variant=='page-action-error':return self.answer({'error':'fixture page action unavailable'},503)
     if name=='/work' and outer.variant=='page-error':return self.answer({'error':'fixture page unavailable'},503)
     if name=='/work' and args.get('action'):return self.answer({'result':{'message':'fixture '+args['action']+' completed'}})
     if name=='/work':
      rows=[] if outer.variant=='page-empty' else [{'id':'1','text':'fix the flaky test','badge':'active','tone':'active'},{'id':'2','text':'document login','badge':'blocked','tone':'warning'}]
      page={'title':'Work queue','summary':f'{len(rows)} items','empty':'nothing tracked yet','rows':rows,'actions':[{'key':'a','label':'add','run':'add','row':False,'confirm':False,'input':'text','prompt':'title','prefill':False},{'key':'s','label':'status','run':'status','row':True,'confirm':False,'input':'choice','options':['active','blocked','done']},{'key':'x','label':'remove','run':'remove','row':True,'confirm':True,'input':'none'}],'glance':{'title':'work','rows':rows}}
      return self.answer({'result':{'page':page}})
     return self.answer({'result':{'message':'fixture command completed'}})
    if path.endswith('/fork') and outer.variant=='tree-fork-error':return self.answer({'error':'fixture cannot create branch'},503)
    if path.endswith('/fork'):return self.answer({**SESSION,'id':'branchdeadbeef123'})
    return self.answer({'error':'unhandled fixture POST '+path},404)
  self.server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=self.server.serve_forever,daemon=True).start()
  self.home.mkdir(parents=True,exist_ok=True)
  (self.home/'daemon.json').write_text(json.dumps({'port':self.server.server_port,'token':'visual-fixture','pid':os.getpid(),'version':2}))
  if self.scenario not in ('login','codex-login','first-login','first-login-existing'):
   providers={'fixture':{'extension':'openai','baseUrl':f'http://127.0.0.1:{self.server.server_port}','apiKey':'fake-not-real','model':'gpt-4o','protocol':'responses'}}
   if self.scenario=='saved-login':providers['second']={'extension':'openai','baseUrl':f'http://127.0.0.1:{self.server.server_port}','apiKey':'fake-second','model':'o3-mini','protocol':'chat_completions'}
   (self.home/'config.json').write_text(json.dumps({'active':'fixture','providers':providers}))
 def close(self):self.stop.set();self.server.shutdown();self.server.server_close()
KEYS={'enter':b'\r','esc':b'\x1b','up':b'\x1b[A','down':b'\x1b[B','left':b'\x1b[D','right':b'\x1b[C','pgup':b'\x1b[5~','pgdn':b'\x1b[6~','ctrl-c':b'\x03','ctrl-j':b'\n','ctrl-v':b'\x16','ctrl-k':b'\x0b','ctrl-home':b'\x1b[1;5H','ctrl-end':b'\x1b[1;5F','shift-enter':b'\x1b[13;2u','alt-enter':b'\x1b\r','backspace':b'\x7f','tab':b'\t'}
def run(binary,home,scenario,size,actions,snapshots,timeout):
 cols,rows=size;master,slave=pty.openpty();fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',rows,cols,0,0));os.set_blocking(master,False)
 shim=home/'bin';shim.mkdir();
 for command in ('open','xdg-open','cmd'):
  launcher=shim/command;launcher.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$ALBEDO_HOME/browser-blocked.log"\nexit 0\n');launcher.chmod(0o755)
 # The shipped Go clipboard uses PATH lookup for pbcopy. Drain synthetic fixture
 # selection bytes; never open or modify the host clipboard, even on failure.
 copy=shim/'pbcopy';copy.write_text('#!/bin/sh\ncat >/dev/null\nprintf "invoked\n" >> "$ALBEDO_HOME/clipboard-blocked.log"\nif [ "$ALBEDO_VISUAL_COPY_FAIL" = 1 ]; then exit 1; fi\nexit 0\n');copy.chmod(0o755)
 paste=shim/'pbpaste';paste.write_text('#!/bin/sh\nprintf "read-blocked\n" >> "$ALBEDO_HOME/clipboard-blocked.log"\nexit 1\n');paste.chmod(0o755)
 env={'PATH':str(shim)+os.pathsep+os.environ.get('PATH',''),'HOME':str(home),'TMPDIR':str(home),'LANG':'en_US.UTF-8','ALBEDO_ROOT':str(ROOT),'ALBEDO_HOME':str(home),'ALBEDO_NO_BROWSER':'1','SSH_CONNECTION':'visual-fixture-no-clipboard','ALBEDO_USE_TS':'1' if binary.startswith('ts') else '0','TERM':'xterm-256color','COLORTERM':'truecolor','FORCE_COLOR':'3','CLICOLOR':'1','CLICOLOR_FORCE':'1','NODE_OPTIONS':'--import='+str(ROOT/'cli/test/manual/visual_codex_preload.mjs') if binary.startswith('ts') else ''}
 env.pop('NO_COLOR',None)
 if binary=='ts-clipboard':env['TSX_TSCONFIG_PATH']=str(ROOT/'cli/tsconfig.json')
 if getattr(run,'fixture_variant','')=='codex-exchange-error':env['ALBEDO_VISUAL_AUTH_ERROR']='1'
 if getattr(run,'fixture_variant','')=='clipboard-fail':env['ALBEDO_VISUAL_COPY_FAIL']='1'
 args_program=getattr(run,'program_args',None)
 cmd=['node',str(ROOT/'cli/bin/albedo.mjs')] if binary=='ts' else ['node','--import',str(ROOT/'cli/node_modules/tsx/dist/loader.mjs'),str(ROOT/'cli/test/manual/chat-clipboard.tsx')] if binary=='ts-clipboard' else [str(binary)]
 if args_program is not None:cmd+=args_program
 elif binary=='ts-clipboard':pass
 elif scenario in ('login','saved-login','codex-login'):cmd+=['login']
 elif scenario not in ('empty-picker','picker','first-login','first-login-existing'):cmd+=['resume',SID]
 proc=subprocess.Popen(cmd,cwd=ROOT,env=env,stdin=slave,stdout=slave,stderr=slave,start_new_session=True);os.close(slave)
 select=selectors.DefaultSelector();select.register(master,selectors.EVENT_READ);raw=bytearray();start=time.monotonic();todo=sorted(actions);taken={}
 try:
  while time.monotonic()-start<timeout and proc.poll() is None:
   for _,_ in select.select(.025):
    try:raw.extend(os.read(master,65536))
    except OSError:pass
   t=time.monotonic()-start
   while todo and t>=todo[0][0]:
    _,key=todo.pop(0);os.write(master,KEYS.get(key,key.encode()));
   for label,at in snapshots.items():
    if label not in taken and t>=at:taken[label]=bytes(raw)
  for label in snapshots:
   if label not in taken:taken[label]=bytes(raw)
 finally:
  forced=proc.poll() is None
  if forced:
   os.killpg(proc.pid,signal.SIGTERM)
   try:proc.wait(timeout=1)
   except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait()
  try:
   while True:
    chunk=os.read(master,65536)
    if not chunk:break
    raw.extend(chunk)
  except OSError:pass
  select.close();os.close(master)
 return taken,bytes(raw),proc.returncode,forced,cmd,{key:env.get(key) for key in ('TERM','COLORTERM','FORCE_COLOR','CLICOLOR','CLICOLOR_FORCE','NO_COLOR','ALBEDO_NO_BROWSER','SSH_CONNECTION','ALBEDO_HOME','HOME','TMPDIR','ALBEDO_ROOT','PATH','NODE_OPTIONS','ALBEDO_VISUAL_AUTH_ERROR')}
COLORS=[(0,0,0),(205,49,49),(13,188,121),(229,229,16),(36,114,200),(188,63,188),(17,168,205),(229,229,229),(102,102,102),(241,76,76),(35,209,139),(245,245,67),(59,142,234),(214,112,214),(41,184,219),(255,255,255)]
def color(mode,value,default):
 if mode==0:return default
 if mode==0x1000000:return COLORS[value%16]
 if mode==0x3000000:return ((value>>16)&255,(value>>8)&255,value&255)
 if mode==0x2000000:
  if value<16:return COLORS[value]
  if value<232:
   n=value-16;levels=[0,95,135,175,215,255];return (levels[n//36],levels[n//6%6],levels[n%6])
  return ((value-232)*10+8,)*3
 return default
FONT=os.environ.get('ALBEDO_VISUAL_FONT') or next((f for f in ('/System/Library/Fonts/SFNSMono.ttf','/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf') if pathlib.Path(f).exists()),'')
if not FONT:raise RuntimeError('set ALBEDO_VISUAL_FONT to an installed monospace font')
BRAILLE_FONT=os.environ.get('ALBEDO_VISUAL_BRAILLE_FONT') or next((f for f in ('/System/Library/Fonts/Apple Braille.ttf','/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf') if pathlib.Path(f).exists()),'')
UNICODE_FONT=os.environ.get('ALBEDO_VISUAL_FALLBACK_FONT') or next((f for f in ('/System/Library/Fonts/Supplemental/Arial Unicode.ttf','/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf') if pathlib.Path(f).exists()),'')
def render(obj,path):
 font=ImageFont.truetype(FONT,15);bold_path=FONT.replace('.ttf','Bold.ttf');italic_path=FONT.replace('.ttf','Italic.ttf');bold=ImageFont.truetype(bold_path,15) if pathlib.Path(bold_path).exists() else font;italicfont=ImageFont.truetype(italic_path,15) if pathlib.Path(italic_path).exists() else font
 cjk_path=os.environ.get('ALBEDO_VISUAL_CJK_FONT') or next((f for f in ('/System/Library/Fonts/Hiragino Sans GB.ttc','/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc') if pathlib.Path(f).exists()),'');cjkfont=ImageFont.truetype(cjk_path,16) if cjk_path else font
 braille=ImageFont.truetype(BRAILLE_FONT,15) if BRAILLE_FONT else None
 unicode_font=ImageFont.truetype(UNICODE_FONT,15) if UNICODE_FONT else None
 coverage={}
 def visible(face,char):
  key=(id(face),char)
  if key not in coverage:coverage[key]=bool(face.getmask(char).getbbox())
  return coverage[key]
 w,h=10,20;img=Image.new('RGB',(obj['cols']*w,obj['rows']*h),(17,19,24));draw=ImageDraw.Draw(img)
 for y,line in enumerate(obj['cells']):
  for x,c in enumerate(line):
   char,width,fgm,fg,bgm,bg,isbold,dim,inverse,underline,italic=c
   foreground=color(fgm,fg,(215,218,224));background=color(bgm,bg,(17,19,24))
   if isbold and fgm==0x1000000 and fg<8:foreground=COLORS[fg+8]
   if inverse:foreground,background=background,foreground
   if dim:foreground=tuple((v+b)//2 for v,b in zip(foreground,background))
   xx=x*w;yy=y*h
   if background!=(17,19,24):draw.rectangle((xx,yy,xx+w-1,yy+h-1),fill=background)
   if char and width:
    glyph=cjkfont if width==2 else bold if isbold else italicfont if italic else font
    if not char.isspace() and char!='\u2800' and not visible(glyph,char):
     alternate=braille if 0x2800<=ord(char[0])<=0x28ff else unicode_font
     if alternate is None or not visible(alternate,char):raise RuntimeError(f'unsupported glyph U+{ord(char[0]):04X} {char!r}; set ALBEDO_VISUAL_BRAILLE_FONT or ALBEDO_VISUAL_FALLBACK_FONT')
     glyph=alternate
    draw.text((xx,yy-1),char,font=glyph,fill=foreground)
    if isbold and bold is font:draw.text((xx+1,yy-1),char,font=glyph,fill=foreground)
   if underline:draw.line((xx,yy+h-2,xx+w-1,yy+h-2),fill=foreground)
 if obj.get('cursorVisible'):
  x,y=obj['cursor'];draw.rectangle((x*w,y*h,x*w+w-1,y*h+h-1),outline=(230,232,235))
 img.save(path)
def capture(args):
 out=OUT/'atlas'/args.label;out.mkdir(parents=True,exist_ok=True);home=pathlib.Path(tempfile.mkdtemp(prefix='albedo-visual-home-'));fixture=Fixture(home,args.scenario,args.fixture_variant);fixture.start()
 try:
  snapshots={item.split(':')[0]:float(item.split(':')[1]) for item in (args.snap or ['initial:1.2'])};actions=[(float(item.split(':',1)[0]),item.split(':',1)[1]) for item in args.action]
  run.program_args=args.program_arg if args.program_arg else None
  run.fixture_variant=args.fixture_variant
  source_binary=args.binary
  if not args.binary.startswith('ts'):
   source=pathlib.Path(args.binary);digest=hashlib.sha256(source.read_bytes()).hexdigest();store=OUT/'binaries';store.mkdir(exist_ok=True)
   frozen=store/digest
   if not frozen.exists():shutil.copy2(source,frozen)
   args.binary=str(frozen)
  taken,raw,exit_code,forced,cmd,environment=run(args.binary,home,args.scenario,(args.cols,args.rows),actions,snapshots,args.timeout)
  (out/f'{args.side}.pty').write_bytes(raw)
  if (home/'browser-blocked.log').exists(): (out/f'{args.side}.browser-blocked.log').write_bytes((home/'browser-blocked.log').read_bytes())
  if (home/'clipboard-blocked.log').exists(): (out/f'{args.side}.clipboard-blocked.log').write_bytes((home/'clipboard-blocked.log').read_bytes())
  executable=pathlib.Path(cmd[0] if pathlib.Path(cmd[0]).is_file() else shutil.which(cmd[0]) or cmd[0]);source_manifest=OUT/'baseline-ts-sources.json'
  metadata={'command':cmd,'source_binary_path':source_binary,'immutable_binary_path':args.binary,'environment':environment,'actions':actions,'snapshots':snapshots,'size':[args.cols,args.rows],'scenario':args.scenario,'fixture_variant':args.fixture_variant,'exit_code':exit_code,'terminated_by_harness':forced,'requests':fixture.logs,'sha256_executable':hashlib.sha256(executable.read_bytes()).hexdigest() if executable.is_file() else None,'sha256_ts_source_manifest':hashlib.sha256(source_manifest.read_bytes()).hexdigest() if args.binary.startswith('ts') and source_manifest.is_file() else None,'sha256_harness':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),'sha256_renderer':hashlib.sha256((ROOT/'cli/test/manual/visual_terminal.mjs').read_bytes()).hexdigest(),'sha256_fake_auth_preload':hashlib.sha256((ROOT/'cli/test/manual/visual_codex_preload.mjs').read_bytes()).hexdigest() if args.binary.startswith('ts') else None,'sha256_fake_clipboard_driver':hashlib.sha256((ROOT/'cli/test/manual/chat-clipboard.tsx').read_bytes()).hexdigest() if args.binary=='ts-clipboard' else None,'render_font':FONT,'cjk_font':os.environ.get('ALBEDO_VISUAL_CJK_FONT') or ('/System/Library/Fonts/Hiragino Sans GB.ttc' if pathlib.Path('/System/Library/Fonts/Hiragino Sans GB.ttc').exists() else 'fallback'),'assertions':{},'sha256_go_sources':hashlib.sha256(json.dumps({str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted((ROOT/'cli').rglob('*.go')) if 'node_modules' not in str(path)},sort_keys=True).encode()).hexdigest() if not args.binary.startswith('ts') else None,'source_revision':'baseline' if args.side=='before' else 'current' if args.side=='after' else 'manual-driver' if args.binary=='ts-clipboard' else 'reference'}
  for label,data in taken.items():
   rawpath=out/f'{args.side}-{label}.pty';rawpath.write_bytes(data);jsonpath=out/f'{args.side}-{label}.json'
   subprocess.run(['node',str(ROOT/'cli/test/manual/visual_terminal.mjs'),str(rawpath),str(jsonpath),str(args.cols),str(args.rows)],cwd=ROOT/'cli',check=True,timeout=10)
   screenshot=json.loads(jsonpath.read_text());render(screenshot,out/f'{args.side}-{label}.png')
   visible='\n'.join(''.join(c[0] or ' ' for c in row) for row in screenshot['cells'])
   for item in args.expect:
    target,fragment=item.split(':',1)
    if target==label:metadata['assertions'][item]=fragment.lower() in visible.lower()
  for item in args.expect_request:
   method,path=item.split(':',1);metadata['assertions']['request:'+item]=any(req[0]==method and req[1].split('?')[0].endswith(path) for req in fixture.logs)
  if args.expect_exit is not None:metadata['assertions']['exit:'+str(args.expect_exit)]=exit_code==args.expect_exit and not forced
  if args.expect_reset:
   metadata['assertions']['not-forced']=not forced
   def restored(mode):
    enabled=raw.rfind(f'\x1b[?{mode}h'.encode())
    disabled=raw.rfind(f'\x1b[?{mode}l'.encode())
    return enabled<0 or disabled>enabled
   metadata['assertions']['cursor-restored']=raw.rfind(b'\x1b[?25l')<0 or raw.rfind(b'\x1b[?25h')>raw.rfind(b'\x1b[?25l')
   metadata['assertions']['mouse-restored']=all(restored(mode) for mode in (1000,1002,1003,1006))
   metadata['assertions']['alternate-not-entered']=all(f'\x1b[?{mode}h'.encode() not in raw for mode in (47,1047,1049))
  (out/f'{args.side}.actions.json').write_text(json.dumps(metadata,indent=2))
  if any(not value for value in metadata['assertions'].values()):raise AssertionError('capture assertions failed: '+str(metadata['assertions']))
  print(out,','.join(taken),len(raw),'bytes',exit_code,flush=True)
 finally:
  fixture.close()
  shutil.rmtree(home,ignore_errors=True)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--binary',required=True);p.add_argument('--side',required=True);p.add_argument('--label',required=True);p.add_argument('--scenario',default='empty');p.add_argument('--program-arg',action='append',default=[]);p.add_argument('--fixture-variant',default='default');p.add_argument('--cols',type=int,default=120);p.add_argument('--rows',type=int,default=40);p.add_argument('--action',action='append',default=[]);p.add_argument('--snap',action='append',default=[]);p.add_argument('--expect',action='append',default=[]);p.add_argument('--expect-request',action='append',default=[]);p.add_argument('--expect-exit',type=int);p.add_argument('--expect-reset',action='store_true');p.add_argument('--timeout',type=float,default=2.5);capture(p.parse_args())
