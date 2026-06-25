unit WebPImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	WEBP port                                                     //
// Version:	0.6                                                           //
// Date:	09-JUN-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, Math, Types, Dialogs,
     {$IFDEF FPC}IntfGraphics, FPImage, GraphType,{$ENDIF}
     WebPDec, WebPEnc, BitmapEveryX;

  { TWebpImage }
type
  TWebpImage = class(TGraphic)
  private
    FBmp: TBitmap;
    procedure DecodeFromStream(Str: TStream);
    // Encode the internal bitmap to WebP and write it to Str.
    //   IsLossless       : True = VP8L lossless; False = VP8 lossy.
    //   CompressionLevel : lossy quality 0..100 (higher = better quality).
    procedure EncodeToStream(Str: TStream; IsLossless: Boolean = False;
                             CompressionLevel: Integer = 75);
  protected
    procedure Draw(ACanvas: TCanvas; const Rect: TRect); override;
  //    function GetEmpty: Boolean; virtual; abstract;
    function GetHeight: Integer; override;
    function GetTransparent: Boolean; override;
    function GetWidth: Integer; override;
    procedure SetHeight(Value: Integer); override;
    procedure SetTransparent(Value: Boolean); override;
    procedure SetWidth(Value: Integer);override;

  public
    procedure Assign(Source: TPersistent); override;
    procedure LoadFromStream(Stream: TStream); override;
    procedure SaveToStream(Stream: TStream); override;
    constructor Create; override;
    destructor Destroy; override;
    function ToBitmap: TBitmap;
  end;

implementation

{ TWebpImage }


procedure TWebpImage.DecodeFromStream(Str: TStream);
var
  Data    : array of Byte;
  DataSize: NativeUInt;
  Pixels  : PByte;
  W, H    : Integer;
begin
  DataSize := NativeUInt(Str.Size - Str.Position);
  if DataSize = 0 then
    raise EInvalidGraphic.Create('WebP: empty stream');

  SetLength(Data, DataSize);
  Str.ReadBuffer(Data[0], DataSize);

  Pixels := WebPDecodeBGRA(@Data[0], DataSize, W, H);
  if Pixels = nil then
    raise EInvalidGraphic.Create('WebP decode failed');
  try
    FBmp := Bitmap_Every(Pixels, W, H);
  finally
    FreeMem(Pixels);
  end;
end;

procedure TWebpImage.Draw(ACanvas: TCanvas; const Rect: TRect);
begin
  ACanvas.StretchDraw(Rect, FBmp);
end;

function TWebpImage.GetHeight: Integer;
begin
  Result := FBmp.Height;
end;

function TWebpImage.GetTransparent: Boolean;
begin
  Result := False;
end;

function TWebpImage.GetWidth: Integer;
begin
  Result := FBmp.Width;
end;

procedure TWebpImage.SetHeight(Value: Integer);
begin
  FBmp.Height := Value;
end;

procedure TWebpImage.SetTransparent(Value: Boolean);
begin
  //
end;

procedure TWebpImage.SetWidth(Value: Integer);
begin
  FBmp.Width := Value;
end;

procedure TWebpImage.Assign(Source: TPersistent);
var Src: TGraphic;
begin
  if source is tgraphic then begin
    Src := Source as TGraphic;
    FBmp.SetSize(Src.Width, Src.Height);
    FBmp.Canvas.Draw(0,0, Src);
  end;
end;

procedure TWebpImage.LoadFromStream(Stream: TStream);
begin
  DecodeFromStream(Stream);
end;

procedure TWebpImage.EncodeToStream(Str: TStream; IsLossless: Boolean = False;
                                    CompressionLevel: Integer = 75);
var
  W, H, y, q: Integer;
  buf: PByte;                 // contiguous BGRA pixel buffer
  rowBytes: Integer;
  encData: PByte;
  encSize: Integer;
  ok: Boolean;
begin
  if (FBmp = nil) or (FBmp.Width <= 0) or (FBmp.Height <= 0) then
    raise EInvalidGraphic.Create('WebP encode: empty bitmap');

  // Ensure a known 32-bit (B,G,R,A) layout for ScanLine.
  FBmp.PixelFormat := pf32bit;
  W := FBmp.Width;
  H := FBmp.Height;
  rowBytes := W * 4;

  // Copy ScanLine rows into a contiguous top-down BGRA buffer (ScanLine rows
  // are not guaranteed contiguous, and the DIB may be bottom-up).
  GetMem(buf, rowBytes * H);
  try
    for y := 0 to H - 1 do
      Move(FBmp.ScanLine[y]^, (buf + y * rowBytes)^, rowBytes);

    encData := nil; encSize := 0;
    if IsLossless then
      // VP8L lossless — preserves the alpha channel of the bitmap.
      ok := WebPEncodeLosslessBGRA(buf, W, H, rowBytes, encData, encSize)
    else
    begin
      // VP8 lossy. CompressionLevel is used as the quality (0..100).
      q := CompressionLevel;
      if q < 0   then q := 0;
      if q > 100 then q := 100;
      ok := WebPEncodeBGRA(buf, W, H, rowBytes, q, encData, encSize);
    end;

    if (not ok) or (encData = nil) or (encSize <= 0) then
      raise EInvalidGraphic.Create('WebP encode failed');
    try
      Str.WriteBuffer(encData^, encSize);
    finally
      FreeMem(encData);
    end;
  finally
    FreeMem(buf);
  end;
end;

procedure TWebpImage.SaveToStream(Stream: TStream);
begin
  // Default: lossy, quality 75. Use EncodeToStream for explicit control.
  EncodeToStream(Stream, False, 75);
end;

constructor TWebpImage.Create;
begin
  inherited Create;

  FBmp := TBitmap.Create;
  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(1,1);
end;

destructor TWebpImage.Destroy;
begin
  FBmp.Free;
  inherited Destroy;
end;

function TWebpImage.ToBitmap: TBitmap;
begin
  Result := FBmp;
end;

initialization
  TPicture.RegisterFileFormat('WebP','WebP Image', TWebPImage);

finalization
  TPicture.UnregisterGraphicClass(TWebpImage);

end.
