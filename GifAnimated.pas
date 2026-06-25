unit GifAnimated;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	GIF (87a / 89a) animation decoder                             //
// Version:	0.1                                                           //
// Date:	25-JUN-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// Decodes animated and still GIF by:                                         //
//   * parsing the logical screen descriptor, colour tables and blocks,       //
//   * LZW-decompressing each image's index data and de-interlacing it,       //
//   * mapping indices through the active palette with transparency,          //
//   * compositing each image onto a persistent canvas honouring the GIF      //
//     disposal methods,                                                       //
//   * exposing the finished full-canvas frames as TBitmaps + durations.      //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, SysUtils, Graphics,
     AnimationCommon, BitmapEveryX;

type
  { TGifAnimation }
  TGifAnimation = class(TCustomAnimation)
  private
    procedure DecodeGif(const Data: TBytes);
  public
    procedure LoadFromStream(Stream: TStream); override;
  end;

implementation

function LZWDecode(const Data: TBytes; MinCode, OutLen: Integer): TBytes;
var
  prefix:  array[0..4095] of Integer;
  suffix:  array[0..4095] of Integer;
  stack:   array[0..4095] of Integer;
  sp, clearCode, endCode, codeSize, nextCode, oldCode, code, c, first: Integer;
  bitBuf, bitCnt, dataPos, outPos, i: Integer;

  function ReadCode: Integer;
  begin
    while (bitCnt < codeSize) and (dataPos < Length(Data)) do
    begin
      bitBuf := bitBuf or (Integer(Data[dataPos]) shl bitCnt);
      Inc(dataPos); Inc(bitCnt, 8);
    end;
    if bitCnt < codeSize then Exit(-1);
    Result := bitBuf and ((1 shl codeSize) - 1);
    bitBuf := bitBuf shr codeSize;
    Dec(bitCnt, codeSize);
  end;

begin
  SetLength(Result, OutLen);
  if (MinCode < 2) or (MinCode > 8) then MinCode := 8;
  clearCode := 1 shl MinCode;
  endCode   := clearCode + 1;
  codeSize  := MinCode + 1;
  nextCode  := clearCode + 2;
  for i := 0 to clearCode - 1 do begin prefix[i] := -1; suffix[i] := i; end;
  oldCode := -1; first := 0; sp := 0; outPos := 0;
  bitBuf := 0; bitCnt := 0; dataPos := 0;

  repeat
    code := ReadCode;
    if code < 0 then Break;

    if code = clearCode then
    begin
      codeSize := MinCode + 1;
      nextCode := clearCode + 2;
      oldCode  := -1;
      Continue;
    end;
    if code = endCode then Break;

    if oldCode = -1 then
    begin
      if (code < clearCode) and (outPos < OutLen) then
      begin
        Result[outPos] := code; Inc(outPos);
      end;
      oldCode := code; first := code;
      Continue;
    end;

    if code < nextCode then
      c := code
    else
    begin
      // KwKwK: code not yet in table; output old sequence + its first symbol.
      c := oldCode;
      stack[sp] := first; Inc(sp);
    end;

    while c >= clearCode do
    begin
      stack[sp] := suffix[c]; Inc(sp);
      c := prefix[c];
    end;
    first := suffix[c];
    stack[sp] := first; Inc(sp);

    while sp > 0 do
    begin
      Dec(sp);
      if outPos < OutLen then
      begin
        Result[outPos] := stack[sp]; Inc(outPos);
      end;
    end;

    if nextCode < 4096 then
    begin
      prefix[nextCode] := oldCode;
      suffix[nextCode] := first;
      Inc(nextCode);
      if (nextCode = (1 shl codeSize)) and (codeSize < 12) then
        Inc(codeSize);
    end;
    oldCode := code;
  until False;
end;

{ TGifAnimation }

