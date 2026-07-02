unit XelAnimate;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Visual component that plays WebP, APNG/PNG and GIF animations //
// Version:	0.2                                                           //
// Date:	25-JUN-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// Drop a TXelAnimate on a form, set FileName (or call LoadFromFile /          //
// LoadFromStream at run time) and it auto-detects the format (WebP, animated //
// PNG/APNG or GIF), decodes it and plays the animation, honouring per-frame  //
// durations and the loop count.                                              //
//                                                                            //
//   Animation1.LoadFromFile('anim.webp');   // AutoPlay starts it            //
//   Animation1.LoadFromFile('anim.png');    // APNG                          //
//   Animation1.LoadFromFile('anim.gif');    // GIF                           //
//   Animation1.Play;  Animation1.Stop;  Animation1.Pause;                    //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  Classes, SysUtils, Graphics, Controls, ExtCtrls,
  AnimationCommon, WebPAnimated, PngAnimated, GifAnimated;

type
  TAnimFormat = (afUnknown, afWebP, afPng, afGif);

  { TXelAnimate }
  TXelAnimate = class(TGraphicControl)
  private
    FAnim:        TCustomAnimation;
    FTimer:       TTimer;
    FFrameIndex:  Integer;
    FPlaying:     Boolean;
    FAutoPlay:    Boolean;
    FStretch:     Boolean;
    FCenter:      Boolean;
    FLoopsDone:   Integer;
    FFileName:    String;
    FOnFrame:     TNotifyEvent;
    FOnComplete:  TNotifyEvent;
    procedure TimerTick(Sender: TObject);
    procedure SetFileName(const Value: String);
    procedure SetFrameIndex(Value: Integer);
    procedure SetStretch(Value: Boolean);
    procedure SetCenter(Value: Boolean);
    function  GetFrameCount: Integer;
    procedure ScheduleNext;
    procedure SizeToFrame;
    procedure ReplaceDecoder(Fmt: TAnimFormat);
  protected
    procedure Paint; override;
    // Reports the animation's canvas size to the LCL auto-sizing machinery,
    // so that with AutoSize = True the control snaps to the animation.
    procedure CalculatePreferredSize(var PreferredWidth, PreferredHeight: Integer;
      WithThemeSpace: Boolean); override;
    procedure SetAutoSize(Value: Boolean); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;
    procedure LoadFromFile(const AFileName: String);
    procedure LoadFromStream(Stream: TStream);
    procedure Clear;
    procedure Play;       // start / resume playback from the current frame
    procedure Stop;       // stop and rewind to the first frame
    procedure Pause;      // stop where it is
    property Animation:  TCustomAnimation read FAnim;
    property FrameCount: Integer read GetFrameCount;
    property Playing:    Boolean read FPlaying;
    property FrameIndex: Integer read FFrameIndex write SetFrameIndex;
  published
    property FileName:  String  read FFileName  write SetFileName;
    // When True the control resizes itself to the animation's pixel size.
    property AutoSize default True;
    property AutoPlay:  Boolean read FAutoPlay  write FAutoPlay  default True;
    property Stretch:   Boolean read FStretch   write SetStretch default False;
    property Center:    Boolean read FCenter    write SetCenter  default True;
    // Fired after each frame is shown / when one full loop finishes.
    property OnFrame:    TNotifyEvent read FOnFrame    write FOnFrame;
    property OnComplete: TNotifyEvent read FOnComplete write FOnComplete;
    // Standard TControl properties so it behaves on a form.
    property Align;
    property Anchors;
    property BorderSpacing;
    property Enabled;
    property Hint;
    property ShowHint;
    property PopupMenu;
    property Visible;
    property OnClick;
    property OnDblClick;
    property OnMouseDown;
    property OnMouseMove;
    property OnMouseUp;
    property OnResize;
  end;

// Sniff the first bytes of a stream to identify the animation format.
function DetectFormat(Stream: TStream): TAnimFormat;

procedure Register;

implementation

{$R txelanimate_images.res}

const
  DEFAULT_FRAME_MS = 100;   // used when a frame declares 0 ms

function DetectFormat(Stream: TStream): TAnimFormat;
var
  hdr: array[0..11] of Byte;
  n: Integer;
  start: Int64;
