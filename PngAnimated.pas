unit PngAnimated;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	PNG / APNG animation decoder                                  //
// Version:	0.1                                                           //
// Date:	25-JUN-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// Decodes still PNG and animated PNG (APNG) by:                              //
//   * parsing the chunk stream (IHDR/PLTE/tRNS/acTL/fcTL/IDAT/fdAT),         //
//   * inflating each frame's image data (pure-Pascal Inflate),              //
//   * reversing the per-scanline filters and expanding to BGRA,             //
//   * compositing the APNG frames onto a persistent canvas honouring the    //
//     dispose / blend operations,                                            //
//   * exposing the finished full-canvas frames as TBitmaps + durations.     //
//                                                                            //
// Supported: colour types 0/2/3/4/6, bit depths 1/2/4/8/16, non-interlaced. //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, SysUtils, Graphics,
     AnimationCommon, Inflate, BitmapEveryX;

type
  { TPngAnimation }
  TPngAnimation = class(TCustomAnimation)
  private
    // IHDR
    FBitDepth:  Integer;
    FColorType: Integer;
    FInterlace: Integer;
    FChannels:  Integer;
    // PLTE / tRNS
    FPalette:   TBytes;     // RGB triplets
    FTrns:      TBytes;     // raw tRNS chunk bytes
    FHasTrns:   Boolean;
    procedure DecodePng(const Data: TBytes);
    // Reverse the PNG scanline filters in-place producing the reconstructed
    // raw samples for a sub-image of size W x H.
    function  Unfilter(const Raw: TBytes; W, H: Integer): TBytes;
    // Expand reconstructed samples to a freshly allocated BGRA buffer (W*H*4).
    function  ExpandToBGRA(const Recon: TBytes; W, H: Integer): PByte;
    // Inflate + unfilter + expand one frame data stream into BGRA. Caller frees.
    function  DecodeFrameImage(const ZData: TBytes; W, H: Integer): PByte;
  public
    procedure LoadFromStream(Stream: TStream); override;
  end;

implementation

type
  TPngFrameInfo = record
    X, Y, W, H:         Integer;
    DelayNum, DelayDen: Integer;
    DisposeOp, BlendOp: Integer;
    Data:               TMemoryStream;
  end;

const
  PNG_SIG: array[0..7] of Byte = ($89,$50,$4E,$47,$0D,$0A,$1A,$0A);

function BE32(const B: TBytes; Ofs: Integer): Cardinal; inline;
begin
  Result := (Cardinal(B[Ofs]) shl 24) or (Cardinal(B[Ofs+1]) shl 16) or
            (Cardinal(B[Ofs+2]) shl 8) or Cardinal(B[Ofs+3]);
end;

function BE16(const B: TBytes; Ofs: Integer): Integer; inline;
begin
  Result := (Integer(B[Ofs]) shl 8) or Integer(B[Ofs+1]);
end;

function TagEq(const B: TBytes; Ofs: Integer; const Tag: AnsiString): Boolean; inline;
begin
  Result := (B[Ofs]   = Byte(Tag[1])) and (B[Ofs+1] = Byte(Tag[2])) and
            (B[Ofs+2] = Byte(Tag[3])) and (B[Ofs+3] = Byte(Tag[4]));
end;

// Per-pixel source-over-destination (non-premultiplied alpha), BGRA.
procedure BlendOver(Dst, Src: PByte); inline;
var sa, da, sa1, oa255, c: Integer;
begin
  sa := Src[3];
  if sa = 255 then
  begin
    Dst[0] := Src[0]; Dst[1] := Src[1]; Dst[2] := Src[2]; Dst[3] := 255;
    Exit;
  end;
  if sa = 0 then Exit;
  da   := Dst[3];
  sa1  := 255 - sa;
  oa255 := sa * 255 + da * sa1;
  if oa255 = 0 then
  begin
    Dst[0] := 0; Dst[1] := 0; Dst[2] := 0; Dst[3] := 0;
    Exit;
  end;
  for c := 0 to 2 do
    Dst[c] := Byte((Src[c]*sa*255 + Dst[c]*da*sa1 + oa255 div 2) div oa255);
  Dst[3] := Byte((oa255 + 127) div 255);