procedure TGifAnimation.DecodeGif(const Data: TBytes);
var
  size, pos: Integer;
  pkd: Byte;
  gctFlag: Boolean;
  gctSize: Integer;
  gct: TBytes;
  // graphic control state for the next image
  hasGCE: Boolean;
  gceDisposal, gceDelay, gceTransIdx: Integer;
  gceTransparent: Boolean;
  // canvas
  canvas, saved: TBytes;
  // loop
  loopSet: Boolean;
  b, blockSize: Integer;

  function ReadByte: Integer;
  begin
    if pos < size then begin Result := Data[pos]; Inc(pos); end
    else Result := -1;
  end;

  procedure SkipSubBlocks;
  var bs: Integer;
  begin
    repeat
      bs := ReadByte;
      if bs <= 0 then Break;
      Inc(pos, bs);
    until False;
  end;

  procedure ReadImage;
  var
    ix, iy, iw, ih, ipacked, lctFlag, interlace, lctSize: Integer;
    lct: TBytes;
    pal: TBytes;
    minCode: Integer;
    lzwData: TMemoryStream;
    bs: Integer;
    indices: TBytes;
    framePix: PByte;
    row, col, srcRow, di, ci, cidx: Integer;
    pass, y: Integer;
    transIdx, disposal, delay: Integer;
    transparent: Boolean;
    dst: PByte;
    bmp: TBitmap;
    rowMap: array of Integer;
    tmp: TBytes;
    usePrev: Boolean;
  begin
    ix := Data[pos] or (Integer(Data[pos+1]) shl 8);
    iy := Data[pos+2] or (Integer(Data[pos+3]) shl 8);
    iw := Data[pos+4] or (Integer(Data[pos+5]) shl 8);
    ih := Data[pos+6] or (Integer(Data[pos+7]) shl 8);
    ipacked := Data[pos+8];
    Inc(pos, 9);

    lctFlag   := (ipacked shr 7) and 1;
    interlace := (ipacked shr 6) and 1;
    lctSize   := 2 shl (ipacked and 7);

    if lctFlag = 1 then
    begin
      SetLength(lct, lctSize * 3);
      Move(Data[pos], lct[0], lctSize * 3);
      Inc(pos, lctSize * 3);
      pal := lct;
    end
    else
      pal := gct;

    // Snapshot the graphic-control state for this image, then clear it.
    transparent := gceTransparent and hasGCE;
    transIdx    := gceTransIdx;
    disposal    := gceDisposal;
    delay       := gceDelay;
    hasGCE := False; gceTransparent := False;
    gceDisposal := 0; gceDelay := 0; gceTransIdx := 0;

    minCode := ReadByte;

    // Gather LZW sub-blocks.
    lzwData := TMemoryStream.Create;
    try
      repeat
        bs := ReadByte;
        if bs <= 0 then Break;
        lzwData.WriteBuffer(Data[pos], bs);
        Inc(pos, bs);
      until False;

      SetLength(tmp, lzwData.Size);
      if lzwData.Size > 0 then
        Move(lzwData.Memory^, tmp[0], lzwData.Size);
    finally
      lzwData.Free;
    end;

    if (iw <= 0) or (ih <= 0) then Exit;
    indices := LZWDecode(tmp, minCode, iw * ih);

    // De-interlace row order if needed.
    SetLength(rowMap, ih);
    if interlace = 1 then
    begin
      di := 0;
      for pass := 0 to 3 do
      begin
        case pass of
          0: begin y := 0; end;
          1: begin y := 4; end;
          2: begin y := 2; end;
        else  begin y := 1; end;
        end;
        while y < ih do
        begin
          rowMap[di] := y; Inc(di);
          case pass of
            0: Inc(y, 8);
            1: Inc(y, 8);
            2: Inc(y, 4);
          else  Inc(y, 2);
          end;
        end;
      end;
    end
    else
      for row := 0 to ih - 1 do rowMap[row] := row;

    // Build this image's BGRA pixels (transparent index -> alpha 0).
    GetMem(framePix, NativeUInt(iw) * NativeUInt(ih) * 4);
    try
      for srcRow := 0 to ih - 1 do
      begin
        row := rowMap[srcRow];
        for col := 0 to iw - 1 do
        begin
          cidx := indices[srcRow * iw + col];
          dst := framePix + (NativeUInt(row) * iw + col) * 4;
          if transparent and (cidx = transIdx) then
          begin
            dst[0] := 0; dst[1] := 0; dst[2] := 0; dst[3] := 0;
          end
          else if (cidx >= 0) and ((cidx*3 + 2) < Length(pal)) then
          begin
            dst[0] := pal[cidx*3 + 2];   // B
            dst[1] := pal[cidx*3 + 1];   // G
            dst[2] := pal[cidx*3 + 0];   // R
            dst[3] := 255;
          end
          else
          begin
            dst[0] := 0; dst[1] := 0; dst[2] := 0; dst[3] := 0;
          end;
        end;
      end;

      // Save canvas region for "restore to previous" disposal.
      usePrev := (disposal = 3);
      if usePrev then
      begin
        SetLength(saved, Length(canvas));
        Move(canvas[0], saved[0], Length(canvas));
      end;

      // Composite onto the canvas: transparent pixels keep what's underneath.
      for row := 0 to ih - 1 do
      begin
        ci := iy + row;
        if (ci < 0) or (ci >= FHeight) then Continue;
        for col := 0 to iw - 1 do
        begin
          cidx := ix + col;
          if (cidx < 0) or (cidx >= FWidth) then Continue;
          dst := framePix + (NativeUInt(row) * iw + col) * 4;
          if dst[3] = 0 then Continue;   // transparent: leave canvas pixel
          PByte(@canvas[(ci * FWidth + cidx) * 4])[0] := dst[0];
          PByte(@canvas[(ci * FWidth + cidx) * 4])[1] := dst[1];
          PByte(@canvas[(ci * FWidth + cidx) * 4])[2] := dst[2];
          PByte(@canvas[(ci * FWidth + cidx) * 4])[3] := dst[3];
        end;
      end;
    finally
      FreeMem(framePix);
    end;

    // Snapshot the canvas as this frame's displayed image.
    bmp := Bitmap_Every(@canvas[0], FWidth, FHeight);
    AddFrame(bmp, delay * 10);   // GIF delay is in 1/100 s

    // Apply disposal to prepare the canvas for the next image.
    case disposal of
      2: // restore to background -> transparent
        for row := 0 to ih - 1 do
        begin
          ci := iy + row;
          if (ci < 0) or (ci >= FHeight) then Continue;
          for col := 0 to iw - 1 do
          begin
            cidx := ix + col;
            if (cidx < 0) or (cidx >= FWidth) then Continue;
            dst := @canvas[(ci * FWidth + cidx) * 4];
            dst[0] := 0; dst[1] := 0; dst[2] := 0; dst[3] := 0;
          end;
        end;
      3: // restore to previous
        if Length(saved) = Length(canvas) then
          Move(saved[0], canvas[0], Length(canvas));
    end;
  end;

