// Worker-compatible metadata reader. Does not transcode user imagery.
function size(bytes) {
  const b=Buffer.isBuffer(bytes)?bytes:Buffer.from(bytes||[]);
  if(b.length<24)throw Error("Raster truncado");
  if(b.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]))){
    if(b.toString("ascii",12,16)!=="IHDR")throw Error("PNG sin IHDR");
    return {width:b.readUInt32BE(16),height:b.readUInt32BE(20),format:"png"};
  }
  if(b[0]===0xff&&b[1]===0xd8) {
    let i=2;
    while(i+4<b.length){
      if(b[i]!==0xff){i++;continue}
      while(i<b.length&&b[i]===0xff)i++;
      const marker=b[i++];
      if(marker===0xd9||marker===0xda)break;
      if(marker===0xd8||marker===0x01||(marker>=0xd0&&marker<=0xd7))continue;
      if(i+2>b.length)break;
      const len=b.readUInt16BE(i);
      if(len<2||i+len>b.length)break;
      const sof=[0xc0,0xc1,0xc2,0xc3,0xc5,0xc6,0xc7,0xc9,0xca,0xcb,0xcd,0xce,0xcf].includes(marker);
      if(sof&&len>=7) return {width:b.readUInt16BE(i+5),height:b.readUInt16BE(i+3),format:"jpeg"};
      i+=len;
    }
    throw Error("JPEG sin tamaño SOF legible");
  }
  if(b.toString("ascii",0,4)==="RIFF"&&b.toString("ascii",8,12)==="WEBP"&&b.length>=30){
    const kind=b.toString("ascii",12,16);
    if(kind==="VP8X")return {width:1+b.readUIntLE(24,3),height:1+b.readUIntLE(27,3),format:"webp"};
    if(kind==="VP8L"){
      if(b[20]!==0x2f)throw Error("VP8L sin cabecera");
      return {width:1+(((b[22]&0x3f)<<8)|b[21]),height:1+(((b[24]&0xf)<<10)|(b[23]<<2)|((b[22]&0xc0)>>6)),format:"webp"};
    }
    if(kind==="VP8 "&&b.length>=30){
      if(b[23]!==0x9d||b[24]!==0x01||b[25]!==0x2a)throw Error("VP8 sin frame key");
      return {width:b.readUInt16LE(26)&0x3fff,height:b.readUInt16LE(28)&0x3fff,format:"webp"};
    }
  }
  throw Error("Formato de raster no reconocido");
}
export default function sharp(input){
  const meta=size(input);
  return {
    metadata:async()=>meta,
    png(){return {toBuffer:async()=>{if(meta.format!=="png")throw Error("Conversión PNG debe hacerse en navegador");return Buffer.from(input)}}}
  };
}
export {size};
