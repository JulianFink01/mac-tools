'use strict';
const post = value => window.webkit.messageHandlers.terminal.postMessage(value);
const term = new Terminal({cursorBlink:true,fontFamily:'Menlo, monospace',fontSize:13,scrollback:2000,screenReaderMode:true,allowProposedApi:false,theme:{background:'#101418',foreground:'#e1e7ed',cursor:'#5ed9d0',selectionBackground:'#335767'}});
const fit = new FitAddon.FitAddon();term.loadAddon(fit);term.open(document.getElementById('terminal'));
// Remote escape sequences must not read/write the Mac clipboard.
term.parser.registerOscHandler(52,()=>true);
term.onData(data=>post({type:'input',data}));
term.onBinary(data=>post({type:'binary',data:btoa(data)}));
term.onResize(size=>post({type:'resize',columns:size.cols,rows:size.rows}));
window.terminalReceive = data => {try{const bytes=Uint8Array.from(atob(data),c=>c.charCodeAt(0));term.write(bytes,()=>post({type:'ack'}));}catch{post({type:'ack'});}};
window.terminalFocus = ()=>{fit.fit();term.focus();};
window.terminalPaste = text=>term.paste(text);
window.terminalSelection = ()=>term.getSelection();
let resizeTimer;new ResizeObserver(()=>{clearTimeout(resizeTimer);resizeTimer=setTimeout(()=>fit.fit(),40);}).observe(document.getElementById('terminal'));
fit.fit();post({type:'ready',columns:term.cols,rows:term.rows});term.focus();
