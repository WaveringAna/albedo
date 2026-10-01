"""Small page-side functions; values cross the boundary, not live JS handles."""

STATE = r"""function() {
  const e = this.nodeType === 1 ? this : this.parentElement;
  if (!e || !e.isConnected) return {connected:false};
  const r = e.getBoundingClientRect(), s = getComputedStyle(e);
  return {connected:true, tag:e.tagName.toLowerCase(), type:e.type || '',
    disabled:!!e.disabled || e.getAttribute('aria-disabled') === 'true',
    readonly:!!e.readOnly || e.getAttribute('aria-readonly') === 'true',
    editable:e.isContentEditable,
    visible:r.width > 0 && r.height > 0 && s.visibility === 'visible'
      && s.display !== 'none' && Number(s.opacity) !== 0,
    width:r.width, height:r.height};
}"""

CONTAINS = r"""function(hit) {
  const e = this.nodeType === 1 ? this : this.parentElement;
  for (let n = hit; n; n = n.parentNode || n.host) if (n === e) return true;
  return false;
}"""

SELECT_TEXT = r"""function() {
  this.focus();
  if (this.getRootNode().activeElement !== this) return false;
  if (typeof this.select === 'function') this.select();
  else if (this.isContentEditable) {
    const range = this.ownerDocument.createRange(); range.selectNodeContents(this);
    const sel = this.ownerDocument.getSelection(); sel.removeAllRanges(); sel.addRange(range);
  } else return false;
  return true;
}"""

READ_VALUE = (
    r"""function() { return this.isContentEditable ? this.textContent : this.value; }"""
)
