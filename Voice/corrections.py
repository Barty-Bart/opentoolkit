"""Conservative, local, explicitly confirmed correction rules."""
import difflib,json,re,time,uuid,logging
from pathlib import Path

def candidate(before,after):
    a=re.findall(r"\w+(?:['’-]\w+)*|[^\w\s]",before)
    b=re.findall(r"\w+(?:['’-]\w+)*|[^\w\s]",after)
    edits=[(tag,i,j,k,l) for tag,i,j,k,l in difflib.SequenceMatcher(None,a,b,autojunk=False).get_opcodes() if tag!='equal']
    if len(edits)!=1:return None
    tag,i,j,k,l=edits[0]
    if tag!='replace' or not (1<=j-i<=4 and 1<=l-k<=4):return None
    old,new=' '.join(a[i:j]),' '.join(b[k:l])
    if old.casefold()==new.casefold() or not all(re.fullmatch(r"\w+(?:['’-]\w+)*",w) for w in a[i:j]+b[k:l]):return None
    if max(len(old),len(new))>80:return None
    return old,new

class RuleStore:
    def __init__(self,path):
        self.path=Path(path)
        self.shared=self.path==Path.home()/'Library/Application Support/Pico/Speech/corrections.json'

    def read(self):
        if self.shared:
            from library_store import get_value
            return json.loads(get_value('corrections',self.path,'[]'))
        try:return json.loads(self.path.read_text())
        except FileNotFoundError:return []
    def write(self,rules):
        if self.shared:
            from library_store import set_value
            set_value('corrections',json.dumps(rules));return
        self.path.parent.mkdir(parents=True,exist_ok=True)
        temp=self.path.with_suffix('.tmp');temp.write_text(json.dumps(rules));temp.chmod(0o600);temp.replace(self.path)
    def save(self,old,new):
        rules=self.read()
        # An existing rule is never silently overwritten.
        if any(r['wrong'].casefold()==old.casefold() for r in rules):return None
        item=dict(id=str(uuid.uuid4()),wrong=old,right=new,enabled=True,created=time.time())
        rules.append(item);self.write(rules);return item
    def change(self,identifier,action):
        rules=self.read()
        if action=='undo':rules=[r for r in rules if r['id']!=identifier]
        else:
            for r in rules:
                if r['id']==identifier:r['enabled']=action=='enable'
        self.write(rules)
    def apply(self,text):
        try:rules=[r for r in self.read() if r.get('enabled')]
        except (ValueError,OSError,TypeError,KeyError):
            logging.getLogger('multitool.voice').warning('Correction rules unavailable; preserving original transcript')
            return text
        if not rules:return text
        mapping={r['wrong'].casefold():r['right'] for r in rules}
        pattern=r'(?<!\w)(?:'+'|'.join(re.escape(r['wrong']) for r in sorted(rules,key=lambda r:-len(r['wrong'])))+r')(?!\w)'
        return re.sub(pattern,lambda m:mapping[m.group().casefold()],text,flags=re.I)

class EditWatch:
    def __init__(self,prefix,text,suffix,now):
        self.prefix,self.text,self.suffix=prefix,text,suffix
        self.expected=prefix+text+suffix;self.deadline=now+30
        self.seen=False;self.last=None;self.changed=now;self.done=False;self.focus_lost=None
    def focus_available(self,available,now):
        if self.done or now>self.deadline:self.done=True;return False
        if not available:
            if self.focus_lost is None:self.focus_lost=now
            if now-self.focus_lost>=1.0:self.done=True
            return not self.done
        if self.focus_lost is not None and now-self.focus_lost>=1.0:
            self.done=True;return False
        self.focus_lost=None
        return True
    def poll(self,value,now):
        if self.done or now>self.deadline:self.done=True;return None
        if not isinstance(value,str) or len(value)>100000:self.done=True;return None
        if not self.seen:
            if value==self.expected:self.seen=True
            elif now>self.deadline-28:self.done=True
            return None
        if not value.startswith(self.prefix) or (self.suffix and not value.endswith(self.suffix)):
            self.done=True;return None
        end=len(value)-len(self.suffix) if self.suffix else len(value)
        current=value[len(self.prefix):end]
        if current!=self.last:self.last=current;self.changed=now;return None
        if current==self.text or now-self.changed<1.5:return None
        result=candidate(self.text,current)
        if result:self.done=True
        return result
