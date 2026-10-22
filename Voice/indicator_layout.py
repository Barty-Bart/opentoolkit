"""Pure screen geometry for a caret-following recording indicator.

Rectangles use AppKit's bottom-left coordinate space. AX caret rectangles are
converted by the caller using the primary display's top edge.
"""
def place_indicator(visible_frames, mouse, caret, size):
    if not visible_frames:
        return (0, 0)
    width, height = size
    anchor = (caret[0], caret[1] + caret[3] / 2) if caret else mouse
    def distance(frame):
        x, y, w, h = frame
        dx = max(x-anchor[0], 0, anchor[0]-(x+w))
        dy = max(y-anchor[1], 0, anchor[1]-(y+h))
        return dx*dx + dy*dy
    x, y, w, h = min(visible_frames, key=distance)
    if caret:
        px, py = caret[0] + 8, caret[1] - height - 6
        if py < y + 8:
            py = caret[1] + caret[3] + 6
    else:
        px, py = x + (w-width)/2, y + 40
    return (max(x+8, min(px, x+w-width-8)),
            max(y+8, min(py, y+h-height-8)))

def glow_frame(field, visible_frames, caret=None, padding=8):
    """Reject unreliable AX frames; return a padded, screen-clipped field outline."""
    import math
    if not field or not all(math.isfinite(n) for n in field):return None
    x,y,w,h=field
    if w<20 or h<12:return None
    if caret:
        cx,cy,cw,ch=caret
        if not (x-4<=cx<=x+w+4 and y-4<=cy+ch/2<=y+h+4):return None
    candidates=[]
    for sx,sy,sw,sh in visible_frames:
        left,bottom=max(x,sx),max(y,sy);right,top=min(x+w,sx+sw),min(y+h,sy+sh)
        if right-left>=20 and top-bottom>=12 and w*h<=sw*sh*.65:
            candidates.append((right-left)*(top-bottom))
            if len(candidates)==1 or candidates[-1]>=max(candidates):
                result=(max(sx,left-padding),max(sy,bottom-padding),min(sx+sw,right+padding)-max(sx,left-padding),min(sy+sh,top+padding)-max(sy,bottom-padding))
    return result if candidates else None


def place_near_field(frames, field, size):
    """Place beside the real input when precise insertion bounds are unavailable."""
    validated=glow_frame(field,frames,padding=0)
    if validated is None:return None
    x,y,w,h=validated
    width,height=size
    # Below the input at its leading edge; flip inside the upper edge if needed.
    return place_indicator(frames,(x,y),(x,y,1,h),size)