end;

function PaethPredictor(a, b, c: Integer): Integer; inline;
var p, pa, pb, pc: Integer;
begin
  p  := a + b - c;
  pa := Abs(p - a); pb := Abs(p - b); pc := Abs(p - c);
  if (pa <= pb) and (pa <= pc) then Result := a
  else if pb <= pc then Result := b
  else Result := c;
end;

{ TPngAnimation }

function TPngAnimation.Unfilter(const Raw: TBytes; W, H: Integer): TBytes;
var
  bitsPerPixel, bpp, bpr, y, x, ft, a, b, c, cur, val: Integer;
  srcPos: Integer;
begin
  bitsPerPixel := FChannels * FBitDepth;
  bpp := (bitsPerPixel + 7) div 8;        // filter offset (>= 1)
  if bpp < 1 then bpp := 1;
  bpr := (W * bitsPerPixel + 7) div 8;    // bytes per reconstructed scanline

  if Length(Raw) < H * (bpr + 1) then
    raise Exception.Create('PNG: filtered data too short');

  SetLength(Result, H * bpr);
  srcPos := 0;
  for y := 0 to H - 1 do
  begin
    ft := Raw[srcPos]; Inc(srcPos);
    for x := 0 to bpr - 1 do
    begin
      cur := Raw[srcPos]; Inc(srcPos);
      if x >= bpp then a := Result[y*bpr + x - bpp] else a := 0;
      if y > 0    then b := Result[(y-1)*bpr + x]   else b := 0;
      if (x >= bpp) and (y > 0) then c := Result[(y-1)*bpr + x - bpp] else c := 0;
      case ft of
        0: val := cur;
        1: val := cur + a;
        2: val := cur + b;
        3: val := cur + ((a + b) div 2);
        4: val := cur + PaethPredictor(a, b, c);
      else
        raise Exception.CreateFmt('PNG: bad filter type %d', [ft]);
      end;
      Result[y*bpr + x] := Byte(val and $FF);
    end;
  end;
end;

function TPngAnimation.ExpandToBGRA(const Recon: TBytes; W, H: Integer): PByte;
var
  bitsPerPixel, bpr, x, y, maxv: Integer;
  row, o: Integer;
  dst: PByte;
  idx, g, r, gg, bb, av: Integer;
  sample: Integer;
  bitPos, shift, mask: Integer;

  function Sample8(rowOfs, ch, totalCh: Integer): Integer;
  // Read channel 'ch' of pixel 'x' for 8/16-bit depths, returning an 8-bit value.
  begin
    if FBitDepth = 16 then
      Result := Recon[rowOfs + (x*totalCh + ch)*2]          // high byte
    else
      Result := Recon[rowOfs + x*totalCh + ch];
  end;

  function RawSample(rowOfs, ch, totalCh: Integer): Integer;
  // Full sample value (for tRNS comparison): 16-bit or 8-bit as stored.
  begin
    if FBitDepth = 16 then
      Result := (Integer(Recon[rowOfs + (x*totalCh + ch)*2]) shl 8) or
                 Integer(Recon[rowOfs + (x*totalCh + ch)*2 + 1])
    else
      Result := Recon[rowOfs + x*totalCh + ch];
  end;

