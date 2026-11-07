// 手順3検証: Elixir 閲覧側が配信するリーダーページのスクリプトから
// 復号まわり（Xorshift32 / xorshiftShuffle / isScrambled / decode）を抜き出し、
// Canvas スタブの上で実行して、スクランブル画像が原画に画素一致で戻るか確かめる。
// usage: node decode_check.js <reader.html> <scrambled.rgba> <original.rgba> <meta.json>
const fs = require('fs');

const [, , htmlPath, scrPath, origPath, metaPath] = process.argv;
const html = fs.readFileSync(htmlPath, 'utf8');
const meta = JSON.parse(fs.readFileSync(metaPath, 'utf8'));
const scrPx = fs.readFileSync(scrPath);
const origPx = fs.readFileSync(origPath);

// リーダーの script ブロック（Xorshift32 を含むもの）を取り出す
const blocks = html.split('<script>').slice(1).map(s => s.split('</script>')[0]);
const script = blocks.find(b => b.includes('class Xorshift32'));
if (!script) { console.log('FAIL: reader script not found'); process.exit(1); }
const start = script.indexOf('class Xorshift32');
const banner = script.indexOf('/* ====', script.indexOf('function decode'));
const core = script.slice(start, banner);

// Canvas スタブ（drawImage の矩形コピーだけを再現する）
class FakeCtx {
  constructor(cv) { this.cv = cv; }
  drawImage(img, ...a) {
    if (a.length === 2) { this.cv._px.set(img._px.subarray(0, this.cv._px.length)); return; }
    const [sx, sy, sw, sh, dx, dy] = a;
    for (let y = 0; y < sh; y++) {
      const sOff = ((sy + y) * img.naturalWidth + sx) * 4;
      const dOff = ((dy + y) * this.cv.width + dx) * 4;
      img._px.copy(this.cv._px, dOff, sOff, sOff + sw * 4);
    }
  }
}
class FakeCanvas {
  constructor() { this.width = 0; this.height = 0; this._px = null; }
  getContext() {
    if (!this._px) this._px = Buffer.alloc(this.width * this.height * 4);
    return new FakeCtx(this);
  }
}
const documentStub = {
  createElement: (tag) => {
    if (tag === 'canvas') return new FakeCanvas();
    throw new Error('unexpected createElement: ' + tag);
  },
};

const factory = new Function('document', 'HTMLCanvasElement',
  core + '\nreturn { decode, isScrambled, xorshiftShuffle };');
const { decode, isScrambled } = factory(documentStub, FakeCanvas);

let pass = 0, fail = 0;
const check = (name, cond) => { console.log((cond ? 'PASS: ' : 'FAIL: ') + name); cond ? pass++ : fail++; };

check('isScrambled(filename) is true', isScrambled(meta.filename) === true);
check('isScrambled(plain name) is false', isScrambled('page01.png') === false);

const img = { naturalWidth: meta.width, naturalHeight: meta.height, _px: scrPx };
const cv = decode(img, meta.filename, meta.tile_size);
check('decoded size matches', cv.width === meta.width && cv.height === meta.height);
check('decoded pixels equal the original', Buffer.compare(cv._px, origPx) === 0);

console.log(`== decode_check: PASS=${pass} FAIL=${fail} ==`);
process.exit(fail ? 1 : 0);
