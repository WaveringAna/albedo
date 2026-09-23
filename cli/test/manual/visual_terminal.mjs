import { readFileSync, writeFileSync } from 'node:fs';
import headless from '@xterm/headless';
const { Terminal } = headless;
const [raw, json, cols, rows] = process.argv.slice(2);
const term = new Terminal({ cols:Number(cols), rows:Number(rows), allowProposedApi:true, scrollback:3000, logLevel:'off' });
await new Promise(resolve => term.write(readFileSync(raw).toString('utf8'), resolve));
const buffer = term.buffer.active;
const cursorToggles = [...readFileSync(raw).toString('utf8').matchAll(/\x1b\[\?25([hl])/g)];
const cursorVisible = cursorToggles.length ? cursorToggles.at(-1)[1] === 'h' : true;
const cells = Array.from({length:Number(rows)}, (_, y) => {
  const line=buffer.getLine(buffer.viewportY+y);
  return Array.from({length:Number(cols)}, (_, x) => {
    const cell=line?.getCell(x);
    return cell ? [cell.getChars(),cell.getWidth(),cell.getFgColorMode(),cell.getFgColor(),cell.getBgColorMode(),cell.getBgColor(),cell.isBold(),cell.isDim(),cell.isInverse(),cell.isUnderline(),cell.isItalic()] : ['',1,0,0,0,0,false,false,false,false,false];
  });
});
writeFileSync(json,JSON.stringify({cols:Number(cols),rows:Number(rows),cursor:[buffer.cursorX,buffer.cursorY],cursorVisible,alternate:buffer.type==='alternate',cells}));
term.dispose();