begin
  bitsPerPixel := FChannels * FBitDepth;
  bpr := (W * bitsPerPixel + 7) div 8;
  GetMem(dst, NativeUInt(W) * NativeUInt(H) * 4);
  try
    maxv := (1 shl FBitDepth) - 1;
    if maxv = 0 then maxv := 1;
    for y := 0 to H - 1 do
    begin
      row := y * bpr;
      for x := 0 to W - 1 do
      begin
        o := (y * W + x) * 4;
        case FColorType of
          0: // grayscale
            begin
              if FBitDepth >= 8 then
                sample := RawSample(row, 0, 1)
              else
              begin
                bitPos := x * FBitDepth;
                shift  := 8 - FBitDepth - (bitPos and 7);
                mask   := maxv;
                sample := (Recon[row + (bitPos shr 3)] shr shift) and mask;
              end;
              if FBitDepth = 16 then g := sample shr 8
              else if FBitDepth = 8 then g := sample
              else g := (sample * 255) div maxv;
              dst[o] := g; dst[o+1] := g; dst[o+2] := g;
              if FHasTrns and (Length(FTrns) >= 2) and (sample = BE16(FTrns, 0)) then
                dst[o+3] := 0
              else
                dst[o+3] := 255;
            end;
          2: // truecolour RGB
            begin
              r  := Sample8(row, 0, 3);
              gg := Sample8(row, 1, 3);
              bb := Sample8(row, 2, 3);
              dst[o] := bb; dst[o+1] := gg; dst[o+2] := r;
              if FHasTrns and (Length(FTrns) >= 6) and
                 (RawSample(row,0,3) = BE16(FTrns,0)) and
                 (RawSample(row,1,3) = BE16(FTrns,2)) and
                 (RawSample(row,2,3) = BE16(FTrns,4)) then
                dst[o+3] := 0
              else
                dst[o+3] := 255;
            end;
          3: // palette
            begin
              if FBitDepth >= 8 then
                idx := Recon[row + x]
              else
              begin
                bitPos := x * FBitDepth;
                shift  := 8 - FBitDepth - (bitPos and 7);
                idx    := (Recon[row + (bitPos shr 3)] shr shift) and maxv;
              end;
              if (idx >= 0) and ((idx*3 + 2) < Length(FPalette)) then
              begin
                dst[o]   := FPalette[idx*3 + 2];   // B
                dst[o+1] := FPalette[idx*3 + 1];   // G
                dst[o+2] := FPalette[idx*3 + 0];   // R
              end
              else
              begin
                dst[o] := 0; dst[o+1] := 0; dst[o+2] := 0;
              end;
              if FHasTrns and (idx < Length(FTrns)) then
                dst[o+3] := FTrns[idx]
              else
                dst[o+3] := 255;
            end;
          4: // grayscale + alpha
            begin
              g  := Sample8(row, 0, 2);
              av := Sample8(row, 1, 2);
              dst[o] := g; dst[o+1] := g; dst[o+2] := g; dst[o+3] := av;
            end;
          6: // RGBA
            begin
              r  := Sample8(row, 0, 4);
              gg := Sample8(row, 1, 4);
              bb := Sample8(row, 2, 4);
              av := Sample8(row, 3, 4);
              dst[o] := bb; dst[o+1] := gg; dst[o+2] := r; dst[o+3] := av;
            end;
        else
          raise Exception.CreateFmt('PNG: unsupported colour type %d', [FColorType]);
        end;
      end;
    end;
  except
    FreeMem(dst);
    raise;
  end;
  Result := dst;
end;

function TPngAnimation.DecodeFrameImage(const ZData: TBytes; W, H: Integer): PByte;
var
  raw, recon: TBytes;
begin
  if Length(ZData) = 0 then
    raise Exception.Create('PNG: empty frame data');
  raw := InflateZlib(@ZData[0], Length(ZData));
  recon := Unfilter(raw, W, H);
  Result := ExpandToBGRA(recon, W, H);
end;

procedure TPngAnimation.DecodePng(const Data: TBytes);
var
  size, pos: Integer;
  len: Cardinal;
  isAPNG: Boolean;
  curFrame: Integer;
  defaultData: TMemoryStream;
  frames: array of TPngFrameInfo;
  i, n: Integer;
  // compositing
  canvas, saved: TBytes;
  framePix: PByte;
  fr: TPngFrameInfo;
  row, col, cx, cy, ms, den: Integer;
  dst, src: PByte;
  usePrev: Boolean;
  zbuf: TBytes;
  bmp: TBitmap;
