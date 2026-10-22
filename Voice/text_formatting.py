"""Explicit spoken formatting commands, without rewriting meaning or using a service."""
import re

def format_text(text,enabled=False):
    if not enabled:return text
    # Only strip an explicit leading mode instruction, never a mid-sentence mention.
    match=re.match(r"^(?:hey[, ]+)?(?:i(?:'m| am) (?:creating|writing) (?:an? )?|(?:write|compose) (?:an? )?)(email|sms|text message)[\s,:.!-]+",text,flags=re.I)
    mode=None
    if match:mode=match.group(1).lower();text=text[match.end():].lstrip()
    text=re.sub(r'\s*\bnew paragraph\b[,.]?\s*','\n\n',text,flags=re.I)
    text=re.sub(r'\s*\bnew line\b[,.]?\s*','\n',text,flags=re.I)
    if mode=='email':
        # Separate a greeting and closing only where punctuation already supplies a boundary.
        text=re.sub(r'^(Hi|Hello|Dear) ([^,.!?\n]{1,40})[,!]\s+',r'\1 \2,\n\n',text,flags=re.I)
        text=re.sub(r'\s+(Best regards|Kind regards|Thanks|Cheers),\s+',r'\n\n\1,\n',text,flags=re.I)
    return text.strip()

# Writing modes are deterministic and local. They never send or invent content.
_legacy_format_text = format_text

def format_text(text, enabled=False, mode='verbatim', message_sentences=2):
    if mode not in ('verbatim','clean','email','message','bullets'):
        mode='verbatim'
    text=_legacy_format_text(text,enabled)
    if mode=='verbatim':return text
    text=re.sub(r'[ \t]+',' ',text).strip()
    if mode=='email':
        text=re.sub(r'^(Hi|Hello|Dear) ([^,.!?\n]{1,40})[,!]\s+',r'\1 \2,\n\n',text,flags=re.I)
        text=re.sub(r'\s+(Best regards|Kind regards|Thanks|Cheers),\s+',r'\n\n\1,\n',text,flags=re.I)
    elif mode in ('message','bullets'):
        try:count=max(1,min(5,int(message_sentences)))
        except (TypeError,ValueError):count=2
        # Boundaries require sentence punctuation and a following capital letter.
        sentences=re.split(r'(?<=[.!?])\s+(?=[A-Z])',text)
        if mode=='message':text='\n\n'.join(' '.join(sentences[i:i+count]) for i in range(0,len(sentences),count))
        else:text='\n'.join('• '+s for s in sentences if s)
    return text