begin
  size := Length(Data);
  if size < 13 then
    raise Exception.Create('GIF: data too small');
  if not ((Data[0] = Ord('G')) and (Data[1] = Ord('I')) and (Data[2] = Ord('F'))) then
    raise Exception.Create('GIF: bad signature');

  FWidth  := Data[6] or (Integer(Data[7]) shl 8);
  FHeight := Data[8] or (Integer(Data[9]) shl 8);
  pkd     := Data[10];
  gctFlag := (pkd shr 7) and 1 = 1;
  gctSize := 2 shl (pkd and 7);
  // FBgColor index is Data[11]; aspect Data[12].
  pos := 13;

  if gctFlag then
  begin
    SetLength(gct, gctSize * 3);
    Move(Data[pos], gct[0], gctSize * 3);
    Inc(pos, gctSize * 3);
  end;

  if (FWidth <= 0) or (FHeight <= 0) then
    raise Exception.Create('GIF: invalid screen size');

  SetLength(canvas, FWidth * FHeight * 4);
  FillChar(canvas[0], Length(canvas), 0);

  hasGCE := False; gceTransparent := False;
  gceDisposal := 0; gceDelay := 0; gceTransIdx := 0;
  loopSet := False;
  FLoopCount := 1;   // a plain GIF without a NETSCAPE loop block plays once

  while pos < size do
  begin
    b := ReadByte;
    case b of
      $3B: Break;                       // trailer
      $2C: ReadImage;                   // image descriptor
      $21:                              // extension introducer
        begin
          b := ReadByte;
          case b of
            $F9: // Graphic Control Extension
              begin
                blockSize := ReadByte;          // = 4
                pkd       := Data[pos];
                gceDisposal    := (pkd shr 2) and 7;
                gceTransparent := (pkd and 1) = 1;
                gceDelay       := Data[pos+1] or (Integer(Data[pos+2]) shl 8);
                gceTransIdx    := Data[pos+3];
                hasGCE := True;
                Inc(pos, blockSize);
                if ReadByte <> 0 then ;         // block terminator
              end;
            $FF: // Application Extension
              begin
                blockSize := ReadByte;          // = 11
                if (blockSize = 11) and (not loopSet) and
                   (Data[pos] = Ord('N')) and (Data[pos+1] = Ord('E')) and
                   (Data[pos+2] = Ord('T')) and (Data[pos+10] = Ord('0')) then
                begin
                  Inc(pos, blockSize);
                  // sub-blocks: 0x03 0x01 loop(2 LE)
                  blockSize := ReadByte;
                  if (blockSize >= 3) and (Data[pos] = 1) then
                  begin
                    FLoopCount := Data[pos+1] or (Integer(Data[pos+2]) shl 8);
                    loopSet := True;
                  end;
                  Inc(pos, blockSize);
                  SkipSubBlocks;
                end
                else
                begin
                  Inc(pos, blockSize);
                  SkipSubBlocks;
                end;
              end;
          else
            SkipSubBlocks;                       // comment / plain-text / unknown
          end;
        end;
    else
      // Unknown byte; stop to avoid runaway parsing.
      if b < 0 then Break;
    end;
  end;

  if FrameCount = 0 then
    raise Exception.Create('GIF: no frames decoded');
end;

procedure TGifAnimation.LoadFromStream(Stream: TStream);
var
  Data: TBytes;
  Size: Integer;
begin
  ClearFrames;
  FWidth := 0; FHeight := 0; FLoopCount := 0; FBgColor := 0;
  Size := Integer(Stream.Size - Stream.Position);
  if Size < 13 then
    raise Exception.Create('GIF: stream too small');
  SetLength(Data, Size);
  Stream.ReadBuffer(Data[0], Size);
  DecodeGif(Data);
end;

end.