begin
  size := Length(Data);
  if (size < 8) then
    raise Exception.Create('PNG: data too small');
  for i := 0 to 7 do
    if Data[i] <> PNG_SIG[i] then
      raise Exception.Create('PNG: bad signature');

  FBitDepth := 8; FColorType := 6; FInterlace := 0; FChannels := 4;
  FHasTrns := False; SetLength(FPalette, 0); SetLength(FTrns, 0);
  isAPNG := False; curFrame := -1;
  frames := nil;
  defaultData := TMemoryStream.Create;
  try
    pos := 8;
    while pos + 8 <= size do
    begin
      len := BE32(Data, pos);
      if pos + 12 + Integer(len) > size then Break;   // truncated

      if TagEq(Data, pos+4, 'IHDR') then
      begin
        FWidth     := Integer(BE32(Data, pos+8));
        FHeight    := Integer(BE32(Data, pos+8+4));
        FBitDepth  := Data[pos+8+8];
        FColorType := Data[pos+8+9];
        FInterlace := Data[pos+8+12];
        case FColorType of
          0: FChannels := 1;
          2: FChannels := 3;
          3: FChannels := 1;
          4: FChannels := 2;
          6: FChannels := 4;
        else
          raise Exception.CreateFmt('PNG: unsupported colour type %d', [FColorType]);
        end;
        if FInterlace <> 0 then
          raise Exception.Create('PNG: interlaced images are not supported');
      end
      else if TagEq(Data, pos+4, 'acTL') then
      begin
        isAPNG := True;
        FLoopCount := Integer(BE32(Data, pos+8+4));   // num_plays (0 = forever)
      end
      else if TagEq(Data, pos+4, 'PLTE') then
      begin
        SetLength(FPalette, len);
        if len > 0 then Move(Data[pos+8], FPalette[0], len);
      end
      else if TagEq(Data, pos+4, 'tRNS') then
      begin
        FHasTrns := True;
        SetLength(FTrns, len);
        if len > 0 then Move(Data[pos+8], FTrns[0], len);
      end
      else if TagEq(Data, pos+4, 'fcTL') then
      begin
        n := Length(frames);
        SetLength(frames, n + 1);
        frames[n].W        := Integer(BE32(Data, pos+8+4));
        frames[n].H        := Integer(BE32(Data, pos+8+8));
        frames[n].X        := Integer(BE32(Data, pos+8+12));
        frames[n].Y        := Integer(BE32(Data, pos+8+16));
        frames[n].DelayNum := BE16(Data, pos+8+20);
        frames[n].DelayDen := BE16(Data, pos+8+22);
        frames[n].DisposeOp:= Data[pos+8+24];
        frames[n].BlendOp  := Data[pos+8+25];
        frames[n].Data     := TMemoryStream.Create;
        curFrame := n;
      end
      else if TagEq(Data, pos+4, 'IDAT') then
      begin
        if (curFrame >= 0) and isAPNG then
          frames[curFrame].Data.WriteBuffer(Data[pos+8], len)
        else
          defaultData.WriteBuffer(Data[pos+8], len);
      end
      else if TagEq(Data, pos+4, 'fdAT') then
      begin
        // 4-byte sequence number, then frame data (zlib continuation).
        if (curFrame >= 0) and (len >= 4) then
          frames[curFrame].Data.WriteBuffer(Data[pos+8+4], len - 4);
      end
      else if TagEq(Data, pos+4, 'IEND') then
        Break;

      pos := pos + 12 + Integer(len);
    end;

    // -=- Still PNG (no APNG chunks or no animation frames) -=-
    if (not isAPNG) or (Length(frames) = 0) then
    begin
      SetLength(zbuf, defaultData.Size);
      if defaultData.Size > 0 then
        Move(defaultData.Memory^, zbuf[0], defaultData.Size);
      framePix := DecodeFrameImage(zbuf, FWidth, FHeight);
      try
        bmp := Bitmap_Every(framePix, FWidth, FHeight);
      finally
        FreeMem(framePix);
      end;
      AddFrame(bmp, 0);
      Exit;
    end;

    // -=- APNG: composite frames onto a persistent canvas -=-
    if (FWidth <= 0) or (FHeight <= 0) then
      raise Exception.Create('PNG: invalid canvas size');

    SetLength(canvas, FWidth * FHeight * 4);
    FillChar(canvas[0], Length(canvas), 0);

    for i := 0 to High(frames) do
    begin
      fr := frames[i];
      if (fr.W <= 0) or (fr.H <= 0) then Continue;

      SetLength(zbuf, fr.Data.Size);
      if fr.Data.Size > 0 then
        Move(fr.Data.Memory^, zbuf[0], fr.Data.Size);

      framePix := DecodeFrameImage(zbuf, fr.W, fr.H);
      try
        // Save the region first if we must restore it after display.
        usePrev := (fr.DisposeOp = 2);
        if usePrev then
        begin
          SetLength(saved, Length(canvas));
          Move(canvas[0], saved[0], Length(canvas));
        end;

        // Composite the sub-image at (X,Y).
        for row := 0 to fr.H - 1 do
        begin
          cy := fr.Y + row;
          if (cy < 0) or (cy >= FHeight) then Continue;
          for col := 0 to fr.W - 1 do
          begin
            cx := fr.X + col;
            if (cx < 0) or (cx >= FWidth) then Continue;
            src := framePix + (NativeUInt(row) * fr.W + col) * 4;
            dst := @canvas[(cy * FWidth + cx) * 4];
            if fr.BlendOp = 0 then
            begin
              // APNG_BLEND_OP_SOURCE: overwrite, alpha included.
              dst[0] := src[0]; dst[1] := src[1]; dst[2] := src[2]; dst[3] := src[3];
            end
            else
              BlendOver(dst, src);   // APNG_BLEND_OP_OVER
          end;
        end;
      finally
        FreeMem(framePix);
      end;

      // Snapshot the canvas as this frame's displayed image.
      bmp := Bitmap_Every(@canvas[0], FWidth, FHeight);
      den := fr.DelayDen; if den = 0 then den := 100;
      ms := (fr.DelayNum * 1000) div den;
      AddFrame(bmp, ms);

      // Apply this frame's disposal to prepare the canvas for the next one.
      case fr.DisposeOp of
        1: // APNG_DISPOSE_OP_BACKGROUND: clear region to transparent.
          for row := 0 to fr.H - 1 do
          begin
            cy := fr.Y + row;
            if (cy < 0) or (cy >= FHeight) then Continue;
            for col := 0 to fr.W - 1 do
            begin
              cx := fr.X + col;
              if (cx < 0) or (cx >= FWidth) then Continue;
              dst := @canvas[(cy * FWidth + cx) * 4];
              dst[0] := 0; dst[1] := 0; dst[2] := 0; dst[3] := 0;
            end;
          end;
        2: // APNG_DISPOSE_OP_PREVIOUS: restore the saved region.
          if Length(saved) = Length(canvas) then
            Move(saved[0], canvas[0], Length(canvas));
      end;
    end;

    if FrameCount = 0 then
      raise Exception.Create('PNG: no animation frames decoded');
  finally
    defaultData.Free;
    for i := 0 to High(frames) do
      if frames[i].Data <> nil then frames[i].Data.Free;
  end;
end;

procedure TPngAnimation.LoadFromStream(Stream: TStream);
var
  Data: TBytes;
  Size: Integer;
begin
  ClearFrames;
  FWidth := 0; FHeight := 0; FLoopCount := 0; FBgColor := 0;
  Size := Integer(Stream.Size - Stream.Position);
  if Size < 8 then
    raise Exception.Create('PNG: stream too small');
  SetLength(Data, Size);
  Stream.ReadBuffer(Data[0], Size);
  DecodePng(Data);
end;

end.