begin
  Result := afUnknown;
  start := Stream.Position;
  FillChar(hdr, SizeOf(hdr), 0);
  n := Stream.Read(hdr, SizeOf(hdr));
  Stream.Position := start;
  if n < 8 then Exit;

  // GIF: "GIF87a" / "GIF89a"
  if (hdr[0] = Ord('G')) and (hdr[1] = Ord('I')) and (hdr[2] = Ord('F')) then
    Exit(afGif);
  // PNG / APNG: 89 50 4E 47 0D 0A 1A 0A
  if (hdr[0] = $89) and (hdr[1] = $50) and (hdr[2] = $4E) and (hdr[3] = $47) then
    Exit(afPng);
  // WebP: "RIFF" .... "WEBP"
  if (n >= 12) and (hdr[0] = Ord('R')) and (hdr[1] = Ord('I')) and
     (hdr[2] = Ord('F')) and (hdr[3] = Ord('F')) and
     (hdr[8] = Ord('W')) and (hdr[9] = Ord('E')) and
     (hdr[10] = Ord('B')) and (hdr[11] = Ord('P')) then
    Exit(afWebP);
end;

constructor TXelAnimate.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FAnim       := nil;
  FTimer      := TTimer.Create(Self);
  FTimer.Enabled  := False;
  FTimer.OnTimer  := TimerTick;
  FFrameIndex := 0;
  FPlaying    := False;
  FAutoPlay   := True;
  FStretch    := False;
  FCenter     := True;
  FLoopsDone  := 0;
  AutoSize := True;                    // resize to the animation by default
  SetInitialBounds(0, 0, 100, 100);   // sensible default until something loads
end;

destructor TXelAnimate.Destroy;
begin
  FTimer.Enabled := False;
  FAnim.Free;
  inherited Destroy;
end;

procedure TXelAnimate.ReplaceDecoder(Fmt: TAnimFormat);
begin
  FreeAndNil(FAnim);
  case Fmt of
    afWebP: FAnim := TWebPAnimation.Create;
    afPng:  FAnim := TPngAnimation.Create;
    afGif:  FAnim := TGifAnimation.Create;
  else
    raise EInvalidGraphic.Create('TXelAnimate: unrecognised image format');
  end;
end;

function TXelAnimate.GetFrameCount: Integer;
begin
  if FAnim = nil then Result := 0
  else Result := FAnim.FrameCount;
end;

procedure TXelAnimate.CalculatePreferredSize(var PreferredWidth,
  PreferredHeight: Integer; WithThemeSpace: Boolean);
begin
  inherited CalculatePreferredSize(PreferredWidth, PreferredHeight, WithThemeSpace);
  // Only report a size once an animation is loaded; otherwise keep the
  // current (design-time) bounds.
  if (FAnim <> nil) and (FAnim.Width > 0) and (FAnim.Height > 0) then
  begin
    PreferredWidth  := FAnim.Width;
    PreferredHeight := FAnim.Height;
  end;
end;

procedure TXelAnimate.SetAutoSize(Value: Boolean);
begin
  inherited SetAutoSize(Value);
  if Value then SizeToFrame;
end;

procedure TXelAnimate.SizeToFrame;
begin
  // With AutoSize on, snap the control to the loaded animation's pixel size.
  if AutoSize and (FAnim <> nil) and (FAnim.Width > 0) and (FAnim.Height > 0) then
  begin
    InvalidatePreferredSize;
    SetBounds(Left, Top, FAnim.Width, FAnim.Height);
  end;
end;

procedure TXelAnimate.Clear;
begin
  FTimer.Enabled := False;
  FPlaying    := False;
  FFrameIndex := 0;
  FLoopsDone  := 0;
  FFileName   := '';
  FreeAndNil(FAnim);
  Invalidate;
end;

procedure TXelAnimate.LoadFromStream(Stream: TStream);
begin
  FTimer.Enabled := False;
  ReplaceDecoder(DetectFormat(Stream));
  FAnim.LoadFromStream(Stream);
  FFrameIndex := 0;
  FLoopsDone  := 0;
  FPlaying    := False;
  SizeToFrame;
  Invalidate;
  if FAutoPlay and (FAnim.FrameCount > 1) then
    Play;
end;

procedure TXelAnimate.LoadFromFile(const AFileName: String);
var fs: TFileStream;
begin
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    LoadFromStream(fs);
  finally
    fs.Free;
  end;
  FFileName := AFileName;
end;

procedure TXelAnimate.SetFileName(const Value: String);
begin
  FFileName := Value;
  // Only attempt a real load at run time with an existing file
  if (Value <> '') and (not (csDesigning in ComponentState))
     and FileExists(Value) then
    LoadFromFile(Value);
end;

procedure TXelAnimate.SetFrameIndex(Value: Integer);
begin
  if GetFrameCount = 0 then Exit;
  if Value < 0 then Value := 0;
  if Value > GetFrameCount - 1 then Value := GetFrameCount - 1;
  if Value <> FFrameIndex then
  begin
    FFrameIndex := Value;
    Invalidate;
  end;
end;

procedure TXelAnimate.SetStretch(Value: Boolean);
begin
  if Value <> FStretch then
  begin
    FStretch := Value;
    Invalidate;
  end;
end;

procedure TXelAnimate.SetCenter(Value: Boolean);
begin
  if Value <> FCenter then
  begin
    FCenter := Value;
    Invalidate;
  end;
end;

procedure TXelAnimate.ScheduleNext;
var ms: Integer;
begin
  if GetFrameCount = 0 then Exit;
  ms := FAnim.Durations[FFrameIndex];
  if ms <= 0 then ms := DEFAULT_FRAME_MS;
  FTimer.Interval := ms;
  FTimer.Enabled  := True;
end;

procedure TXelAnimate.Play;
begin
  if GetFrameCount = 0 then Exit;
  if GetFrameCount = 1 then
  begin
    // Single frame: nothing to animate, just show it
    FFrameIndex := 0;
    Invalidate;
    Exit;
  end;
  FPlaying := True;
  Invalidate;
  ScheduleNext;
end;

procedure TXelAnimate.Pause;
begin
  FTimer.Enabled := False;
  FPlaying := False;
end;

procedure TXelAnimate.Stop;
begin
  FTimer.Enabled := False;
  FPlaying    := False;
  FFrameIndex := 0;
  FLoopsDone  := 0;
  Invalidate;
end;

procedure TXelAnimate.TimerTick(Sender: TObject);
begin
  FTimer.Enabled := False;
  if GetFrameCount = 0 then Exit;

  if FFrameIndex >= GetFrameCount - 1 then
  begin
    // Reached the last frame: one loop is complete.
    Inc(FLoopsDone);
    if Assigned(FOnComplete) then FOnComplete(Self);
    // LoopCount = 0 means loop forever; otherwise stop after that many loops.
    if (FAnim.LoopCount > 0) and (FLoopsDone >= FAnim.LoopCount) then
    begin
      FPlaying := False;
      Exit;
    end;
    FFrameIndex := 0;
  end
  else
    Inc(FFrameIndex);

  Invalidate;
  if Assigned(FOnFrame) then FOnFrame(Self);
  ScheduleNext;
end;

procedure TXelAnimate.Paint;
var
  bmp: TBitmap;
  dx, dy: Integer;
  r: TRect;
begin
  if (FAnim <> nil) and (FAnim.FrameCount > 0) and (FFrameIndex < FAnim.FrameCount) then
  begin
    bmp := FAnim.Frames[FFrameIndex];
    if FStretch then
      Canvas.StretchDraw(ClientRect, bmp)
    else
    begin
      if FCenter then
      begin
        dx := (ClientWidth  - bmp.Width)  div 2;
        dy := (ClientHeight - bmp.Height) div 2;
      end
      else
      begin
        dx := 0; dy := 0;
      end;
      Canvas.Draw(dx, dy, bmp);
    end;
  end
  else
  begin
    // Design-time / empty placeholder.
    Canvas.Brush.Color := clBtnFace;
    Canvas.FillRect(ClientRect);
    Canvas.Pen.Color := clGray;
    r := ClientRect;
    Canvas.Rectangle(r);
    Canvas.TextOut(4, 4, 'TXelAnimate');
  end;
end;

procedure Register;
begin
  RegisterComponents('Xelitan', [TXelAnimate]);
end;

end.
